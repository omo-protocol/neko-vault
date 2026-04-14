// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

library AdapterAccountingLib {
    function trackedAssets(
        uint256 balance,
        uint256 totalAllocations,
        uint256 totalExternalDeposits,
        uint256 settlementSurplusAssets
    ) internal pure returns (uint256 allocatedInAdapterBounded, uint256 trackedSurplus, uint256 trackedTotalAssets) {
        uint256 allocatedInAdapter =
            totalAllocations > totalExternalDeposits ? totalAllocations - totalExternalDeposits : 0;

        allocatedInAdapterBounded = allocatedInAdapter < balance ? allocatedInAdapter : balance;

        uint256 idleBalance = balance > allocatedInAdapterBounded ? balance - allocatedInAdapterBounded : 0;
        trackedSurplus = settlementSurplusAssets < idleBalance ? settlementSurplusAssets : idleBalance;
        trackedTotalAssets = allocatedInAdapterBounded + totalExternalDeposits + trackedSurplus;
    }

    function withinLiveValuationBounds(uint256 totalValue, uint256 trackedAssetsValue) internal pure returns (bool) {
        if (trackedAssetsValue == 0) return totalValue == 0;

        uint256 minExpected = (trackedAssetsValue * 75) / 100;
        uint256 maxExpected = (trackedAssetsValue * 150) / 100;
        return totalValue >= minExpected && totalValue <= maxExpected;
    }
}
