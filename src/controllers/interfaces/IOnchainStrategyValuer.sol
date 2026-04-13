// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

interface IOnchainStrategyValuer {
    function quoteCurrentAssets() external view returns (uint256 assets, bool healthy);
}
