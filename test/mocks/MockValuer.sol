// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

contract MockValuer {
    mapping(address => uint256) public values;
    mapping(bytes32 => uint256) public strategyValues;

    function setValue(address target, uint256 value) external {
        values[target] = value;
    }

    function setValue(bytes32 strategyId, uint256 value) external {
        strategyValues[strategyId] = value;
    }

    function getValue(address target) external view returns (uint256) {
        return values[target];
    }

    function getValue(bytes32 strategyId) external view returns (uint256) {
        return strategyValues[strategyId];
    }

    // Add getTotalValue to match the refactored realAssets implementation
    function getTotalValue(address target) external view returns (uint256) {
        return values[target];
    }
}