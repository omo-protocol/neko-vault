// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {KellySignLib} from "./KellySignLib.sol";
import {DustFloorLib} from "./DustFloorLib.sol";
import {RitualPrecompiles} from "../../interfaces/ritual/IRitualPrecompiles.sol";
import {SchedulerSetupLib} from "./SchedulerSetupLib.sol";
import {MultiLegSubmitLib} from "./MultiLegSubmitLib.sol";
import {CrossVenueCommandLib} from "../../base/CrossVenueCommandLib.sol";
import {RitualHttpLib} from "./RitualHttpLib.sol";
import {
    Side,
    ExecStatus,
    ExecutionIntent,
    NormalizedExecutionReceipt,
    FundingReceipt,
    CommandReady,
    BaseCommandSubmitted,
    BaseCommandFailed,
    ReserveRefillReady
} from "./SharedVenueTypes.sol";
import {
    MAX_LEGS,
    REF_LEG_SENTINEL,
    ML_VENUE_HL_PERP,
    ML_VENUE_HL_SPOT,
    ML_VENUE_PM,
    MultiLegFundingState,
    MultiLegTradingState,
    LegConfig,
    LegBufferSnapshot,
    LegFill,
    MultiLegCycleRequested,
    MultiLegLegSubmitted,
    MultiLegLegFill,
    MultiLegCycleCompleted,
    MultiLegRecoveryMarked,
    MultiLegFundingStateChanged,
    MultiLegTradingStateChanged,
    MultiLegBufferSnapshotUpdated,
    MultiLegBufferSyncSubmitted,
    MultiLegFundingReceiptIngested,
    MultiLegKellyApplied,
    OffchainKellyWeights,
    ValuationPushed,
    AutoUnwindTriggered,
    LegFailThresholdHit
} from "./MultiLegTypes.sol";

/// @title MultiLegController
/// @notice N-leg cross-venue controller. Legs execute sequentially; each has its own buffer topped
///         up via its own destinationRef. Supports off-chain signed Kelly weight overrides
///         (replay-protected, time-bounded) with a static config fallback. Handles the full
///         lifecycle: initial allocation, incremental opens, unwind → REFILL_RESERVE. Allowed
///         venues: HYPERLIQUID-PERP, HYPERLIQUID-SPOT, POLYMARKET. Clone-safe (EIP-1167).
contract MultiLegController is ReentrancyGuard {

    // ─── Errors ──────────────────────────────────────────────────────────────

    error NotOwner();
    error NotVaultManager();
    error NotSchedulerOrOwner();
    error NotAsyncDelivery();
    error AlreadyInitialized();
    error InvalidAddress();
    error InvalidConfig();
    error InvalidState();
    error InvalidJobId();
    error TooManyLegs();
    error KellyStale();
    error KellyInvalidSignature();
    error KellyNonceReused();
    error SpotRequiresPositiveWeight();
    error UnsupportedVenue();
    error WeightExceedsCap();
    error NotFunderOrManager();

    // ─── Init storage ────────────────────────────────────────────────────────

    bool internal _initialized;
    address public owner;
    address public vaultManager;
    address public baseVault;
    address public baseAsset;
    bytes32 public strategyId;

    // ─── Ritual integration ──────────────────────────────────────────────────

    string public adapterUrl;
    address public executor;
    uint64 public pollIntervalBlocks;
    uint64 public maxPollBlock;
    uint256 public deliveryGasLimit;
    /// @notice Async HTTP precompile TTL (blocks). Settable at runtime so we can tune without redeploying.
    uint256 public httpTtl;
    string[] public secretHeaderKeys;
    string[] public secretHeaderValues;
    /// @notice ECIES-encrypted venue secrets (one blob per secret, encrypted to `executor` pubkey).
    ///         Owner populates via `setSecrets` after deploy. Paired with `_secretSignatures` which
    ///         holds the owner-EOA signatures over each blob's keccak256 hash.
    bytes[] internal _encryptedSecrets;
    bytes[] internal _secretSignatures;

    // ─── Config ──────────────────────────────────────────────────────────────

    LegConfig[MAX_LEGS] public legs;
    uint8 public legCount;
    uint256 public bufferStalenessSeconds;
    uint256 public minCycleNotionalUsd;
    uint256 public maxCycleNotionalUsd;
    uint256 public envelopeTtlSeconds;

    address public kellySigner;
    bool public useKelly;
    /// @notice Dedicated role for posting funding receipts. If zero, only owner/vaultManager can call
    ///         `ingestFundingReceipt`. Operators typically set this to the adapter's Ritual EOA so
    ///         the adapter can autonomously ack top-up settlement.
    address public funder;

    // ─── State ───────────────────────────────────────────────────────────────

    MultiLegFundingState public fundingState;
    MultiLegTradingState public tradingState;

    uint64 public nextCycleSeq;
    bytes32 public currentCycleId;
    uint256 public currentCycleTargetUsd;
    uint8 public currentLegIndex;

    LegFill[MAX_LEGS] public currentCycleFills;

    /// @dev Partial-unwind override targets per leg. ONLY applied when `_currentCycleIsUnwind`
    ///      is true (so target=0 for a full unwind is a valid override, not "unset"). Reset at
    ///      cycle completion.
    uint256[MAX_LEGS] internal _unwindTargetOverrideUsd;
    /// @dev True during cycles started via `requestPartialUnwind`. Gates the override-target
    ///      path in `_legNotional` and the REFILL_RESERVE emission at cycle completion.
    bool internal _currentCycleIsUnwind;
    /// @dev Total USD expected to be realized by the current unwind cycle. Computed at
    ///      `requestPartialUnwind` time as `r × NAV`. Consumed by the cycle-complete path
    ///      to emit a REFILL_RESERVE command on Base so the module credits the sleeve.
    uint256 internal _unwindShortfallUsd;

    /// @dev Block number when the current pending async job started. Used by tick() to detect
    ///      stuck LEG_PENDING / VALUATION_PENDING / UNWIND_PENDING states and auto-reset after
    ///      `maxPendingBlocks` without requiring manual pauseTrading/unpauseTrading intervention.
    uint256 public pendingSinceBlock;
    uint256 public maxPendingBlocks; // 0 = disable auto-recovery

    /// @notice If non-zero, `tick()` auto-triggers a partial unwind sized to refill Base reserve
    ///         whenever the most recent valuation reports `lastBaseReserveUsd < minBaseReserveUsd`.
    ///         Operator-set; 0 disables (manual-only).
    uint256 public minBaseReserveUsd;

    /// @dev Auto-clear counter for LEG_FAILED. Incremented on each auto-clear, reset on any
    ///      successful leg fill. If it exceeds `legFailThreshold` (operator-set), tick() stops
    ///      auto-clearing and emits `LegFailThresholdHit` so operator intervenes.
    uint256 public legFailCount;
    uint256 public legFailThreshold; // 0 = unlimited retries

    /// @notice Minimum notional per HL leg order (micro-USD). HL's venue-side floor is ~$10
    ///         notional per order; submitting below that gets rejected. Applies to HL_PERP +
    ///         HL_SPOT venues only — PM legs bypass this check (PM's floor is per-share, not USD).
    ///         Set to 0 to disable. Check runs in `_submitLeg`; on a ref-leg below-floor the
    ///         cycle aborts cleanly (no orders placed). On a hedge-leg below-floor mid-cycle the
    ///         state goes to UNHEDGED so operator can unwind the already-filled reference leg.
    uint256 public minHlNotionalUsd;

    /// @notice Dust floors expressed in bps of *deployable* capital (`lastNavUsd - lastBaseReserveUsd`).
    ///         Below `deployable × floor / 10_000`, the controller skips the action entirely.
    ///         Relative so the vault behaves the same whether TVL is $17 or $17M. Before the first
    ///         valuation (deployable=0) floors evaluate to 0 and don't gate anything. Set any field
    ///         to 0 to disable the respective gate.
    uint256 public minTopupBps;          // skip TOPUP_* if amount < deployable × bps / 10000
    uint256 public minRefillBps;         // skip REFILL_RESERVE if realized < deployable × bps / 10000
    uint256 public minRebalanceBps;      // skip drift-rebalance if drift < deployable × bps / 10000

    bytes32 public pendingLegJobId;
    bytes32 public pendingBufferSyncJobId;
    bytes32 public pendingValuationJobId;
    bytes32 public pendingBaseCommandJobId;
    bytes32 public lastSubmittedCommandNonce;
    bytes32 public reserveDestinationRef;

    uint256 public tickScheduleId;
    uint256 public valuationScheduleId;

    /// @dev Deferred async-submit queue. Callbacks can't nest a new 0x0805 precompile call
    ///      (Ritual enforces "one per tx"), so they set a kind+data pair here and the next
    ///      `tick()` dispatches. Kinds:
    ///        0 = none
    ///        1 = top-up for leg at data (data = legIndex in low byte)
    ///        2 = submit next leg (data = legIndex)
    ///        3 = submit valuation sync after all legs filled
    uint8 internal _deferredKind;
    uint256 internal _deferredData;

    /// @notice Last Base-side NAV + reserve reported by the valuation-sync callback.
    uint256 public lastNavUsd;
    uint256 public lastBaseReserveUsd;
    uint256 public lastValuationTimestamp;

    LegBufferSnapshot[MAX_LEGS] public bufferSnapshots;

    /// @notice Latest on-chain Kelly target. Pushed by `submitKellyWeights`; consumed by
    ///         `_effectiveWeight` + `_effectiveCycleNotional` while fresh. When expired or
    ///         absent, controller falls back to static `legs[i].weightBps`.
    OffchainKellyWeights public latestKelly;
    mapping(bytes32 => bool) public usedKellyNonces;

    // Funding in-flight — tracks which leg and how much
    uint8 public pendingTopUpLegIndex;
    bytes32 public pendingTopUpCycle;
    uint256 public pendingTopUpAmount;

    // ─── Modifiers ───────────────────────────────────────────────────────────

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyVaultManager() {
        if (msg.sender != owner && msg.sender != vaultManager) revert NotVaultManager();
        _;
    }

    modifier onlyAsyncDelivery() {
        if (msg.sender != RitualPrecompiles.ASYNC_DELIVERY) revert NotAsyncDelivery();
        _;
    }

    modifier onlySchedulerOrOwner() {
        if (msg.sender != RitualPrecompiles.SCHEDULER && msg.sender != owner && msg.sender != vaultManager) {
            revert NotSchedulerOrOwner();
        }
        _;
    }

    // ─── Sentinel constructor (EIP-1167 template) ────────────────────────────

    constructor() {
        _initialized = true;
    }

    receive() external payable {}

    // ─── Init ────────────────────────────────────────────────────────────────

    struct InitParams {
        address owner;
        address vaultManager;
        address baseVault;
        address baseAsset;
        bytes32 strategyId;
        string adapterUrl;
        address executor;
        LegConfig[] legs;
        uint256 bufferStalenessSeconds;
        uint256 minCycleNotionalUsd;
        uint256 maxCycleNotionalUsd;
        uint256 envelopeTtlSeconds;
        address kellySigner; // address(0) disables Kelly; falls back to static weights
        bytes32 reserveDestinationRef; // where refill-reserve envelope routes on Base
    }

    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        if (p.owner == address(0) || p.baseVault == address(0) || p.baseAsset == address(0)) revert InvalidAddress();
        if (p.legs.length == 0 || p.legs.length > MAX_LEGS) revert TooManyLegs();
        if (p.minCycleNotionalUsd == 0 || p.maxCycleNotionalUsd < p.minCycleNotionalUsd) revert InvalidConfig();
        if (p.envelopeTtlSeconds == 0 || p.bufferStalenessSeconds == 0) revert InvalidConfig();
        _initialized = true;

        owner = p.owner;
        vaultManager = p.vaultManager == address(0) ? p.owner : p.vaultManager;
        baseVault = p.baseVault;
        baseAsset = p.baseAsset;
        strategyId = p.strategyId;

        adapterUrl = p.adapterUrl;
        executor = p.executor;
        pollIntervalBlocks = 25;
        maxPollBlock = 4500;
        deliveryGasLimit = 300_000;
        httpTtl = 200; // default; tune via setHttpConfig

        legCount = uint8(p.legs.length);
        bool anyReference = false;
        for (uint8 i; i < p.legs.length; i++) {
            _validateLeg(p.legs[i]);
            legs[i] = p.legs[i];
            if (p.legs[i].referenceLegIndex == REF_LEG_SENTINEL) {
                anyReference = true;
            } else {
                // Hedge leg must reference a lower-index leg (DAG; prevents circular deps and
                // guarantees the reference has filled by the time this leg sizes off it).
                if (p.legs[i].referenceLegIndex >= i) revert InvalidConfig();
            }
        }
        // At least one leg must be a reference — otherwise there's nothing to size hedges against.
        if (!anyReference) revert InvalidConfig();

        bufferStalenessSeconds = p.bufferStalenessSeconds;
        minCycleNotionalUsd = p.minCycleNotionalUsd;
        maxCycleNotionalUsd = p.maxCycleNotionalUsd;
        envelopeTtlSeconds = p.envelopeTtlSeconds;

        kellySigner = p.kellySigner;
        useKelly = p.kellySigner != address(0);
        reserveDestinationRef = p.reserveDestinationRef;

        fundingState = MultiLegFundingState.STALE;
        tradingState = MultiLegTradingState.IDLE;
        nextCycleSeq = 1;
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    /// @notice Bundled setter for `executor` + `adapterUrl` + `funder` + `kellySigner`.
    ///         Pass empty / zero to leave unchanged.
    function setIntegrationRefs(address e, string calldata u, address f, address k) external onlyOwner {
        if (e != address(0)) executor = e;
        if (bytes(u).length > 0) adapterUrl = u;
        if (f != address(0)) funder = f;
        if (k != address(0)) {
            kellySigner = k;
            useKelly = true;
        }
    }

    /// @notice Tune all HTTP async-precompile parameters. Pass 0 to leave unchanged.
    function setHttpConfig(uint64 pi, uint64 mpb, uint256 dgl, uint256 ttl) external onlyOwner {
        if (pi > 0) pollIntervalBlocks = pi;
        if (mpb > 0) maxPollBlock = mpb;
        if (dgl > 0) deliveryGasLimit = dgl;
        if (ttl > 0) httpTtl = ttl;
    }

    /// @notice Deposit msg.value into RitualWallet (credited to this clone) and register `tick` +
    ///         `syncValuation` recurring schedules. Scheduler constraint: numCalls × frequency
    ///         ≤ 10_000 blocks (~58 min) per batch. For longer autonomy, re-invoke to register
    ///         fresh schedules — harmless overlap with old one (old schedule finishes naturally).
    function fundAndSchedule(
        uint32 tickFreq,
        uint32 valuationFreq,
        uint32 tickNumCalls,
        uint32 valuationNumCalls,
        uint32 gasLimit,
        uint256 maxFeePerGas,
        uint32 lockDurationBlocks
    ) external payable onlyOwner {
        (tickScheduleId, valuationScheduleId) = SchedulerSetupLib.fundAndScheduleBoth(
            this.tick.selector,
            this.syncValuation.selector,
            tickFreq,
            valuationFreq,
            tickNumCalls,
            valuationNumCalls,
            gasLimit,
            maxFeePerGas,
            lockDurationBlocks,
            msg.value
        );
    }


    /// @notice Replace stored ECIES-encrypted venue secrets + owner-signatures + TEE header map
    ///         in a single call. Bundled to stay under EIP-170. After calling, also invoke
    ///         `SecretsAccessControl.grantAccess(thisClone, secretsHash, ...)` on Ritual so the
    ///         executor will accept requests routed through this clone.
    function setSecrets(bytes[] calldata blobs, bytes[] calldata sigs) external onlyOwner {
        if (blobs.length != sigs.length) revert InvalidConfig();
        delete _encryptedSecrets;
        delete _secretSignatures;
        for (uint256 i; i < blobs.length; i++) {
            _encryptedSecrets.push(blobs[i]);
            _secretSignatures.push(sigs[i]);
        }
    }

    // getSecrets removed — operator re-runs bootstrapClone to refresh if needed (reads blobs
    // from `_encryptedSecrets` via storage slot if truly required). Dropped for size budget.


    function setSecretHeaders(string[] calldata keys, string[] calldata values) external onlyOwner {
        if (keys.length != values.length) revert InvalidConfig();
        delete secretHeaderKeys;
        delete secretHeaderValues;
        for (uint256 i; i < keys.length; i++) {
            secretHeaderKeys.push(keys[i]);
            secretHeaderValues.push(values[i]);
        }
    }

    function setLegConfig(uint8 index, LegConfig calldata cfg) external onlyOwner {
        if (index >= legCount) revert InvalidConfig();
        // Only mutate LegConfig while idle — changing venue/market/weights mid-cycle could corrupt
        // `currentCycleFills[]` accounting and leave stale positions untracked.
        if (tradingState != MultiLegTradingState.IDLE) revert InvalidState();
        _validateLeg(cfg);
        legs[index] = cfg;
    }

    /// @notice MultiLeg supports exactly three venue types. Spot requires a positive weight
    ///         (you must hold the asset before you can sell it). If `maxAbsWeightBps > 0`,
    ///         `|weightBps|` must not exceed it — the same cap is later enforced on Kelly overrides.
    function _validateLeg(LegConfig memory cfg) internal pure {
        if (cfg.venue != ML_VENUE_HL_PERP && cfg.venue != ML_VENUE_HL_SPOT && cfg.venue != ML_VENUE_PM) {
            revert UnsupportedVenue();
        }
        if (cfg.venue == ML_VENUE_HL_SPOT && cfg.weightBps <= 0) revert SpotRequiresPositiveWeight();
        if (cfg.maxAbsWeightBps > 0) {
            uint16 absW = cfg.weightBps < 0 ? uint16(-cfg.weightBps) : uint16(cfg.weightBps);
            if (absW > cfg.maxAbsWeightBps) revert WeightExceedsCap();
        }
        // Hedge legs must have a non-zero beta (0 would mean "don't hedge", which is the same as
        // not declaring a hedge leg at all — config error). Reference legs (sentinel) ignore beta.
        if (cfg.referenceLegIndex != REF_LEG_SENTINEL && cfg.betaBps == 0) revert InvalidConfig();
    }

    /// @notice Bundled ops-config setter to stay under EIP-170. Pass 0 to leave any field
    ///         unchanged. Ritual `block.timestamp` is MILLISECONDS so `bufferStalenessMs`
    ///         is ms (e.g. `3_600_000` = 1h). `minCycleUsd`/`maxCycleUsd` validated as pair
    ///         (must be non-zero with max≥min, or both zero to leave alone).
    function setOpsConfig(
        uint256 minCycleUsd,
        uint256 maxCycleUsd,
        uint256 bufferStalenessMs,
        uint256 maxPendingB,
        uint256 minBaseReserve,
        uint256 legFailThresh
    ) external onlyOwner {
        if (minCycleUsd > 0 || maxCycleUsd > 0) {
            if (minCycleUsd == 0 || maxCycleUsd < minCycleUsd) revert InvalidConfig();
            minCycleNotionalUsd = minCycleUsd;
            maxCycleNotionalUsd = maxCycleUsd;
        }
        if (bufferStalenessMs > 0) bufferStalenessSeconds = bufferStalenessMs;
        // `0` is a valid value for the last three (disables the respective gate), so we can't
        // gate on non-zero. Caller must be explicit — pass the current value to keep it.
        maxPendingBlocks = maxPendingB;
        minBaseReserveUsd = minBaseReserve;
        legFailThreshold = legFailThresh;
    }

    /// @notice Combined guard setter: three dust floors (bps of deployable) + HL venue-min
    ///         notional (micro-USD). HL rejects orders below ~$10 notional so we set this
    ///         floor to 10_000_000 = $10. Pass 0 for any field to disable its gate.
    function setDustFloorsBps(uint256 topupBps, uint256 refillBps, uint256 rebalanceBps, uint256 hlMinNotional)
        external
        onlyOwner
    {
        minTopupBps = topupBps;
        minRefillBps = refillBps;
        minRebalanceBps = rebalanceBps;
        minHlNotionalUsd = hlMinNotional;
    }

    /// @notice Current signed USD notional of leg `legIndex`'s fill (from `currentCycleFills`,
    ///         set after each leg completes). Used by `requestPartialUnwind` to size the scaled
    ///         targets. Zero if no cycle has filled this leg yet.
    function currentPositionUsd(uint8 legIndex) internal view returns (uint256) {
        return currentCycleFills[legIndex].filledNotionalUsd;
    }

    /// @dev Effective hedge ratio w for leg `legIndex` = hedge_notional / (|β| × ref_notional).
    ///      Returns 0 for reference legs. In bps scale (10000 = 1.0).
    function _effectiveW(uint8 legIndex) internal view returns (uint256) {
        LegConfig memory cfg = legs[legIndex];
        if (cfg.referenceLegIndex == REF_LEG_SENTINEL) return 0;
        uint256 refFill = currentCycleFills[cfg.referenceLegIndex].filledNotionalUsd;
        if (refFill == 0) return 0;
        uint256 hedge = currentCycleFills[legIndex].filledNotionalUsd;
        int16 b = cfg.betaBps;
        uint256 absBeta = b < 0 ? uint256(uint16(-b)) : uint256(uint16(b));
        if (absBeta == 0) return 0;
        return (hedge * 10_000 * 10_000) / (refFill * absBeta);
    }

    /// @notice Sum of absolute drift in USD across all hedge legs whose `|w_effective − w_target|`
    ///         exceeds their `driftToleranceBps`. Zero if no leg is outside tolerance.
    ///         `tick()` gates the auto-rebalance on `driftUsd >= minRebalanceUsd` so we don't pay
    ///         bridge/CCTP/gas fees on dust-scale hedge drift.
    function _driftDetected() internal view returns (uint256 driftUsd) {
        for (uint8 i; i < legCount; i++) {
            LegConfig memory cfg = legs[i];
            if (cfg.referenceLegIndex == REF_LEG_SENTINEL) continue;
            if (cfg.driftToleranceBps == 0) continue;
            uint256 wEff = _effectiveW(i);
            if (wEff == 0) continue; // no fills yet, nothing to drift from
            uint256 wTarget = _absWeight(i);
            uint256 delta = wEff > wTarget ? wEff - wTarget : wTarget - wEff;
            if (delta > cfg.driftToleranceBps) {
                // USD drift on this hedge = delta_bps × |β|_bps × refFillUsd / (10000 × 10000).
                uint256 refFill = currentCycleFills[cfg.referenceLegIndex].filledNotionalUsd;
                int16 b = cfg.betaBps;
                uint256 absBeta = b < 0 ? uint256(uint16(-b)) : uint256(uint16(b));
                driftUsd += (delta * absBeta * refFill) / (10_000 * 10_000);
            }
        }
    }

    function pauseTrading() external onlyVaultManager {
        _setTradingState(MultiLegTradingState.PAUSED);
    }

    function unpauseTrading() external onlyVaultManager {
        if (tradingState != MultiLegTradingState.PAUSED) revert InvalidState();
        _setTradingState(MultiLegTradingState.IDLE);
    }

    function pauseFunding() external onlyVaultManager {
        _setFundingState(MultiLegFundingState.PAUSED);
    }

    function unpauseFunding() external onlyVaultManager {
        if (fundingState != MultiLegFundingState.PAUSED) revert InvalidState();
        _setFundingState(MultiLegFundingState.STALE);
    }

    /// @notice Admin escape hatch: clear frozen pending job IDs when the TEE adapter fails to
    ///         deliver and the Long-Running HTTP TTL elapsed without a callback. Each boolean
    ///         wipes the corresponding pending ID, letting the next scheduler tick retry.
    ///         Does NOT reset trading/funding state — use `clearRecovery` / `unpauseTrading`
    ///         separately if needed.
    function forceClearPending(
        bool leg,
        bool bufferSync,
        bool valuation,
        bool baseCommand
    ) external onlyVaultManager {
        if (leg) pendingLegJobId = bytes32(0);
        if (bufferSync) pendingBufferSyncJobId = bytes32(0);
        if (valuation) pendingValuationJobId = bytes32(0);
        if (baseCommand) pendingBaseCommandJobId = bytes32(0);
    }

    /// @notice Clear a recoverable failure state to IDLE. Only `LEG_FAILED` (first-leg failed,
    ///         no venue positions were opened) and `RECOVERY_REQUIRED` (generic) are clearable
    ///         directly. `UNHEDGED` has open venue positions that MUST be closed via
    ///         `requestUnwind` first — clearing without unwind would desync on-chain fill records
    ///         from the venue state and let the next cycle double-up exposure.
    function clearRecovery() external onlyVaultManager {
        if (tradingState != MultiLegTradingState.RECOVERY_REQUIRED && tradingState != MultiLegTradingState.LEG_FAILED)
        {
            revert InvalidState();
        }
        _setTradingState(MultiLegTradingState.IDLE);
    }

    /// @notice Partial withdrawal — shrink every leg by the same ratio `r = shortfallUsd / NAV`.
    ///         Preserves the current hedge ratio w_effective on each LegGroup (framework
    ///         INVARIANT 1). For each leg: newTarget = (1 − r) × current. Calls `_submitLeg(0)`
    ///         and the existing leg-chain delivers the scaled rebalance through the delta logic.
    ///         `shortfallUsd == current NAV` is a full unwind (each leg targets 0).
    function requestPartialUnwind(uint256 shortfallUsd) external nonReentrant onlyVaultManager {
        _internalPartialUnwind(shortfallUsd);
    }

    /// @dev Internal partial-unwind driver. Shared between operator-invoked
    ///      `requestPartialUnwind` and the auto-trigger path in `tick()` (low-reserve).
    ///      Returns the new cycleId so the caller can emit AutoUnwindTriggered against it.
    function _internalPartialUnwind(uint256 shortfallUsd) internal returns (bytes32 cid) {
        if (tradingState != MultiLegTradingState.IDLE && tradingState != MultiLegTradingState.READY) {
            revert InvalidState();
        }
        if (shortfallUsd == 0) revert InvalidConfig();
        uint256 nav = lastNavUsd;
        if (nav == 0) revert InvalidState();
        uint256 cappedShortfall = shortfallUsd > nav ? nav : shortfallUsd;
        uint256 rBps = (cappedShortfall * 10_000) / nav;
        if (rBps > 10_000) rBps = 10_000;

        cid = _newCycleId();
        currentCycleId = cid;
        currentLegIndex = 0;
        _currentCycleIsUnwind = true;
        _unwindShortfallUsd = cappedShortfall;
        for (uint8 i; i < legCount; i++) {
            uint256 currentNotional = currentPositionUsd(i);
            _unwindTargetOverrideUsd[i] = (currentNotional * (10_000 - rBps)) / 10_000;
            delete currentCycleFills[i];
        }
        emit MultiLegCycleRequested(cid, cappedShortfall, legCount);
        _submitLeg(0);
    }

    // [removed] requestUnwind + /unwind protocol: superseded by `requestPartialUnwind` which
    // uses the same `/leg/execute` delta-rebalance path to shrink positions (r=1 = full close).

    /// @notice Off-chain Kelly push — signer posts a signed target weight vector + total notional.
    ///         Verified here, cached in `latestKelly`, consumed by `_effectiveWeight` and
    ///         `_effectiveCycleNotional` while fresh. Replay-protected via `nonce`; freshness via
    ///         `validUntil`. Operator clamps via each leg's `maxAbsWeightBps`.
    function submitKellyWeights(OffchainKellyWeights calldata w, bytes calldata signature) external {
        if (!useKelly) revert InvalidState();
        if (w.validUntil < block.timestamp) revert KellyStale();
        if (usedKellyNonces[w.nonce]) revert KellyNonceReused();
        address signer = KellySignLib.recoverSigner(strategyId, address(this), w, signature);
        if (signer != kellySigner) revert KellyInvalidSignature();
        usedKellyNonces[w.nonce] = true;
        latestKelly = w;
        emit MultiLegKellyApplied(w.nonce, w.totalTargetNotional, w.validUntil);
    }

    // ─── Scheduler entrypoints ───────────────────────────────────────────────

    function tick(uint256 /* executionIndex */) external nonReentrant onlySchedulerOrOwner {
        // Auto-recovery: if any pending job has been in flight longer than `maxPendingBlocks`
        // (AsyncDelivery presumably dropped the callback), clear it and reset tradingState so
        // the next tick can make progress. Prevents ops having to manually pause/unpause.
        _autoRecoverIfStuck();

        if (tradingState == MultiLegTradingState.PAUSED || fundingState == MultiLegFundingState.PAUSED) return;
        if (
            tradingState == MultiLegTradingState.RECOVERY_REQUIRED || tradingState == MultiLegTradingState.UNHEDGED
        ) return;
        // LEG_FAILED: auto-clear so next cycle can retry. Capped by `legFailThreshold` so
        // repeated failures don't silently burn Ritual gas; past the cap, stay LEG_FAILED and
        // let the operator intervene.
        if (tradingState == MultiLegTradingState.LEG_FAILED) {
            legFailCount += 1;
            if (legFailThreshold > 0 && legFailCount > legFailThreshold) {
                emit LegFailThresholdHit(legFailCount);
                return; // stay LEG_FAILED; operator must call clearRecovery()
            }
            _setTradingState(MultiLegTradingState.IDLE);
        }
        // If an unwind is already in flight, the valuation-sync + REFILL_RESERVE will follow via callback.
        if (tradingState == MultiLegTradingState.UNWIND_PENDING) return;

        // Process any deferred async submit queued by a prior callback (callbacks can't nest
        // 0x0805 precompile calls — Ritual enforces one per tx). Returns early if dispatched.
        if (_dispatchDeferred()) return;

        if (_anyBufferStale()) {
            if (pendingBufferSyncJobId == bytes32(0)) _submitBufferSync();
            return;
        }

        if (fundingState == MultiLegFundingState.TOPUP_PENDING) return;

        // Auto-unwind-on-low-reserve: if valuation reports Base reserve below the operator's
        // min, shrink venue positions proportionally to refill. Uses `requestPartialUnwind`
        // internally so the framework invariants (hedge ratio preserved) hold.
        if (
            minBaseReserveUsd > 0 && lastValuationTimestamp > 0 && lastBaseReserveUsd < minBaseReserveUsd
                && (tradingState == MultiLegTradingState.IDLE || tradingState == MultiLegTradingState.READY)
                && lastNavUsd > 0
        ) {
            uint256 shortfall = minBaseReserveUsd - lastBaseReserveUsd;
            bytes32 cid = _internalPartialUnwind(shortfall);
            emit AutoUnwindTriggered(cid, lastBaseReserveUsd, shortfall);
            return;
        }

        if (_tryEmitTopUp()) return;

        // Drift-rebalance: if any hedge leg's effective `w` has drifted outside its tolerance
        // due to price moves, kick off a rebalance cycle. Framework INVARIANT 1. Dust floor is
        // bps of deployable capital; min=0 still triggers on any detected drift.
        if (tradingState == MultiLegTradingState.IDLE || tradingState == MultiLegTradingState.READY) {
            uint256 driftUsd = _driftDetected();
            uint256 rebalanceFloor = DustFloorLib.floorUsd(lastNavUsd, lastBaseReserveUsd, minRebalanceBps);
            if (driftUsd > 0 && driftUsd >= rebalanceFloor) {
                _tryStartCycle();
                return;
            }
        }

        if (tradingState == MultiLegTradingState.IDLE) _tryStartCycle();
    }

    /// @dev Clear pending-async stale state after `maxPendingBlocks` blocks, resetting
    ///      tradingState to IDLE so the next tick can progress. No-op if maxPendingBlocks=0.
    function _autoRecoverIfStuck() internal {
        if (maxPendingBlocks == 0) return;
        bool anyPending = pendingLegJobId != bytes32(0) || pendingValuationJobId != bytes32(0)
            || pendingBaseCommandJobId != bytes32(0) || pendingBufferSyncJobId != bytes32(0);
        if (!anyPending) {
            pendingSinceBlock = 0;
            return;
        }
        if (pendingSinceBlock == 0) {
            pendingSinceBlock = block.number;
            return;
        }
        if (block.number - pendingSinceBlock <= maxPendingBlocks) return;
        pendingLegJobId = bytes32(0);
        pendingValuationJobId = bytes32(0);
        pendingBaseCommandJobId = bytes32(0);
        pendingBufferSyncJobId = bytes32(0);
        pendingSinceBlock = 0;
        if (
            tradingState == MultiLegTradingState.LEG_PENDING
                || tradingState == MultiLegTradingState.VALUATION_PENDING
        ) {
            _setTradingState(MultiLegTradingState.IDLE);
        }
    }

    function syncValuation(uint256 /* executionIndex */) external nonReentrant onlySchedulerOrOwner {
        if (tradingState == MultiLegTradingState.LEG_PENDING) return;
        if (pendingValuationJobId != bytes32(0)) return;
        _submitValuationSync();
    }

    function requestCycle() external nonReentrant onlyVaultManager {
        if (tradingState != MultiLegTradingState.IDLE) revert InvalidState();
        if (_anyBufferStale()) revert InvalidState();
        _tryStartCycle();
    }

    // ─── Callbacks ───────────────────────────────────────────────────────────

    function onBufferSyncResult(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        // NOTE: AsyncDelivery passes the Phase 1 origin tx hash as jobId — NOT the controller-
        // computed job id we stored in `pendingBufferSyncJobId`. `onlyAsyncDelivery` is the
        // authoritative auth check; don't gate on jobId equality.
        if (pendingBufferSyncJobId == bytes32(0)) return;
        pendingBufferSyncJobId = bytes32(0);

        (uint16 statusCode, bytes memory body, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) {
            _setFundingState(MultiLegFundingState.STALE);
            return;
        }

        LegBufferSnapshot[] memory snaps = abi.decode(body, (LegBufferSnapshot[]));
        uint8 count = legCount;
        uint256 len = snaps.length < count ? snaps.length : count;
        for (uint8 i; i < len; i++) {
            bufferSnapshots[i] = snaps[i];
            emit MultiLegBufferSnapshotUpdated(i, snaps[i].bufferUsd, snaps[i].timestamp);
        }

        if (fundingState == MultiLegFundingState.STALE) _setFundingState(MultiLegFundingState.OK);
        // Queue a top-up for next tick() if any leg is below min. Can't submit here (Ritual:
        // one 0x0805 per tx).
        for (uint8 i; i < legCount; i++) {
            if (bufferSnapshots[i].bufferUsd < legs[i].bufferMinUsd) {
                _deferredKind = 1;
                _deferredData = i;
                break;
            }
        }
    }

    function onLegResult(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        // Silent no-op guards: reverting here causes Ritual's AsyncDelivery to interpret the
        // delivery as failed and re-poke the precompile, which re-POSTs the same /leg/execute
        // to the adapter. Every duplicate POST places another order on the venue, draining
        // margin. Idempotency lives here: if the expected pending state is gone (already
        // processed, or FSM moved on), we just return — leaving the adapter stateless.
        if (tradingState != MultiLegTradingState.LEG_PENDING) return;
        if (pendingLegJobId == bytes32(0)) return;
        pendingLegJobId = bytes32(0);

        NormalizedExecutionReceipt memory r = _decodeReceipt(result);
        uint8 idx = currentLegIndex;
        currentCycleFills[idx] = LegFill({
            status: r.status,
            filledNotionalUsd: r.filledNotionalUsd,
            avgPriceE18: r.avgPriceE18,
            externalOrderId: r.externalOrderId
        });
        emit MultiLegLegFill(currentCycleId, idx, r.status, r.filledNotionalUsd);

        bool filled = r.status == ExecStatus.Filled || r.status == ExecStatus.PartialFill;
        if (!filled || r.filledNotionalUsd == 0) {
            // Failure policy: first-leg failure → LEG_FAILED (safe abort, no partial exposure).
            // Later-leg failure → UNHEDGED (operator action: close prior fills or retry).
            if (idx == 0) {
                _setTradingState(MultiLegTradingState.LEG_FAILED);
                emit MultiLegRecoveryMarked(currentCycleId, idx, "first leg failed; no legs opened");
            } else {
                _setTradingState(MultiLegTradingState.UNHEDGED);
                emit MultiLegRecoveryMarked(currentCycleId, idx, "mid-cycle leg failed");
            }
            return;
        }

        // A successful leg fill resets the LEG_FAILED auto-clear counter.
        legFailCount = 0;

        uint8 next = idx + 1;
        // Queue for next tick: can't submit another 0x0805 call here.
        if (next >= legCount) {
            _deferredKind = 3;
            _deferredData = 0;
        } else {
            _deferredKind = 2;
            _deferredData = next;
        }
    }

    /// @notice Callback from adapter after it computes + pushes NAV to Base and reads Base reserve.
    ///         Body: abi.encode(uint256 navUsd, uint256 baseReserveUsd, bytes32 baseTxHash, bool baseSuccess).
    ///         The push itself is done by the TEE adapter: sign `valuer.updateValue(nav, nonce, sig)`
    ///         with the dKMS-held valuer signer key and submit on Base via the dKMS-held Base EOA.
    ///         This callback stores the reported state so subsequent `tick()` calls can auto-trigger
    ///         unwind when reserve is low.
    function onValuationSync(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        pendingValuationJobId = bytes32(0);
        (uint16 statusCode, bytes memory body, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) return;

        (uint256 navUsd, uint256 baseReserveUsd, bytes32 baseTxHash, bool baseSuccess) =
            abi.decode(body, (uint256, uint256, bytes32, bool));

        lastNavUsd = navUsd;
        lastBaseReserveUsd = baseReserveUsd;
        lastValuationTimestamp = block.timestamp;
        emit ValuationPushed(navUsd, baseReserveUsd, baseTxHash, baseSuccess);

        if (tradingState == MultiLegTradingState.VALUATION_PENDING) {
            _setTradingState(MultiLegTradingState.READY);
            emit MultiLegCycleCompleted(currentCycleId);
            // If this cycle was a partial unwind, queue a REFILL_RESERVE on Base (dispatched by
            // next tick since we can't nest another precompile here) so the module pushes the
            // now-returned USDC into the sleeve and reconciles externalDeposits.
            if (_currentCycleIsUnwind && _unwindShortfallUsd > 0) {
                _deferredKind = 4;
                _deferredData = _unwindShortfallUsd;
                // Note: _clearUnwindState() runs in _dispatchDeferred after REFILL_RESERVE emits.
            } else {
                _clearUnwindState();
            }
            _setTradingState(MultiLegTradingState.IDLE);
        }
    }

    function ingestFundingReceipt(FundingReceipt calldata receipt) external {
        if (msg.sender != owner && msg.sender != vaultManager && msg.sender != funder) {
            revert NotFunderOrManager();
        }
        if (pendingTopUpCycle != receipt.cycleId) revert InvalidJobId();
        pendingTopUpCycle = bytes32(0);
        pendingTopUpAmount = 0;
        uint8 legIdx = pendingTopUpLegIndex;
        if (fundingState == MultiLegFundingState.TOPUP_PENDING) _setFundingState(MultiLegFundingState.OK);
        emit MultiLegFundingReceiptIngested(receipt.cycleId, legIdx, receipt.commandType, receipt.status);
    }

    // ─── Views ───────────────────────────────────────────────────────────────
    // Struct getters removed — callers use autogenerated `legs(i)`, `bufferSnapshots(i)`,
    // `currentCycleFills(i)` tuple getters. `effectiveWeightBps` / `effectiveSide` /
    // `effectiveCycleNotional` removed — operator can reconstruct from `legs(i)` + `latestKelly(i)`
    // + `maxCycleNotionalUsd`. Dropped to stay under EIP-170 runtime size limit.

    // ─── Internal ────────────────────────────────────────────────────────────

    function _anyBufferStale() internal view returns (bool) {
        for (uint8 i; i < legCount; i++) {
            if (bufferSnapshots[i].timestamp == 0) return true;
            if (block.timestamp > bufferSnapshots[i].timestamp + bufferStalenessSeconds) return true;
        }
        return false;
    }

    /// @notice Drain the deferred-submit queue set by a callback. Returns true if dispatched.
    function _dispatchDeferred() internal returns (bool) {
        uint8 kind = _deferredKind;
        if (kind == 0) return false;
        uint256 data = _deferredData;
        _deferredKind = 0;
        _deferredData = 0;
        if (kind == 1) {
            // Top-up for leg `data`: re-emit command (the callback already validated the need).
            uint8 legIdx = uint8(data);
            LegConfig memory cfg = legs[legIdx];
            uint256 amount = cfg.bufferTargetUsd - bufferSnapshots[legIdx].bufferUsd;
            // Dust floor — bps-of-deployable. Drain the deferred slot either way (cleared above)
            // so we don't spin on the same tiny shortfall forever.
            if (amount < DustFloorLib.floorUsd(lastNavUsd, lastBaseReserveUsd, minTopupBps)) return true;
            CrossVenueCommandLib.CommandType cmd = _commandForLeg(legIdx);
            _emitCommand(cmd, amount, cfg.destinationRef);
            pendingTopUpLegIndex = legIdx;
            pendingTopUpAmount = amount;
            pendingTopUpCycle = currentCycleId == bytes32(0) ? _newCycleId() : currentCycleId;
            _setFundingState(MultiLegFundingState.TOPUP_PENDING);
        } else if (kind == 2) {
            currentLegIndex = uint8(data);
            _submitLeg(uint8(data));
        } else if (kind == 3) {
            _setTradingState(MultiLegTradingState.VALUATION_PENDING);
            _submitValuationSync();
        } else if (kind == 4) {
            // Refill reserve after partial unwind: shrink-leg cycle already ran, adapter has
            // CCTP'd the freed USDC back to the Base module. This command tells the module to
            // push that USDC into the sleeve (sleeve.recordSettlement reconciles
            // externalDeposits[strategyId]). `data` is the total realized USD. Dust floor
            // bps-of-deployable suppresses sub-floor refill command round-trips.
            if (data >= DustFloorLib.floorUsd(lastNavUsd, lastBaseReserveUsd, minRefillBps)) {
                emit ReserveRefillReady(currentCycleId, data);
                _emitCommand(CrossVenueCommandLib.CommandType.REFILL_RESERVE, data, reserveDestinationRef);
            }
            _setTradingState(MultiLegTradingState.IDLE);
            _clearUnwindState();
        }
        return true;
    }

    /// @dev Reset per-cycle unwind flags + override targets so the next cycle uses regular sizing.
    function _clearUnwindState() internal {
        _currentCycleIsUnwind = false;
        _unwindShortfallUsd = 0;
        for (uint8 i; i < legCount; i++) _unwindTargetOverrideUsd[i] = 0;
    }

    function _tryEmitTopUp() internal returns (bool acted) {
        if (fundingState == MultiLegFundingState.PAUSED || fundingState == MultiLegFundingState.STALE) return false;
        uint256 topupFloor = DustFloorLib.floorUsd(lastNavUsd, lastBaseReserveUsd, minTopupBps);
        for (uint8 i; i < legCount; i++) {
            LegConfig memory cfg = legs[i];
            if (bufferSnapshots[i].bufferUsd < cfg.bufferMinUsd) {
                uint256 amount = cfg.bufferTargetUsd - bufferSnapshots[i].bufferUsd;
                // Dust floor: skip sub-floor top-ups so bridge + CCTP + gas fees don't exceed
                // the amount being moved. `minTopupBps = 0` disables (floor=0).
                if (amount < topupFloor) continue;
                CrossVenueCommandLib.CommandType cmd = _commandForLeg(i);
                _emitCommand(cmd, amount, cfg.destinationRef);
                pendingTopUpLegIndex = i;
                pendingTopUpAmount = amount;
                pendingTopUpCycle = currentCycleId == bytes32(0) ? _newCycleId() : currentCycleId;
                _setFundingState(MultiLegFundingState.TOPUP_PENDING);
                return true;
            }
        }
        if (fundingState != MultiLegFundingState.OK) _setFundingState(MultiLegFundingState.OK);
        return false;
    }

    /// @notice Venue → Base command mapping. HL perp + HL spot share one Base→HL rail.
    function _commandForLeg(uint8 legIndex) internal view returns (CrossVenueCommandLib.CommandType) {
        bytes32 v = legs[legIndex].venue;
        if (v == ML_VENUE_PM) return CrossVenueCommandLib.CommandType.TOPUP_PM_BUFFER;
        return CrossVenueCommandLib.CommandType.TOPUP_HL_BUFFER; // both HL perp + HL spot
    }

    function _emitCommand(CrossVenueCommandLib.CommandType cmd, uint256 amount, bytes32 destinationRef) internal {
        bytes32 cycleId = currentCycleId == bytes32(0) ? _newCycleId() : currentCycleId;
        // Nonce is derived from cycleId, cmd, and destinationRef — stateless and deterministic.
        // Earlier `nextNonce++` counter broke autonomous operation: the Ritual HTTP precompile
        // can dispatch the async request to the TEE out-of-band while the outer tick tx reverts,
        // leaving the counter at its pre-tx value while the envelope is already en route to
        // Base, creating a permanent `usedNonces` lock on the Gateway. Derived-nonce + cycleId-
        // based Gateway dedup makes this safe even under partial tx failure.
        uint256 nonce = uint256(keccak256(abi.encode(cycleId, cmd, destinationRef)));
        // Ritual `block.timestamp` is in MILLISECONDS; Base validates `env.deadline` against
        // its own SECONDS-scale `block.timestamp`. Convert to seconds before adding TTL so
        // Base's expiry check is meaningful. envelopeTtlSeconds is in seconds (per its name).
        uint256 deadline = (block.timestamp / 1000) + envelopeTtlSeconds;
        bytes32 payloadHash = keccak256(abi.encode(cmd, amount, destinationRef));
        bytes32 ritualTxHash = blockhash(block.number - 1);
        emit CommandReady(
            cycleId, cmd, baseVault, baseAsset, amount, destinationRef, payloadHash, nonce, deadline, ritualTxHash
        );

        CrossVenueCommandLib.CommandEnvelope memory env = CrossVenueCommandLib.CommandEnvelope({
            cycleId: cycleId,
            commandType: cmd,
            dstVault: baseVault,
            asset: baseAsset,
            amount: amount,
            destinationRef: destinationRef,
            payloadHash: payloadHash,
            nonce: nonce,
            deadline: deadline,
            ritualTxHash: ritualTxHash
        });
        _submitCommandToBase(env);
    }

    function _submitCommandToBase(CrossVenueCommandLib.CommandEnvelope memory env) internal {
        bytes32 jobId = keccak256(abi.encodePacked("ml-base-cmd", env.nonce, block.number));
        pendingBaseCommandJobId = jobId;
        lastSubmittedCommandNonce = bytes32(env.nonce);
        MultiLegSubmitLib.dispatch(
            _submitCtx(),
            "/base/execute-command",
            abi.encode(env),
            this.onBaseCommandSubmitted.selector
        );
    }

    function _submitCtx() internal view returns (MultiLegSubmitLib.Ctx memory) {
        return MultiLegSubmitLib.Ctx({
            adapterUrl: adapterUrl,
            executor: executor,
            encryptedSecrets: _encryptedSecrets,
            secretSignatures: _secretSignatures,
            secretHeaderKeys: secretHeaderKeys,
            secretHeaderValues: secretHeaderValues,
            pollIntervalBlocks: pollIntervalBlocks,
            maxPollBlock: maxPollBlock,
            deliveryGasLimit: deliveryGasLimit,
            ttl: httpTtl,
            controller: address(this)
        });
    }

    function onBaseCommandSubmitted(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        if (pendingBaseCommandJobId == bytes32(0)) return;
        pendingBaseCommandJobId = bytes32(0);

        (uint16 statusCode, bytes memory body, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) return;
        (bytes32 baseTxHash, bool success,) = abi.decode(body, (bytes32, bool, string));
        emit BaseCommandSubmitted(lastSubmittedCommandNonce, baseTxHash, success);

        if (success && fundingState == MultiLegFundingState.TOPUP_PENDING) {
            // Invalidate buffer snapshot for the topped-up leg → next tick forces a fresh
            // `/buffers` read reflecting the newly-received funds (instead of waiting for
            // bufferStalenessSeconds to expire, which would keep firing redundant top-ups).
            bufferSnapshots[pendingTopUpLegIndex].timestamp = 0;
            pendingTopUpCycle = bytes32(0);
            pendingTopUpAmount = 0;
            _setFundingState(MultiLegFundingState.OK);
        }
    }

    // [removed] onUnwindResult: adapter `/unwind` protocol retired. Partial unwinds run through
    // `requestPartialUnwind` → per-leg `_submitLeg` delta rebalance → `onLegResult` normal path.

    function _tryStartCycle() internal {
        if (tradingState != MultiLegTradingState.IDLE) return;
        if (fundingState != MultiLegFundingState.OK) return;

        uint256 target = _effectiveCycleNotional();
        if (target < minCycleNotionalUsd) return;

        bytes32 cid = _newCycleId();
        currentCycleId = cid;
        currentCycleTargetUsd = target;
        currentLegIndex = 0;
        // Zero out prior cycle fills.
        for (uint8 i; i < legCount; i++) {
            delete currentCycleFills[i];
        }
        emit MultiLegCycleRequested(cid, target, legCount);
        _submitLeg(0);
    }

    function _submitLeg(uint8 legIndex) internal {
        LegConfig memory cfg = legs[legIndex];
        uint256 notional = _legNotional(legIndex);

        // HL venue-min guard: HL rejects orders below ~$10 notional. Abort cycle cleanly.
        // Ref-leg below → IDLE. Hedge-leg below → UNHEDGED. State-change event fires via
        // _setTradingState; no separate event to save bytecode.
        if (
            (cfg.venue == ML_VENUE_HL_PERP || cfg.venue == ML_VENUE_HL_SPOT)
                && minHlNotionalUsd > 0 && notional < minHlNotionalUsd
        ) {
            _setTradingState(
                cfg.referenceLegIndex == REF_LEG_SENTINEL
                    ? MultiLegTradingState.IDLE
                    : MultiLegTradingState.UNHEDGED
            );
            return;
        }

        ExecutionIntent memory intent = ExecutionIntent({
            cycleId: currentCycleId,
            venue: cfg.venue,
            marketRef: cfg.marketRef,
            side: _effectiveSide(legIndex),
            targetNotionalUsd: notional,
            maxSlippageBps: cfg.maxSlippageBps,
            expiryBlock: block.number + maxPollBlock,
            idempotencyKey: keccak256(abi.encodePacked(currentCycleId, legIndex)),
            marginMode: cfg.marginMode
        });
        bytes32 jobId = keccak256(abi.encodePacked(intent.idempotencyKey, block.number));
        pendingLegJobId = jobId;

        MultiLegSubmitLib.dispatch(
            _submitCtx(),
            "/leg/execute",
            abi.encode(intent),
            this.onLegResult.selector
        );
        _setTradingState(MultiLegTradingState.LEG_PENDING);
        emit MultiLegLegSubmitted(currentCycleId, legIndex, jobId, notional);
    }

    /// @notice Delta-managed sizing:
    ///           • Reference leg (`referenceLegIndex == REF_LEG_SENTINEL`):
    ///                notional = cycleTargetUsd × |w|/10000
    ///           • Hedge leg: notional = refFill × |w|/10000 × |β|/10000
    ///         This is the canonical framework — every hedge leg ties its size to its reference
    ///         via the two-parameter (w, β) decomposition. Classic DN is w=1, β=1. Partial hedge
    ///         is w<1; cross-instrument hedge is β≠1.
    function _legNotional(uint8 legIndex) internal view returns (uint256) {
        // Partial-unwind override: gated by the cycle-level unwind flag (NOT the value), so an
        // override of 0 means "target zero" (full close) during a full unwind instead of being
        // treated as "no override set."
        if (_currentCycleIsUnwind) {
            return _unwindTargetOverrideUsd[legIndex];
        }
        LegConfig memory cfg = legs[legIndex];
        uint256 absW = _absWeight(legIndex);
        if (cfg.referenceLegIndex == REF_LEG_SENTINEL) {
            return (currentCycleTargetUsd * absW) / 10_000;
        }
        // Hedge leg: size off the reference leg's reported post-rebalance fill.
        // Magnitude uses |β|; sign combines with sign(weight) at order-side inference in adapter.
        require(cfg.referenceLegIndex < legCount, "bad refLeg");
        uint256 refFill = currentCycleFills[cfg.referenceLegIndex].filledNotionalUsd;
        int16 b = cfg.betaBps;
        uint256 absBeta = b < 0 ? uint256(uint16(-b)) : uint256(uint16(b));
        return (refFill * absW * absBeta) / (10_000 * 10_000);
    }

    function _effectiveWeight(uint8 legIndex) internal view returns (int16) {
        LegConfig memory cfg = legs[legIndex];
        if (useKelly && latestKelly.validUntil >= block.timestamp) {
            int16 w = latestKelly.targetWeightBps[legIndex];
            if (w != 0) {
                // Spot legs can't go negative even under Kelly — fall back to static.
                if (cfg.venue == ML_VENUE_HL_SPOT && w < 0) return cfg.weightBps;
                // Clamp Kelly override to the static cap — operator's hard ceiling on risk.
                if (cfg.maxAbsWeightBps > 0) {
                    int16 cap = int16(cfg.maxAbsWeightBps);
                    if (w > cap) return cap;
                    if (w < -cap) return -cap;
                }
                return w;
            }
        }
        return cfg.weightBps;
    }

    function _absWeight(uint8 legIndex) internal view returns (uint256) {
        int16 w = _effectiveWeight(legIndex);
        return w < 0 ? uint256(uint16(-w)) : uint256(uint16(w));
    }

    function _effectiveSide(uint8 legIndex) internal view returns (Side) {
        LegConfig memory cfg = legs[legIndex];
        int16 w = _effectiveWeight(legIndex);
        // Reference leg: direction from sign of weight alone (+ = buy/long, − = sell/short).
        if (cfg.referenceLegIndex == REF_LEG_SENTINEL) {
            return w < 0 ? Side.Sell : Side.Buy;
        }
        // Hedge leg: direction from sign(w) × sign(β). Two anti-correlated negatives (e.g. PM
        // YES ref with weight +, NO hedge with w=+ and β=−) yield buy on NO — which is the
        // correct hedge. Same side × positive β on HL spot+perp hedge yields sell perp for a
        // long spot ref.
        int16 b = cfg.betaBps;
        int256 combined = int256(w) * int256(b);
        return combined < 0 ? Side.Sell : Side.Buy;
    }

    function _effectiveCycleNotional() internal view returns (uint256) {
        if (useKelly && latestKelly.validUntil >= block.timestamp && latestKelly.totalTargetNotional > 0) {
            uint256 k = latestKelly.totalTargetNotional;
            return k > maxCycleNotionalUsd ? maxCycleNotionalUsd : k;
        }
        return maxCycleNotionalUsd;
    }

    function _submitBufferSync() internal {
        bytes32 jobId = keccak256(abi.encodePacked(strategyId, "ml-buffer", block.number));
        pendingBufferSyncJobId = jobId;
        MultiLegSubmitLib.dispatch(
            _submitCtx(), "/buffers", abi.encode(strategyId), this.onBufferSyncResult.selector
        );
        emit MultiLegBufferSyncSubmitted(jobId);
    }

    function _submitValuationSync() internal {
        pendingValuationJobId = keccak256(abi.encodePacked(strategyId, "ml-val", block.number));
        MultiLegSubmitLib.dispatch(
            _submitCtx(), "/valuation", abi.encode(strategyId), this.onValuationSync.selector
        );
    }

    function _decodeReceipt(bytes calldata result) internal view returns (NormalizedExecutionReceipt memory r) {
        (uint16 statusCode, bytes memory body, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) {
            r.status = ExecStatus.Failed;
            r.terminal = true;
            return r;
        }
        r = abi.decode(body, (NormalizedExecutionReceipt));
    }

    function _newCycleId() internal returns (bytes32 cid) {
        cid = keccak256(abi.encodePacked(strategyId, nextCycleSeq, block.number));
        nextCycleSeq += 1;
    }

    function _setFundingState(MultiLegFundingState next) internal {
        if (fundingState == next) return;
        fundingState = next;
        emit MultiLegFundingStateChanged(next);
    }

    function _setTradingState(MultiLegTradingState next) internal {
        if (tradingState == next) return;
        tradingState = next;
        emit MultiLegTradingStateChanged(next);
    }
}
