// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAutomatedWithdrawalController, IOnchainStrategyValuer} from "../controllers/StrategyControllerInterfaces.sol";
import {AdapterAccountingLib} from "./libraries/AdapterAccountingLib.sol";
import {ContractCodeCheckerLib} from "./libraries/ContractCodeCheckerLib.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {UniversalAdapterEscrowStorage} from "./UniversalAdapterEscrowStorage.sol";

abstract contract UniversalAdapterEscrowInternals is UniversalAdapterEscrowStorage {
    using ContractCodeCheckerLib for address;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    function _validateAutomationFlags(uint256 automationFlags) internal pure {
        if (automationFlags > MAX_AUTOMATION_FLAGS) revert InvalidData();
    }

    function _validateWhitelistTarget(address target) internal view {
        if (target.code.length == 0) revert InvalidData();
        // Allow EIP-1167 minimal proxies (fixed implementation, safe despite DELEGATECALL)
        // Block other contracts containing DELEGATECALL (upgradeable proxies)
        if (target.containsDelegatecallOpcode() && target.cloneImplementation() == address(0)) {
            revert InvalidData();
        }
    }

    function _shouldAutoWithdraw(bytes4 caller, address initiator) internal view returns (bool) {
        return caller == DEALLOCATE_SELECTOR && _isAllocator(initiator);
    }

    function _isAllocator(address account) internal view returns (bool allocator) {
        (bool success, bytes memory data) =
            parentVault.staticcall(abi.encodeWithSignature("isAllocator(address)", account));
        if (!success || data.length < 32) {
            return false;
        }
        allocator = abi.decode(data, (bool));
    }

    function _executeMulticall(bytes32 strategyId, Call[] memory calls, bool bypassCircuitBreaker) internal {
        uint256 balanceBefore = IERC20(asset).balanceOf(address(this));

        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];
            _validateWhitelistedCall(call);

            (bool success, bytes memory returnData) = call.target.call{value: call.value}(call.data);
            if (!success) {
                revert CallFailed(i, returnData);
            }
        }

        uint256 balanceAfter = IERC20(asset).balanceOf(address(this));
        _recordMulticallBalanceChange(strategyId, balanceBefore, balanceAfter, bypassCircuitBreaker);
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
        _recordWithdrawnAssets(strategyId, withdrawnAmount);

        if (withdrawnAmount < shortfallAssets) revert SlippageTooHigh();
    }

    function _trackedAssets(uint256 balance)
        internal
        view
        returns (uint256 allocatedInAdapterBounded, uint256 trackedSurplus, uint256 trackedAssets)
    {
        return AdapterAccountingLib.trackedAssets(balance, totalAllocations, totalExternalDeposits, settlementSurplusAssets);
    }

    function _resolveCurrentValuation() internal view returns (bool hasValue, bool hasStaleData, uint256 totalValue) {
        (hasValue, hasStaleData, totalValue,,) = _resolveSnapshotValuation();
    }

    function _resolveSnapshotValuation()
        internal
        view
        returns (bool hasValue, bool hasStaleData, uint256 totalValue, uint64 snapshotTimestamp, bool fromOnchain)
    {
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
        if (strategyIds.length == 0) {
            return (false, false, 0, 0);
        }

        healthy = true;

        for (uint256 i = 0; i < strategyIds.length; i++) {
            address agent = strategies[strategyIds[i]].agent;
            (bool valuationSuccess, bool strategyHealthy, uint256 strategyValue) = _quoteOnchainStrategyValue(agent);
            if (!valuationSuccess) {
                return (false, false, 0, 0);
            }

            totalValue += strategyValue;
            if (!strategyHealthy) {
                healthy = false;
            }
        }

        return (true, healthy, totalValue, 0);
    }

    function _supportsOnchainValuationAgent(address agent) internal view returns (bool) {
        if (agent == address(0) || agent == address(this) || agent == parentVault || agent.code.length == 0) {
            return false;
        }

        (bool success,,) = _quoteOnchainStrategyValue(agent);
        if (success) return true;

        if (agent.containsPushedSelector(IOnchainStrategyValuer.quoteCurrentAssets.selector)) return true;

        address implementation = agent.cloneImplementation();
        return implementation != address(0)
            && implementation.containsPushedSelector(IOnchainStrategyValuer.quoteCurrentAssets.selector);
    }

    function _queueProtectedAssets(address queue) internal view returns (uint256 protectedAssets) {
        (bool success, bytes memory result) = queue.staticcall(abi.encodeWithSignature("totalProtectedAssets()"));
        if (!success || result.length < 32) {
            return type(uint256).max;
        }

        protectedAssets = abi.decode(result, (uint256));
    }

    function _validateWhitelistedCall(Call memory call) internal view {
        if (call.data.length < 4) revert InvalidData();

        bytes4 selector = bytes4(call.data);
        if (!functionWhitelist[call.target][selector].allowed && !functionWhitelist[call.target][bytes4(0)].allowed) {
            revert FunctionNotWhitelisted();
        }
        if (whitelistCodeHashes[call.target] != call.target.codehash) revert InvalidData();
    }

    function _quoteOnchainStrategyValue(address agent)
        internal
        view
        returns (bool success, bool healthy, uint256 totalValue)
    {
        (bool valuationSuccess, bytes memory data) =
            agent.staticcall(abi.encodeWithSelector(IOnchainStrategyValuer.quoteCurrentAssets.selector));
        if (!valuationSuccess || data.length < 64) {
            return (false, false, 0);
        }

        uint256 rawHealthy;
        assembly {
            totalValue := mload(add(data, 0x20))
            rawHealthy := mload(add(data, 0x40))
        }
        if (rawHealthy > 1) {
            return (false, false, 0);
        }
        healthy = rawHealthy == 1;
        return (true, healthy, totalValue);
    }

    function _markValuationDirty() internal {
        cachedValuationTimestamp = 0;
    }

    function _recordWithdrawnAssets(bytes32 strategyId, uint256 withdrawnAmount) internal {
        if (withdrawnAmount == 0) return;

        uint256 oldExtDeposits = externalDeposits[strategyId];
        uint256 reduction = withdrawnAmount > oldExtDeposits ? oldExtDeposits : withdrawnAmount;
        if (reduction > totalExternalDeposits) {
            reduction = totalExternalDeposits;
        }

        if (reduction > 0) {
            externalDeposits[strategyId] = oldExtDeposits - reduction;
            totalExternalDeposits -= reduction;
            emit ExternalDepositsReduced(strategyId, oldExtDeposits, externalDeposits[strategyId], reduction);
        }

        uint256 surplus = withdrawnAmount - reduction;
        if (surplus > 0) {
            settlementSurplusAssets += surplus;
        }

        if (reduction > 0 || surplus > 0) {
            _markValuationDirty();
        }

        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }
    }

    function _recordMulticallBalanceChange(
        bytes32 strategyId,
        uint256 balanceBefore,
        uint256 balanceAfter,
        bool bypassCircuitBreaker
    ) internal {
        if (!bypassCircuitBreaker && balanceAfter < balanceBefore && balanceBefore > 0) {
            uint256 loss = balanceBefore - balanceAfter;
            uint256 lossBps = (loss * 10000) / balanceBefore;
            if (lossBps > MAX_BALANCE_LOSS_BPS) revert ExcessiveBalanceLoss();
        }

        if (balanceAfter < balanceBefore) {
            uint256 deposited = balanceBefore - balanceAfter;
            uint256 surplusConsumed = deposited > settlementSurplusAssets ? settlementSurplusAssets : deposited;
            if (surplusConsumed > 0) {
                settlementSurplusAssets -= surplusConsumed;
                deposited -= surplusConsumed;
            }
            if (deposited > 0) {
                externalDeposits[strategyId] += deposited;
                totalExternalDeposits += deposited;
            }
            if (surplusConsumed > 0 || deposited > 0) {
                _markValuationDirty();
            }
        }
        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }
    }


}
