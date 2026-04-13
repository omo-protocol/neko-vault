// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IUniversalAdapterEscrow} from "./interfaces/IUniversalAdapterEscrow.sol";
import {IUniversalValuerOffchain} from "./interfaces/IUniversalValuerOffchain.sol";
import {IAutomatedWithdrawalController, IOnchainStrategyValuer} from "../controllers/StrategyControllerInterfaces.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract UniversalAdapterEscrow is IUniversalAdapterEscrow {
    using SafeERC20Lib for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;
    /* CONSTANTS */

    bytes4 private constant DEALLOCATE_SELECTOR = 0x4b219d16; // deallocate(address,bytes,uint256)
    bytes4 private constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8; // forceDeallocate(address,bytes,uint256,address)
    uint256 private constant MAX_BALANCE_LOSS_BPS = 1000;
    uint256 private constant MAX_AUTOMATION_CALLS = 64;
    uint256 private constant MAX_CACHED_VALUATION_AGE = 4 hours;
    uint256 public constant EMERGENCY_HAIRCUT = 500; // 5% in basis points
    /* IMMUTABLES */
    address public immutable parentVault;
    address public immutable asset;
    address public immutable valuer;
    /* STORAGE */
    mapping(bytes32 => StrategyConfig) public strategies;
    mapping(bytes32 => uint256) public allocations;
    EnumerableSet.Bytes32Set private activeStrategies;
    uint256 public totalAllocations;
    mapping(bytes32 => uint256) public externalDeposits;
    uint256 public totalExternalDeposits;
    uint256 public settlementSurplusAssets;
    uint256 private cachedValuation;
    uint256 private cachedValuationTimestamp;
    mapping(address => mapping(bytes4 => WhitelistConfig)) public functionWhitelist;
    bool public paused;
    address public owner;
    address public settlementQueue;
    bool public emergencyMode;
    uint256 public emergencyModeActivatedAt;

    /* MODIFIERS */
    modifier onlyVault() {
        if (msg.sender != parentVault) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlySettlementQueue() {
        if (msg.sender != settlementQueue) revert NotAuthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyStrategyAgentOrOwner(bytes32 strategyId) {
        StrategyConfig memory strategy = strategies[strategyId];
        if (!strategy.active) revert StrategyNotActive();
        if (msg.sender != strategy.agent && msg.sender != owner) revert NotAuthorized();
        _;
    }

    constructor(address _parentVault, address _valuer, bool _useOffchainValuer) {
        parentVault = _parentVault;
        valuer = _valuer;
        asset = IVaultV2(_parentVault).asset();
        owner = IVaultV2(_parentVault).owner();

        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);

        if (_useOffchainValuer && _valuer != address(0)) {
            bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));
            try IUniversalValuerOffchain(_valuer).registerEscrowTotal(escrowTotalId) {} catch {}
        }
    }

    /* EXTERNAL FUNCTIONS */
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address)
        external
        override
        onlyVault
        notPaused
        returns (bytes32[] memory ids, int256 change)
    {
        if (data.length == 0) revert InvalidData();

        (bytes32 strategyId, uint256 automationFlags,, Call[] memory calls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));
        bool autoAllocationEnabled =
            selector == IVaultV2.allocate.selector && automationFlags <= 3 && (automationFlags & 1) != 0;

        if (!strategies[strategyId].active) revert StrategyNotActive();
        if (assets == 0) revert InvalidAmount();
        if (calls.length > 0) {
            revert LiquidityDataMustHaveEmptyCalls();
        }

        allocations[strategyId] += assets;
        totalAllocations += assets;

        activeStrategies.add(strategyId);

        if (autoAllocationEnabled) {
            uint256 externalBefore = externalDeposits[strategyId];
            try IAutomatedWithdrawalController(strategies[strategyId].agent).quoteAutomaticAllocation(assets) returns (
                Call[] memory allocationCalls
            ) {
                if (allocationCalls.length > 0) {
                    _executeMulticall(strategyId, allocationCalls, true);
                    uint256 externalAfter = externalDeposits[strategyId];
                    if (externalAfter < externalBefore || externalAfter - externalBefore > assets) {
                        revert InvalidAmount();
                    }
                }
            } catch {}
        }

        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = int256(assets);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    function deallocate(bytes memory data, uint256 assets, bytes4 caller, address)
        external
        override
        onlyVault
        notPaused
        returns (bytes32[] memory ids, int256 change)
    {
        if (data.length == 0) revert InvalidData();

        (bytes32 strategyId, uint256 automationFlags, bool autoWithdrawalEnabledLegacy,) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));
        bool autoWithdrawalEnabled = autoWithdrawalEnabledLegacy || (automationFlags <= 3 && (automationFlags & 2) != 0);
        uint256 adapterBalance = IERC20(asset).balanceOf(address(this));

        if (!strategies[strategyId].active) revert StrategyNotActive();

        if (autoWithdrawalEnabled && caller == IVaultV2.deallocate.selector && assets > adapterBalance) {
            _autoWithdraw(strategyId, assets - adapterBalance);
            adapterBalance = IERC20(asset).balanceOf(address(this));
        }

        uint256 actualAmount;

        if (caller == FORCE_DEALLOCATE_SELECTOR) {
            uint256 slack = allocations[strategyId] > externalDeposits[strategyId]
                ? allocations[strategyId] - externalDeposits[strategyId]
                : 0;

            if (assets > slack) {
                revert InvalidAmount();
            }
            if (assets > adapterBalance) revert InsufficientAdapterBalance(adapterBalance, assets);
            actualAmount = assets;
        } else {
            if (assets > adapterBalance) {
                revert InsufficientAdapterBalance(adapterBalance, assets);
            }

            actualAmount = assets;
        }

        uint256 allocationDecrease = actualAmount > allocations[strategyId] ? allocations[strategyId] : actualAmount;
        allocations[strategyId] -= allocationDecrease;
        totalAllocations -= allocationDecrease;

        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = -int256(allocationDecrease);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    function realAssets() external view override returns (uint256 assets) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        (uint256 allocatedInAdapterBounded,, uint256 trackedAssets) = _trackedAssets(balance);

        (bool hasValue, bool hasStaleData, uint256 totalValue) = _resolveCurrentValuation();

        if (hasValue) {
            if (hasStaleData || emergencyMode) {
                return totalValue * (10000 - EMERGENCY_HAIRCUT) / 10000;
            }

            return totalValue;
        }
        if (totalAllocations == 0) {
            return trackedAssets;
        }
        if (!emergencyMode) {
            revert ValuationUnavailable();
        }
        if (cachedValuationTimestamp != 0 && block.timestamp - cachedValuationTimestamp <= MAX_CACHED_VALUATION_AGE) {
            uint256 haircuttedBaseline =
                ((allocatedInAdapterBounded + totalExternalDeposits) * (10000 - EMERGENCY_HAIRCUT)) / 10000;
            return cachedValuation < haircuttedBaseline ? cachedValuation : haircuttedBaseline;
        }
        return ((allocatedInAdapterBounded + totalExternalDeposits) * (10000 - EMERGENCY_HAIRCUT)) / 10000;
    }

    /* EXTERNAL FUNCTIONS - STRATEGY MANAGEMENT */
    function setStrategy(bytes32 strategyId, address agent, bytes calldata preConfiguredData, uint256 dailyLimit)
        external
        onlyOwner
    {
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));
        if (strategyId == escrowTotalId) {
            revert StrategyIdCollisionWithEscrowTotal();
        }

        strategies[strategyId] = StrategyConfig({
            agent: agent,
            preConfiguredData: preConfiguredData,
            dailyLimit: dailyLimit,
            lastResetTime: block.timestamp,
            dailyUsed: 0,
            active: true
        });

        emit StrategySet(strategyId, agent, dailyLimit);
    }

    function removeStrategy(bytes32 strategyId) external onlyOwner {
        if (allocations[strategyId] > 0 || externalDeposits[strategyId] > 0) {
            revert InvalidStrategy();
        }

        delete strategies[strategyId];
        _removeFromActiveStrategies(strategyId);

        emit StrategyRemoved(strategyId);
    }

    function updateWhitelist(address target, bytes4 selector, bool allowed, uint256 limit) external onlyOwner {
        functionWhitelist[target][selector] = WhitelistConfig({allowed: allowed, limit: limit});

        emit WhitelistUpdated(target, selector, allowed, limit);
    }

    /* EXTERNAL FUNCTIONS - STRATEGY EXECUTION */
    function executeStrategy(bytes32 strategyId, Call[] calldata calls)
        external
        onlyStrategyAgentOrOwner(strategyId)
        notPaused
    {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @notice Execute strategy calls with additional slippage protection
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    /// @param minBalanceIncrease Minimum balance increase required (for withdrawals), 0 to skip check
    function executeStrategyWithSlippage(bytes32 strategyId, Call[] calldata calls, uint256 minBalanceIncrease)
        external
        onlyStrategyAgentOrOwner(strategyId)
        notPaused
    {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        if (minBalanceIncrease > 0) {
            uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
            require(balanceAfter >= balanceBefore + minBalanceIncrease, "Slippage: insufficient balance increase");

            if (balanceAfter > balanceBefore) {
                uint256 withdrawnAmount = balanceAfter - balanceBefore;
                uint256 oldExtDeposits = externalDeposits[strategyId];
                uint256 reduction = withdrawnAmount;

                if (reduction > oldExtDeposits) {
                    reduction = oldExtDeposits;
                }
                if (reduction > totalExternalDeposits) {
                    reduction = totalExternalDeposits;
                }

                if (reduction > 0) {
                    externalDeposits[strategyId] = oldExtDeposits - reduction;
                    totalExternalDeposits -= reduction;

                    emit ExternalDepositsReduced(strategyId, oldExtDeposits, externalDeposits[strategyId], reduction);

                    if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
                        _removeFromActiveStrategies(strategyId);
                    }
                }
            }

            if (balanceAfter > balanceBefore + minBalanceIncrease) {
                SafeERC20Lib.safeTransfer(asset, parentVault, balanceAfter - (balanceBefore + minBalanceIncrease));
            }
        }

        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @notice Execute strategy calls with circuit breaker bypassed
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    function executeStrategyBypassCircuitBreaker(bytes32 strategyId, Call[] calldata calls)
        external
        onlyStrategyAgentOrOwner(strategyId)
        notPaused
    {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, true);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @notice Withdraw assets from external protocol to refill adapter balance
    /// @param strategyId The strategy to withdraw from
    /// @param withdrawCalls Array of calls to execute protocol withdrawals
    /// @param minBalanceIncrease Minimum balance increase required (slippage protection)
    function withdrawFromStrategy(bytes32 strategyId, Call[] calldata withdrawCalls, uint256 minBalanceIncrease)
        external
        onlyStrategyAgentOrOwner(strategyId)
        notPaused
    {
        if (withdrawCalls.length == 0) revert InvalidData();
        if (withdrawCalls.length > 64) revert InvalidData(); // Reasonable limit

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, withdrawCalls, false);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));

        if (balanceAfter <= balanceBefore) {
            revert InvalidAmount();
        }

        uint256 withdrawnAmount = balanceAfter - balanceBefore;

        if (withdrawnAmount < minBalanceIncrease) {
            revert SlippageTooHigh();
        }

        uint256 oldExtDeposits = externalDeposits[strategyId];
        uint256 reduction = withdrawnAmount;

        if (reduction > oldExtDeposits) {
            reduction = oldExtDeposits;
        }
        if (reduction > totalExternalDeposits) {
            reduction = totalExternalDeposits;
        }
        if (reduction > 0) {
            externalDeposits[strategyId] = oldExtDeposits - reduction;
            totalExternalDeposits -= reduction;

            emit ExternalDepositsReduced(strategyId, oldExtDeposits, externalDeposits[strategyId], reduction);

            if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
                _removeFromActiveStrategies(strategyId);
            }
        }

        emit StrategyWithdrawn(strategyId, withdrawnAmount, msg.sender);
    }

    /* EXTERNAL FUNCTIONS - ADMIN */
    function sweep(address token, address recipient) external onlyOwner {
        if (token == asset) revert CannotSweepAsset();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            SafeERC20Lib.safeTransfer(token, recipient, balance);
            emit TokenSwept(token, recipient, balance);
        }
    }

    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseStatusChanged(_paused);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }

    function setSettlementQueue(address settlementQueue_) external onlyOwner {
        if (settlementQueue_ == address(0)) {
            if (settlementQueue == address(0)) revert InvalidAmount();
            if (_queueProtectedAssets(settlementQueue) != 0) revert InvalidData();
            settlementQueue = address(0);
            emit SettlementQueueSet(address(0));
            return;
        }
        if (settlementQueue != address(0) && settlementQueue != settlementQueue_) {
            if (_queueProtectedAssets(settlementQueue) != 0) revert InvalidData();
        }
        if (
            ISettlementQueueValidation(settlementQueue_).vault() != parentVault
                || ISettlementQueueValidation(settlementQueue_).sleeve() != address(this)
        ) {
            revert InvalidData();
        }
        settlementQueue = settlementQueue_;
        emit SettlementQueueSet(settlementQueue_);
    }

    function recordSettlement(bytes32 strategyId, uint256 assetsReceived) external onlySettlementQueue notPaused {
        if (!strategies[strategyId].active) revert StrategyNotActive();
        if (assetsReceived == 0) revert InvalidAmount();

        uint256 oldExtDeposits = externalDeposits[strategyId];
        uint256 reduction = assetsReceived > oldExtDeposits ? oldExtDeposits : assetsReceived;
        if (reduction > totalExternalDeposits) {
            reduction = totalExternalDeposits;
        }

        if (reduction == 0) {
            cachedValuationTimestamp = 0;
            if (allocations[strategyId] == 0) {
                SafeERC20Lib.safeTransfer(asset, parentVault, assetsReceived);
            } else {
                settlementSurplusAssets += assetsReceived;
            }
            emit SettlementRecorded(strategyId, assetsReceived, oldExtDeposits);
            return;
        }

        externalDeposits[strategyId] = oldExtDeposits - reduction;
        totalExternalDeposits -= reduction;

        uint256 surplus = assetsReceived - reduction;
        if (allocations[strategyId] == 0) {
            SafeERC20Lib.safeTransfer(asset, parentVault, assetsReceived);
        } else if (surplus > 0) {
            settlementSurplusAssets += surplus;
        }

        cachedValuationTimestamp = 0;

        emit ExternalDepositsReduced(strategyId, oldExtDeposits, externalDeposits[strategyId], reduction);
        emit SettlementRecorded(strategyId, assetsReceived, externalDeposits[strategyId]);

        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }
    }

    /// @notice Manually sync strategy with valuer for drift correction (owner-only)
    /// @dev Optional maintenance hook for deployments that still use an external valuer.
    /// @param strategyId Strategy to sync with valuer
    function syncStrategyWithValuer(bytes32 strategyId) external onlyOwner {
        if (!strategies[strategyId].active) revert StrategyNotActive();
        if (!_hasExternalValuer()) revert ValuationUnavailable();

        (bool success, bytes memory data) = valuer.staticcall(abi.encodeWithSignature("getValue(bytes32)", strategyId));

        if (!success || data.length < 32) {
            revert ValuationUnavailable();
        }

        uint256 valuerValue = abi.decode(data, (uint256));
        uint256 trackedValue = externalDeposits[strategyId];

        if (valuerValue != trackedValue) {
            int256 delta;

            if (valuerValue > trackedValue) {
                uint256 increase = valuerValue - trackedValue;
                externalDeposits[strategyId] = valuerValue;
                totalExternalDeposits += increase;
                delta = int256(increase);

                emit YieldAccrued(strategyId, increase);
            } else {
                uint256 decrease = trackedValue - valuerValue;
                externalDeposits[strategyId] = valuerValue;

                if (decrease > totalExternalDeposits) {
                    totalExternalDeposits = 0;
                } else {
                    totalExternalDeposits -= decrease;
                }

                delta = -int256(decrease);
            }

            emit ExternalDepositsValuerSynced(strategyId, trackedValue, valuerValue, delta);

            if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
                _removeFromActiveStrategies(strategyId);
            }
        }
    }

    /// @notice Manually adjust totalExternalDeposits to remove accounting drift
    /// @param strategyIds Array of strategy IDs to update
    /// @param newValues Array of new external deposit values for each strategy
    function syncExternalDepositsPerStrategy(bytes32[] calldata strategyIds, uint256[] calldata newValues)
        external
        onlyOwner
    {
        require(strategyIds.length == newValues.length, "Length mismatch");
        require(strategyIds.length > 0, "Empty arrays");

        uint256 totalDelta = 0;

        for (uint256 i = 0; i < strategyIds.length; i++) {
            bytes32 strategyId = strategyIds[i];
            uint256 oldValue = externalDeposits[strategyId];
            uint256 newValue = newValues[i];

            require(newValue <= oldValue, "Can only reduce ghost deposits");

            uint256 delta = oldValue - newValue;
            externalDeposits[strategyId] = newValue;
            totalDelta += delta;

            if (allocations[strategyId] == 0 && newValue == 0) {
                _removeFromActiveStrategies(strategyId);
            }

            emit ExternalDepositSyncedPerStrategy(strategyId, oldValue, newValue, delta);
        }

        totalExternalDeposits -= totalDelta;

        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 newMinKnown = balance + totalExternalDeposits;

        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        if (_hasExternalValuer()) {
            (bool success, bytes memory data) = valuer.staticcall(abi.encodeWithSignature("getValue(bytes32)", totalId));

            if (success && data.length >= 32) {
                uint256 valuerValue = abi.decode(data, (uint256));

                uint256 minExpected = (newMinKnown * 8000) / 10000;
                uint256 maxExpected = (newMinKnown * 12000) / 10000;

                if (valuerValue < minExpected || valuerValue > maxExpected) {
                    uint256 deviation;
                    if (valuerValue > newMinKnown) {
                        deviation = valuerValue - newMinKnown;
                    } else {
                        deviation = newMinKnown - valuerValue;
                    }

                    uint256 deviationBps = newMinKnown == 0 ? 0 : (deviation * 10000) / newMinKnown; // basis points

                    emit SyncDeviationWarning(newMinKnown, valuerValue, deviation, deviationBps);
                }
            }
        }

        cachedValuationTimestamp = 0;

        emit ExternalDepositsSyncedBatch(msg.sender, totalDelta, totalExternalDeposits);
    }

    /// @notice Reduce per-strategy externalDeposits to clear irrecoverable external exposure
    /// @dev Enables removal of stuck strategies after losses
    /// @param strategyId The strategy to update
    /// @param newPerStrategy The new per-strategy externalDeposits value (must be <= current)
    function reduceExternalDeposits(bytes32 strategyId, uint256 newPerStrategy) external onlyOwner {
        uint256 current = externalDeposits[strategyId];

        if (newPerStrategy > current) revert InvalidAmount();

        uint256 delta = current - newPerStrategy;

        externalDeposits[strategyId] = newPerStrategy;

        require(delta <= totalExternalDeposits, "Invariant: delta exceeds total");
        totalExternalDeposits -= delta;

        if (allocations[strategyId] == 0 && newPerStrategy == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        emit ExternalDepositsReduced(strategyId, current, newPerStrategy, delta);
    }

    /// @notice Refresh cached valuation from the active valuation source
    function refreshCachedValuation() external {
        (bool hasValue,, uint256 totalValue) = _resolveCurrentValuation();

        if (!hasValue) {
            revert("Valuation unavailable");
        }

        if (totalAllocations > 0) {
            require(totalValue >= (totalAllocations * 75) / 100, "Valuation too low");
            require(totalValue <= (totalAllocations * 150) / 100, "Valuation too high");
        }

        cachedValuation = totalValue;
        cachedValuationTimestamp = block.timestamp;
        emit CachedValuationRefreshed(totalValue, block.timestamp);
    }

    function quoteSnapshotAssets() external view returns (uint256 assets, bool healthy) {
        (assets,, healthy) = _quoteSnapshotState();
    }

    function quoteSnapshotState() external view returns (uint256 assets, uint64 snapshotTimestamp, bool healthy) {
        return _quoteSnapshotState();
    }

    function _quoteSnapshotState() internal view returns (uint256 assets, uint64 snapshotTimestamp, bool healthy) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        (,, uint256 trackedAssets) = _trackedAssets(balance);
        (bool hasValue, bool hasStaleData, uint256 totalValue, uint64 valuationTimestamp, bool fromOnchain) =
            _resolveSnapshotValuation();
        uint256 valuationBase = totalAllocations > 0 ? totalAllocations : trackedAssets;

        if (fromOnchain && !_withinLiveValuationBounds(totalValue, valuationBase)) {
            return (trackedAssets, 0, false);
        }

        if (!hasValue) {
            return (trackedAssets, 0, false);
        }

        if (totalValue > trackedAssets) {
            totalValue = trackedAssets;
        }

        return (totalValue, valuationTimestamp, !hasStaleData && !emergencyMode && valuationTimestamp != 0);
    }

    /* VIEW FUNCTIONS */
    function getStrategy(bytes32 strategyId) external view returns (StrategyConfig memory) {
        return strategies[strategyId];
    }

    function getWhitelist(address target, bytes4 selector) external view returns (WhitelistConfig memory) {
        return functionWhitelist[target][selector];
    }

    function getAllocation(bytes32 strategyId) external view returns (uint256) {
        return allocations[strategyId];
    }

    function getActiveStrategies() external view returns (bytes32[] memory) {
        return activeStrategies.values();
    }

    function getIdleAssets() external view returns (uint256 idleAssets) {
        uint256 balance = IERC20(asset).balanceOf(address(this));

        uint256 allocatedInAdapter =
            totalAllocations > totalExternalDeposits ? totalAllocations - totalExternalDeposits : 0;

        if (balance > allocatedInAdapter) {
            return balance - allocatedInAdapter;
        }

        return 0;
    }

    /* INTERNAL FUNCTIONS */
    function _executeMulticall(bytes32 strategyId, Call[] memory calls, bool bypassCircuitBreaker) internal {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];
            if (call.data.length < 4) revert InvalidData();

            bytes4 selector = bytes4(call.data);

            WhitelistConfig memory config = functionWhitelist[call.target][selector];
            if (!config.allowed) {
                config = functionWhitelist[call.target][bytes4(0)];
                if (!config.allowed) {
                    revert FunctionNotWhitelisted();
                }
            }

            (bool success, bytes memory returnData) = call.target.call{value: call.value}(call.data);
            if (!success) {
                revert CallFailed(i, returnData);
            }
        }

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (!bypassCircuitBreaker && balanceAfter < balanceBefore && balanceBefore > 0) {
            uint256 loss = balanceBefore - balanceAfter;
            uint256 lossBps = (loss * 10000) / balanceBefore;

            if (lossBps > MAX_BALANCE_LOSS_BPS) {
                revert ExcessiveBalanceLoss();
            }
        }

        if (balanceAfter < balanceBefore) {
            uint256 deposited = balanceBefore - balanceAfter;
            externalDeposits[strategyId] += deposited;
            totalExternalDeposits += deposited;
        }
        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }
    }

    function _removeFromActiveStrategies(bytes32 strategyId) internal {
        activeStrategies.remove(strategyId);
    }

    function _autoWithdraw(bytes32 strategyId, uint256 shortfallAssets) internal {
        if (shortfallAssets == 0) return;

        Call[] memory withdrawCalls;
        try IAutomatedWithdrawalController(strategies[strategyId].agent).quoteAutomaticWithdrawal(shortfallAssets)
        returns (Call[] memory quotedCalls) {
            withdrawCalls = quotedCalls;
        } catch {
            revert InvalidData();
        }
        if (withdrawCalls.length == 0) revert InvalidData();
        if (withdrawCalls.length > MAX_AUTOMATION_CALLS) revert InvalidData();

        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));
        _executeMulticall(strategyId, withdrawCalls, false);
        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));

        if (balanceAfter <= balanceBefore) revert InvalidAmount();

        uint256 withdrawnAmount = balanceAfter - balanceBefore;
        uint256 oldExtDeposits = externalDeposits[strategyId];
        uint256 reduction = withdrawnAmount;

        if (reduction > oldExtDeposits) reduction = oldExtDeposits;
        if (reduction > totalExternalDeposits) reduction = totalExternalDeposits;

        if (reduction > 0) {
            externalDeposits[strategyId] = oldExtDeposits - reduction;
            totalExternalDeposits -= reduction;

            emit ExternalDepositsReduced(strategyId, oldExtDeposits, externalDeposits[strategyId], reduction);

            if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
                _removeFromActiveStrategies(strategyId);
            }
        }
    }

    function _trackedAssets(uint256 balance)
        internal
        view
        returns (uint256 allocatedInAdapterBounded, uint256 trackedSurplus, uint256 trackedAssets)
    {
        uint256 allocatedInAdapter =
            totalAllocations > totalExternalDeposits ? totalAllocations - totalExternalDeposits : 0;

        allocatedInAdapterBounded = allocatedInAdapter < balance ? allocatedInAdapter : balance;

        uint256 idleBalance = balance > allocatedInAdapterBounded ? balance - allocatedInAdapterBounded : 0;
        trackedSurplus = settlementSurplusAssets < idleBalance ? settlementSurplusAssets : idleBalance;
        trackedAssets = allocatedInAdapterBounded + totalExternalDeposits + trackedSurplus;
    }

    function _resolveCurrentValuation() internal view returns (bool hasValue, bool hasStaleData, uint256 totalValue) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        (,, uint256 trackedAssets) = _trackedAssets(balance);
        bool fromOnchain;
        (hasValue, hasStaleData, totalValue,, fromOnchain) = _resolveSnapshotValuation();
        uint256 valuationBase = totalAllocations > 0 ? totalAllocations : trackedAssets;
        if (fromOnchain && !_withinLiveValuationBounds(totalValue, valuationBase)) {
            return (false, false, 0);
        }
    }

    function _resolveSnapshotValuation()
        internal
        view
        returns (bool hasValue, bool hasStaleData, uint256 totalValue, uint64 snapshotTimestamp, bool fromOnchain)
    {
        if (_hasExternalValuer()) {
            (bool healthSuccess, bytes memory healthData) =
                valuer.staticcall(abi.encodeWithSignature("isValuationHealthy(address)", address(this)));

            bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));
            (bool totalSuccess, uint256 totalAssets, uint64 totalTimestamp) = _readValuerTotalValue(totalId);

            if (totalSuccess) {
                bool totalHealthy = true;
                if (healthSuccess && healthData.length >= 32) {
                    totalHealthy = abi.decode(healthData, (bool));
                }
                return (true, !totalHealthy, totalAssets, totalTimestamp, false);
            }

            if (healthSuccess && healthData.length >= 32) {
                hasStaleData = !abi.decode(healthData, (bool));
                (hasValue, totalValue, snapshotTimestamp) = _aggregateActiveStrategyValuesWithTimestamp();
                return (hasValue, hasStaleData, totalValue, snapshotTimestamp, false);
            }
        }

        (bool onchainSuccess, bool onchainHealthy, uint256 onchainValue, uint64 onchainTimestamp) =
            _aggregateOnchainStrategySnapshot();
        if (onchainSuccess) {
            return (true, !onchainHealthy, onchainValue, onchainTimestamp, true);
        }

        return (false, false, 0, 0, false);
    }

    function _aggregateOnchainStrategyValue() internal view returns (bool success, bool healthy, uint256 totalValue) {
        (success, healthy, totalValue,) = _aggregateOnchainStrategySnapshot();
    }

    function _aggregateOnchainStrategySnapshot()
        internal
        view
        returns (bool success, bool healthy, uint256 totalValue, uint64 snapshotTimestamp)
    {
        bytes32[] memory strategyIds = activeStrategies.values();
        if (strategyIds.length != 1) {
            return (false, false, 0, 0);
        }

        address agent = strategies[strategyIds[0]].agent;
        (bool valuationSuccess, bytes memory data) =
            agent.staticcall(abi.encodeWithSelector(IOnchainStrategyValuer.quoteCurrentAssets.selector));
        if (!valuationSuccess || data.length < 64) {
            return (false, false, 0, 0);
        }

        (totalValue, healthy) = abi.decode(data, (uint256, bool));
        if (!healthy) {
            return (false, false, 0, 0);
        }
        return (true, true, totalValue, uint64(block.timestamp));
    }

    function _hasExternalValuer() internal view returns (bool) {
        return valuer != address(0) && valuer.code.length > 0;
    }

    function _aggregateActiveStrategyValues() internal view returns (bool success, uint256 totalValue) {
        (success, totalValue,) = _aggregateActiveStrategyValuesWithTimestamp();
    }

    function _aggregateActiveStrategyValuesWithTimestamp()
        internal
        view
        returns (bool success, uint256 totalValue, uint64 snapshotTimestamp)
    {
        bytes32[] memory strategyIds = activeStrategies.values();
        if (strategyIds.length == 0) {
            return (true, 0, 0);
        }

        snapshotTimestamp = type(uint64).max;

        for (uint256 i = 0; i < strategyIds.length; i++) {
            (bool valueSuccess, bytes memory data) =
                valuer.staticcall(abi.encodeWithSignature("getValue(bytes32)", strategyIds[i]));
            if (!valueSuccess || data.length < 32) {
                return (false, 0, 0);
            }

            (bool timestampSuccess, uint64 reportTimestamp) = _getValuerReportTimestamp(strategyIds[i]);
            if (!timestampSuccess || reportTimestamp == 0) {
                return (false, 0, 0);
            }
            if (reportTimestamp < snapshotTimestamp) {
                snapshotTimestamp = reportTimestamp;
            }

            totalValue += abi.decode(data, (uint256));
        }

        return (true, totalValue, snapshotTimestamp);
    }

    function _readValuerTotalValue(bytes32 totalId)
        internal
        view
        returns (bool success, uint256 totalValue, uint64 timestamp)
    {
        bytes memory data;
        (success, data) = valuer.staticcall(abi.encodeWithSignature("getValue(bytes32)", totalId));
        if (!success || data.length < 32) {
            return (false, 0, 0);
        }

        totalValue = abi.decode(data, (uint256));
        (bool timestampSuccess, uint64 reportTimestamp) = _getValuerReportTimestamp(totalId);
        if (!timestampSuccess) {
            if (totalValue == 0) {
                return (false, 0, 0);
            }
            return (true, totalValue, 0);
        }

        return (true, totalValue, reportTimestamp);
    }

    function _withinLiveValuationBounds(uint256 totalValue, uint256 trackedAssets) internal pure returns (bool) {
        if (trackedAssets == 0) return totalValue == 0;

        uint256 minExpected = (trackedAssets * 75) / 100;
        uint256 maxExpected = (trackedAssets * 150) / 100;
        return totalValue >= minExpected && totalValue <= maxExpected;
    }

    function _queueProtectedAssets(address queue) internal view returns (uint256 protectedAssets) {
        (bool success, bytes memory result) = queue.staticcall(abi.encodeWithSignature("totalProtectedAssets()"));
        if (!success || result.length < 32) {
            return type(uint256).max;
        }

        protectedAssets = abi.decode(result, (uint256));
    }

    function _getValuerReportTimestamp(bytes32 strategyId) internal view returns (bool success, uint64 timestamp) {
        bytes memory data;
        (success, data) = valuer.staticcall(abi.encodeWithSignature("getReport(bytes32)", strategyId));
        if (!success || data.length == 0) {
            return (false, 0);
        }

        IUniversalValuerOffchain.ValueReport memory report = abi.decode(data, (IUniversalValuerOffchain.ValueReport));
        if (report.timestamp == 0 || report.timestamp > type(uint64).max) {
            return (false, 0);
        }

        return (true, uint64(report.timestamp));
    }

    function getCachedValuation() external view returns (uint256 value, uint256 timestamp, bool isStale) {
        value = cachedValuation;
        timestamp = cachedValuationTimestamp;

        isStale = cachedValuationTimestamp == 0 || block.timestamp - cachedValuationTimestamp > MAX_CACHED_VALUATION_AGE;
    }

    /* EMERGENCY MODE FUNCTIONS */
    function enableEmergencyMode() external onlyOwner {
        if (emergencyMode) revert EmergencyModeAlreadyEnabled();

        emergencyMode = true;
        cachedValuationTimestamp = 0; // Disable cached valuation usage during emergency fallback
        emergencyModeActivatedAt = block.timestamp;

        emit EmergencyModeEnabled(block.timestamp, "Valuer unavailable");
    }

    function disableEmergencyMode() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotEnabled();

        (bool hasValue,, uint256 totalValue) = _resolveCurrentValuation();

        if (!hasValue) revert ValuerStillUnavailable();

        if (totalAllocations > 0 && totalValue == 0) revert ValuerStillUnavailable();

        uint256 duration = block.timestamp - emergencyModeActivatedAt;
        emergencyMode = false;
        emergencyModeActivatedAt = 0;

        emit EmergencyModeDisabled(block.timestamp, duration);
    }
}

interface ISettlementQueueValidation {
    function vault() external view returns (address);
    function sleeve() external view returns (address);
}
