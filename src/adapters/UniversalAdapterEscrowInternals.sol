// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAutomatedWithdrawalController, IOnchainStrategyValuer} from "../controllers/StrategyControllerInterfaces.sol";
import {IUniversalValuerOffchain} from "./interfaces/IUniversalValuerOffchain.sol";
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
        if (target.code.length == 0 || target.containsDelegatecallOpcode()) {
            revert InvalidData();
        }
    }

    function _shouldAutoWithdraw(bytes4 caller, address initiator) internal view returns (bool) {
        if (caller == WITHDRAW_SELECTOR || caller == REDEEM_SELECTOR) {
            return true;
        }
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
        uint256 balance = IERC20(asset).balanceOf(address(this));
        (,, uint256 trackedAssets) = _trackedAssets(balance);
        bool fromOnchain;
        (hasValue, hasStaleData, totalValue,, fromOnchain) = _resolveSnapshotValuation();
        uint256 valuationBase = totalAllocations > 0 ? totalAllocations : trackedAssets;
        if (fromOnchain && !AdapterAccountingLib.withinLiveValuationBounds(totalValue, valuationBase)) {
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
                bool totalHealthy = healthSuccess && healthData.length >= 32 && abi.decode(healthData, (bool));
                return (true, !totalHealthy, totalAssets, totalTimestamp, false);
            }

            if (healthSuccess && healthData.length >= 32) {
                hasStaleData = !abi.decode(healthData, (bool));
                (hasValue, totalValue, snapshotTimestamp) = _aggregateActiveStrategyValuesWithTimestamp();
                if (hasValue) {
                    return (hasValue, hasStaleData, totalValue, snapshotTimestamp, false);
                }
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
        return (true, healthy, totalValue, 0);
    }

    function _hasExternalValuer() internal view returns (bool) {
        return valuer != address(0) && valuer.code.length > 0;
    }

    function _supportsOnchainValuationAgent(address agent) internal view returns (bool) {
        if (agent.code.length == 0) return false;

        (bool success, bytes memory data) =
            agent.staticcall(abi.encodeWithSelector(IOnchainStrategyValuer.quoteCurrentAssets.selector));
        if (success && data.length >= 64) return true;

        if (agent.containsPushedSelector(IOnchainStrategyValuer.quoteCurrentAssets.selector)) return true;

        address implementation = agent.cloneImplementation();
        return implementation != address(0)
            && implementation.containsPushedSelector(IOnchainStrategyValuer.quoteCurrentAssets.selector);
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
            return (false, 0, 0);
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
        if (!success || data.length < 192) {
            return (false, 0);
        }

        IUniversalValuerOffchain.ValueReport memory report = abi.decode(data, (IUniversalValuerOffchain.ValueReport));
        if (report.timestamp == 0 || report.timestamp > type(uint64).max) {
            return (false, 0);
        }

        return (true, uint64(report.timestamp));
    }

    function _validateWhitelistedCall(Call memory call) internal view {
        if (call.data.length < 4) revert InvalidData();

        bytes4 selector = bytes4(call.data);
        if (!functionWhitelist[call.target][selector].allowed && !functionWhitelist[call.target][bytes4(0)].allowed) {
            revert FunctionNotWhitelisted();
        }
        if (whitelistCodeHashes[call.target] != call.target.codehash) revert InvalidData();
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
            externalDeposits[strategyId] += deposited;
            totalExternalDeposits += deposited;
        }
        if (allocations[strategyId] == 0 && externalDeposits[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }
    }


}
