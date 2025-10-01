// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {MockERC20} from "./MockERC20.sol";

/// @title MockReentrantToken
/// @notice Mock ERC20 token that can re-enter during transfer operations
/// @dev Simulates ERC777-like or hooked ERC20 behavior for testing reentrancy vulnerabilities
contract MockReentrantToken is MockERC20 {
    address public reentrantTarget;
    bytes public reentrantCalldata;
    bool public shouldReenter;
    bool private _inCallback;

    constructor(string memory name_, string memory symbol_, uint8 decimals_)
        MockERC20(name_, symbol_, decimals_)
    {}

    /// @notice Configure reentrancy behavior
    /// @param target The contract to call during reentrancy
    /// @param data The calldata to use for reentrancy
    /// @param reenter Whether to actually perform reentrancy
    function setReentrancy(address target, bytes memory data, bool reenter) external {
        reentrantTarget = target;
        reentrantCalldata = data;
        shouldReenter = reenter;
    }

    /// @notice Transfer with reentrancy callback to receiver
    /// @dev Calls receiver before completing transfer (ERC777-like behavior)
    function transfer(address to, uint256 amount) public override returns (bool) {
        // Execute reentrancy before state changes (if enabled and not already in callback)
        if (shouldReenter && !_inCallback && to != address(0)) {
            _inCallback = true;
            (bool success,) = reentrantTarget.call(reentrantCalldata);
            require(success, "Reentrancy call failed");
            _inCallback = false;
        }

        // Standard transfer logic
        return super.transfer(to, amount);
    }

    /// @notice TransferFrom with reentrancy callback to receiver
    /// @dev Calls receiver before completing transfer (ERC777-like behavior)
    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        // Execute reentrancy before state changes (if enabled and not already in callback)
        if (shouldReenter && !_inCallback && to != address(0)) {
            _inCallback = true;
            (bool success,) = reentrantTarget.call(reentrantCalldata);
            require(success, "Reentrancy call failed");
            _inCallback = false;
        }

        // Standard transferFrom logic
        return super.transferFrom(from, to, amount);
    }

    /// @notice Reset reentrancy flag (for testing)
    function resetReentrancy() external {
        shouldReenter = false;
        reentrantTarget = address(0);
        reentrantCalldata = "";
    }
}
