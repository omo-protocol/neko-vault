// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

contract MockValuer {
    mapping(address => uint256) public values;

    function setValue(address target, uint256 value) external {
        values[target] = value;
    }

    function getValue(address target) external view returns (uint256) {
        return values[target];
    }

    // Add getTotalValue to match the refactored realAssets implementation
    function getTotalValue(address target) external view returns (uint256) {
        return values[target];
    }
}