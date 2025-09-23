// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity >=0.5.0;

/// @title IStrategyEscrow
/// @notice Interface for the Strategy Escrow that holds funds and executes whitelisted strategies
interface IStrategyEscrow {
    /* STRUCTS */

    struct Call {
        address target;
        bytes data;
        uint256 value;
    }

    struct WhitelistEntry {
        bool allowed;
        uint256 dailyLimit;
        uint256 usedToday;
        uint256 lastReset;
    }

    /* ERRORS */

    error NotAuthorized();
    error NotWhitelisted();
    error DailyLimitExceeded();
    error CallFailed(address target, bytes data);
    error InvalidStrategy();
    error ReentrancyGuard();
    error MulticallIsPaused();
    error AlreadyPaused();
    error NotPaused();
    error InvalidRecipient();
    error AlreadyInitialized();
    error InvalidAdapter();

    /* EVENTS */

    event StrategyExecuted(bytes32 indexed strategyId, address indexed agent, uint256 callsExecuted);
    event WhitelistUpdated(address indexed target, bytes4 indexed selector, bool allowed);
    event AgentUpdated(bytes32 indexed strategyId, address indexed agent);
    event AllocationNotified(bytes32 indexed strategyId, uint256 amount);
    event EmergencyWithdrawal(address indexed recipient, uint256 amount);
    event PositionUpdated(bytes32 indexed strategyId, bytes positionData);
    event MulticallPaused(address indexed pauser, uint256 timestamp);
    event MulticallUnpaused(address indexed unpauser, uint256 timestamp);
    event GuardianUpdated(address indexed oldGuardian, address indexed newGuardian);
    event AdapterSet(address indexed adapter);

    /* FUNCTIONS */

    /// @notice Executes multiple calls for a specific strategy
    /// @param strategyId The strategy identifier
    /// @param calls Array of calls to execute
    function executeMulticall(bytes32 strategyId, Call[] calldata calls) external;

    /// @notice Notifies the escrow of an allocation from the adapter
    /// @param strategyId The strategy identifier
    /// @param amount The amount allocated
    function notifyAllocation(bytes32 strategyId, uint256 amount) external;

    /// @notice Emergency withdrawal of all funds to specified recipient
    /// @param recipient The address to send funds to
    function emergencyWithdrawAll(address recipient) external;

    /// @notice Get active strategies
    /// @return Array of active strategy identifiers
    function getActiveStrategies() external view returns (bytes32[] memory);

    /// @notice Get position data for a strategy
    /// @param strategyId The strategy identifier
    /// @return Encoded position data
    function getStrategyPosition(bytes32 strategyId) external view returns (bytes memory);

    /// @notice Check if a call is whitelisted
    /// @param target The contract to call
    /// @param selector The function selector
    /// @return Whether the call is whitelisted
    function isWhitelisted(address target, bytes4 selector) external view returns (bool);

    /// @notice Get the authorized agent for a strategy
    /// @param strategyId The strategy identifier
    /// @return The agent address
    function strategyAgents(bytes32 strategyId) external view returns (address);

    /// @notice Update whitelist for a target and selector
    /// @param target The contract address
    /// @param selector The function selector
    /// @param allowed Whether to allow or disallow
    /// @param dailyLimit Optional daily limit for this call
    function updateWhitelist(address target, bytes4 selector, bool allowed, uint256 dailyLimit) external;

    /// @notice Set the agent for a strategy
    /// @param strategyId The strategy identifier
    /// @param agent The agent address
    function setStrategyAgent(bytes32 strategyId, address agent) external;

    /// @notice Pause multicall execution
    function pauseMulticall() external;

    /// @notice Unpause multicall execution
    function unpauseMulticall() external;

    /// @notice Set guardian address for emergency pause capability
    /// @param guardian Address of the guardian
    function setGuardian(address guardian) external;

    /// @notice Check if multicall can be unpaused automatically
    /// @return bool True if MAX_PAUSE_DURATION has elapsed
    function canAutoUnpause() external view returns (bool);

    /// @notice Check if multicall is currently paused
    /// @return bool True if paused
    function multicallPaused() external view returns (bool);

    /// @notice Get the guardian address
    /// @return address The guardian address
    function guardian() external view returns (address);

    /// @notice Get the pause timestamp
    /// @return uint256 The timestamp when pause was activated
    function pauseTimestamp() external view returns (uint256);
}