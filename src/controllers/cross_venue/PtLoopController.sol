// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RitualPrecompiles} from "../../interfaces/ritual/IRitualPrecompiles.sol";
import {IRitualWallet} from "../../interfaces/ritual/IScheduler.sol";
import {SchedulerSetupLib} from "./SchedulerSetupLib.sol";
import {ControllerAdminLib} from "./ControllerAdminLib.sol";
import {MultiLegSubmitLib} from "./MultiLegSubmitLib.sol";
import {CrossVenueCommandLib} from "../../base/CrossVenueCommandLib.sol";
import {RitualHttpLib} from "./RitualHttpLib.sol";
import {
    Side,
    MarginMode,
    ExecStatus,
    ExecutionIntent,
    NormalizedExecutionReceipt,
    FundingReceipt,
    CommandReady,
    BaseCommandSubmitted,
    BaseCommandFailed,
    ReserveRefillReady
} from "./SharedVenueTypes.sol";

bytes32 constant VENUE_PENDLE = keccak256("PENDLE");

enum PtFundingState {
    OK,
    TOPUP_PENDING,
    STALE,
    PAUSED
}

enum PtTradingState {
    IDLE,
    ITER_PENDING,
    VALUATION_PENDING,
    READY,
    ITER_FAILED,
    RECOVERY_REQUIRED,
    PAUSED
}

struct PtLoopConfig {
    /// bytes32-packed Pendle market address on Arb. User-supplied at clone creation.
    /// Adapter decodes as `address(uint160(uint256(marketRef)))` and calls Pendle directly.
    bytes32 marketRef;
    uint16 maxSlippageBps;
    uint16 maxLoops; // 1 for flash-loan path (atomic); N for iterative fallback
    uint256 loopNotionalUsd; // base notional per iteration / per flash-loan sandwich
    uint256 bufferTargetUsd;
    uint256 bufferMinUsd;
    bytes32 destinationRef; // PT funding rail ref — e.g. keccak256("dest:arb:ptloop")
    uint256 bufferStalenessSeconds;
    uint256 envelopeTtlSeconds;
    /// Target leverage in bps. 10_000 = 1.0x (no leverage), 50_000 = 5.0x. Capped at 100_000 (10x).
    /// Set to 10_000 to disable looping (pure PT buy-and-hold).
    uint16 targetLeverageBps;
    /// Minimum acceptable health factor in bps. 11_000 = 1.10 (protocol floor).
    /// Adapter reverts the leg if live lending-venue LTV would push HF below this at targetLeverage.
    uint16 hfMinBps;
    /// EVM chain ID where the PT loop executes (e.g. 42161 Arb, 10 OP, 1 ETH). Opaque on Ritual;
    /// adapter uses it to look up the chain's RPC, Pendle router, flash vault, executor factory,
    /// and lending-venue registry. Controller never reads this field — it's a config label
    /// passed through to the adapter via the PtIterationIntent payload.
    uint64 targetChainId;
    /// Morpho Blue market id (bytes32) for the lending pair. Looked up once by the operator
    /// from Morpho's UI/API — e.g. for PT-USDai-18JUN2026/USDC on Arb:
    /// `0x958b40fcd0df023c156ec4a7eb8ffd47985b19d8bb02a36fb0af1bfc837fd605`. Opaque on Ritual;
    /// adapter calls `Morpho.idToMarketParams(id)` to read loanToken/collateral/oracle/irm/lltv
    /// at runtime and re-validates every cycle.
    bytes32 morphoMarketId;
}

/// @notice PT iteration payload sent to the adapter's `/pt/execute`. Wraps the shared
///         `ExecutionIntent` with PT-specific leverage, HF floor, the execution chain ID, and
///         a direction flag so the adapter can route open-vs-shrink without heuristics.
struct PtIterationIntent {
    ExecutionIntent intent;
    uint16 targetLeverageBps;
    uint16 hfMinBps;
    uint64 targetChainId;
    /// Morpho Blue market id. Adapter calls `idToMarketParams(id)` + `market(id)` for live
    /// validation and supply/borrow calldata construction.
    bytes32 morphoMarketId;
    /// `false` = open/incremental deposit (enterLoop, additive to existing position).
    /// `true`  = shrink (exitLoop, partial if target>0 else full close).
    bool isUnwind;
}

struct PtBufferSnapshot {
    uint256 bufferUsd;
    uint256 timestamp;
}

event PtLoopCycleRequested(bytes32 indexed cycleId, uint16 maxLoops, uint256 loopNotionalUsd);
event PtLoopIterationSubmitted(bytes32 indexed cycleId, uint16 iteration, bytes32 jobId, uint256 notionalUsd);
event PtLoopIterationFill(bytes32 indexed cycleId, uint16 iteration, ExecStatus status, uint256 filledNotionalUsd);
event PtLoopCycleCompleted(bytes32 indexed cycleId, uint16 completedIterations);
event PtLoopRecoveryMarked(bytes32 indexed cycleId, uint16 iteration, string reason);
event PtFundingStateChanged(PtFundingState indexed next);
event PtTradingStateChanged(PtTradingState indexed next);
event PtBufferSnapshotUpdated(uint256 bufferUsd, uint256 timestamp);
event PtBufferSyncSubmitted(bytes32 jobId);
event PtValuationSyncSubmitted(bytes32 jobId);
event PtFundingReceiptIngested(bytes32 indexed cycleId, CrossVenueCommandLib.CommandType commandType, ExecStatus status);

/// @title PtLoopController
/// @notice Ritual-side Pendle PT loop archetype. One buffer, N iterations per cycle.
///         Each iteration submits a PT buy to the adapter; cycle completes after maxLoops or
///         on iteration failure. Buffer top-ups flow through CommandReady → relay → BaseExecutionGateway
///         with a PT-specific destinationRef (uses TOPUP_PM_BUFFER command type since Base gateway
///         only supports PM/HL/PAUSE; operators can map destinationRef to any configured funding rail,
///         or add TOPUP_PT_BUFFER to the gateway in a future deployment).
contract PtLoopController is ReentrancyGuard {
    error NotOwner();
    error NotVaultManager();
    error NotSchedulerOrOwner();
    error NotAsyncDelivery();
    error AlreadyInitialized();
    error InvalidAddress();
    error InvalidConfig();
    error InvalidState();
    error InvalidJobId();

    bool internal _initialized;
    address public owner;
    address public vaultManager;
    address public baseVault;
    address public baseAsset;
    bytes32 public strategyId;

    string public adapterUrl;
    address public executor;
    uint64 public pollIntervalBlocks;
    uint64 public maxPollBlock;
    uint256 public deliveryGasLimit;
    uint256 public httpTtl;
    string[] public secretHeaderKeys;
    string[] public secretHeaderValues;
    bytes[] internal _encryptedSecrets;
    bytes[] internal _secretSignatures;

    uint256 public tickScheduleId;
    uint256 public valuationScheduleId;

    /// @dev Schedule parameters cached so `tick()` / `syncValuation()` can self-renew the
    ///      recurring schedules before the current batch exhausts. Without this, schedules
    ///      silently die after `numCalls × frequency` blocks (~58min at our typical cadence).
    ///      Set during `fundAndSchedule`; renewal uses them verbatim.
    uint32 public tickFreq;
    uint32 public valuationFreq;
    uint32 public tickNumCalls;
    uint32 public valuationNumCalls;
    uint32 public scheduleGasLimit;
    uint256 public scheduleMaxFeePerGas;
    /// @dev When the current batch has `<= scheduleRenewThreshold` executions remaining, the
    ///      next tick/valuation self-renews. Default 2 (renew within the last 2 executions).
    uint32 public scheduleRenewThreshold;

    /// @dev Conservative upper bound on the async HTTP precompile (0x0805) fee per tick, in wei
    ///      of RITUAL. The precompile bills the controller's RitualWallet independently of the
    ///      scheduler's tx gas, so any cost check that ignores this will drain funds below the
    ///      renewal-viability threshold. Default 2e15 (0.002 RITUAL). See SchedulerSetupLib docs.
    uint256 public perCallHttpBudget;

    PtLoopConfig public cfg;

    PtFundingState public fundingState;
    PtTradingState public tradingState;

    uint64 public nextCycleSeq;
    bytes32 public currentCycleId;
    uint16 public currentIteration;
    uint256 public currentCycleFilledTotalUsd;

    bytes32 public pendingIterJobId;
    bytes32 public pendingBufferSyncJobId;
    bytes32 public pendingValuationJobId;
    bytes32 public pendingBaseCommandJobId;
    bytes32 public lastSubmittedCommandNonce;

    PtBufferSnapshot public bufferSnapshot;

    bytes32 public pendingTopUpCycle;
    uint256 public pendingTopUpAmount;

    /// @notice Optional override of the Base command type this controller emits for top-ups.
    ///         Gateway currently implements TOPUP_PM_BUFFER / TOPUP_HL_BUFFER / PAUSE. Operators may
    ///         set this to PM or HL (whichever funding rail their PT buffer shares) until a dedicated
    ///         TOPUP_PT_BUFFER command type is added to the gateway.
    CrossVenueCommandLib.CommandType public topUpCommandType;

    // ─── Autonomy primitives (mirror MultiLegController patterns) ───────────

    /// @dev Dedicated role for posting funding receipts. If zero, only owner/vaultManager can
    ///      call `ingestFundingReceipt`. Operators set this to the adapter's Ritual EOA so the
    ///      adapter can autonomously ack top-up settlement.
    address public funder;

    /// @dev Block number when the current pending async job started. Used by tick() to detect
    ///      stuck ITER_PENDING / VALUATION_PENDING states and auto-reset after `maxPendingBlocks`.
    uint256 public pendingSinceBlock;
    uint256 public maxPendingBlocks; // 0 = disable auto-recovery

    /// @dev Auto-clear counter for ITER_FAILED. Incremented on each auto-clear, reset on any
    ///      successful iteration fill. Past `legFailThreshold` (0 = unlimited), tick() stops
    ///      auto-clearing and the operator must call clearRecovery().
    uint256 public legFailCount;
    uint256 public legFailThreshold;

    /// @dev Deferred async-submit queue. Ritual enforces one 0x0805 precompile call per tx, so
    ///      callbacks that need to trigger the next async hop queue their intent here and the
    ///      next `tick()` dispatches. Kinds:
    ///        0 = none
    ///        1 = top-up (re-emit command — `_tryEmitTopUp` path)
    ///        2 = submit next iteration (data = iteration index)
    ///        3 = submit valuation sync after all iterations done
    ///        4 = emit REFILL_RESERVE on Base after unwind-cycle (data = realized USD)
    uint8 internal _deferredKind;
    uint256 internal _deferredData;

    // ─── NAV + reserve (populated by onValuationSync) ───────────────────────

    uint256 public lastNavUsd;
    uint256 public lastBaseReserveUsd;
    uint256 public lastValuationTimestamp;

    /// @notice If non-zero, tick() auto-triggers a partial unwind when Base reserve falls below
    ///         this floor. Operator-set. 0 disables (manual-only).
    uint256 public minBaseReserveUsd;

    /// @notice Where REFILL_RESERVE commands route (usually `keccak("dest:refill")`).
    bytes32 public reserveDestinationRef;

    // ─── Unwind state ───────────────────────────────────────────────────────

    /// @dev True during cycles started by requestPartialUnwind / auto-unwind. Gates the
    ///      isUnwind flag in PtIterationIntent so the adapter routes to exitLoop.
    bool internal _currentCycleIsUnwind;
    /// @dev Target position size after the unwind cycle completes (0 = full close). Adapter
    ///      only supports target=0 in MVP; partial-shrink accounting TBD.
    uint256 internal _unwindTargetOverrideUsd;
    /// @dev USD amount we expect to realize back to Base after the unwind cycle. Used to size
    ///      the subsequent REFILL_RESERVE command.
    uint256 internal _unwindShortfallUsd;

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

    constructor() {
        _initialized = true;
    }

    receive() external payable {}

    struct InitParams {
        address owner;
        address vaultManager;
        address baseVault;
        address baseAsset;
        bytes32 strategyId;
        string adapterUrl;
        address executor;
        PtLoopConfig cfg;
        CrossVenueCommandLib.CommandType topUpCommandType;
        /// @dev Adapter's Ritual EOA — autonomously acks funding receipts via `ingestFundingReceipt`.
        ///      Set to address(0) to disable autonomous funding ack (owner/vaultManager-only).
        address funder;
        /// @dev destinationRef used to emit REFILL_RESERVE commands on Base after unwind cycles.
        ///      Typically `keccak256("dest:refill")`.
        bytes32 reserveDestinationRef;
        /// @dev If non-zero, tick() auto-triggers partial unwinds when Base reserve < this floor.
        uint256 minBaseReserveUsd;
    }

    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        if (p.owner == address(0) || p.baseVault == address(0) || p.baseAsset == address(0)) revert InvalidAddress();
        if (p.cfg.maxLoops == 0 || p.cfg.loopNotionalUsd == 0) revert InvalidConfig();
        if (p.cfg.envelopeTtlSeconds == 0 || p.cfg.bufferStalenessSeconds == 0) revert InvalidConfig();
        if (p.topUpCommandType == CrossVenueCommandLib.CommandType.PAUSE) revert InvalidConfig();
        _validatePtConfig(p.cfg);

        _initialized = true;
        owner = p.owner;
        vaultManager = p.vaultManager == address(0) ? p.owner : p.vaultManager;
        baseVault = p.baseVault;
        baseAsset = p.baseAsset;
        strategyId = p.strategyId;

        adapterUrl = p.adapterUrl;
        executor = p.executor;
        // Autonomy-ready defaults — operator can still override via setHttpConfig /
        // setAutonomyParams. Values chosen to match the live multileg runbook from the Apr 2026
        // testnet ops (see DEPLOYMENT.md §10 pitfalls #8, #19):
        //   pollIntervalBlocks=25  — 25 blocks ≈ 8.75s at 350ms/block
        //   maxPollBlock=4500      — polling budget for Long-Running HTTP
        //   deliveryGasLimit=2_000_000 — Phase 2 delivery needs ≫300k for decodeEnvelope + storage
        //                                writes + event emits; default 300k OOGs silently.
        //   httpTtl=30             — Circle-advised working max; 200 gets silently rejected.
        //   maxPendingBlocks=200   — auto-recover FSM if AsyncDelivery drops a callback
        //   legFailThreshold=3     — allow up to 3 auto-retries before requiring manual intervention
        pollIntervalBlocks = 25;
        maxPollBlock = 4500;
        deliveryGasLimit = 2_000_000;
        httpTtl = 30;
        maxPendingBlocks = 200;
        legFailThreshold = 3;
        funder = p.funder;

        cfg = p.cfg;
        topUpCommandType = p.topUpCommandType;
        reserveDestinationRef = p.reserveDestinationRef;
        minBaseReserveUsd = p.minBaseReserveUsd;
        fundingState = PtFundingState.STALE;
        tradingState = PtTradingState.IDLE;
        nextCycleSeq = 1;
    }

    // ─── Admin ───────────────────────────────────────────────────────────────

    function setAdapterUrl(string calldata u) external onlyOwner {
        adapterUrl = u;
    }

    function setExecutor(address e) external onlyOwner {
        executor = e;
    }

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

    /// @notice Deposit `msg.value` into RitualWallet + schedule `tick` + `syncValuation` via the Scheduler.
    ///         See MultiLegController.fundAndSchedule for parameter semantics.
    function fundAndSchedule(
        uint32 tickFreq,
        uint32 valuationFreq,
        uint32 tickNumCalls,
        uint32 valuationNumCalls,
        uint32 gasLimit,
        uint256 maxFeePerGas,
        uint32 lockDurationBlocks
    ) external payable onlyOwner {
        _cacheScheduleParams(tickFreq, valuationFreq, tickNumCalls, valuationNumCalls, gasLimit, maxFeePerGas);

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
            msg.value,
            perCallHttpBudget
        );
    }

    function _cacheScheduleParams(
        uint32 _tickFreq,
        uint32 _valuationFreq,
        uint32 _tickNumCalls,
        uint32 _valuationNumCalls,
        uint32 _gasLimit,
        uint256 _maxFeePerGas
    ) internal {
        tickFreq = _tickFreq;
        valuationFreq = _valuationFreq;
        tickNumCalls = _tickNumCalls;
        valuationNumCalls = _valuationNumCalls;
        scheduleGasLimit = _gasLimit;
        scheduleMaxFeePerGas = _maxFeePerGas;
        if (scheduleRenewThreshold == 0) scheduleRenewThreshold = 2;
        if (perCallHttpBudget == 0) perCallHttpBudget = 2e15;
    }

    /// @notice Owner escape hatch: update the renewal threshold. Default 2 (renew when the
    ///         current batch has ≤2 executions left). Higher = earlier renewal (safer).
    function setScheduleRenewThreshold(uint32 t) external onlyOwner {
        scheduleRenewThreshold = t;
    }

    /// @notice Owner escape hatch: update the per-tick HTTP fee estimate. Raise this if the
    ///         async HTTP precompile's real cost climbs (renewals would otherwise over-commit
    ///         and fail mid-batch). Pass 0 only if scheduled callbacks don't emit 0x0805 calls.
    function setPerCallHttpBudget(uint256 b) external onlyOwner {
        perCallHttpBudget = b;
    }

    /// @notice Owner-only rescue of funds deposited into the Ritual system wallet under this
    ///         clone's account. Calls `RitualWallet.withdraw(amount)` which returns native RITUAL
    ///         to this contract, then forwards to `to`. Without this, deposits made via
    ///         `fundAndSchedule` would be permanently stranded if the schedule is retired early.
    function withdrawRitualWallet(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0) || amount == 0) revert InvalidAddress();
        IRitualWallet(RitualPrecompiles.RITUAL_WALLET).withdraw(amount);
        (bool ok,) = to.call{value: amount}("");
        require(ok, "native forward failed");
    }

    /// @dev Renew the tick schedule if we're in the last `scheduleRenewThreshold` executions of
    ///      the current batch. Skips silently if RitualWallet balance can't cover at least one
    ///      full new batch — prevents partial renewal that would eat all remaining funds without
    ///      producing a usable schedule. Caller: tick() on every execution.
    function _maybeRenewTick(uint256 executionIndex) internal {
        if (tickNumCalls == 0) return;
        if (executionIndex + scheduleRenewThreshold < tickNumCalls) return;
        if (!_hasRitualBalanceFor(tickNumCalls)) return;
        tickScheduleId = SchedulerSetupLib.renewCallback(
            this.tick.selector,
            tickFreq,
            tickNumCalls,
            scheduleGasLimit,
            scheduleMaxFeePerGas,
            tickFreq
        );
    }

    function _maybeRenewValuation(uint256 executionIndex) internal {
        if (valuationNumCalls == 0) return;
        if (executionIndex + scheduleRenewThreshold < valuationNumCalls) return;
        if (!_hasRitualBalanceFor(valuationNumCalls)) return;
        valuationScheduleId = SchedulerSetupLib.renewCallback(
            this.syncValuation.selector,
            valuationFreq,
            valuationNumCalls,
            scheduleGasLimit,
            scheduleMaxFeePerGas,
            valuationFreq
        );
    }

    function _hasRitualBalanceFor(uint32 numCalls) internal view returns (bool) {
        uint256 cost = (uint256(scheduleGasLimit) * scheduleMaxFeePerGas + perCallHttpBudget) * numCalls;
        return IRitualWallet(RitualPrecompiles.RITUAL_WALLET).balanceOf(address(this)) >= cost;
    }

    /// @notice Replace the stored ECIES-encrypted venue secrets and their owner-EOA signatures.
    ///         Body extracted to `ControllerAdminLib` to stay under EIP-170.
    function setSecrets(bytes[] calldata blobs, bytes[] calldata sigs) external onlyOwner {
        ControllerAdminLib.applySecrets(_encryptedSecrets, _secretSignatures, blobs, sigs);
    }

    function getSecrets() external view returns (bytes[] memory blobs, bytes[] memory sigs) {
        blobs = _encryptedSecrets;
        sigs = _secretSignatures;
    }

    function setConfig(PtLoopConfig calldata c) external onlyOwner {
        if (c.maxLoops == 0 || c.loopNotionalUsd == 0) revert InvalidConfig();
        if (c.envelopeTtlSeconds == 0 || c.bufferStalenessSeconds == 0) revert InvalidConfig();
        _validatePtConfig(c);
        cfg = c;
    }

    /// @dev Structural (on-chain) validation. Live-state checks (does the Pendle market exist on
    ///      Arb? is Silo-for-this-PT listed? does its LTV support the target leverage?) happen
    ///      adapter-side because Ritual can't read Arb contracts. Ritual guarantees only:
    ///      (1) user gave a non-zero market ref,
    ///      (2) leverage is within global sanity bounds [1.0x, 10x],
    ///      (3) HF floor is above the protocol minimum (1.10) whenever leverage > 1.
    ///      Adapter emits ExecStatus.Failed at runtime if anything more nuanced breaks.
    function _validatePtConfig(PtLoopConfig calldata c) internal pure {
        if (c.marketRef == bytes32(0)) revert InvalidConfig();
        if (c.destinationRef == bytes32(0)) revert InvalidConfig();
        if (c.targetChainId == 0) revert InvalidConfig();
        if (c.morphoMarketId == bytes32(0)) revert InvalidConfig();
        // leverage = 0 disallowed (caller must set 10_000 for "no leverage" explicitly);
        // cap at 100_000 bps = 10x. Higher than that is "trust me bro" territory.
        if (c.targetLeverageBps < 10_000 || c.targetLeverageBps > 100_000) revert InvalidConfig();
        // HF floor 11_000 bps = 1.10 applies whenever leverage > 1. At leverage=1 there's no debt
        // so HF is undefined; we ignore hfMinBps in that case.
        if (c.targetLeverageBps > 10_000 && c.hfMinBps < 11_000) revert InvalidConfig();
    }

    function setSecretHeaders(string[] calldata keys, string[] calldata values) external onlyOwner {
        ControllerAdminLib.applyHeaders(secretHeaderKeys, secretHeaderValues, keys, values);
    }

    function pauseTrading() external onlyVaultManager {
        _setTradingState(PtTradingState.PAUSED);
    }

    function unpauseTrading() external onlyVaultManager {
        if (tradingState != PtTradingState.PAUSED) revert InvalidState();
        _setTradingState(PtTradingState.IDLE);
    }

    function pauseFunding() external onlyVaultManager {
        _setFundingState(PtFundingState.PAUSED);
    }

    function unpauseFunding() external onlyVaultManager {
        if (fundingState != PtFundingState.PAUSED) revert InvalidState();
        _setFundingState(PtFundingState.STALE);
    }

    function clearRecovery() external onlyVaultManager {
        if (tradingState != PtTradingState.RECOVERY_REQUIRED && tradingState != PtTradingState.ITER_FAILED) {
            revert InvalidState();
        }
        _setTradingState(PtTradingState.IDLE);
    }

    function setMinBaseReserveUsd(uint256 v) external onlyOwner {
        minBaseReserveUsd = v;
    }

    function setReserveDestinationRef(bytes32 r) external onlyOwner {
        reserveDestinationRef = r;
    }

    // ─── Unwind / shrink ─────────────────────────────────────────────────────

    /// @notice Shrink the PT loop position. MVP: only full close (`shortfallUsd >= lastNavUsd`)
    ///         is fully supported — target=0. Partial-shrink target sizing is reserved for a
    ///         future iteration (requires proportional repay/withdraw accounting).
    function requestPartialUnwind(uint256 shortfallUsd) external nonReentrant onlyVaultManager {
        _internalPartialUnwind(shortfallUsd);
    }

    function _internalPartialUnwind(uint256 shortfallUsd) internal returns (bytes32 cid) {
        if (tradingState != PtTradingState.IDLE) revert InvalidState();
        if (shortfallUsd == 0) revert InvalidConfig();
        uint256 nav = lastNavUsd;
        if (nav == 0) revert InvalidState();

        uint256 capped = shortfallUsd > nav ? nav : shortfallUsd;
        // MVP: always full close. If the operator wants partial, we treat it as full close
        // until proportional shrink is wired. Safer default — full unwind guarantees clean
        // state for REFILL_RESERVE.
        _currentCycleIsUnwind = true;
        _unwindShortfallUsd = capped;
        _unwindTargetOverrideUsd = 0;

        cid = _newCycleId();
        currentCycleId = cid;
        currentIteration = 0;
        currentCycleFilledTotalUsd = 0;
        emit PtLoopCycleRequested(cid, 1 /* single unwind iteration */, capped);
        _submitIteration(0);
    }

    // ─── Scheduler entrypoints ───────────────────────────────────────────────

    function tick(uint256 executionIndex) external nonReentrant onlySchedulerOrOwner {
        // Auto-recovery for dropped AsyncDelivery callbacks. Mirrors MultiLegController pattern.
        _autoRecoverIfStuck();

        // Self-renew the tick schedule before the current batch exhausts. No-op if we're not
        // in the last `scheduleRenewThreshold` executions, or if RitualWallet balance can't
        // cover a fresh batch. Runs first so a failure-state early-return below doesn't block
        // the renewal.
        _maybeRenewTick(executionIndex);

        if (tradingState == PtTradingState.PAUSED || fundingState == PtFundingState.PAUSED) return;
        if (tradingState == PtTradingState.RECOVERY_REQUIRED) return;
        // Auto-clear ITER_FAILED so the next cycle can retry. Capped by legFailThreshold so
        // repeated failures don't silently burn Ritual gas — past the cap the operator must
        // call clearRecovery() to resume.
        if (tradingState == PtTradingState.ITER_FAILED) {
            legFailCount += 1;
            if (legFailThreshold > 0 && legFailCount > legFailThreshold) return;
            _setTradingState(PtTradingState.IDLE);
        }

        // Drain any submit deferred by a prior callback (Ritual enforces one 0x0805 per tx).
        if (_dispatchDeferred()) return;

        if (_bufferStale()) {
            if (pendingBufferSyncJobId == bytes32(0)) _submitBufferSync();
            return;
        }
        if (fundingState == PtFundingState.TOPUP_PENDING) return;

        // Auto-unwind on low reserve — mirrors MultiLegController pattern. Only when IDLE and
        // NAV has been populated by a valuation sync. Uses `_internalPartialUnwind` so the
        // REFILL_RESERVE emission path runs at cycle completion.
        if (
            minBaseReserveUsd > 0 && lastValuationTimestamp > 0 && lastBaseReserveUsd < minBaseReserveUsd
                && tradingState == PtTradingState.IDLE && lastNavUsd > 0
        ) {
            uint256 shortfall = minBaseReserveUsd - lastBaseReserveUsd;
            _internalPartialUnwind(shortfall);
            return;
        }

        if (_tryEmitTopUp()) return;
        if (tradingState == PtTradingState.IDLE) _tryStartCycle();
    }

    /// @dev Clear pending-async stale state after `maxPendingBlocks`, resetting tradingState to
    ///      IDLE so the next tick can progress. No-op if maxPendingBlocks=0.
    function _autoRecoverIfStuck() internal {
        if (maxPendingBlocks == 0) return;
        bool anyPending = pendingIterJobId != bytes32(0) || pendingValuationJobId != bytes32(0)
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
        pendingIterJobId = bytes32(0);
        pendingValuationJobId = bytes32(0);
        pendingBaseCommandJobId = bytes32(0);
        pendingBufferSyncJobId = bytes32(0);
        pendingSinceBlock = 0;
        if (tradingState == PtTradingState.ITER_PENDING || tradingState == PtTradingState.VALUATION_PENDING) {
            _setTradingState(PtTradingState.IDLE);
        }
    }

    function syncValuation(uint256 executionIndex) external nonReentrant onlySchedulerOrOwner {
        _maybeRenewValuation(executionIndex);
        if (tradingState == PtTradingState.ITER_PENDING) return;
        if (pendingValuationJobId != bytes32(0)) return;
        _submitValuationSync();
    }

    function requestCycle() external nonReentrant onlyVaultManager {
        if (tradingState != PtTradingState.IDLE) revert InvalidState();
        if (_bufferStale()) revert InvalidState();
        _tryStartCycle();
    }

    // ─── Callbacks ───────────────────────────────────────────────────────────

    /// @notice NOTE: AsyncDelivery passes the Phase 1 origin tx hash as `jobId`, NOT the
    ///         controller-computed id we stored. `onlyAsyncDelivery` is the authoritative auth
    ///         check — do NOT gate on jobId equality. Just use the stored id as a "are we
    ///         expecting a callback at all" flag and silently return if not.
    function onBufferSyncResult(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        if (pendingBufferSyncJobId == bytes32(0)) return;
        pendingBufferSyncJobId = bytes32(0);

        (uint16 statusCode, bytes memory body, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) {
            _setFundingState(PtFundingState.STALE);
            return;
        }
        PtBufferSnapshot memory snap = abi.decode(body, (PtBufferSnapshot));
        bufferSnapshot = snap;
        emit PtBufferSnapshotUpdated(snap.bufferUsd, snap.timestamp);
        if (fundingState == PtFundingState.STALE) _setFundingState(PtFundingState.OK);

        // Can't submit another 0x0805 call here (Ritual: one per tx). Queue for next tick if
        // buffer is below min.
        if (snap.bufferUsd < cfg.bufferMinUsd) {
            _deferredKind = 1;
            _deferredData = 0;
        }
    }

    /// @notice Silent-guard pattern: reverting here would make AsyncDelivery re-poke the
    ///         precompile, which re-POSTs /pt/execute → duplicate adapter calls → duplicate
    ///         enterLoop txs on Arb → over-leveraged position. Return silently if state moved
    ///         on. Use the stored jobId solely as an "expecting a callback" flag (AsyncDelivery
    ///         actually passes a different value — it's the phase-1 tx hash).
    function onIterationResult(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        if (tradingState != PtTradingState.ITER_PENDING) return;
        if (pendingIterJobId == bytes32(0)) return;
        pendingIterJobId = bytes32(0);

        NormalizedExecutionReceipt memory r = _decodeReceipt(result);
        uint16 iter = currentIteration;
        emit PtLoopIterationFill(currentCycleId, iter, r.status, r.filledNotionalUsd);

        bool ok = (r.status == ExecStatus.Filled || r.status == ExecStatus.PartialFill) && r.filledNotionalUsd > 0;
        if (!ok) {
            if (iter == 0) {
                _setTradingState(PtTradingState.ITER_FAILED);
                emit PtLoopRecoveryMarked(currentCycleId, iter, "first iter failed");
            } else {
                _setTradingState(PtTradingState.RECOVERY_REQUIRED);
                emit PtLoopRecoveryMarked(currentCycleId, iter, "mid-loop iter failed");
            }
            return;
        }

        // Successful fill resets the ITER_FAILED auto-clear counter.
        legFailCount = 0;
        currentCycleFilledTotalUsd += r.filledNotionalUsd;

        // Can't nest another 0x0805 call from a callback — queue for next tick dispatch.
        uint16 next = iter + 1;
        if (next >= cfg.maxLoops) {
            _deferredKind = 3;
            _deferredData = 0;
        } else {
            _deferredKind = 2;
            _deferredData = next;
        }
    }

    /// @notice AsyncDelivery ALWAYS calls callbacks with `(bytes32 jobId, bytes result)`. Previous
    ///         `(bytes)` signature triggered calldata-length revert and the state machine got
    ///         stuck. The ignored `jobId` argument is structural — must be present in the ABI.
    function onValuationSync(bytes32 /* jobId */, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        pendingValuationJobId = bytes32(0);
        (uint16 statusCode, bytes memory body, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) return;

        // Valuation body shape matches MultiLegController.onValuationSync — keeps the adapter's
        // /valuation response format uniform across archetypes.
        (uint256 navUsd, uint256 baseReserveUsd, , ) = abi.decode(body, (uint256, uint256, bytes32, bool));
        lastNavUsd = navUsd;
        lastBaseReserveUsd = baseReserveUsd;
        lastValuationTimestamp = block.timestamp;

        if (tradingState == PtTradingState.VALUATION_PENDING) {
            _setTradingState(PtTradingState.READY);
            // If this was an unwind cycle, queue a REFILL_RESERVE on Base (deferred — can't
            // nest another 0x0805 call from a callback).
            if (_currentCycleIsUnwind && _unwindShortfallUsd > 0) {
                _deferredKind = 4;
                _deferredData = _unwindShortfallUsd;
            } else {
                _clearUnwindState();
            }
            _setTradingState(PtTradingState.IDLE);
        }
    }

    function _clearUnwindState() internal {
        _currentCycleIsUnwind = false;
        _unwindShortfallUsd = 0;
        _unwindTargetOverrideUsd = 0;
    }

    function ingestFundingReceipt(FundingReceipt calldata receipt) external {
        if (msg.sender != owner && msg.sender != vaultManager && msg.sender != funder) {
            revert NotVaultManager();
        }
        if (pendingTopUpCycle != receipt.cycleId) revert InvalidJobId();
        pendingTopUpCycle = bytes32(0);
        pendingTopUpAmount = 0;
        if (fundingState == PtFundingState.TOPUP_PENDING) _setFundingState(PtFundingState.OK);
        emit PtFundingReceiptIngested(receipt.cycleId, receipt.commandType, receipt.status);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _bufferStale() internal view returns (bool) {
        if (bufferSnapshot.timestamp == 0) return true;
        // Ritual block.timestamp is in MILLISECONDS — `bufferStalenessSeconds` is also stored in
        // ms despite the misleading name (operator passes 3_600_000 for 1hr). Same convention
        // as MultiLegController. Converting now would break existing configs.
        return block.timestamp > bufferSnapshot.timestamp + cfg.bufferStalenessSeconds;
    }

    /// @notice Drain the deferred-submit queue set by a callback. Returns true if dispatched.
    function _dispatchDeferred() internal returns (bool) {
        uint8 kind = _deferredKind;
        if (kind == 0) return false;
        uint256 data = _deferredData;
        _deferredKind = 0;
        _deferredData = 0;
        if (kind == 1) {
            // Top-up: re-emit command for the single buffer. Drain slot either way so we don't
            // spin on the same shortfall.
            if (bufferSnapshot.bufferUsd >= cfg.bufferMinUsd) return true;
            uint256 amount = cfg.bufferTargetUsd - bufferSnapshot.bufferUsd;
            _emitCommand(topUpCommandType, amount, cfg.destinationRef);
            pendingTopUpAmount = amount;
            pendingTopUpCycle = currentCycleId == bytes32(0) ? _newCycleId() : currentCycleId;
            _setFundingState(PtFundingState.TOPUP_PENDING);
            // Silence unused-var complaint — `data` reserved for future per-leg addressing.
            data;
        } else if (kind == 2) {
            currentIteration = uint16(data);
            _submitIteration(uint16(data));
        } else if (kind == 3) {
            _setTradingState(PtTradingState.VALUATION_PENDING);
            emit PtLoopCycleCompleted(currentCycleId, currentIteration + 1);
            _submitValuationSync();
        } else if (kind == 4) {
            // Unwind cycle finished + USDC returned to Base module. Fire REFILL_RESERVE so the
            // module credits the sleeve. `data` is the realized USD amount.
            emit ReserveRefillReady(currentCycleId, data);
            _emitCommand(CrossVenueCommandLib.CommandType.REFILL_RESERVE, data, reserveDestinationRef);
            _clearUnwindState();
        }
        return true;
    }

    // ─── Admin extras (autonomy + recovery) ─────────────────────────────────

    function setFunder(address f) external onlyOwner {
        funder = f;
    }

    function setAutonomyParams(uint256 newMaxPendingBlocks, uint256 newLegFailThreshold) external onlyOwner {
        maxPendingBlocks = newMaxPendingBlocks;
        legFailThreshold = newLegFailThreshold;
    }

    /// @notice Admin escape hatch: clear frozen pending job IDs when AsyncDelivery silently
    ///         drops a callback. Each bool wipes the corresponding pending ID — next tick() can
    ///         then retry. Does NOT reset funding/trading state; use clearRecovery() / unpause.
    function forceClearPending(bool iter, bool bufferSync, bool valuation, bool baseCommand)
        external
        onlyVaultManager
    {
        if (iter) pendingIterJobId = bytes32(0);
        if (bufferSync) pendingBufferSyncJobId = bytes32(0);
        if (valuation) pendingValuationJobId = bytes32(0);
        if (baseCommand) pendingBaseCommandJobId = bytes32(0);
        pendingSinceBlock = 0;
    }

    function _tryEmitTopUp() internal returns (bool acted) {
        if (fundingState == PtFundingState.PAUSED || fundingState == PtFundingState.STALE) return false;
        if (bufferSnapshot.bufferUsd >= cfg.bufferMinUsd) {
            if (fundingState != PtFundingState.OK) _setFundingState(PtFundingState.OK);
            return false;
        }
        uint256 amount = cfg.bufferTargetUsd - bufferSnapshot.bufferUsd;
        _emitCommand(topUpCommandType, amount, cfg.destinationRef);
        pendingTopUpAmount = amount;
        pendingTopUpCycle = currentCycleId == bytes32(0) ? _newCycleId() : currentCycleId;
        _setFundingState(PtFundingState.TOPUP_PENDING);
        return true;
    }

    function _emitCommand(CrossVenueCommandLib.CommandType cmd, uint256 amount, bytes32 destinationRef) internal {
        bytes32 cycleId = currentCycleId == bytes32(0) ? _newCycleId() : currentCycleId;
        // Stateless nonce: keccak(cycleId, cmd, destinationRef). See MultiLegController._emitCommand
        // for the rationale — avoids counter-rollback when Ritual tick tx reverts after async dispatch.
        uint256 nonce = uint256(keccak256(abi.encode(cycleId, cmd, destinationRef)));
        // Ritual block.timestamp is ms; Base validates deadline in seconds. Convert before TTL.
        uint256 deadline = (block.timestamp / 1000) + cfg.envelopeTtlSeconds;
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
        pendingBaseCommandJobId = keccak256(abi.encodePacked("pt-base-cmd", env.nonce, block.number));
        lastSubmittedCommandNonce = bytes32(env.nonce);
        MultiLegSubmitLib.dispatch(
            _submitCtx(), "/base/execute-command", abi.encode(env), this.onBaseCommandSubmitted.selector
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

        // Critical for autonomy: clear TOPUP_PENDING on success + invalidate the buffer
        // snapshot so the next tick forces a fresh /pt/buffer read reflecting the newly-
        // received funds (instead of waiting for bufferStalenessSeconds to expire). Without
        // this, the FSM is stuck TOPUP_PENDING forever.
        if (success && fundingState == PtFundingState.TOPUP_PENDING) {
            bufferSnapshot.timestamp = 0;
            pendingTopUpCycle = bytes32(0);
            pendingTopUpAmount = 0;
            _setFundingState(PtFundingState.OK);
        }
    }

    function _tryStartCycle() internal {
        if (tradingState != PtTradingState.IDLE) return;
        if (fundingState != PtFundingState.OK) return;

        bytes32 cid = _newCycleId();
        currentCycleId = cid;
        currentIteration = 0;
        currentCycleFilledTotalUsd = 0;
        emit PtLoopCycleRequested(cid, cfg.maxLoops, cfg.loopNotionalUsd);
        _submitIteration(0);
    }

    function _submitIteration(uint16 iter) internal {
        // Open path: `loopNotionalUsd` is the per-iteration base amount.
        // Unwind path: use the override target (0 for full close in MVP). Adapter routes to
        // exitLoop when isUnwind=true.
        uint256 targetNotional = _currentCycleIsUnwind ? _unwindTargetOverrideUsd : cfg.loopNotionalUsd;

        ExecutionIntent memory intent = ExecutionIntent({
            cycleId: currentCycleId,
            venue: VENUE_PENDLE,
            marketRef: cfg.marketRef,
            side: _currentCycleIsUnwind ? Side.Sell : Side.Buy,
            targetNotionalUsd: targetNotional,
            maxSlippageBps: cfg.maxSlippageBps,
            expiryBlock: block.number + maxPollBlock,
            idempotencyKey: keccak256(abi.encodePacked(currentCycleId, "pt-iter", iter)),
            marginMode: MarginMode.Isolated // Pendle isn't margin-based; field is inert here
        });
        // Wrap the generic intent with PT-specific leverage + HF floor + unwind flag so the
        // adapter can size the sandwich and route open-vs-shrink without heuristics.
        PtIterationIntent memory ptIntent = PtIterationIntent({
            intent: intent,
            targetLeverageBps: cfg.targetLeverageBps,
            hfMinBps: cfg.hfMinBps,
            targetChainId: cfg.targetChainId,
            morphoMarketId: cfg.morphoMarketId,
            isUnwind: _currentCycleIsUnwind
        });
        bytes32 jobId = keccak256(abi.encodePacked(intent.idempotencyKey, block.number));
        pendingIterJobId = jobId;
        MultiLegSubmitLib.dispatch(
            _submitCtx(), "/pt/execute", abi.encode(ptIntent), this.onIterationResult.selector
        );
        _setTradingState(PtTradingState.ITER_PENDING);
        emit PtLoopIterationSubmitted(currentCycleId, iter, jobId, cfg.loopNotionalUsd);
    }

    function _submitBufferSync() internal {
        bytes32 jobId = keccak256(abi.encodePacked(strategyId, "pt-buffer", block.number));
        pendingBufferSyncJobId = jobId;
        MultiLegSubmitLib.dispatch(
            _submitCtx(), "/pt/buffer", abi.encode(strategyId), this.onBufferSyncResult.selector
        );
        emit PtBufferSyncSubmitted(jobId);
    }

    function _submitValuationSync() internal {
        bytes32 jobId = keccak256(abi.encodePacked(strategyId, "pt-val", block.number));
        pendingValuationJobId = jobId;
        MultiLegSubmitLib.dispatch(
            _submitCtx(), "/pt/valuation", abi.encode(strategyId), this.onValuationSync.selector
        );
        emit PtValuationSyncSubmitted(jobId);
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

    function _setFundingState(PtFundingState next) internal {
        if (fundingState == next) return;
        fundingState = next;
        emit PtFundingStateChanged(next);
    }

    function _setTradingState(PtTradingState next) internal {
        if (tradingState == next) return;
        tradingState = next;
        emit PtTradingStateChanged(next);
    }
}
