// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IUniversalAdapterEscrow} from "./interfaces/IUniversalAdapterEscrow.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

contract UniversalAdapterEscrow is IUniversalAdapterEscrow {
    using SafeERC20Lib for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /* CONSTANTS */
    bytes4 private constant DEALLOCATE_SELECTOR = 0x4b219d16; // deallocate(address,bytes,uint256)
    bytes4 private constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8; // forceDeallocate(address,bytes,uint256,address)
    uint256 private constant MAX_BALANCE_LOSS_BPS = 1000;
    uint256 private constant VALUER_GAS_STIPEND = 200000;
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
    uint256 private cachedValuation;
    uint256 private cachedValuationTimestamp;
    mapping(address => mapping(bytes4 => WhitelistConfig)) public functionWhitelist;
    bool public paused;
    address public owner;
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

    constructor(
        address _parentVault,
        address _valuer,
        bool _useOffchainValuer
    ) {
        parentVault = _parentVault;
        valuer = _valuer;
        asset = IVaultV2(_parentVault).asset();
        owner = IVaultV2(_parentVault).owner();

        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }

    /* EXTERNAL FUNCTIONS */

    function allocate(
        bytes memory data,
        uint256 assets,
        bytes4,
        address
    ) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        (bytes32 strategyId, , , Call[] memory calls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));

        if (!strategies[strategyId].active) revert StrategyNotActive();
        if (assets == 0) revert InvalidAmount();
        if (calls.length > 0) {
            revert LiquidityDataMustHaveEmptyCalls();
        }

        allocations[strategyId] += assets;
        totalAllocations += assets;

        activeStrategies.add(strategyId);

        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = int256(assets);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    function deallocate(
        bytes memory data,
        uint256 assets,
        bytes4 caller,
        address
    ) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        (bytes32 strategyId, , , ) = abi.decode(data, (bytes32, uint256, bool, Call[]));
        uint256 adapterBalance = IERC20(asset).balanceOf(address(this));
        uint256 actualAmount;

        if (caller == FORCE_DEALLOCATE_SELECTOR) {
            uint256 slack = allocations[strategyId] > externalDeposits[strategyId]
                ? allocations[strategyId] - externalDeposits[strategyId]
                : 0;

            if (assets > slack) {
                revert InvalidAmount();
            }
            if (assets > adapterBalance) {
                actualAmount = adapterBalance;
                emit PartialDeallocate(strategyId, assets, actualAmount);
            } else {
                actualAmount = assets;
            }
        } else {
            if (assets > adapterBalance) {
                revert InsufficientAdapterBalance(adapterBalance, assets);
            }

            actualAmount = assets;
        }

        uint256 allocationDecrease = actualAmount > allocations[strategyId]
            ? allocations[strategyId]
            : actualAmount;
        allocations[strategyId] -= allocationDecrease;
        totalAllocations -= allocationDecrease;

        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = -int256(actualAmount);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    /// @notice Withdraw assets from external protocol to refill adapter balance
    /// @param strategyId The strategy to withdraw from
    /// @param withdrawCalls Array of calls to execute protocol withdrawals
    /// @param minBalanceIncrease Minimum balance increase required (slippage protection)
    function withdrawFromStrategy(
        bytes32 strategyId,
        Call[] calldata withdrawCalls,
        uint256 minBalanceIncrease
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
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
        }

        emit StrategyWithdrawn(strategyId, withdrawnAmount, msg.sender);
    }

    function realAssets() external view override returns (uint256 assets) {
        uint256 balance = IERC20(asset).balanceOf(address(this));

        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits
            : 0;

        uint256 excessIdle = balance > allocatedInAdapter
            ? balance - allocatedInAdapter
            : 0;

        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));

            uint256 totalValueAdj;
            if (totalValue >= excessIdle) {
                totalValueAdj = totalValue - excessIdle;
            } else {
                totalValueAdj = totalValue + allocatedInAdapter;
            }
            if (totalValueAdj > 0) {
                if (emergencyMode) {
                    // Apply 5% conservative haircut during emergency mode
                    return totalValueAdj * (10000 - EMERGENCY_HAIRCUT) / 10000;
                }
                return totalValueAdj;
            }
            if (totalAllocations == 0) {
                return 0;  // Legitimate 0 value when nothing allocated
            }
            if (emergencyMode) {
                if (cachedValuationTimestamp > 0 &&
                    block.timestamp - cachedValuationTimestamp <= MAX_CACHED_VALUATION_AGE) {
                    return cachedValuation * (10000 - EMERGENCY_HAIRCUT) / 10000;
                }

                return totalExternalDeposits * (10000 - EMERGENCY_HAIRCUT) / 10000;
            }

            revert ValuationUnavailable();
        }
        if (totalAllocations == 0) {
            return 0;
        }
        if (emergencyMode) {
            if (cachedValuationTimestamp > 0 &&
                block.timestamp - cachedValuationTimestamp <= MAX_CACHED_VALUATION_AGE) {
                return cachedValuation * (10000 - EMERGENCY_HAIRCUT) / 10000;
            }

            return totalExternalDeposits * (10000 - EMERGENCY_HAIRCUT) / 10000;
        }

        revert ValuationUnavailable();
    }

    /* EXTERNAL FUNCTIONS - STRATEGY MANAGEMENT */

    function setStrategy(
        bytes32 strategyId,
        address agent,
        bytes calldata preConfiguredData,
        uint256 dailyLimit
    ) external onlyOwner {
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

    function updateWhitelist(
        address target,
        bytes4 selector,
        bool allowed,
        uint256 limit
    ) external onlyOwner {
        functionWhitelist[target][selector] = WhitelistConfig({
            allowed: allowed,
            limit: limit
        });

        emit WhitelistUpdated(target, selector, allowed, limit);
    }

    /* EXTERNAL FUNCTIONS - STRATEGY EXECUTION */

    function executeStrategy(
        bytes32 strategyId,
        Call[] calldata calls
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
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
    function executeStrategyWithSlippage(
        bytes32 strategyId,
        Call[] calldata calls,
        uint256 minBalanceIncrease
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        if (minBalanceIncrease > 0) {
            uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
            require(balanceAfter >= balanceBefore + minBalanceIncrease, "Slippage: insufficient balance increase");

            if (balanceAfter > balanceBefore) {
                uint256 withdrawnAmount = balanceAfter - balanceBefore;
                if (withdrawnAmount > minBalanceIncrease) withdrawnAmount = minBalanceIncrease;

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
                }
            }

            if (balanceAfter > balanceBefore + minBalanceIncrease) {
                SafeERC20Lib.safeTransfer(
                    asset,
                    parentVault,
                    balanceAfter - (balanceBefore + minBalanceIncrease)
                );
            }
        }

        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @notice Execute strategy calls with circuit breaker bypassed
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    function executeStrategyBypassCircuitBreaker(
        bytes32 strategyId,
        Call[] calldata calls
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, true);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        if (balanceAfter > balanceBefore) revert InvalidAmount();

        emit StrategyExecuted(strategyId, msg.sender);
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

    /// @notice Manually sync strategy with valuer for drift correction (owner-only)
    /// @param strategyId Strategy to sync with valuer
    function syncStrategyWithValuer(bytes32 strategyId) external onlyOwner {
        if (!strategies[strategyId].active) revert StrategyNotActive();

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", strategyId)
        );

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
        }
    }

    /// @notice Manually adjust totalExternalDeposits to remove accounting drift
    /// @param strategyIds Array of strategy IDs to update
    /// @param newValues Array of new external deposit values for each strategy
    function syncExternalDepositsPerStrategy(bytes32[] calldata strategyIds, uint256[] calldata newValues) external onlyOwner {
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

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

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

                uint256 deviationBps = (deviation * 10000) / newMinKnown; // basis points

                emit SyncDeviationWarning(
                    newMinKnown,
                    valuerValue,
                    deviation,
                    deviationBps
                );
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

    /// @notice Refresh cached valuation from current valuer state
    function refreshCachedValuation() external {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits : 0;
        uint256 excessIdle = balance > allocatedInAdapter ? balance - allocatedInAdapter : 0;

        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));
            uint256 totalValueAdj;

            if (totalValue >= excessIdle) {
                totalValueAdj = totalValue - excessIdle;
            } else {
                totalValueAdj = totalValue + allocatedInAdapter;
            }

            if (totalAllocations > 0) {
                require(totalValueAdj >= (totalAllocations * 80) / 100, "Valuation too low - check valuer");
                require(totalValueAdj <= (totalAllocations * 150) / 100, "Valuation too high - check valuer");
            }

            if (totalValueAdj > 0) {
                cachedValuation = totalValueAdj;
                cachedValuationTimestamp = block.timestamp;
                emit CachedValuationRefreshed(totalValueAdj, block.timestamp);
            }
        } else {
            revert("Valuer call failed");
        }
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

    /// @notice Get idle balance for a specific strategy
    function getIdleBalance(bytes32 strategyId) external view returns (uint256 idle) {
        uint256 allocated = allocations[strategyId];
        uint256 deployed = externalDeposits[strategyId];

        if (allocated > deployed) {
            return allocated - deployed;
        }

        return 0;
    }

    function getIdleAssets() external view returns (uint256 idleAssets) {
        uint256 balance = IERC20(asset).balanceOf(address(this));

        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits
            : 0;

        if (balance > allocatedInAdapter) {
            return balance - allocatedInAdapter;
        }

        return 0;
    }

    function getGhostAmount() external view returns (uint256 ghost) {
        uint256 balance = IERC20(asset).balanceOf(address(this));

        uint256 allocatedInAdapter = totalAllocations > totalExternalDeposits
            ? totalAllocations - totalExternalDeposits
            : 0;

        uint256 excessIdle = balance > allocatedInAdapter
            ? balance - allocatedInAdapter
            : 0;

        uint256 minKnown = totalAllocations;

        (bool success, bytes memory data) = valuer.staticcall(
            abi.encodeWithSignature("getTotalValue(address)", address(this))
        );

        if (success && data.length >= 32) {
            uint256 valuerValue = abi.decode(data, (uint256));

            uint256 valuerValueAdj = valuerValue > excessIdle
                ? valuerValue - excessIdle
                : 0;

            if (minKnown > valuerValueAdj) {
                return minKnown - valuerValueAdj; // Amount of ghost (overpricing)
            }
        }
        return 0; // No ghost detected
    }

    /* INTERNAL FUNCTIONS */

    function _executeMulticall(bytes32 strategyId, Call[] memory calls, bool bypassCircuitBreaker) internal {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];

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

    function _syncExternalDepositsWithValuer(
        bytes32 strategyId,
        uint256 withdrawnAmount,
        uint256 requestedAssets
    ) internal {
        uint256 trackedValue = externalDeposits[strategyId];

        if (trackedValue == 0) return;

        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", strategyId)
        );

        if (success && data.length >= 32) {
            uint256 actualValue = abi.decode(data, (uint256));

            bool valuerConfigured = (actualValue > 0 || trackedValue == 0);

            if (valuerConfigured && actualValue != trackedValue) {
                int256 delta;

                if (actualValue < trackedValue) {
                    uint256 decrease = trackedValue - actualValue;

                    uint256 expectedMin = (withdrawnAmount * 80) / 100;
                    uint256 expectedMax = (withdrawnAmount * 120) / 100;

                    if (decrease < expectedMin || decrease > expectedMax) {
                        emit UnexpectedValueChange(
                            strategyId,
                            withdrawnAmount,
                            decrease,
                            withdrawnAmount,
                            "Value decrease outside expected range"
                        );
                    }

                    externalDeposits[strategyId] = actualValue;

                    if (decrease > totalExternalDeposits) {
                        emit AccountingDesyncDetected(strategyId, decrease, totalExternalDeposits);
                        totalExternalDeposits = 0;
                    } else {
                        totalExternalDeposits -= decrease;
                    }

                    delta = -int256(decrease);
                } else {
                    uint256 increase = actualValue - trackedValue;

                    externalDeposits[strategyId] = actualValue;
                    totalExternalDeposits += increase;

                    emit YieldAccrued(strategyId, increase);

                    delta = int256(increase);
                }

                emit ExternalDepositsValuerSynced(strategyId, trackedValue, actualValue, delta);
            } else {
                _applyConservativeReduction(strategyId, trackedValue, withdrawnAmount, false);
            }
        } else {
            bool cacheStale = block.timestamp - cachedValuationTimestamp >= MAX_CACHED_VALUATION_AGE;
            _applyConservativeReduction(strategyId, trackedValue, withdrawnAmount, cacheStale);
        }
    }

    function _applyConservativeReduction(
        bytes32 strategyId,
        uint256 trackedValue,
        uint256 withdrawnAmount,
        bool emitWarning
    ) internal {
        uint256 conservativeReduction = withdrawnAmount;

        uint256 maxReduction = trackedValue < totalExternalDeposits ? trackedValue : totalExternalDeposits;
        if (conservativeReduction > maxReduction) {
            conservativeReduction = maxReduction;
        }

        if (conservativeReduction > 0) {
            externalDeposits[strategyId] = trackedValue - conservativeReduction;
            totalExternalDeposits -= conservativeReduction;

            if (emitWarning) {
                emit UnexpectedValueChange(
                    strategyId,
                    withdrawnAmount,
                    conservativeReduction,
                    withdrawnAmount,
                    "Valuer unavailable - using conservative estimate"
                );
            } else {
                emit ExternalDepositsValuerSynced(
                    strategyId,
                    trackedValue,
                    trackedValue - conservativeReduction,
                    -int256(conservativeReduction)
                );
            }
        }
    }

    function _getStrategyValue(bytes32 strategyId) internal view returns (uint256 value) {
        (bool success, bytes memory data) = valuer.staticcall(
            abi.encodeWithSignature("getValue(bytes32)", strategyId)
        );

        if (success && data.length >= 32) {
            value = abi.decode(data, (uint256));
            if (value == 0) {
                value = allocations[strategyId];
            }
        } else {
            value = allocations[strategyId];
        }
    }

    function getCachedValuation() external view returns (uint256 value, uint256 timestamp, bool isStale) {
        value = cachedValuation;
        timestamp = cachedValuationTimestamp;

        isStale = cachedValuationTimestamp == 0 ||
                  block.timestamp - cachedValuationTimestamp > MAX_CACHED_VALUATION_AGE;
    }

    /* EMERGENCY MODE FUNCTIONS */

    function enableEmergencyMode() external onlyOwner {
        if (emergencyMode) revert EmergencyModeAlreadyEnabled();

        emergencyMode = true;
        emergencyModeActivatedAt = block.timestamp;

        emit EmergencyModeEnabled(block.timestamp, "Valuer unavailable");
    }

    function disableEmergencyMode() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotEnabled();

        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));
        (bool success, bytes memory data) = valuer.staticcall{gas: VALUER_GAS_STIPEND}(
            abi.encodeWithSignature("getValue(bytes32)", totalId)
        );

        if (!success || data.length < 32) revert ValuerStillUnavailable();

        uint256 totalValue = abi.decode(data, (uint256));

        if (totalAllocations > 0 && totalValue == 0) revert ValuerStillUnavailable();

        uint256 duration = block.timestamp - emergencyModeActivatedAt;
        emergencyMode = false;
        emergencyModeActivatedAt = 0;

        emit EmergencyModeDisabled(block.timestamp, duration);
    }
}
