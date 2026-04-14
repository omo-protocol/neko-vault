// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ISendAssetsGate} from "../interfaces/IGate.sol";

/// @notice Gate that restricts sendAssets to a single wrapper address.
/// @dev The wrapper address is immutable after initialization (set once via clone factory).
/// If the wrapper changes, deploy a new gate instance. This is by design — the gate is
/// deployed per-vault with a fixed wrapper, and raw address comparison is intentional.
contract WrapperOnlySendAssetsGate is ISendAssetsGate {
    address public wrapper;
    bool private _initialized;

    constructor(address wrapper_) {
        if (wrapper_ == address(0)) {
            _initialized = true;
            return;
        }
        _initialize(wrapper_);
    }

    function initialize(address wrapper_) external {
        _initialize(wrapper_);
    }

    function _initialize(address wrapper_) internal {
        require(!_initialized, "initialized");
        require(wrapper_ != address(0), "invalid wrapper");

        _initialized = true;
        wrapper = wrapper_;
    }

    function canSendAssets(address account) external view returns (bool) {
        return account == wrapper;
    }
}
