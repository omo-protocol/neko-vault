// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {IAdapter} from "../../src/interfaces/IAdapter.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {SafeERC20Lib} from "../../src/libraries/SafeERC20Lib.sol";

contract MockVaultV2 {
    address public asset;
    address public owner;
    mapping(address => bool) public adapters;
    mapping(address => uint256) public forceDeallocatePenalty;

    constructor(address _asset, address _owner) {
        asset = _asset;
        owner = _owner;
    }

    function addAdapter(address adapter) external {
        adapters[adapter] = true;
        forceDeallocatePenalty[adapter] = 0.01e18; // 1% penalty
    }

    function removeAdapter(address adapter) external {
        adapters[adapter] = false;
    }

    function isAdapter(address adapter) external view returns (bool) {
        return adapters[adapter];
    }

    /// @notice Mock implementation of forceDeallocate
    function forceDeallocate(address adapter, bytes memory data, uint256 assets, address onBehalf)
        external
        returns (uint256 penaltyShares)
    {
        require(adapters[adapter], "Not an adapter");

        // Call adapter.deallocate with forceDeallocate selector
        (bytes32[] memory ids, int256 change) = IAdapter(adapter).deallocate(data, assets, this.forceDeallocate.selector, msg.sender);

        // Transfer assets from adapter to vault
        SafeERC20Lib.safeTransferFrom(asset, adapter, address(this), assets);

        // Calculate penalty (simplified - just return a mock penalty)
        penaltyShares = (assets * forceDeallocatePenalty[adapter]) / 1e18;

        return penaltyShares;
    }

    /// @notice Mock withdraw function (simplified)
    function withdraw(uint256 assets, address receiver, address onBehalf) external returns (uint256 shares) {
        // Simplified mock - just transfer assets and return mock shares
        SafeERC20Lib.safeTransfer(asset, receiver, assets);
        return assets; // 1:1 assets to shares ratio for simplicity
    }
}