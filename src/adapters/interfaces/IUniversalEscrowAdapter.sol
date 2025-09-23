// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IUniversalEscrowAdapter
/// @notice Interface for the Universal Escrow Adapter that bridges Morpho Vault V2 to multiple strategies
interface IUniversalEscrowAdapter {
    /* ERRORS */

    error NotAuthorized();
    error InvalidStrategy();
    error InvalidData();
    error EmergencyOnly();
    error StrategyPaused();
    error EmergencyRecoveryAlreadyPending();
    error NoEmergencyRecoveryPending();
    error EmergencyRecoveryNotInitiated();
    error EmergencyRecoveryTimelockNotExpired();

    /* EVENTS */

    event StrategyAllocated(bytes32 indexed strategyId, uint256 amount);
    event StrategyDeallocated(bytes32 indexed strategyId, uint256 amount);
    event EmergencyWithdrawal(address indexed recipient, uint256 amount);
    event StrategyRegistered(bytes32 indexed strategyId, address valuer);
    event StrategyPausedToggled(bytes32 indexed strategyId, bool paused);
    event EmergencyRecoveryInitiated(uint256 executeTimestamp);
    event EmergencyRecoveryCancelled();

    /* FUNCTIONS */

    /// @notice Allocates funds to a specific strategy
    /// @param data Encoded strategy allocation data (strategyId, amount, params)
    /// @return ids Array of allocation identifiers
    /// @return change Net change in allocated assets
    function allocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);

    /// @notice Deallocates funds from a specific strategy
    /// @param data Encoded strategy deallocation data (strategyId, amount, params)
    /// @return ids Array of deallocation identifiers
    /// @return change Net change in allocated assets
    function deallocate(bytes memory data, uint256 assets, bytes4 selector, address sender)
        external
        returns (bytes32[] memory ids, int256 change);

    /// @notice Returns total value of all strategies
    /// @return assets Total value in underlying asset
    function realAssets() external view returns (uint256 assets);

    /// @notice Emergency withdrawal of all funds
    /// @dev Only callable by authorized roles during emergency
    function forceRecovery() external;

    /// @notice Get the escrow contract address
    function escrow() external view returns (address);

    /// @notice Get the valuer contract address
    function valuer() external view returns (address);

    /// @notice Get allocation for a specific strategy
    function getStrategyAllocation(bytes32 strategyId) external view returns (uint256);

    /// @notice Get the parent vault address
    function parentVault() external view returns (address);
}