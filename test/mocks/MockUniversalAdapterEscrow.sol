// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/**
 * @title MockUniversalAdapterEscrow
 * @notice Mock adapter for testing valuer interactions
 */
contract MockUniversalAdapterEscrow {
    bytes32[] private strategies;

    constructor(bytes32[] memory _strategies) {
        strategies = _strategies;
    }

    function getActiveStrategies() external view returns (bytes32[] memory) {
        return strategies;
    }

    function addStrategy(bytes32 strategyId) external {
        strategies.push(strategyId);
    }

    function removeStrategy(uint256 index) external {
        require(index < strategies.length, "Invalid index");
        strategies[index] = strategies[strategies.length - 1];
        strategies.pop();
    }
}
