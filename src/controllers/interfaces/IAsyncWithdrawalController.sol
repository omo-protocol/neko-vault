// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface IAsyncWithdrawalController {
    function initiateAsyncWithdrawal(uint256 shortfallAssets) external returns (bool initiated);
}
