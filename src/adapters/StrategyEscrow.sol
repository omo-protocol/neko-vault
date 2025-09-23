// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IStrategyEscrow} from "./interfaces/IStrategyEscrow.sol";
import {IUniversalEscrowAdapter} from "./interfaces/IUniversalEscrowAdapter.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

/// @title StrategyEscrow
/// @notice Holds funds and executes whitelisted strategy operations
/// @dev Implements secure multicall with granular permissions
contract StrategyEscrow is IStrategyEscrow {
    using SafeERC20Lib for IERC20;

    /* CONSTANTS */

    uint256 private constant DAY = 86400;
    uint256 private constant MAX_PAUSE_DURATION = 72 hours;

    /* IMMUTABLES */

    address public immutable adapter;
    address public immutable owner;

    /* STORAGE */

    mapping(address => mapping(bytes4 => WhitelistEntry)) public whitelist;
    mapping(bytes32 => address) public strategyAgents;
    mapping(bytes32 => bytes) public activeStrategies;
    mapping(bytes32 => uint256) public strategyAllocations;

    bytes32[] public activeStrategyList;
    uint256 private locked; // Reentrancy guard

    // Pause state
    bool public multicallPaused;
    uint256 public pauseTimestamp;
    address public guardian; // Optional guardian for emergency pause

    /* MODIFIERS */

    modifier onlyAdapter() {
        if (msg.sender != adapter) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier onlyAgent(bytes32 strategyId) {
        if (msg.sender != strategyAgents[strategyId] && msg.sender != adapter) {
            revert NotAuthorized();
        }
        _;
    }

    modifier nonReentrant() {
        if (locked != 0) revert ReentrancyGuard();
        locked = 1;
        _;
        locked = 0;
    }

    modifier whenMulticallNotPaused() {
        if (multicallPaused) revert MulticallIsPaused();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && msg.sender != guardian) revert NotAuthorized();
        _;
    }

    /* CONSTRUCTOR */

    constructor(address _adapter, address _owner) {
        adapter = _adapter;
        owner = _owner;
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc IStrategyEscrow
    function executeMulticall(
        bytes32 strategyId,
        Call[] calldata calls
    ) external override onlyAgent(strategyId) nonReentrant whenMulticallNotPaused {
        uint256 callsExecuted = 0;

        for (uint256 i = 0; i < calls.length; i++) {
            _executeCall(calls[i]);
            callsExecuted++;
        }

        // Update position tracking
        _updateStrategyPosition(strategyId, calls);

        emit StrategyExecuted(strategyId, msg.sender, callsExecuted);
    }

    /// @inheritdoc IStrategyEscrow
    function notifyAllocation(
        bytes32 strategyId,
        uint256 amount
    ) external override onlyAdapter {
        strategyAllocations[strategyId] += amount;
        _addActiveStrategy(strategyId);

        emit AllocationNotified(strategyId, amount);
    }

    /// @inheritdoc IStrategyEscrow
    function emergencyWithdrawAll(address recipient) external override onlyAdapter {
        // Validate recipient address - must be the adapter itself or the vault
        if (recipient != adapter && recipient != IUniversalEscrowAdapter(adapter).parentVault()) {
            revert InvalidRecipient();
        }

        // Withdraw all tokens to recipient
        address[] memory tokens = _getHeldTokens();
        uint256 totalWithdrawn = 0;

        for (uint256 i = 0; i < tokens.length; i++) {
            uint256 balance = IERC20(tokens[i]).balanceOf(address(this));
            if (balance > 0) {
                SafeERC20Lib.safeTransfer(tokens[i], recipient, balance);
                totalWithdrawn += balance;
            }
        }

        // Clear all active strategies
        delete activeStrategyList;

        emit EmergencyWithdrawal(recipient, totalWithdrawn);
    }

    /// @inheritdoc IStrategyEscrow
    function getActiveStrategies() external view override returns (bytes32[] memory) {
        return activeStrategyList;
    }

    /// @inheritdoc IStrategyEscrow
    function getStrategyPosition(
        bytes32 strategyId
    ) external view override returns (bytes memory) {
        return activeStrategies[strategyId];
    }

    /// @inheritdoc IStrategyEscrow
    function isWhitelisted(
        address target,
        bytes4 selector
    ) external view override returns (bool) {
        WhitelistEntry memory entry = whitelist[target][selector];
        return entry.allowed;
    }

    /* ADMIN FUNCTIONS */

    /// @inheritdoc IStrategyEscrow
    function updateWhitelist(
        address target,
        bytes4 selector,
        bool allowed,
        uint256 dailyLimit
    ) external override onlyOwner {
        whitelist[target][selector] = WhitelistEntry({
            allowed: allowed,
            dailyLimit: dailyLimit,
            usedToday: 0,
            lastReset: block.timestamp
        });

        emit WhitelistUpdated(target, selector, allowed);
    }

    /// @inheritdoc IStrategyEscrow
    function setStrategyAgent(
        bytes32 strategyId,
        address agent
    ) external override onlyOwner {
        strategyAgents[strategyId] = agent;
        emit AgentUpdated(strategyId, agent);
    }

    /// @notice Pause multicall execution
    /// @dev Can be called by owner or guardian for emergency response
    function pauseMulticall() external onlyOwnerOrGuardian {
        if (multicallPaused) revert AlreadyPaused();

        multicallPaused = true;
        pauseTimestamp = block.timestamp;

        emit MulticallPaused(msg.sender, block.timestamp);
    }

    /// @notice Unpause multicall execution
    /// @dev Owner can unpause anytime, auto-unpause after MAX_PAUSE_DURATION
    function unpauseMulticall() external {
        if (!multicallPaused) revert NotPaused();

        // Auto-unpause after max duration or owner unpause
        bool autoUnpauseAvailable = block.timestamp > pauseTimestamp + MAX_PAUSE_DURATION;
        bool isOwner = msg.sender == owner;

        if (!autoUnpauseAvailable && !isOwner) revert NotAuthorized();

        multicallPaused = false;
        pauseTimestamp = 0;

        emit MulticallUnpaused(msg.sender, block.timestamp);
    }

    /// @notice Set guardian address for emergency pause capability
    /// @param _guardian Address of the guardian (can be address(0) to remove)
    function setGuardian(address _guardian) external onlyOwner {
        address oldGuardian = guardian;
        guardian = _guardian;
        emit GuardianUpdated(oldGuardian, _guardian);
    }

    /// @notice Check if multicall can be unpaused automatically
    /// @return bool True if MAX_PAUSE_DURATION has elapsed
    function canAutoUnpause() external view returns (bool) {
        return multicallPaused && block.timestamp > pauseTimestamp + MAX_PAUSE_DURATION;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Execute a single call with whitelist and limit checks
    function _executeCall(Call memory call) internal {
        bytes4 selector = bytes4(call.data);
        WhitelistEntry storage entry = whitelist[call.target][selector];

        // Check whitelist
        if (!entry.allowed) revert NotWhitelisted();

        // Check daily limit if applicable
        if (entry.dailyLimit > 0) {
            // Reset daily counter if needed
            if (block.timestamp > entry.lastReset + DAY) {
                entry.usedToday = 0;
                entry.lastReset = block.timestamp;
            }

            // Check limit
            if (entry.usedToday + call.value > entry.dailyLimit) {
                revert DailyLimitExceeded();
            }

            entry.usedToday += call.value;
        }

        // Execute call
        (bool success, bytes memory result) = call.target.call{value: call.value}(call.data);
        if (!success) revert CallFailed(call.target, call.data);
    }

    /// @dev Update strategy position data based on executed calls
    function _updateStrategyPosition(bytes32 strategyId, Call[] memory calls) internal {
        // Encode the calls as position data for now
        // This can be enhanced with strategy-specific position tracking
        activeStrategies[strategyId] = abi.encode(calls, block.timestamp);
        emit PositionUpdated(strategyId, activeStrategies[strategyId]);
    }

    /// @dev Add strategy to active list if not present
    function _addActiveStrategy(bytes32 strategyId) internal {
        for (uint256 i = 0; i < activeStrategyList.length; i++) {
            if (activeStrategyList[i] == strategyId) return;
        }
        activeStrategyList.push(strategyId);
    }

    /// @dev Get list of tokens held by escrow
    // Storage for tracking tokens that have been deposited
    address[] internal trackedTokens;
    mapping(address => bool) internal isTracked;

    function _getHeldTokens() internal view returns (address[] memory tokens) {
        // Return the tracked tokens
        return trackedTokens;
    }

    // Add a function to track tokens (called when tokens are deposited)
    function _trackToken(address token) internal {
        if (!isTracked[token] && token != address(0)) {
            trackedTokens.push(token);
            isTracked[token] = true;
        }
    }

    // Public function to manually track tokens (for testing/setup)
    function trackToken(address token) external onlyOwner {
        _trackToken(token);
    }

    /* RECEIVE FUNCTION */

    /// @dev Allow receiving ETH
    receive() external payable {}
}