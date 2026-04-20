// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IERC20} from "../interfaces/IERC20.sol";
import {AdapterAccountingLib} from "./libraries/AdapterAccountingLib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";
import {UniversalAdapterEscrowInternals} from "./UniversalAdapterEscrowInternals.sol";

abstract contract UniversalAdapterEscrowValuation is UniversalAdapterEscrowInternals {
    using EnumerableSet for EnumerableSet.Bytes32Set;

    function realAssets() external view override returns (uint256 assets) {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        (, uint256 trackedSurplus, uint256 trackedAssets) = _trackedAssets(balance);

        (bool hasValue, bool hasStaleData, uint256 totalValue) = _resolveCurrentValuation();

        if (hasValue) {
            if (hasStaleData || emergencyMode) {
                return totalValue * (10000 - EMERGENCY_HAIRCUT) / 10000;
            }

            return totalValue;
        }
        if (totalAllocations == 0) {
            return trackedSurplus;
        }
        if (!emergencyMode) {
            revert ValuationUnavailable();
        }
        if (cachedValuationTimestamp != 0 && block.timestamp - cachedValuationTimestamp <= MAX_CACHED_VALUATION_AGE) {
            uint256 haircuttedBaseline = (trackedAssets * (10000 - EMERGENCY_HAIRCUT)) / 10000;
            return cachedValuation < haircuttedBaseline ? cachedValuation : haircuttedBaseline;
        }
        return (trackedAssets * (10000 - EMERGENCY_HAIRCUT)) / 10000;
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
        _markValuationDirty();

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
        _markValuationDirty();

        if (allocations[strategyId] == 0 && newPerStrategy == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        emit ExternalDepositsReduced(strategyId, current, newPerStrategy, delta);
    }

    /// @notice Refresh cached valuation from the active valuation source
    function refreshCachedValuation() external {
        (bool hasValue,, uint256 totalValue,,) = _resolveSnapshotValuation();

        if (!hasValue) {
            revert("Valuation unavailable");
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
        (, uint256 trackedSurplus, uint256 trackedAssets) = _trackedAssets(balance);
        (bool hasValue, bool hasStaleData, uint256 totalValue, uint64 valuationTimestamp,) =
            _resolveSnapshotValuation();

        if (!hasValue) {
            return (totalAllocations == 0 ? trackedSurplus : trackedAssets, 0, false);
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

        emit EmergencyModeEnabled(block.timestamp, "Valuation unavailable");
    }

    function disableEmergencyMode() external onlyOwner {
        if (!emergencyMode) revert EmergencyModeNotEnabled();

        (bool hasValue,, uint256 totalValue) = _resolveCurrentValuation();

        if (!hasValue) revert ValuationUnavailable();

        if (totalAllocations > 0 && totalValue == 0) revert ValuationUnavailable();

        uint256 duration = block.timestamp - emergencyModeActivatedAt;
        emergencyMode = false;
        emergencyModeActivatedAt = 0;

        emit EmergencyModeDisabled(block.timestamp, duration);
    }
}
