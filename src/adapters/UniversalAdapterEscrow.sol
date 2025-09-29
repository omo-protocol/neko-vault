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

    // Vault function selectors for call validation
    bytes4 private constant DEALLOCATE_SELECTOR = 0x4b219d16; // deallocate(address,bytes,uint256)
    bytes4 private constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8; // forceDeallocate(address,bytes,uint256,address)

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

    // Total allocations tracking for gas optimization
    uint256 public totalAllocations;

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

    modifier onlyStrategyAgentOrOwner(bytes32 strategyId) {
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
        (bytes32 strategyId, , bool executeNow, Call[] memory calls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));

        // Validate strategy exists and is active
        if (!strategies[strategyId].active) revert StrategyNotActive();

        // L-13 FIX: Use full assets amount to prevent locked tokens
        // Unlike old architecture where only partial amount was used, we utilize 100% of transferred assets
        // This prevents the issue where assets > amount would leave tokens stuck in adapter
        if (assets == 0) revert InvalidAmount();

        // FEE-ON-TRANSFER FIX: Calculate actual received amount to handle weird ERC20s
        // The vault transfers `assets` amount, but due to fees, adapter might receive less
        // We must track the actual received amount, not the intended transfer amount
        uint256 currentBalance = IERC20(asset).balanceOf(address(this));

        // GAS OPTIMIZATION: Use totalAllocations state variable instead of looping
        // This is O(1) instead of O(n) where n is the number of active strategies
        // Actual received amount = current balance - what was already allocated
        // This accounts for any fees deducted during transfer
        uint256 actualReceived = currentBalance - totalAllocations;

        // Ensure we don't track more than what was intended to be transferred
        if (actualReceived > assets) {
            actualReceived = assets;
        }

        // Update allocation tracking with actual received amount (not intended amount)
        allocations[strategyId] += actualReceived;
        totalAllocations += actualReceived;

        // Add to active strategies if not already present (O(1) operation)
        activeStrategies.add(strategyId);

        // Optionally execute strategy immediately after allocation
        if (executeNow && calls.length > 0) {
            _executeMulticall(strategyId, calls);
        }

        // Return results using actual received amount
        ids = new bytes32[](1);
        ids[0] = strategyId;
        change = int256(actualReceived);

        emit AllocationUpdated(strategyId, allocations[strategyId], change);
    }

    /// @inheritdoc IAdapter
    function deallocate(
        bytes memory data,
        uint256 assets,
        bytes4 caller,
        address
    ) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        // Decode deallocation data - SAME format as allocate for vault compatibility
        (bytes32 strategyId, , , Call[] memory withdrawCalls) =
            abi.decode(data, (bytes32, uint256, bool, Call[]));

        // IMPORTANT: No allocation validation here - users should be able to withdraw
        // idle assets, profits, or do emergency withdrawals even from strategies with 0 allocation

        uint256 adapterBalance = IERC20(asset).balanceOf(address(this));
        uint256 actualAmount;

        // SECURITY FIX: For forceDeallocate, ignore calls but use same data format
        if (caller == FORCE_DEALLOCATE_SELECTOR) {
            // Only allow if sufficient balance is available in adapter
            // Vault has approval to pull tokens directly via transferFrom
            if (assets > adapterBalance) {
                revert InvalidAmount();
            }
            actualAmount = assets;
            // No external calls executed - withdrawCalls are ignored for security
        } else {
            // Normal deallocate: Smart Balance-First Deallocate
            // Check adapter balance first to avoid unnecessary protocol withdrawals
            // This ensures profits and idle assets are accessible
            if (assets <= adapterBalance) {
                // Sufficient balance in adapter - no need for external withdrawal calls
                // This optimizes gas and allows access to idle assets and accumulated profits
                actualAmount = assets;
                // Skip withdrawal calls since we have enough balance
            } else {
                // Insufficient balance - need to withdraw from protocol
                // Get current strategy value including yield
                uint256 currentValue = _getStrategyValue(strategyId);

                // Execute withdrawal calls to pull funds from external protocol
                if (withdrawCalls.length > 0) {
                    _executeMulticall(strategyId, withdrawCalls);
                }

                // After withdrawal, check new balance and cap by what's actually available
                uint256 newBalance = IERC20(asset).balanceOf(address(this));
                actualAmount = assets > newBalance ? newBalance : assets;

                // Ensure we don't report more than what strategy had
                // This maintains consistency with strategy tracking
                if (actualAmount > currentValue) {
                    actualAmount = currentValue;
                }
            }
        }

        // Update allocation - handle case where actualAmount exceeds tracked allocation
        uint256 allocationDecrease = actualAmount > allocations[strategyId]
            ? allocations[strategyId]
            : actualAmount;
        allocations[strategyId] -= allocationDecrease;
        totalAllocations -= allocationDecrease;

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
        // L-13 FIX: Comprehensive asset utilization tracking
        // This function ensures all assets (both allocated to strategies and idle) are accounted for
        // No assets are lost or left unused in the adapter

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

        // Fallback: return at least the idle assets (ensures no assets are hidden)
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
    ) external onlyStrategyAgentOrOwner(strategyId) notPaused {
        _executeMulticall(strategyId, calls);
        emit StrategyExecuted(strategyId, msg.sender);
    }

    /// @inheritdoc IUniversalAdapterEscrow
    function executePreConfigured(bytes32 strategyId) external onlyStrategyAgentOrOwner(strategyId) notPaused {
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

    /// @notice Get idle assets that are not allocated to any strategy
    /// @dev L-13 FIX: Provides visibility into unused assets to ensure full utilization
    /// @return idleAssets Amount of assets sitting idle in the adapter
    function getIdleAssets() external view returns (uint256 idleAssets) {
        return IERC20(asset).balanceOf(address(this));
    }

    /* INTERNAL FUNCTIONS */

    /// @notice Execute multiple calls with validation
    /// @param calls Array of calls to execute
    function _executeMulticall(bytes32 /* strategyId */, Call[] memory calls) internal {
        // L-16 Fix: Removed daily limit tracking logic per recommendation
        // Daily limits were problematic and could prevent emergency operations

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

            // L-16 Fix: All limit checking removed per security recommendation
            // Limits were problematic due to denomination mixing and could prevent
            // emergency operations. Whitelisting provides sufficient access control.

            // Execute the call
            (bool success, bytes memory returnData) = call.target.call{value: call.value}(call.data);
            if (!success) {
                revert CallFailed(i, returnData);
            }
        }
    }


    /// @notice Remove a strategy from the active list
    /// @param strategyId The strategy to remove
    function _removeFromActiveStrategies(bytes32 strategyId) internal {
        // O(1) operation with EnumerableSet
        activeStrategies.remove(strategyId);
    }

    /// @notice Get strategy value including yield from valuer
    /// @param strategyId The strategy identifier
    /// @return value The strategy value including any yield
    function _getStrategyValue(bytes32 strategyId) internal view returns (uint256 value) {
        // Try to get value from valuer, fallback to allocation if valuer call fails
        (bool success, bytes memory data) = valuer.staticcall(
            abi.encodeWithSignature("getValue(bytes32)", strategyId)
        );

        if (success && data.length >= 32) {
            value = abi.decode(data, (uint256));
            // If valuer returns 0, use allocation as fallback
            if (value == 0) {
                value = allocations[strategyId];
            }
        } else {
            // Fallback to allocation if valuer call fails
            value = allocations[strategyId];
        }
    }


    /// @notice Receive ETH
    receive() external payable {}
}