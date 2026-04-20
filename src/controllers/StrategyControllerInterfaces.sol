// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IUniversalAdapterEscrow} from "../adapters/interfaces/IUniversalAdapterEscrow.sol";

interface IAutomatedWithdrawalController {
    function quoteAutomaticAllocation(uint256 assets)
        external
        view
        returns (IUniversalAdapterEscrow.Call[] memory calls);

    function quoteAutomaticWithdrawal(uint256 shortfallAssets)
        external
        view
        returns (IUniversalAdapterEscrow.Call[] memory calls);
}

interface IAsyncWithdrawalController {
    function initiateAsyncWithdrawal(uint256 shortfallAssets) external returns (bool initiated);
}

interface IOnchainStrategyValuer {
    function quoteCurrentAssets() external view returns (uint256 assets, bool healthy);
}

interface IWithdrawalReserveSource {
    function totalProtectedAssets() external view returns (uint256 assets);
}
