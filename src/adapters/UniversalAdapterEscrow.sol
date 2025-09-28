// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IAdapter} from "../interfaces/IAdapter.sol";
import {IUniversalAdapterEscrow} from "./interfaces/IUniversalAdapterEscrow.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @title UniversalAdapterEscrow
/// @notice Unified adapter that merges UniversalEscrowAdapter and StrategyEscrow functionality
/// @dev Simplifies architecture by combining adapter and escrow logic into a single contract
contract UniversalAdapterEscrow is IUniversalAdapterEscrow {
    using SafeERC20Lib for IERC20;
    using EnumerableSet for EnumerableSet.Bytes32Set;

    /* CONSTANTS */

    uint256 private constant BASIS_POINTS = 10000;
    uint256 private constant DAY = 24 hours;

    // Pre-computed function selectors for gas optimization
    bytes4 private constant TRANSFER_SELECTOR = 0xa9059cbb; // transfer(address,uint256)
    bytes4 private constant APPROVE_SELECTOR = 0x095ea7b3;  // approve(address,uint256)
    bytes4 private constant TRANSFER_FROM_SELECTOR = 0x23b872dd; // transferFrom(address,address,uint256)

    /* IMMUTABLES */

    address public immutable parentVault;
    address public immutable asset;
    address public immutable valuer;
    bool public immutable useOffchainValuer;

    /* STORAGE */

    // Strategy management
    mapping(bytes32 => StrategyConfig) public strategies;
    mapping(bytes32 => uint256) public allocations;
    EnumerableSet.Bytes32Set private activeStrategies;

    // Whitelist management
    mapping(address => mapping(bytes4 => WhitelistConfig)) public functionWhitelist;

    // Pause state
    bool public paused;

    // Access control
    address public owner;

    /* MODIFIERS */

    modifier onlyVault() {
        if (msg.sender != parentVault) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotAuthorized();
        _;
    }

    modifier notPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier onlyStrategyAgent(bytes32 strategyId) {
        StrategyConfig memory strategy = strategies[strategyId];
        if (!strategy.active) revert StrategyNotActive();
        if (msg.sender != strategy.agent && msg.sender != owner) revert NotAuthorized();
        _;
    }

    /* CONSTRUCTOR */

    constructor(
        address _parentVault,
        address _valuer,
        bool _useOffchainValuer
    ) {
        parentVault = _parentVault;
        valuer = _valuer;
        useOffchainValuer = _useOffchainValuer;

        // Get asset from parent vault
        asset = IVaultV2(_parentVault).asset();

        // Set owner to vault owner
        owner = IVaultV2(_parentVault).owner();

        // Approve parent vault to pull assets back for deallocations
        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }

    /* EXTERNAL FUNCTIONS - ADAPTER INTERFACE */

    /// @inheritdoc IAdapter
    function allocate(
        bytes memory data,
        uint256 assets,
        bytes4,
        address
    ) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        // Decode allocation data
        (bytes32 strategyId, uint256 amount, bool executeNow, Call[] memory calls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));

        // Validate strategy exists and is active
        if (!strategies[strategyId].active) revert StrategyNotActive();

        // Validate amount
        if (amount == 0 || amount > assets) revert InvalidAmount();

        // Update allocation tracking
        allocations[strategyId] += amount;

        // Add to active strategies if not already present (O(1) operation)
        activeStrategies.add(strategyId);

        // Optionally execute strategy immediately after allocation
        if (executeNow && calls.length > 0) {
            _executeMulticall(strategyId, calls);
        }

        // Return results
        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = int256(amount);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    /// @inheritdoc IAdapter
    function deallocate(
        bytes memory data,
        uint256 assets,
        bytes4,
        address
    ) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        // Decode deallocation data - no longer includes amount
        (bytes32 strategyId, Call[] memory withdrawCalls) =
            abi.decode(data, (bytes32, Call[]));

        // Validate allocation exists
        uint256 currentAllocation = allocations[strategyId];
        if (currentAllocation == 0) revert InvalidStrategy();

        // Use assets parameter directly, capped by current allocation
        uint256 actualAmount = assets > currentAllocation ? currentAllocation : assets;

        // Execute withdrawal calls if provided (to withdraw from protocol)
        if (withdrawCalls.length > 0) {
            _executeMulticall(strategyId, withdrawCalls);
        }

        // Update allocation
        allocations[strategyId] -= actualAmount;

        // Remove from active strategies if fully deallocated
        if (allocations[strategyId] == 0) {
            _removeFromActiveStrategies(strategyId);
        }

        // Transfer assets back to vault
        // The vault will pull the assets using transferFrom

        // Return results
        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = -int256(actualAmount);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    /// @inheritdoc IAdapter
    function realAssets() external view override returns (uint256 assets) {
        // Call getTotalValue which aggregates all strategy values + idle assets
        (bool success, bytes memory data) = valuer.staticcall(
            abi.encodeWithSignature("getTotalValue(address)", address(this))
        );

        if (success && data.length >= 32) {
            uint256 totalValue = abi.decode(data, (uint256));
            if (totalValue > 0) {
                return totalValue;
            }
        }

        // Fallback: return at least the idle assets
        return IERC20(asset).balanceOf(address(this));
    }

    /* EXTERNAL FUNCTIONS - STRATEGY MANAGEMENT */

    /// @inheritdoc IUniversalAdapterEscrow
    function setStrategy(
        bytes32 strategyId,
        address agent,
        bytes calldata preConfiguredData,
        uint256 dailyLimit
    ) external onlyOwner {
        strategies[strategyId] = StrategyConfig({
            agent: agent,
            preConfiguredData: preConfiguredData,
            dailyLimit: dailyLimit,
            lastResetTime: block.timestamp,
            dailyUsed: 0,
            active: true
        });

        emit StrategySet(strategyId, agent, dailyLimit);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function removeStrategy(bytes32 strategyId) external onlyOwner {
        // Cannot remove strategy with active allocation
        if (allocations[strategyId] > 0) revert InvalidStrategy();

        delete strategies[strategyId];
        _removeFromActiveStrategies(strategyId);

        emit StrategyRemoved(strategyId);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function updateWhitelist(
        address target,
        bytes4 selector,
        bool allowed,
        uint256 limit
    ) external onlyOwner {
        functionWhitelist[target][selector] = WhitelistConfig({
            allowed: allowed,
            limit: limit
        });

        emit WhitelistUpdated(target, selector, allowed, limit);
    }

    /* EXTERNAL FUNCTIONS - STRATEGY EXECUTION */

    /// @inheritdoc IUniversalAdapterEscrow
    function executeStrategy(
        bytes32 strategyId,
        Call[] calldata calls
    ) external onlyStrategyAgent(strategyId) notPaused {
        _executeMulticall(strategyId, calls);
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function executePreConfigured(bytes32 strategyId) external onlyStrategyAgent(strategyId) notPaused {
        StrategyConfig memory strategy = strategies[strategyId];
        if (strategy.preConfiguredData.length == 0) revert InvalidData();

        // Decode pre-configured calls
        Call[] memory calls = abi.decode(strategy.preConfiguredData, (Call[]));

        _executeMulticall(strategyId, calls);
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /* EXTERNAL FUNCTIONS - ADMIN */

    /// @inheritdoc IUniversalAdapterEscrow
    function sweep(address token, address recipient) external onlyOwner {
        if (token == asset) revert CannotSweepAsset();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance > 0) {
            SafeERC20Lib.safeTransfer(token, recipient, balance);
            emit TokenSwept(token, recipient, balance);
        }
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function setPaused(bool _paused) external onlyOwner {
        paused = _paused;
        emit PauseStatusChanged(_paused);
    }

    /// @notice Transfer ownership
    /// @param newOwner The new owner address
    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid owner");
        owner = newOwner;
    }

    /* VIEW FUNCTIONS */

    /// @inheritdoc IUniversalAdapterEscrow
    function getStrategy(bytes32 strategyId) external view returns (StrategyConfig memory) {
        return strategies[strategyId];
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function getWhitelist(address target, bytes4 selector) external view returns (WhitelistConfig memory) {
        return functionWhitelist[target][selector];
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function getAllocation(bytes32 strategyId) external view returns (uint256) {
        return allocations[strategyId];
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function getActiveStrategies() external view returns (bytes32[] memory) {
        return activeStrategies.values();
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Execute multiple calls with validation
    /// @param strategyId The strategy executing the calls
    /// @param calls Array of calls to execute
    function _executeMulticall(bytes32 strategyId, Call[] memory calls) internal {
        StrategyConfig storage strategy = strategies[strategyId];

        // Reset daily limit if needed
        if (block.timestamp >= strategy.lastResetTime + DAY) {
            strategy.lastResetTime = block.timestamp;
            strategy.dailyUsed = 0;
        }

        for (uint256 i = 0; i < calls.length; i++) {
            Call memory call = calls[i];

            // Extract function selector
            bytes4 selector = bytes4(call.data);

            // Check whitelist
            WhitelistConfig memory config = functionWhitelist[call.target][selector];
            if (!config.allowed) {
                // Check if all functions are whitelisted for this target
                config = functionWhitelist[call.target][bytes4(0)];
                if (!config.allowed) {
                    revert FunctionNotWhitelisted();
                }
            }

            // Check call limit for value transfers
            if (call.value > 0 || _isTokenTransfer(selector, call.data)) {
                uint256 transferAmount = _extractTransferAmount(call.data, call.value);

                // Check per-call limit
                if (config.limit > 0 && transferAmount > config.limit) {
                    revert CallLimitExceeded();
                }

                // Check daily limit
                if (strategy.dailyLimit > 0) {
                    if (strategy.dailyUsed + transferAmount > strategy.dailyLimit) {
                        revert DailyLimitExceeded();
                    }
                    strategy.dailyUsed += transferAmount;
                }
            }

            // Execute the call
            (bool success, bytes memory returnData) = call.target.call{value: call.value}(call.data);
            if (!success) {
                revert CallFailed(i, returnData);
            }
        }
    }

    /// @notice Check if a function selector is a token transfer
    /// @param selector The function selector
    /// @param data The calldata
    /// @return Whether this is a token transfer
    function _isTokenTransfer(bytes4 selector, bytes memory data) internal pure returns (bool) {
        return (
            selector == TRANSFER_SELECTOR ||
            selector == APPROVE_SELECTOR ||
            selector == TRANSFER_FROM_SELECTOR
        ) && data.length >= 68; // Minimum length for these functions
    }

    /// @notice Extract transfer amount from calldata
    /// @param data The calldata
    /// @param value ETH value being sent
    /// @return The transfer amount
    function _extractTransferAmount(bytes memory data, uint256 value) internal pure returns (uint256) {
        if (value > 0) return value;

        if (data.length < 68) return 0;

        bytes4 selector = bytes4(data);

        // For transfer and approve, amount is the second parameter
        if (selector == TRANSFER_SELECTOR || selector == APPROVE_SELECTOR) {
            uint256 amount;
            assembly {
                amount := mload(add(data, 68)) // Skip 4 bytes selector + 32 bytes address
            }
            return amount;
        }

        // For transferFrom, amount is the third parameter
        if (selector == TRANSFER_FROM_SELECTOR) {
            if (data.length < 100) return 0;
            uint256 amount;
            assembly {
                amount := mload(add(data, 100)) // Skip 4 bytes selector + 32 bytes from + 32 bytes to
            }
            return amount;
        }

        return 0;
    }

    /// @notice Remove a strategy from the active list
    /// @param strategyId The strategy to remove
    function _removeFromActiveStrategies(bytes32 strategyId) internal {
        // O(1) operation with EnumerableSet
        activeStrategies.remove(strategyId);
    }

    /// @notice Receive ETH
    receive() external payable {}
}