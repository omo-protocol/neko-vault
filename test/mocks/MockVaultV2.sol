// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

contract MockVaultV2 {
    address public asset;
    address public owner;
    mapping(address => bool) public adapters;

    constructor(address _asset, address _owner) {
        asset = _asset;
        owner = _owner;
    }

    function addAdapter(address adapter) external {
        adapters[adapter] = true;
    }

    function removeAdapter(address adapter) external {
        adapters[adapter] = false;
    }

    function isAdapter(address adapter) external view returns (bool) {
        return adapters[adapter];
    }
}