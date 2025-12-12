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
    event ExternalDepositsReduced(bytes32 indexed strategyId, uint256 oldValue, uint256 newValue, uint256 delta);
    event ExternalDepositSyncedPerStrategy(bytes32 indexed strategyId, uint256 oldValue, uint256 newValue, uint256 delta);
    event ExternalDepositsSyncedBatch(address indexed syncer, uint256 totalDelta, uint256 newTotalValue);
    event SyncDeviationWarning(uint256 newMinKnown, uint256 valuerValue, uint256 deviation, uint256 deviationBps);
    event CachedValuationRefreshed(uint256 newValue, uint256 timestamp);
    event ExternalDepositsValuerSynced(bytes32 indexed strategyId, uint256 oldValue, uint256 newValue, int256 delta);
    event YieldAccrued(bytes32 indexed strategyId, uint256 yieldAmount);
    event UnexpectedValueChange(bytes32 indexed strategyId, uint256 expected, uint256 actual, uint256 withdrawn, string reason);
    event AccountingDesyncDetected(bytes32 indexed strategyId, uint256 decrease, uint256 totalAvailable);
    event EmergencyModeEnabled(uint256 timestamp, string reason);
    event EmergencyModeDisabled(uint256 timestamp, uint256 duration);
    event PartialDeallocate(bytes32 indexed strategyId, uint256 requested, uint256 actual);
    event StrategyWithdrawn(bytes32 indexed strategyId, uint256 amount, address indexed executor);

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
    error ExcessiveBalanceLoss();
    error ValuationUnavailable();
    error EmergencyModeAlreadyEnabled();
    error EmergencyModeNotEnabled();
    error ValuerStillUnavailable();
    error LiquidityDataMustHaveEmptyCalls();
    error InsufficientAdapterBalance(uint256 available, uint256 requested);
    error StrategyIdCollisionWithEscrowTotal(); // SECURITY FIX: strategyId cannot equal ESCROW_TOTAL ID

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

    /// @notice Execute strategy calls with additional slippage protection
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    /// @param minBalanceIncrease Minimum balance increase required (for withdrawals), 0 to skip check
    function executeStrategyWithSlippage(
        bytes32 strategyId,
        Call[] calldata calls,
        uint256 minBalanceIncrease
    ) external;

    /// @notice Execute strategy calls with circuit breaker bypassed
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    /// @dev USE WITH EXTREME CAUTION: Bypasses 10% balance loss circuit breaker
    function executeStrategyBypassCircuitBreaker(
        bytes32 strategyId,
        Call[] calldata calls
    ) external;

    /// @notice Withdraw assets from external protocol to refill adapter balance
    /// @param strategyId The strategy to withdraw from
    /// @param withdrawCalls Array of calls to execute protocol withdrawals
    /// @param minBalanceIncrease Minimum balance increase required (slippage protection)
    function withdrawFromStrategy(
        bytes32 strategyId,
        Call[] calldata withdrawCalls,
        uint256 minBalanceIncrease
    ) external;

    /// @notice Sweep tokens that are not the primary asset
    /// @param token Token address to sweep
    /// @param recipient Address to receive the tokens
    function sweep(address token, address recipient) external;

    /// @notice Set the pause status
    /// @param _paused Whether to pause the contract
    function setPaused(bool _paused) external;

    /// @notice Sync external deposits for specific strategies with actual values
    /// @param strategyIds Array of strategy IDs to update
    /// @param newValues Array of new external deposit values for each strategy
    function syncExternalDepositsPerStrategy(bytes32[] calldata strategyIds, uint256[] calldata newValues) external;

    /// @notice Manually sync strategy with valuer for drift correction (owner-only)
    /// @dev Simple manual sync when drift accumulates from fees/slippage/yield
    /// @param strategyId Strategy to sync with valuer
    function syncStrategyWithValuer(bytes32 strategyId) external;

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

    /// @notice Get the owner address
    /// @return The owner address
    function owner() external view returns (address);

    /// @notice Get idle assets that are not allocated to any strategy
    /// @return idleAssets Amount of assets sitting idle in the adapter
    function getIdleAssets() external view returns (uint256 idleAssets);

    /// @notice Get cached valuation info for monitoring
    /// @return value The cached valuation value
    /// @return timestamp When the valuation was cached
    /// @return isStale Whether the cached value is too old (>1 hour)
    function getCachedValuation() external view returns (uint256 value, uint256 timestamp, bool isStale);

    /// @notice Enable emergency mode when valuer is unavailable
    /// @dev Applies conservative haircut to prevent arbitrage during valuer downtime
    function enableEmergencyMode() external;

    /// @notice Disable emergency mode when valuer is restored
    /// @dev Requires valuer to be working before disabling
    function disableEmergencyMode() external;

    /// @notice Check if emergency mode is active
    /// @return Whether emergency mode is active
    function emergencyMode() external view returns (bool);

    /// @notice Get when emergency mode was activated
    /// @return Timestamp of emergency mode activation (0 if not active)
    function emergencyModeActivatedAt() external view returns (uint256);

    /// @notice Get the emergency haircut percentage in basis points
    /// @return Haircut in basis points (e.g., 500 = 5%)
    function EMERGENCY_HAIRCUT() external view returns (uint256);
}
