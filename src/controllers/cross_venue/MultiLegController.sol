// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
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
    ML_VENUE_HL_PERP,
    ML_VENUE_HL_SPOT,
    ML_VENUE_PM,
    MultiLegFundingState,
    MultiLegTradingState,
    LegConfig,
    LegBufferSnapshot,
    LegFill,
    OffchainKellyWeights,
    MultiLegCycleRequested,
    MultiLegLegSubmitted,
    MultiLegLegFill,
    MultiLegCycleCompleted,
    MultiLegRecoveryMarked,
    MultiLegFundingStateChanged,
    MultiLegTradingStateChanged,
    MultiLegBufferSnapshotUpdated,
    MultiLegBufferSyncSubmitted,
    MultiLegKellyApplied,
    MultiLegFundingReceiptIngested,
    ValuationPushed,
    AutoUnwindTriggered
} from "./MultiLegTypes.sol";

/// @title MultiLegController
/// @notice N-leg cross-venue controller. Legs execute sequentially; each has its own buffer topped
///         up via its own destinationRef. Supports off-chain signed Kelly weight overrides
///         (replay-protected, time-bounded) with a static config fallback. Handles the full
///         lifecycle: initial allocation, incremental opens, unwind → REFILL_RESERVE. Allowed
///         venues: HYPERLIQUID-PERP, HYPERLIQUID-SPOT, POLYMARKET. Clone-safe (EIP-1167).
contract MultiLegController is ReentrancyGuard {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

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

    uint256 public nextNonce;
    uint64 public nextCycleSeq;
    bytes32 public currentCycleId;
    uint256 public currentCycleTargetUsd;
    uint8 public currentLegIndex;

    LegFill[MAX_LEGS] public currentCycleFills;

    bytes32 public pendingLegJobId;
    bytes32 public pendingBufferSyncJobId;
    bytes32 public pendingValuationJobId;
    bytes32 public pendingBaseCommandJobId;
    bytes32 public pendingUnwindJobId;
    bytes32 public lastSubmittedCommandNonce;
    bytes32 public reserveDestinationRef;
    uint256 public pendingUnwindTargetUsd;

    uint256 public tickScheduleId;
    uint256 public valuationScheduleId;
    /// @dev Schedule auto-extend params. Packed into one slot:
    ///         tickFreq (uint32) | valuationFreq (uint32) | extendGas (uint32) — bits 0..95.
    ///      Stored on first `fundAndSchedule` call; tick/syncValuation re-use them to extend.
    uint96 internal _schedPacked;
    uint256 public scheduleMaxFeePerGas;

    /// @notice Last Base-side NAV + reserve reported by the valuation-sync callback.
    uint256 public lastNavUsd;
    uint256 public lastBaseReserveUsd;
    uint256 public lastValuationTimestamp;
    /// @notice If non-zero, tick() auto-triggers unwind when lastBaseReserveUsd < minBaseReserveUsd.
    uint256 public minBaseReserveUsd;
    /// @notice Target refill amount when auto-unwinding (usually `target - current`).
    uint256 public autoUnwindTargetUsd;
    /// @notice Max age of the valuation-sync report before auto-unwind is skipped. Zero = no cap
    ///         (auto-unwind always uses whatever `lastBaseReserveUsd` is). Prevents firing unwinds
    ///         off stale reserve data.
    uint256 public maxValuationStalenessSeconds;

    LegBufferSnapshot[MAX_LEGS] public bufferSnapshots;

    // Funding in-flight — tracks which leg and how much
    uint8 public pendingTopUpLegIndex;
    bytes32 public pendingTopUpCycle;
    uint256 public pendingTopUpAmount;

    // Off-chain Kelly
    OffchainKellyWeights public latestKelly;
    mapping(bytes32 => bool) public usedKellyNonces;

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
        for (uint8 i; i < p.legs.length; i++) {
            _validateLeg(p.legs[i]);
            legs[i] = p.legs[i];
        }

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

    function setAdapterUrl(string calldata u) external onlyOwner {
        adapterUrl = u;
    }

    function setExecutor(address e) external onlyOwner {
        executor = e;
    }

    /// @notice Tune all HTTP async-precompile parameters without redeploying. Owner-only.
    ///         Pass 0 to leave any field unchanged.
    function setHttpConfig(
        uint64 newPollInterval,
        uint64 newMaxPollBlock,
        uint256 newDeliveryGasLimit,
        uint256 newHttpTtl
    ) external onlyOwner {
        if (newPollInterval > 0) pollIntervalBlocks = newPollInterval;
        if (newMaxPollBlock > 0) maxPollBlock = newMaxPollBlock;
        if (newDeliveryGasLimit > 0) deliveryGasLimit = newDeliveryGasLimit;
        if (newHttpTtl > 0) httpTtl = newHttpTtl;
    }

    /// @notice Deposit msg.value into RitualWallet (credited to this clone) and schedule both
    ///         `tick` and `syncValuation` recurring calls on the Ritual Scheduler. Owner-only.
    ///         `tickFreq` / `valuationFreq` in blocks (1 block ≈ 350ms on Ritual, so
    ///         `tickFreq = 100` ≈ every 35s). `numCalls = 0` means run until wallet runs dry.
    ///         Lock duration must extend past `currentBlock + numCalls * frequency + ttl` or the
    ///         Scheduler will reject.
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
        _schedPacked = uint96(tickFreq) | (uint96(valuationFreq) << 32) | (uint96(gasLimit) << 64);
        scheduleMaxFeePerGas = maxFeePerGas;
    }

    function _maybeExtend(bool isTick, uint256 executionIndex) internal {
        if (msg.sender != RitualPrecompiles.SCHEDULER) return;
        uint256 nid = SchedulerSetupLib.maybeExtend(
            isTick ? this.tick.selector : this.syncValuation.selector,
            isTick,
            executionIndex,
            _schedPacked,
            scheduleMaxFeePerGas
        );
        if (nid != 0) {
            if (isTick) tickScheduleId = nid; else valuationScheduleId = nid;
        }
    }


    /// @notice Replace the stored ECIES-encrypted venue secrets and their owner-EOA signatures.
    ///         `blobs[i]` is the ECIES ciphertext of one secret (venue PK, etc.) to the executor pubkey;
    ///         `sigs[i]` is `sign(keccak256(blobs[i]))` by the secret owner EOA. After calling this,
    ///         the owner must also call `SecretsAccessControl.grantAccess(thisClone, secretsHash, ...)`
    ///         so the executor accepts requests originating from this contract.
    function setSecrets(bytes[] calldata blobs, bytes[] calldata sigs) external onlyOwner {
        if (blobs.length != sigs.length) revert InvalidConfig();
        delete _encryptedSecrets;
        delete _secretSignatures;
        for (uint256 i; i < blobs.length; i++) {
            _encryptedSecrets.push(blobs[i]);
            _secretSignatures.push(sigs[i]);
        }
    }

    function getSecrets() external view returns (bytes[] memory blobs, bytes[] memory sigs) {
        blobs = _encryptedSecrets;
        sigs = _secretSignatures;
    }

    function setKellySigner(address s) external onlyOwner {
        kellySigner = s;
        useKelly = s != address(0);
    }

    function setFunder(address f) external onlyOwner {
        funder = f;
    }

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
    }

    function setCycleBounds(uint256 minUsd, uint256 maxUsd) external onlyOwner {
        if (minUsd == 0 || maxUsd < minUsd) revert InvalidConfig();
        minCycleNotionalUsd = minUsd;
        maxCycleNotionalUsd = maxUsd;
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

    /// @notice Configure auto-unwind behavior. If `min > 0`, scheduler tick auto-triggers
    ///         `requestUnwind(target)` once the latest valuation-sync reports Base reserve below
    ///         `min`. Set min=0 to disable; operator-triggered unwinds remain available.
    function setAutoUnwindThresholds(uint256 min, uint256 target) external onlyOwner {
        minBaseReserveUsd = min;
        autoUnwindTargetUsd = target;
    }

    function setMaxValuationStaleness(uint256 s) external onlyOwner {
        maxValuationStalenessSeconds = s;
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
        bool baseCommand,
        bool unwind
    ) external onlyVaultManager {
        if (leg) pendingLegJobId = bytes32(0);
        if (bufferSync) pendingBufferSyncJobId = bytes32(0);
        if (valuation) pendingValuationJobId = bytes32(0);
        if (baseCommand) pendingBaseCommandJobId = bytes32(0);
        if (unwind) pendingUnwindJobId = bytes32(0);
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

    /// @notice Kick off an unwind to refill Base reserve. Adapter closes all open legs, realizes USDC,
    ///         and reports the delivered amount. Controller then emits a `REFILL_RESERVE` CommandEnvelope
    ///         which the scheduled-tx path routes to Base.
    /// @notice Kick off an unwind. Callable from IDLE, READY, and UNHEDGED — UNHEDGED requires unwind
    ///         to close the partially-opened legs before the controller can accept new cycles.
    function requestUnwind(uint256 targetAssetsUsd) external nonReentrant onlyVaultManager {
        if (
            tradingState != MultiLegTradingState.IDLE && tradingState != MultiLegTradingState.READY
                && tradingState != MultiLegTradingState.UNHEDGED
        ) revert InvalidState();
        if (targetAssetsUsd == 0) revert InvalidConfig();
        pendingUnwindTargetUsd = targetAssetsUsd;
        currentCycleId = _newCycleId();
        _setTradingState(MultiLegTradingState.UNWIND_PENDING);
        _submitUnwind(targetAssetsUsd);
    }

    /// @notice Off-chain Kelly weights posted by `kellySigner`. EIP-191 signed digest over
    ///         (strategyId, targetWeightBps, totalTargetNotional, validUntil, nonce, chainId, address(this)).
    function submitKellyWeights(OffchainKellyWeights calldata w, bytes calldata signature) external {
        if (!useKelly) revert InvalidState();
        if (w.validUntil < block.timestamp) revert KellyStale();
        if (usedKellyNonces[w.nonce]) revert KellyNonceReused();

        bytes32 digest = keccak256(
            abi.encode(
                strategyId, w.targetWeightBps, w.totalTargetNotional, w.validUntil, w.nonce, block.chainid, address(this)
            )
        ).toEthSignedMessageHash();
        address signer = digest.recover(signature);
        if (signer != kellySigner) revert KellyInvalidSignature();

        usedKellyNonces[w.nonce] = true;
        latestKelly = w;
        emit MultiLegKellyApplied(w.nonce, w.totalTargetNotional, w.validUntil);
    }

    // ─── Scheduler entrypoints ───────────────────────────────────────────────

    function tick(uint256 executionIndex) external nonReentrant onlySchedulerOrOwner {
        _maybeExtend(true, executionIndex);
        if (tradingState == MultiLegTradingState.PAUSED || fundingState == MultiLegFundingState.PAUSED) return;
        if (
            tradingState == MultiLegTradingState.RECOVERY_REQUIRED || tradingState == MultiLegTradingState.UNHEDGED
                || tradingState == MultiLegTradingState.LEG_FAILED
        ) return;
        // If an unwind is already in flight, the valuation-sync + REFILL_RESERVE will follow via callback.
        if (tradingState == MultiLegTradingState.UNWIND_PENDING) return;

        if (_anyBufferStale()) {
            if (pendingBufferSyncJobId == bytes32(0)) _submitBufferSync();
            return;
        }

        // Auto-reserve maintenance: if latest valuation-sync reported Base reserve below min,
        // kick off an unwind to refill. Takes priority over new cycle starts. Skipped if the
        // valuation report is older than `maxValuationStalenessSeconds` (when configured) —
        // prevents firing off stale data.
        if (
            minBaseReserveUsd > 0 && lastValuationTimestamp > 0 && lastBaseReserveUsd < minBaseReserveUsd
                && (
                    maxValuationStalenessSeconds == 0
                        || block.timestamp - lastValuationTimestamp <= maxValuationStalenessSeconds
                )
                && (tradingState == MultiLegTradingState.IDLE || tradingState == MultiLegTradingState.READY)
        ) {
            uint256 target = autoUnwindTargetUsd > 0 ? autoUnwindTargetUsd : minBaseReserveUsd - lastBaseReserveUsd;
            currentCycleId = _newCycleId();
            pendingUnwindTargetUsd = target;
            _setTradingState(MultiLegTradingState.UNWIND_PENDING);
            emit AutoUnwindTriggered(currentCycleId, lastBaseReserveUsd, target);
            _submitUnwind(target);
            return;
        }

        if (fundingState == MultiLegFundingState.TOPUP_PENDING) return;

        if (_tryEmitTopUp()) return;

        if (tradingState == MultiLegTradingState.IDLE) _tryStartCycle();
    }

    function syncValuation(uint256 executionIndex) external nonReentrant onlySchedulerOrOwner {
        _maybeExtend(false, executionIndex);
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
        _tryEmitTopUp();
    }

    function onLegResult(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        if (tradingState != MultiLegTradingState.LEG_PENDING) revert InvalidState();
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

        uint8 next = idx + 1;
        if (next >= legCount) {
            _setTradingState(MultiLegTradingState.VALUATION_PENDING);
            _submitValuationSync();
            return;
        }

        currentLegIndex = next;
        _submitLeg(next);
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

    function getLegConfig(uint8 i) external view returns (LegConfig memory) {
        return legs[i];
    }

    function getLegBuffer(uint8 i) external view returns (LegBufferSnapshot memory) {
        return bufferSnapshots[i];
    }

    function getLegFill(uint8 i) external view returns (LegFill memory) {
        return currentCycleFills[i];
    }

    function effectiveWeightBps(uint8 i) external view returns (int16) {
        return _effectiveWeight(i);
    }

    /// @notice Direction inferred from the effective weight's sign. Buy when weight > 0, Sell when < 0.
    function effectiveSide(uint8 i) external view returns (Side) {
        return _effectiveSide(i);
    }

    function effectiveCycleNotional() external view returns (uint256) {
        return _effectiveCycleNotional();
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _anyBufferStale() internal view returns (bool) {
        for (uint8 i; i < legCount; i++) {
            if (bufferSnapshots[i].timestamp == 0) return true;
            if (block.timestamp > bufferSnapshots[i].timestamp + bufferStalenessSeconds) return true;
        }
        return false;
    }

    function _tryEmitTopUp() internal returns (bool acted) {
        if (fundingState == MultiLegFundingState.PAUSED || fundingState == MultiLegFundingState.STALE) return false;
        for (uint8 i; i < legCount; i++) {
            LegConfig memory cfg = legs[i];
            if (bufferSnapshots[i].bufferUsd < cfg.bufferMinUsd) {
                uint256 amount = cfg.bufferTargetUsd - bufferSnapshots[i].bufferUsd;
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
        uint256 nonce = nextNonce++;
        bytes32 cycleId = currentCycleId == bytes32(0) ? _newCycleId() : currentCycleId;
        uint256 deadline = block.timestamp + envelopeTtlSeconds;
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
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) {
            emit BaseCommandFailed(lastSubmittedCommandNonce, statusCode, errorMessage);
            return;
        }
        (bytes32 baseTxHash, bool success,) = abi.decode(body, (bytes32, bool, string));
        emit BaseCommandSubmitted(lastSubmittedCommandNonce, baseTxHash, success);
    }

    /// @notice Callback from adapter after it closes all open legs and reports realized USDC.
    ///         Body: abi.encode(uint256 realizedAssetsUsd).
    function onUnwindResult(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        if (tradingState != MultiLegTradingState.UNWIND_PENDING) revert InvalidState();
        if (pendingUnwindJobId == bytes32(0)) return;
        pendingUnwindJobId = bytes32(0);

        (uint16 statusCode, bytes memory body, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) {
            _setTradingState(MultiLegTradingState.RECOVERY_REQUIRED);
            emit MultiLegRecoveryMarked(currentCycleId, 0, "unwind failed at adapter");
            return;
        }

        uint256 realizedUsd = abi.decode(body, (uint256));
        if (realizedUsd == 0) {
            _setTradingState(MultiLegTradingState.IDLE);
            return;
        }
        emit ReserveRefillReady(currentCycleId, realizedUsd);
        _emitCommand(CrossVenueCommandLib.CommandType.REFILL_RESERVE, realizedUsd, reserveDestinationRef);

        for (uint8 i; i < legCount; i++) {
            delete currentCycleFills[i];
        }
        pendingUnwindTargetUsd = 0;
        _setTradingState(MultiLegTradingState.IDLE);
    }

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

    function _legNotional(uint8 legIndex) internal view returns (uint256) {
        LegConfig memory cfg = legs[legIndex];
        uint256 absW = _absWeight(legIndex);
        if (cfg.sizeFromPrevFill && legIndex > 0) {
            uint256 prev = currentCycleFills[legIndex - 1].filledNotionalUsd;
            return (prev * absW) / 10_000;
        }
        return (currentCycleTargetUsd * absW) / 10_000;
    }

    function _effectiveWeight(uint8 legIndex) internal view returns (int16) {
        LegConfig memory cfg = legs[legIndex];
        if (useKelly && latestKelly.validUntil >= block.timestamp) {
            int16 w = latestKelly.targetWeightBps[legIndex];
            if (w != 0) {
                // Clamp Kelly override to the per-leg static cap. Operator retains a hard ceiling
                // so a compromised / buggy Kelly signer can't exceed risk bounds.
                if (cfg.venue == ML_VENUE_HL_SPOT && w < 0) {
                    // Spot legs can't go negative even via Kelly — fall back to static.
                    return cfg.weightBps;
                }
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
        return _effectiveWeight(legIndex) < 0 ? Side.Sell : Side.Buy;
    }

    function _effectiveCycleNotional() internal view returns (uint256) {
        if (useKelly && latestKelly.validUntil >= block.timestamp && latestKelly.totalTargetNotional > 0) {
            uint256 k = latestKelly.totalTargetNotional;
            if (k > maxCycleNotionalUsd) return maxCycleNotionalUsd;
            return k;
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

    function _submitUnwind(uint256 targetAssetsUsd) internal {
        pendingUnwindJobId = keccak256(abi.encodePacked(currentCycleId, "ml-unwind", block.number));
        MultiLegSubmitLib.dispatch(
            _submitCtx(),
            "/unwind",
            abi.encode(currentCycleId, targetAssetsUsd),
            this.onUnwindResult.selector
        );
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
