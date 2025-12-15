// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "../interfaces/IGate.sol";

/// @title EmergencyGateWithRoles
/// @notice Enhanced emergency gate with role-based access control for automated monitoring
/// @dev Supports multiple roles: OWNER, GUARDIAN, MONITOR, EMERGENCY_RESPONDER
///
/// ROLE HIERARCHY:
/// - OWNER: Full control (add/remove roles, change mode, manage exceptions)
/// - GUARDIAN: Can activate emergency but not change configuration (multisig recommended)
/// - MONITOR: Can ONLY activate emergency (for automated monitoring systems)
/// - EMERGENCY_RESPONDER: Can add exceptions during emergency (for recovery operations)
///
/// USE CASES:
/// 1. Owner = Protocol team multisig (full control)
/// 2. Guardian = Additional multisig for redundancy
/// 3. Monitor = Automated security monitoring contract (detect & respond to incidents)
/// 4. Emergency Responder = Hot wallet for adding exceptions during active incident
///
/// SECURITY MODEL:
/// - Multiple monitors can be added (different monitoring systems)
/// - Monitors can ONLY activate emergency (cannot deactivate or change config)
/// - Guardians can activate AND deactivate emergency
/// - Only owner can add/remove roles and manage exceptions normally
/// - Emergency responders can add exceptions ONLY during emergency mode
/// - Rate limiting prevents abuse from compromised monitors
contract EmergencyGateWithRoles is IReceiveSharesGate, ISendSharesGate, IReceiveAssetsGate, ISendAssetsGate {

    /* TYPES */

    enum Mode {
        NORMAL,           // All operations allowed
        DEPOSIT_ONLY,     // Block new deposits, allow withdrawals
        WITHDRAWAL_ONLY,  // Allow deposits, block withdrawals
        EMERGENCY         // Block all operations
    }

    /* IMMUTABLES */

    /// @notice The vault this gate protects
    address public immutable vault;

    /* STORAGE */

    /// @notice Current gate mode
    Mode public mode;

    /// @notice Primary owner with full control
    address public owner;

    /// @notice Addresses that can activate/deactivate emergency
    mapping(address => bool) public isGuardian;

    /// @notice Addresses that can ONLY activate emergency (monitoring systems)
    mapping(address => bool) public isMonitor;

    /// @notice Addresses that can add exceptions during emergency
    mapping(address => bool) public isEmergencyResponder;

    /// @notice Addresses that bypass restrictions
    mapping(address => bool) public isException;

    /// @notice Rate limiting for monitors to prevent spam
    mapping(address => uint256) public lastEmergencyActivation;
    uint256 public constant MONITOR_COOLDOWN = 5 minutes;

    /// @notice Emergency activation history
    struct EmergencyEvent {
        address activator;
        uint256 timestamp;
        Mode previousMode;
        string reason;
    }
    EmergencyEvent[] public emergencyHistory;

    /// @notice Flag to track if we're in an automated emergency response
    bool public isAutomatedEmergency;

    /* EVENTS */

    event ModeChanged(Mode oldMode, Mode newMode, address indexed changedBy, string reason);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event ExceptionSet(address indexed account, bool isException, address indexed setBy);
    event GuardianSet(address indexed account, bool isGuardian);
    event MonitorSet(address indexed account, bool isMonitor);
    event EmergencyResponderSet(address indexed account, bool isResponder);
    event AutomatedEmergencyActivated(address indexed monitor, string reason);
    event EmergencyDeactivatedByGuardian(address indexed guardian);

    /* ERRORS */

    error Unauthorized();
    error InvalidAddress();
    error MonitorCooldown();
    error NotInEmergency();
    error CannotDeactivate();

    /* CONSTRUCTOR */

    constructor(address _vault, address _owner, Mode _initialMode) {
        if (_vault == address(0) || _owner == address(0)) revert InvalidAddress();

        vault = _vault;
        owner = _owner;
        mode = _initialMode;

        // Vault itself is always an exception
        isException[_vault] = true;

        emit ModeChanged(Mode.NORMAL, _initialMode, msg.sender, "Initialization");
        emit ExceptionSet(_vault, true, msg.sender);
    }

    /* MODIFIERS */

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyGuardianOrOwner() {
        if (msg.sender != owner && !isGuardian[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyMonitorOrGuardianOrOwner() {
        if (msg.sender != owner && !isGuardian[msg.sender] && !isMonitor[msg.sender]) {
            revert Unauthorized();
        }
        _;
    }

    modifier onlyEmergencyResponderOrOwner() {
        if (msg.sender != owner && !isEmergencyResponder[msg.sender]) revert Unauthorized();
        _;
    }

    modifier onlyDuringEmergency() {
        if (mode != Mode.EMERGENCY) revert NotInEmergency();
        _;
    }

    /* OWNER FUNCTIONS */

    /// @notice Set mode with reason (owner only)
    function setMode(Mode newMode, string calldata reason) external onlyOwner {
        Mode oldMode = mode;
        mode = newMode;
        isAutomatedEmergency = false;  // Manual mode change clears automated flag
        emit ModeChanged(oldMode, newMode, msg.sender, reason);
    }

    /// @notice Add or remove guardian
    function setGuardian(address account, bool _isGuardian) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isGuardian[account] = _isGuardian;
        emit GuardianSet(account, _isGuardian);
    }

    /// @notice Add or remove monitor (automated systems)
    function setMonitor(address account, bool _isMonitor) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isMonitor[account] = _isMonitor;
        emit MonitorSet(account, _isMonitor);
    }

    /// @notice Add or remove emergency responder
    function setEmergencyResponder(address account, bool _isResponder) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isEmergencyResponder[account] = _isResponder;
        emit EmergencyResponderSet(account, _isResponder);
    }

    /// @notice Set exception (owner only during normal operations)
    function setException(address account, bool _isException) external onlyOwner {
        if (account == address(0)) revert InvalidAddress();
        isException[account] = _isException;
        emit ExceptionSet(account, _isException, msg.sender);
    }

    /// @notice Batch set exceptions (owner only)
    function setExceptionBatch(address[] calldata accounts, bool _isException) external onlyOwner {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert InvalidAddress();
            isException[accounts[i]] = _isException;
            emit ExceptionSet(accounts[i], _isException, msg.sender);
        }
    }

    /// @notice Transfer ownership
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        address oldOwner = owner;
        owner = newOwner;
        emit OwnerChanged(oldOwner, newOwner);
    }

    /* GUARDIAN FUNCTIONS */

    /// @notice Activate emergency mode (guardian or owner)
    function activateEmergency(string calldata reason) external onlyGuardianOrOwner {
        Mode oldMode = mode;
        mode = Mode.EMERGENCY;
        isAutomatedEmergency = false;  // Manually activated by guardian

        // Record in history
        emergencyHistory.push(EmergencyEvent({
            activator: msg.sender,
            timestamp: block.timestamp,
            previousMode: oldMode,
            reason: reason
        }));

        emit ModeChanged(oldMode, Mode.EMERGENCY, msg.sender, reason);
    }

    /// @notice Deactivate emergency mode (guardian or owner only)
    function deactivateEmergency(string calldata reason) external onlyGuardianOrOwner {
        Mode oldMode = mode;
        mode = Mode.NORMAL;
        isAutomatedEmergency = false;

        emit ModeChanged(oldMode, Mode.NORMAL, msg.sender, reason);
        emit EmergencyDeactivatedByGuardian(msg.sender);
    }

    /* MONITOR FUNCTIONS (Automated Systems) */

    /// @notice Activate emergency mode (monitor only) with rate limiting
    /// @dev Monitors can ONLY activate emergency, not deactivate
    /// @dev Rate limited to prevent spam from compromised monitors
    function activateEmergencyAutomated(string calldata reason) external {
        // Check authorization
        if (!isMonitor[msg.sender]) revert Unauthorized();

        // Rate limiting: prevent same monitor from triggering too frequently
        // Skip cooldown check if this is the first activation (lastEmergencyActivation == 0)
        if (lastEmergencyActivation[msg.sender] != 0 &&
            block.timestamp <= lastEmergencyActivation[msg.sender] + MONITOR_COOLDOWN) {
            revert MonitorCooldown();
        }

        // Update last activation time
        lastEmergencyActivation[msg.sender] = block.timestamp;

        // Activate emergency
        Mode oldMode = mode;
        mode = Mode.EMERGENCY;
        isAutomatedEmergency = true;  // Mark as automated activation

        // Record in history
        emergencyHistory.push(EmergencyEvent({
            activator: msg.sender,
            timestamp: block.timestamp,
            previousMode: oldMode,
            reason: reason
        }));

        emit AutomatedEmergencyActivated(msg.sender, reason);
        emit ModeChanged(oldMode, Mode.EMERGENCY, msg.sender, reason);
    }

    /* EMERGENCY RESPONDER FUNCTIONS */

    /// @notice Add exception during emergency (emergency responder only)
    /// @dev Allows quick whitelisting of recovery addresses during active incident
    function addExceptionDuringEmergency(address account, string calldata reason)
        external
        onlyEmergencyResponderOrOwner
        onlyDuringEmergency
    {
        if (account == address(0)) revert InvalidAddress();
        isException[account] = true;
        emit ExceptionSet(account, true, msg.sender);
    }

    /// @notice Batch add exceptions during emergency
    function addExceptionBatchDuringEmergency(address[] calldata accounts, string calldata reason)
        external
        onlyEmergencyResponderOrOwner
        onlyDuringEmergency
    {
        for (uint256 i = 0; i < accounts.length; i++) {
            if (accounts[i] == address(0)) revert InvalidAddress();
            isException[accounts[i]] = true;
            emit ExceptionSet(accounts[i], true, msg.sender);
        }
    }

    /* GATE INTERFACE IMPLEMENTATIONS */

    function canReceiveShares(address account) external view override returns (bool) {
        if (isException[account]) return true;
        if (mode == Mode.NORMAL) return true;
        if (mode == Mode.DEPOSIT_ONLY) return false;
        if (mode == Mode.WITHDRAWAL_ONLY) return true;
        if (mode == Mode.EMERGENCY) return false;
        return false;
    }

    function canSendShares(address account) external view override returns (bool) {
        if (isException[account]) return true;
        if (mode == Mode.NORMAL) return true;
        if (mode == Mode.DEPOSIT_ONLY) return true;
        if (mode == Mode.WITHDRAWAL_ONLY) return true;
        if (mode == Mode.EMERGENCY) return false;
        return false;
    }

    function canReceiveAssets(address account) external view override returns (bool) {
        if (isException[account]) return true;
        if (mode == Mode.NORMAL) return true;
        if (mode == Mode.DEPOSIT_ONLY) return true;
        if (mode == Mode.WITHDRAWAL_ONLY) return false;
        if (mode == Mode.EMERGENCY) return false;
        return false;
    }

    function canSendAssets(address account) external view override returns (bool) {
        if (isException[account]) return true;
        if (mode == Mode.NORMAL) return true;
        if (mode == Mode.DEPOSIT_ONLY) return false;
        if (mode == Mode.WITHDRAWAL_ONLY) return true;
        if (mode == Mode.EMERGENCY) return false;
        return false;
    }

    /* VIEW FUNCTIONS */

    function getModeString() external view returns (string memory) {
        if (mode == Mode.NORMAL) return "NORMAL";
        if (mode == Mode.DEPOSIT_ONLY) return "DEPOSIT_ONLY";
        if (mode == Mode.WITHDRAWAL_ONLY) return "WITHDRAWAL_ONLY";
        if (mode == Mode.EMERGENCY) return "EMERGENCY";
        return "UNKNOWN";
    }

    function checkPermissions(address account) external view returns (
        bool canDeposit,
        bool canWithdraw,
        bool canTransfer
    ) {
        bool _isException = isException[account];
        if (_isException) return (true, true, true);

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

    /// @notice Get emergency history count
    function getEmergencyHistoryLength() external view returns (uint256) {
        return emergencyHistory.length;
    }

    /// @notice Get specific emergency event
    function getEmergencyEvent(uint256 index) external view returns (
        address activator,
        uint256 timestamp,
        Mode previousMode,
        string memory reason
    ) {
        EmergencyEvent memory evt = emergencyHistory[index];
        return (evt.activator, evt.timestamp, evt.previousMode, evt.reason);
    }

    /// @notice Get all roles for an address
    function getRoles(address account) external view returns (
        bool _isOwner,
        bool _isGuardian,
        bool _isMonitor,
        bool _isEmergencyResponder,
        bool _isException
    ) {
        return (
            account == owner,
            isGuardian[account],
            isMonitor[account],
            isEmergencyResponder[account],
            isException[account]
        );
    }
}
