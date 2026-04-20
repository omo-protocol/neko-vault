// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RitualPrecompiles} from "../../interfaces/ritual/IRitualPrecompiles.sol";
import {SchedulerSetupLib} from "./SchedulerSetupLib.sol";
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
    BaseCommandFailed
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
    bytes32 marketRef;
    uint16 maxSlippageBps;
    uint16 maxLoops; // iterations per cycle
    uint256 loopNotionalUsd; // notional per iteration
    uint256 bufferTargetUsd;
    uint256 bufferMinUsd;
    bytes32 destinationRef; // PT funding rail ref
    uint256 bufferStalenessSeconds;
    uint256 envelopeTtlSeconds;
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
    }

    function initialize(InitParams calldata p) external {
        if (_initialized) revert AlreadyInitialized();
        if (p.owner == address(0) || p.baseVault == address(0) || p.baseAsset == address(0)) revert InvalidAddress();
        if (p.cfg.maxLoops == 0 || p.cfg.loopNotionalUsd == 0) revert InvalidConfig();
        if (p.cfg.envelopeTtlSeconds == 0 || p.cfg.bufferStalenessSeconds == 0) revert InvalidConfig();
        if (p.topUpCommandType == CrossVenueCommandLib.CommandType.PAUSE) revert InvalidConfig();

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
        httpTtl = 200;

        cfg = p.cfg;
        topUpCommandType = p.topUpCommandType;
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

    /// @notice Replace the stored ECIES-encrypted venue secrets and their owner-EOA signatures.
    ///         See MultiLegController.setSecrets for the full flow.
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

    function setConfig(PtLoopConfig calldata c) external onlyOwner {
        if (c.maxLoops == 0 || c.loopNotionalUsd == 0) revert InvalidConfig();
        if (c.envelopeTtlSeconds == 0 || c.bufferStalenessSeconds == 0) revert InvalidConfig();
        cfg = c;
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

    // ─── Scheduler entrypoints ───────────────────────────────────────────────

    function tick(uint256 /* executionIndex */) external nonReentrant onlySchedulerOrOwner {
        if (tradingState == PtTradingState.PAUSED || fundingState == PtFundingState.PAUSED) return;
        if (tradingState == PtTradingState.RECOVERY_REQUIRED || tradingState == PtTradingState.ITER_FAILED) return;

        if (_bufferStale()) {
            if (pendingBufferSyncJobId == bytes32(0)) _submitBufferSync();
            return;
        }
        if (fundingState == PtFundingState.TOPUP_PENDING) return;
        if (_tryEmitTopUp()) return;
        if (tradingState == PtTradingState.IDLE) _tryStartCycle();
    }

    function syncValuation(uint256 /* executionIndex */) external nonReentrant onlySchedulerOrOwner {
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

    function onBufferSyncResult(bytes32 jobId, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        if (pendingBufferSyncJobId != jobId) revert InvalidJobId();
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
        _tryEmitTopUp();
    }

    function onIterationResult(bytes32 jobId, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        if (tradingState != PtTradingState.ITER_PENDING) revert InvalidState();
        if (pendingIterJobId != jobId) revert InvalidJobId();
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

        currentCycleFilledTotalUsd += r.filledNotionalUsd;
        uint16 next = iter + 1;
        if (next >= cfg.maxLoops) {
            _setTradingState(PtTradingState.VALUATION_PENDING);
            emit PtLoopCycleCompleted(currentCycleId, next);
            _submitValuationSync();
            return;
        }
        currentIteration = next;
        _submitIteration(next);
    }

    function onValuationSync(bytes calldata result) external onlyAsyncDelivery nonReentrant {
        pendingValuationJobId = bytes32(0);
        (uint16 statusCode,, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) return;
        if (tradingState == PtTradingState.VALUATION_PENDING) {
            _setTradingState(PtTradingState.READY);
            _setTradingState(PtTradingState.IDLE);
        }
    }

    function ingestFundingReceipt(FundingReceipt calldata receipt) external onlyVaultManager {
        if (pendingTopUpCycle != receipt.cycleId) revert InvalidJobId();
        pendingTopUpCycle = bytes32(0);
        pendingTopUpAmount = 0;
        if (fundingState == PtFundingState.TOPUP_PENDING) _setFundingState(PtFundingState.OK);
        emit PtFundingReceiptIngested(receipt.cycleId, receipt.commandType, receipt.status);
    }

    // ─── Internal ────────────────────────────────────────────────────────────

    function _bufferStale() internal view returns (bool) {
        if (bufferSnapshot.timestamp == 0) return true;
        return block.timestamp > bufferSnapshot.timestamp + cfg.bufferStalenessSeconds;
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

    function onBaseCommandSubmitted(bytes32 jobId, bytes calldata result) external onlyAsyncDelivery nonReentrant {
        if (pendingBaseCommandJobId != jobId) revert InvalidJobId();
        pendingBaseCommandJobId = bytes32(0);

        (uint16 statusCode, bytes memory body, string memory errorMessage) = RitualHttpLib.decodeEnvelope(result);
        if (statusCode < 200 || statusCode >= 300 || bytes(errorMessage).length > 0) {
            emit BaseCommandFailed(lastSubmittedCommandNonce, statusCode, errorMessage);
            return;
        }
        (bytes32 baseTxHash, bool success,) = abi.decode(body, (bytes32, bool, string));
        emit BaseCommandSubmitted(lastSubmittedCommandNonce, baseTxHash, success);
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
        ExecutionIntent memory intent = ExecutionIntent({
            cycleId: currentCycleId,
            venue: VENUE_PENDLE,
            marketRef: cfg.marketRef,
            side: Side.Buy,
            targetNotionalUsd: cfg.loopNotionalUsd,
            maxSlippageBps: cfg.maxSlippageBps,
            expiryBlock: block.number + maxPollBlock,
            idempotencyKey: keccak256(abi.encodePacked(currentCycleId, "pt-iter", iter)),
            marginMode: MarginMode.Isolated // Pendle isn't margin-based; field is inert here
        });
        bytes32 jobId = keccak256(abi.encodePacked(intent.idempotencyKey, block.number));
        pendingIterJobId = jobId;
        MultiLegSubmitLib.dispatch(
            _submitCtx(), "/pt/execute", abi.encode(intent), this.onIterationResult.selector
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
