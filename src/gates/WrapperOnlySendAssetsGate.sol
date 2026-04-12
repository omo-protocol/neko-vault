// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ISendAssetsGate} from "../interfaces/IGate.sol";

contract WrapperOnlySendAssetsGate is ISendAssetsGate {
    address public immutable wrapper;

    constructor(address wrapper_) {
        require(wrapper_ != address(0), "invalid wrapper");
        wrapper = wrapper_;
    }

    function canSendAssets(address account) external view returns (bool) {
        return account == wrapper;
    }
}
