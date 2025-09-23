// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {IVaultV2} from "../interfaces/IVaultV2.sol";
import {IERC20} from "../interfaces/IERC20.sol";
import {IUniversalEscrowAdapter} from "./interfaces/IUniversalEscrowAdapter.sol";
import {IStrategyEscrow} from "./interfaces/IStrategyEscrow.sol";
import {IUniversalValuer} from "./interfaces/IUniversalValuer.sol";
import {IUniversalValuerOffchain} from "./interfaces/IUniversalValuerOffchain.sol";
import {SafeERC20Lib} from "../libraries/SafeERC20Lib.sol";

/// @title UniversalEscrowAdapter
/// @notice Adapter that bridges Morpho Vault V2 to multiple strategies via StrategyEscrow
/// @dev Implements IAdapter interface for compatibility with Morpho Vault V2
contract UniversalEscrowAdapter is IUniversalEscrowAdapter {
    using SafeERC20Lib for IERC20;

    /* CONSTANTS */

    uint256 private constant EMERGENCY_PENALTY_BPS = 50; // 0.5% penalty on emergency withdrawal
    uint256 private constant EMERGENCY_TIMELOCK = 24 hours; // 24-hour timelock for emergency recovery

    /* IMMUTABLES */

    address public immutable parentVault;
    address public immutable escrow;
    address public immutable valuer;
    bool public immutable useOffchainValuer;
    address public immutable asset;

    /* STORAGE */

    mapping(bytes32 => uint256) public allocations; // strategyId => amount allocated
    mapping(bytes32 => bool) public strategyPaused; // strategyId => paused status
    bytes32[] public activeStrategies;
    bool public emergencyMode;

    // Emergency recovery timelock
    uint256 public emergencyRecoveryTimestamp;
    bool public emergencyRecoveryPending;

    /* MODIFIERS */

    modifier onlyVault() {
        if (msg.sender != parentVault) revert NotAuthorized();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != IVaultV2(parentVault).owner()) revert NotAuthorized();
        _;
    }

    modifier notEmergency() {
        if (emergencyMode) revert EmergencyOnly();
        _;
    }

    /* CONSTRUCTOR */

    constructor(
        address _parentVault,
        address _escrow,
        address _valuer,
        bool _useOffchainValuer
    ) {
        parentVault = _parentVault;
        escrow = _escrow;
        valuer = _valuer;
        useOffchainValuer = _useOffchainValuer;
        asset = IVaultV2(_parentVault).asset();

        // Approve parent vault to pull assets back
        SafeERC20Lib.safeApprove(asset, _parentVault, type(uint256).max);
    }

    /* EXTERNAL FUNCTIONS */

    /// @inheritdoc IUniversalEscrowAdapter
    function allocate(
        bytes memory data,
        uint256 assets,
        bytes4,
        address
    ) external override onlyVault notEmergency returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        (bytes32 strategyId, uint256 amount, bytes memory params) = abi.decode(
            data,
            (bytes32, uint256, bytes)
        );

        if (strategyPaused[strategyId]) revert StrategyPaused();

        // Transfer assets to escrow
        if (amount > 0 && amount <= assets) {
            SafeERC20Lib.safeTransfer(asset, escrow, amount);
            allocations[strategyId] += amount;

            // Notify escrow of allocation
            IStrategyEscrow(escrow).notifyAllocation(strategyId, amount);

            // Track active strategy
            _addActiveStrategy(strategyId);

            emit StrategyAllocated(strategyId, amount);
        }

        // Return allocation info
        ids = new bytes32[](1);
        ids[0] = strategyId;
        return (ids, int256(amount));
    }

    /// @inheritdoc IUniversalEscrowAdapter
    function deallocate(
        bytes memory data,
        uint256 assets,
        bytes4,
        address
    ) external override onlyVault returns (bytes32[] memory ids, int256 change) {
        if (data.length == 0) revert InvalidData();

        (bytes32 strategyId, uint256 amount, bytes memory params) = abi.decode(
            data,
            (bytes32, uint256, bytes)
        );

        uint256 actualAmount = amount > assets ? assets : amount;
        uint256 currentAllocation = allocations[strategyId];
        actualAmount = actualAmount > currentAllocation ? currentAllocation : actualAmount;

        if (actualAmount > 0) {
            // Execute strategy-specific deallocation in escrow
            IStrategyEscrow.Call[] memory calls = _buildDeallocationCalls(
                strategyId,
                actualAmount,
                params
            );

            if (calls.length > 0) {
                IStrategyEscrow(escrow).executeMulticall(strategyId, calls);
            }

            allocations[strategyId] -= actualAmount;

            // Remove from active strategies if fully deallocated
            if (allocations[strategyId] == 0) {
                _removeActiveStrategy(strategyId);
            }

            emit StrategyDeallocated(strategyId, actualAmount);
        }

        ids = new bytes32[](1);
        ids[0] = strategyId;
        return (ids, -int256(actualAmount));
    }

    /// @inheritdoc IUniversalEscrowAdapter
    function realAssets() external view override returns (uint256) {
        if (emergencyMode) {
            // In emergency mode, just return escrow balance
            return IERC20(asset).balanceOf(escrow);
        }

        // Get total valuation from appropriate valuer
        if (useOffchainValuer) {
            // Use off-chain valuer with signed reports
            return IUniversalValuerOffchain(valuer).getTotalValue(escrow);
        } else {
            // Use on-chain valuer (legacy)
            return IUniversalValuer(valuer).getTotalValue(escrow);
        }
    }

    /// @notice Initiate emergency recovery (step 1 of 2)
    /// @dev Starts 24-hour timelock before emergency recovery can be executed
    function initiateEmergencyRecovery() external onlyOwner {
        if (emergencyRecoveryPending) revert EmergencyRecoveryAlreadyPending();

        emergencyRecoveryTimestamp = block.timestamp + EMERGENCY_TIMELOCK;
        emergencyRecoveryPending = true;

        emit EmergencyRecoveryInitiated(emergencyRecoveryTimestamp);
    }

    /// @notice Cancel pending emergency recovery
    function cancelEmergencyRecovery() external onlyOwner {
        if (!emergencyRecoveryPending) revert NoEmergencyRecoveryPending();

        emergencyRecoveryPending = false;
        emergencyRecoveryTimestamp = 0;

        emit EmergencyRecoveryCancelled();
    }

    /// @inheritdoc IUniversalEscrowAdapter
    function forceRecovery() external override onlyOwner {
        if (!emergencyRecoveryPending) revert EmergencyRecoveryNotInitiated();
        if (block.timestamp < emergencyRecoveryTimestamp) revert EmergencyRecoveryTimelockNotExpired();

        // Clear timelock state
        emergencyRecoveryPending = false;
        emergencyRecoveryTimestamp = 0;

        emergencyMode = true;

        // Emergency withdraw all from escrow - now with validated recipient
        IStrategyEscrow(escrow).emergencyWithdrawAll(address(this));

        uint256 recoveredAmount = IERC20(asset).balanceOf(address(this));

        // Apply penalty with overflow protection
        uint256 penalty;
        uint256 netRecovered;

        unchecked {
            // Safe math: EMERGENCY_PENALTY_BPS is constant 50, max value 10000
            penalty = (recoveredAmount * EMERGENCY_PENALTY_BPS) / 10000;

            // Check for underflow
            if (recoveredAmount >= penalty) {
                netRecovered = recoveredAmount - penalty;
            } else {
                // Should never happen with 0.5% penalty, but safety first
                penalty = recoveredAmount;
                netRecovered = 0;
            }
        }

        if (penalty > 0) {
            // Send penalty to treasury
            address treasury = IVaultV2(parentVault).owner();
            SafeERC20Lib.safeTransfer(asset, treasury, penalty);
        }

        // Transfer remaining funds back to vault
        if (netRecovered > 0) {
            SafeERC20Lib.safeTransfer(asset, parentVault, netRecovered);
        }

        emit EmergencyWithdrawal(address(this), netRecovered);
    }

    /// @inheritdoc IUniversalEscrowAdapter
    function getStrategyAllocation(bytes32 strategyId) external view override returns (uint256) {
        return allocations[strategyId];
    }

    /* ADMIN FUNCTIONS */

    /// @notice Toggle pause status for a strategy
    function toggleStrategyPause(bytes32 strategyId, bool paused) external onlyOwner {
        strategyPaused[strategyId] = paused;
        emit StrategyPausedToggled(strategyId, paused);
    }

    /// @notice Reset emergency mode
    function resetEmergencyMode() external onlyOwner {
        emergencyMode = false;
    }

    /* INTERNAL FUNCTIONS */

    /// @dev Add strategy to active list if not already present
    function _addActiveStrategy(bytes32 strategyId) internal {
        for (uint256 i = 0; i < activeStrategies.length; i++) {
            if (activeStrategies[i] == strategyId) return;
        }
        activeStrategies.push(strategyId);
    }

    /// @dev Remove strategy from active list
    function _removeActiveStrategy(bytes32 strategyId) internal {
        uint256 length = activeStrategies.length;
        for (uint256 i = 0; i < length; i++) {
            if (activeStrategies[i] == strategyId) {
                activeStrategies[i] = activeStrategies[length - 1];
                activeStrategies.pop();
                break;
            }
        }
    }

    /// @dev Build deallocation calls based on strategy type
    function _buildDeallocationCalls(
        bytes32 strategyId,
        uint256 amount,
        bytes memory params
    ) internal view returns (IStrategyEscrow.Call[] memory calls) {
        // For simple deallocations, just transfer tokens back to adapter
        calls = new IStrategyEscrow.Call[](1);
        calls[0] = IStrategyEscrow.Call({
            target: asset,
            value: 0,
            data: abi.encodeWithSelector(IERC20.transfer.selector, address(this), amount)
        });

        // In production, this would contain strategy-specific logic:
        // if (strategyId == keccak256("VNEKO_VF")) {
        //     // vNeko volatility farming deallocation
        //     calls = new IStrategyEscrow.Call[](2);
        //     // Remove liquidity, withdraw collateral, etc.
        // } else if (strategyId == keccak256("PT_KHYPE_LOOP")) {
        //     // PT-kHYPE loop deallocation
        //     calls = new IStrategyEscrow.Call[](3);
        //     // Unwind loop, swap PT to underlying, etc.
        // }

        return calls;
    }

    /* VIEW FUNCTIONS */

    /// @notice Get all active strategy IDs
    function getActiveStrategies() external view returns (bytes32[] memory) {
        return activeStrategies;
    }

    /// @notice Check if strategy is active
    function isStrategyActive(bytes32 strategyId) external view returns (bool) {
        return allocations[strategyId] > 0;
    }
}