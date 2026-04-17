// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAutomatedWithdrawalController} from "../controllers/StrategyControllerInterfaces.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {UniversalAdapterEscrowValuation} from "./UniversalAdapterEscrowValuation.sol";

import {ISettlementQueueValidation, UniversalAdapterEscrowStorage} from "./UniversalAdapterEscrowStorage.sol";

contract UniversalAdapterEscrow is UniversalAdapterEscrowValuation {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    constructor(address _parentVault) UniversalAdapterEscrowStorage(_parentVault) {}

    function allocate(bytes memory data, uint256 assets, bytes4 selector, address)
        external
        override
        onlyVault
        notPaused
        nonReentrant
        returns (bytes32[] memory ids, int256 change)
    {
        if (data.length == 0) revert InvalidData();

        (bytes32 strategyId, uint256 automationFlags, Call[] memory calls) =
            abi.decode(data, (bytes32, uint256, Call[]));
        _validateAutomationFlags(automationFlags);
        bool autoAllocationEnabled =
            selector == IVaultV2.allocate.selector && (automationFlags & AUTO_ALLOCATION_FLAG) != 0;

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
            uint256 adapterBalanceBefore = IERC20(asset).balanceOf(address(this));
            try IAutomatedWithdrawalController(strategies[strategyId].agent).quoteAutomaticAllocation(assets) returns (
                Call[] memory allocationCalls
            ) {
                if (allocationCalls.length > 0) {
                    if (allocationCalls.length > MAX_AUTOMATION_CALLS) revert InvalidData();
                    _executeMulticall(strategyId, allocationCalls, true);
                    uint256 externalAfter = externalDeposits[strategyId];
                    if (externalAfter < externalBefore || externalAfter - externalBefore > assets) {
                        revert InvalidAmount();
                    }
                    // Bound actual balance impact: adapter should not lose more than allocated amount
                    uint256 adapterBalanceAfter = IERC20(asset).balanceOf(address(this));
                    if (adapterBalanceBefore > adapterBalanceAfter && adapterBalanceBefore - adapterBalanceAfter > assets) {
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

    /// @dev Deallocate transfers assets from sleeve to vault. Queue-protected liquidity is safe because
    /// _reserveLocalLiquidity() and _availableUnreservedLiquidity() use balanceOf(vault) + balanceOf(sleeve),
    /// so the total system liquidity is preserved when assets move between vault and sleeve.
    function deallocate(bytes memory data, uint256 assets, bytes4 caller, address initiator)
        external
        override
        onlyVault
        notPaused
        nonReentrant
        returns (bytes32[] memory ids, int256 change)
    {
        if (data.length == 0) revert InvalidData();

        (bytes32 strategyId, uint256 automationFlags,) = abi.decode(data, (bytes32, uint256, Call[]));
        _validateAutomationFlags(automationFlags);
        bool autoWithdrawalEnabled = (automationFlags & AUTO_WITHDRAW_FLAG) != 0;
        uint256 adapterBalance = IERC20(asset).balanceOf(address(this));

        if (!strategies[strategyId].active) revert StrategyNotActive();

        if (autoWithdrawalEnabled && _shouldAutoWithdraw(caller, initiator) && assets > adapterBalance) {
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

        // Clamp surplus to projected idle balance after vault pulls assets.
        // The vault will transferFrom(sleeve, vault, actualAmount) AFTER this function returns,
        // so we must subtract actualAmount from current balance to get the true post-pull balance.
        if (settlementSurplusAssets > 0) {
            uint256 currentBalance = IERC20(asset).balanceOf(address(this));
            uint256 projectedBalance = currentBalance > actualAmount ? currentBalance - actualAmount : 0;
            uint256 inAdapterAlloc = totalAllocations > totalExternalDeposits ? totalAllocations - totalExternalDeposits : 0;
            if (projectedBalance > inAdapterAlloc) {
                uint256 maxSurplus = projectedBalance - inAdapterAlloc;
                if (settlementSurplusAssets > maxSurplus) {
                    settlementSurplusAssets = maxSurplus;
                }
            } else {
                settlementSurplusAssets = 0;
            }
        }

        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = -int256(allocationDecrease);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    function setStrategy(bytes32 strategyId, address agent, bytes calldata preConfiguredData, uint256 dailyLimit)
        external
        onlyOwner
    {
        if (!_supportsOnchainValuationAgent(agent)) {
            revert InvalidData();
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
        if (allowed) {
            _validateWhitelistTarget(target);
            whitelistCodeHashes[target] = target.codehash;
        }
        functionWhitelist[target][selector] = WhitelistConfig({allowed: allowed, limit: limit});

        emit WhitelistUpdated(target, selector, allowed, limit);
    }

    /// @notice Whitelist a target without DELEGATECALL safety checks
    /// @dev Use only for trusted proxy contracts that cannot pass _validateWhitelistTarget
    function updateWhitelistUnsafe(address target, bytes4 selector, bool allowed, uint256 limit) external onlyOwner {
        if (allowed) {
            if (target.code.length == 0) revert InvalidData();
            whitelistCodeHashes[target] = target.codehash;
        }
        functionWhitelist[target][selector] = WhitelistConfig({allowed: allowed, limit: limit});

        emit WhitelistUpdated(target, selector, allowed, limit);
    }

    /* EXTERNAL FUNCTIONS - STRATEGY EXECUTION */
    function executeStrategy(bytes32 strategyId, Call[] calldata calls)
        external
        onlyStrategyAgentOrOwner(strategyId)
        notPaused
        nonReentrant
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
        nonReentrant
    {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        _executeMulticall(strategyId, calls, false);

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        uint256 withdrawnAmount = balanceAfter > balanceBefore ? balanceAfter - balanceBefore : 0;

        _recordWithdrawnAssets(strategyId, withdrawnAmount);

        if (minBalanceIncrease > 0) {
            require(withdrawnAmount >= minBalanceIncrease, "Slippage: insufficient balance increase");
            if (balanceAfter > balanceBefore + minBalanceIncrease) {
                uint256 excess = balanceAfter - (balanceBefore + minBalanceIncrease);
                // Reduce surplus before transferring excess to vault to prevent double-counting
                if (settlementSurplusAssets > 0) {
                    uint256 surplusReduction = excess > settlementSurplusAssets ? settlementSurplusAssets : excess;
                    settlementSurplusAssets -= surplusReduction;
                }
                SafeERC20Lib.safeTransfer(asset, parentVault, excess);
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
        nonReentrant
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
        nonReentrant
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
        _recordWithdrawnAssets(strategyId, withdrawnAmount);

        if (withdrawnAmount < minBalanceIncrease) {
            revert SlippageTooHigh();
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
        bytes32 queueStrategyId = ISettlementQueueValidation(settlementQueue_).strategyId();
        if (
            queueStrategyId == bytes32(0)
                || 
            ISettlementQueueValidation(settlementQueue_).vault() != parentVault
                || ISettlementQueueValidation(settlementQueue_).sleeve() != address(this)
        ) {
            revert InvalidData();
        }
        settlementQueue = settlementQueue_;
        emit SettlementQueueSet(settlementQueue_);
    }

    /// @notice Force-remove a broken settlement queue that can't be removed via setSettlementQueue
    /// @dev Use when the existing queue reverts on totalProtectedAssets(), preventing normal removal
    function forceRemoveSettlementQueue() external onlyOwner {
        if (settlementQueue == address(0)) revert InvalidAmount();
        settlementQueue = address(0);
        emit SettlementQueueSet(address(0));
    }

    function recordSettlement(bytes32 strategyId, uint256 assetsReceived) external onlySettlementQueue notPaused nonReentrant {
        if (!strategies[strategyId].active) revert StrategyNotActive();
        if (assetsReceived == 0) revert InvalidAmount();

        uint256 oldExtDeposits = externalDeposits[strategyId];
        uint256 reduction = assetsReceived > oldExtDeposits ? oldExtDeposits : assetsReceived;
        if (reduction > totalExternalDeposits) {
            reduction = totalExternalDeposits;
        }

        if (reduction == 0) {
            _markValuationDirty();
            if (allocations[strategyId] == 0) {
                _removeFromActiveStrategies(strategyId);
                SafeERC20Lib.safeTransfer(asset, parentVault, assetsReceived);
            } else {
                settlementSurplusAssets += assetsReceived;
            }
            emit SettlementRecorded(strategyId, assetsReceived, oldExtDeposits);
            return;
        }

        externalDeposits[strategyId] = oldExtDeposits - reduction;
        totalExternalDeposits -= reduction;

        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        uint256 surplus = assetsReceived - reduction;
        if (allocations[strategyId] == 0) {
            SafeERC20Lib.safeTransfer(asset, parentVault, assetsReceived);
        } else if (surplus > 0) {
            settlementSurplusAssets += surplus;
        }

        _markValuationDirty();

        emit ExternalDepositsReduced(strategyId, oldExtDeposits, externalDeposits[strategyId], reduction);
        emit SettlementRecorded(strategyId, assetsReceived, externalDeposits[strategyId]);
    }

    /// @notice Accept native token for bridge messaging fees (LZ OFT).
    receive() external payable {}
}
