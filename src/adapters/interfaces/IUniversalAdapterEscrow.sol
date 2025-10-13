// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IAdapter} from "../../interfaces/IAdapter.sol";

/// @title IUniversalAdapterEscrow
/// @notice Interface for the unified adapter that merges UniversalEscrowAdapter and StrategyEscrow functionality
/// @dev Implements IAdapter for compatibility with VaultV2 and adds strategy execution capabilities
interface IUniversalAdapterEscrow is IAdapter {
    /* STRUCTS */

    /// @notice Configuration for a strategy
    struct StrategyConfig {
        address agent;           // Agent authorized to execute this strategy
        bytes preConfiguredData; // Optional pre-configured calldata
        uint256 dailyLimit;      // Daily spending limit for the strategy
        uint256 lastResetTime;   // Last time the daily limit was reset
        uint256 dailyUsed;       // Amount used today
        bool active;             // Whether the strategy is active
    }

    /// @notice Configuration for whitelisted functions
    struct WhitelistConfig {
        bool allowed;      // Whether the function is allowed
        uint256 limit;     // Limit per call (0 for unlimited if allowed)
    }

    /// @notice Multicall execution structure
    struct Call {
        address target;  // Target contract
        bytes data;      // Calldata to execute
        uint256 value;   // ETH value to send
    }

    /* EVENTS */

    event StrategySet(bytes32 indexed strategyId, address indexed agent, uint256 dailyLimit);
    event StrategyExecuted(bytes32 indexed strategyId, address indexed executor);
    event WhitelistUpdated(address indexed target, bytes4 indexed selector, bool allowed, uint256 limit);
    event TokenSwept(address indexed token, address indexed recipient, uint256 amount);
    event PauseStatusChanged(bool paused);
    event AllocationUpdated(bytes32 indexed strategyId, uint256 newAmount, int256 change);
    event StrategyRemoved(bytes32 indexed strategyId);
    event ExternalDepositsSynced(address indexed syncer, uint256 oldValue, uint256 newValue);

    /* ERRORS */

    error NotAuthorized();
    error InvalidStrategy();
    error StrategyNotActive();
    error DailyLimitExceeded();
    error FunctionNotWhitelisted();
    error CallLimitExceeded();
    error ContractPaused();
    error InvalidData();
    error CannotSweepAsset();
    error CallFailed(uint256 index, bytes returnData);
    error InvalidAmount();
    error SlippageTooHigh();

    /* EXTERNAL FUNCTIONS */

    /// @notice Set or update a strategy configuration
    /// @param strategyId Unique identifier for the strategy
    /// @param agent Address authorized to execute this strategy
    /// @param preConfiguredData Optional pre-configured calldata for the strategy
    /// @param dailyLimit Daily spending limit for the strategy
    function setStrategy(
        bytes32 strategyId,
        address agent,
        bytes calldata preConfiguredData,
        uint256 dailyLimit
    ) external;

    /// @notice Remove a strategy
    /// @param strategyId The strategy to remove
    function removeStrategy(bytes32 strategyId) external;

    /// @notice Update function whitelist
    /// @param target Target contract address
    /// @param selector Function selector (use bytes4(0) for all functions)
    /// @param allowed Whether the function is allowed
    /// @param limit Call limit (0 for unlimited if allowed)
    function updateWhitelist(
        address target,
        bytes4 selector,
        bool allowed,
        uint256 limit
    ) external;

    /// @notice Execute a strategy with multiple calls
    /// @param strategyId The strategy to execute
    /// @param calls Array of calls to execute
    function executeStrategy(bytes32 strategyId, Call[] calldata calls) external;

    /// @notice Execute a pre-configured strategy
    /// @param strategyId The strategy with pre-configured calldata
    function executePreConfigured(bytes32 strategyId) external;

    /// @notice Sweep tokens that are not the primary asset
    /// @param token Token address to sweep
    /// @param recipient Address to receive the tokens
    function sweep(address token, address recipient) external;

    /// @notice Set the pause status
    /// @param _paused Whether to pause the contract
    function setPaused(bool _paused) external;

    /// @notice Manually sync totalExternalDeposits to remove ghost amounts
    /// @param newTotalExternalDeposits The corrected external deposits value (must be <= current)
    function syncExternalDeposits(uint256 newTotalExternalDeposits) external;

    /* VIEW FUNCTIONS */

    /// @notice Get strategy configuration
    /// @param strategyId The strategy identifier
    /// @return config The strategy configuration
    function getStrategy(bytes32 strategyId) external view returns (StrategyConfig memory config);

    /// @notice Get whitelist configuration for a function
    /// @param target Target contract
    /// @param selector Function selector
    /// @return config The whitelist configuration
    function getWhitelist(address target, bytes4 selector) external view returns (WhitelistConfig memory config);

    /// @notice Get allocation for a strategy
    /// @param strategyId The strategy identifier
    /// @return amount The allocated amount
    function getAllocation(bytes32 strategyId) external view returns (uint256 amount);

    /// @notice Get all active strategy IDs
    /// @return Array of active strategy IDs
    function getActiveStrategies() external view returns (bytes32[] memory);

    /// @notice Check if contract is paused
    /// @return Whether the contract is paused
    function paused() external view returns (bool);

    /// @notice Get the parent vault address
    /// @return The parent vault address
    function parentVault() external view returns (address);

    /// @notice Get the asset address
    /// @return The asset address
    function asset() external view returns (address);

    /// @notice Get the valuer address
    /// @return The valuer address
    function valuer() external view returns (address);

    /// @notice Check if using offchain valuer
    /// @return Whether using offchain valuer
    function useOffchainValuer() external view returns (bool);

    /// @notice Get idle assets that are not allocated to any strategy
    /// @dev L-13 FIX: Provides visibility into unused assets to ensure full utilization
    /// @return idleAssets Amount of assets sitting idle in the adapter
    function getIdleAssets() external view returns (uint256 idleAssets);

    /// @notice Calculate current ghost amount (overpricing) if any
    /// @dev Helper function to monitor when manual sync might be needed
    /// @return ghost The amount by which minKnownValue exceeds valuer's reported value
    function getGhostAmount() external view returns (uint256 ghost);
}