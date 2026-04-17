// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @title IBaseStrategyModule
/// @notice Narrow execution surface invoked only by BaseExecutionGateway.
///         No `execute(bytes)`, no `call(target,data)`, no delegatecall.
interface IBaseStrategyModule {
    function topUpPmBuffer(uint256 amount, bytes32 destinationRef, bytes32 payloadHash, bytes32 cycleId) external;

    function topUpHlBuffer(uint256 amount, bytes32 destinationRef, bytes32 payloadHash, bytes32 cycleId) external;

    function pauseDeployments(bytes32 cycleId) external;

    function refillReserve(uint256 amount, bytes32 destinationRef, bytes32 payloadHash, bytes32 cycleId) external;
}
