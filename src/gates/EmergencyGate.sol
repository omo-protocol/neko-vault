// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity 0.8.28;

import "../interfaces/IGate.sol";

/// @title EmergencyGate
/// @notice Emergency gate contract for VaultV2 that can block deposits, withdrawals, and transfers
/// @dev Implements all 4 gate interfaces for comprehensive control
/// @dev CRITICAL: Gates MUST NEVER REVERT - always return boolean values
/// @dev CRITICAL: Gates must not consume excessive gas
///
/// SECURITY FEATURES:
/// - Multi-mode operation: NORMAL (allow all), DEPOSIT_ONLY (block withdrawals), EMERGENCY (block all)
/// - Owner-based access control with ownership transfer
/// - Exception list for emergency operations (e.g., allow specific addresses during emergency)
/// - Event emission for transparency and monitoring
/// - Gas-optimized: minimal storage reads, no loops
///
/// USE CASES:
/// 1. Normal Operations: mode = NORMAL, all operations allowed
/// 2. Block New Deposits: mode = DEPOSIT_ONLY, deposits blocked, withdrawals allowed
/// 3. Block Withdrawals: mode = WITHDRAWAL_ONLY, deposits allowed, withdrawals blocked
/// 4. Complete Lockdown: mode = EMERGENCY, all operations blocked
/// 5. Selective Access: mode = EMERGENCY + exceptions list for authorized addresses
///
/// DEPLOYMENT STRATEGY:
/// - Deploy gate during vault initialization
/// - Set to NORMAL mode by default
/// - Pre-configure exceptions (owner, emergency multisig, etc.)
/// - In emergency: owner calls setEmergencyMode(true) immediately
/// - After vault timelock expires, execute setXXXGate(emergencyGateAddress)
contract EmergencyGate is IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate {

    /* TYPES */

    enum Mode {
        NORMAL,           // All operations allowed
        DEPOSIT_ONLY,     // Block new deposits, allow withdrawals
        WITHDRAWAL_ONLY,  // Allow deposits, block withdrawals
        EMERGENCY         // Block all operations
    }

    /* IMMUTABLES */

    /// @notice The vault this gate protects (for reference only)
    address public immutable vault;

    /* STORAGE */

    /// @notice Current gate mode
    Mode public mode;

    /// @notice Owner who can change settings
    address public owner;

    /// @notice Addresses that bypass restrictions even in EMERGENCY mode
    /// @dev Use for: vault address itself, emergency multisig, trusted contracts
    mapping(address => bool) public isException;

    /* EVENTS */

    event ModeChanged(Mode oldMode, Mode newMode, address indexed changedBy);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event ExceptionSet(address indexed account, bool isException);

    /* ERRORS */

    error Unauthorized();
    error InvalidAddress();

    /* CONSTRUCTOR */

    /// @notice Initialize the emergency gate
    /// @param _vault Address of the vault this gate protects
    /// @param _owner Initial owner (typically vault owner or emergency multisig)
    /// @param _initialMode Initial mode (typically NORMAL)
    constructor(address _vault, address _owner, Mode _initialMode) {
        if (_vault == address(0) || _owner == address(0)) revert InvalidAddress();

        vault = _vault;
        owner = _owner;
        mode = _initialMode;

        // Vault itself is always an exception to prevent self-blocking
        isException[_vault] = true;

        emit ModeChanged(Mode.NORMAL, _initialMode, msg.sender);
        emit ExceptionSet(_vault, true);
    }

    /* MODIFIERS */

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    /* OWNER FUNCTIONS */

    /// @notice Change the gate mode
    /// @param newMode The new mode to set
    /// @dev This is the PRIMARY emergency function - can be called immediately by owner
    function setMode(Mode newMode) external onlyOwner {
        Mode oldMode = mode;
        mode = newMode;
        emit ModeChanged(oldMode, newMode, msg.sender);
    }

    /// @notice Activate emergency mode (block all operations)
    /// @dev Convenience function for quick emergency response
    function activateEmergency() external onlyOwner {
        Mode oldMode = mode;
        mode = Mode.EMERGENCY;
        emit ModeChanged(oldMode, Mode.EMERGENCY, msg.sender);
    }

    /// @notice Deactivate emergency mode (return to normal)
    /// @dev Convenience function for quick recovery
    function deactivateEmergency() external onlyOwner {
        Mode oldMode = mode;
        mode = Mode.NORMAL;
        emit ModeChanged(oldMode, Mode.NORMAL, msg.sender);
    }

    /// @notice Set exception status for an address
    /// @param account Address to set exception for
    /// @param _isException True to allow access even in emergency, false to revoke
    /// @dev Use for: emergency multisig, trusted contracts, etc.
    function setException(address account, bool _isException) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isException[account] = _isException;
        emit ExceptionSet(account, _isException);
    }

    /// @notice Batch set exceptions for multiple addresses
    /// @param accounts Array of addresses to set exceptions for
    /// @param _isException True to allow access, false to revoke
    /// @dev Gas-efficient way to configure multiple exceptions
    function setExceptionBatch(address[] calldata accounts, bool _isException) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert InvalidAddress();
            isException[accounts[i]] = _isException;
            emit ExceptionSet(accounts[i], _isException);
        }
    }

    /// @notice Transfer ownership
    /// @param newOwner New owner address
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnerChanged(oldOwner, newOwner);
    }

    /* GATE INTERFACE IMPLEMENTATIONS */

    /// @notice Check if account can receive shares (for deposits, mints, transfers)
    /// @dev CRITICAL: NEVER REVERT - always return boolean
    /// @dev Called by: deposit(), mint(), transfer(), transferFrom(), fee accrual
    function canReceiveShares(address account) external view override returns (bool) {
        // Exceptions always allowed
        if (isException[account]) return true;

        // Check mode
        if (mode == Mode.NORMAL) return true;
        if (mode == Mode.DEPOSIT_ONLY) return false; 
        if (mode == Mode.WITHDRAWAL_ONLY) return true;
        if (mode == Mode.EMERGENCY) return false;  // Block everything

        return false;  // Default: block
    }

    /// @notice Check if account can send shares (for withdrawals, redeems, transfers)
    /// @dev CRITICAL: NEVER REVERT - always return boolean
    /// @dev Called by: withdraw(), redeem(), transfer(), transferFrom()
    function canSendShares(address account) external view override returns (bool) {
        // Exceptions always allowed
        if (isException[account]) return true;

        // Check mode
        if (mode == Mode.NORMAL) return true;
        if (mode == Mode.DEPOSIT_ONLY) return true;  // Allow withdrawals and transfers
        if (mode == Mode.WITHDRAWAL_ONLY) return true;  // Allow sending shares (for transfers, not withdrawals - vault handles withdrawal blocking differently)
        if (mode == Mode.EMERGENCY) return false;  // Block everything

        return false;  // Default: block
    }

    /// @notice Check if account can receive assets (for withdrawals)
    /// @dev CRITICAL: NEVER REVERT - always return boolean
    /// @dev Called by: withdraw(), redeem()
    /// @dev NOTE: Vault itself always bypasses this check in VaultV2.sol
    function canReceiveAssets(address account) external view override returns (bool) {
        // Exceptions always allowed
        if (isException[account]) return true;

        // Check mode
        if (mode == Mode.NORMAL) return true;
        if (mode == Mode.DEPOSIT_ONLY) return true;
        if (mode == Mode.WITHDRAWAL_ONLY) return false;
        if (mode == Mode.EMERGENCY) return false;  // Block everything

        return false;  // Default: block
    }

    /// @notice Check if account can send assets (for deposits)
    /// @dev CRITICAL: NEVER REVERT - always return boolean
    /// @dev Called by: deposit(), mint()
    function canSendAssets(address account) external view override returns (bool) {
        // Exceptions always allowed
        if (isException[account]) return true;

        // Check mode
        if (mode == Mode.NORMAL) return true;
        if (mode == Mode.DEPOSIT_ONLY) return false;  // Block deposits -> block sending assets
        if (mode == Mode.WITHDRAWAL_ONLY) return true;  // Allow deposits -> allow sending assets
        if (mode == Mode.EMERGENCY) return false;  // Block everything

        return false;  // Default: block
    }

    /* VIEW FUNCTIONS */

    /// @notice Get current mode as string for easier debugging
    function getModeString() external view returns (string memory) {
        if (mode == Mode.NORMAL) return "NORMAL";
        if (mode == Mode.DEPOSIT_ONLY) return "DEPOSIT_ONLY";
        if (mode == Mode.WITHDRAWAL_ONLY) return "WITHDRAWAL_ONLY";
        if (mode == Mode.EMERGENCY) return "EMERGENCY";
        return "UNKNOWN";
    }

    /// @notice Check what operations are allowed for an address
    /// @return canDeposit True if address can deposit
    /// @return canWithdraw True if address can withdraw
    /// @return canTransfer True if address can transfer shares
    function checkPermissions(address account) external view returns (
        bool canDeposit,
        bool canWithdraw,
        bool canTransfer
    ) {
        // Check if exception
        bool _isException = isException[account];

        if (_isException) {
            return (true, true, true);
        }

        if (mode == Mode.NORMAL) {
            return (true, true, true);
        } else if (mode == Mode.DEPOSIT_ONLY) {
            return (false, true, false);
        } else if (mode == Mode.WITHDRAWAL_ONLY) {
            return (true, false, true);
        } else if (mode == Mode.EMERGENCY) {
            return (false, false, false);
        }

        return (false, false, false);
    }
}
