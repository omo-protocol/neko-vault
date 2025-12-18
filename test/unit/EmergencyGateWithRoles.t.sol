// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/gates/EmergencyGateWithRoles.sol";

/// @title EmergencyGateWithRolesTest
/// @notice Comprehensive test suite for EmergencyGateWithRoles contract
/// @dev Tests cover: roles, modes, emergency activation, rate limiting, exceptions, history tracking
contract EmergencyGateWithRolesTest is Test {
    EmergencyGateWithRoles public gate;

    address public constant VAULT = address(0x1);
    address public owner = address(0x2);
    address public guardian1 = address(0x3);
    address public guardian2 = address(0x4);
    address public monitor1 = address(0x5);
    address public monitor2 = address(0x6);
    address public responder1 = address(0x7);
    address public user1 = address(0x8);
    address public user2 = address(0x9);

    /* EVENTS */
    event ModeChanged(EmergencyGateWithRoles.Mode oldMode, EmergencyGateWithRoles.Mode newMode, address indexed changedBy, string reason);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event ExceptionSet(address indexed account, bool isException, address indexed setBy);
    event GuardianSet(address indexed account, bool isGuardian);
    event MonitorSet(address indexed account, bool isMonitor);
    event EmergencyResponderSet(address indexed account, bool isResponder);
    event AutomatedEmergencyActivated(address indexed monitor, string reason);
    event EmergencyDeactivatedByGuardian(address indexed guardian);

    function setUp() public {
        gate = new EmergencyGateWithRoles(VAULT, owner, EmergencyGateWithRoles.Mode.NORMAL);
    }

    /* ============================================================ */
    /*                     DEPLOYMENT TESTS                         */
    /* ============================================================ */

    function test_Deployment_Success() public view {
        assertEq(gate.vault(), VAULT);
        assertEq(gate.owner(), owner);
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.NORMAL));
        assertTrue(gate.isException(VAULT), "Vault should be exception by default");
        assertFalse(gate.isAutomatedEmergency());
    }

    function test_Deployment_InvalidVault() public {
        vm.expectRevert(EmergencyGateWithRoles.InvalidAddress.selector);
        new EmergencyGateWithRoles(address(0), owner, EmergencyGateWithRoles.Mode.NORMAL);
    }

    function test_Deployment_InvalidOwner() public {
        vm.expectRevert(EmergencyGateWithRoles.InvalidAddress.selector);
        new EmergencyGateWithRoles(VAULT, address(0), EmergencyGateWithRoles.Mode.NORMAL);
    }

    function test_Deployment_DifferentInitialModes() public {
        EmergencyGateWithRoles gateEmergency = new EmergencyGateWithRoles(
            VAULT, owner, EmergencyGateWithRoles.Mode.EMERGENCY
        );
        assertEq(uint8(gateEmergency.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));

        EmergencyGateWithRoles gateDepositsPaused = new EmergencyGateWithRoles(
            VAULT, owner, EmergencyGateWithRoles.Mode.DEPOSITS_PAUSED
        );
        assertEq(uint8(gateDepositsPaused.mode()), uint8(EmergencyGateWithRoles.Mode.DEPOSITS_PAUSED));
    }

    /* ============================================================ */
    /*                    ROLE MANAGEMENT TESTS                     */
    /* ============================================================ */

    function test_SetGuardian_Success() public {
        vm.expectEmit(true, true, false, true);
        emit GuardianSet(guardian1, true);

        vm.prank(owner);
        gate.setGuardian(guardian1, true);

        assertTrue(gate.isGuardian(guardian1));
    }

    function test_SetGuardian_Remove() public {
        vm.prank(owner);
        gate.setGuardian(guardian1, true);
        assertTrue(gate.isGuardian(guardian1));

        vm.prank(owner);
        gate.setGuardian(guardian1, false);
        assertFalse(gate.isGuardian(guardian1));
    }

    function test_SetGuardian_Unauthorized() public {
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.setGuardian(guardian1, true);
    }

    function test_SetGuardian_ZeroAddress() public {
        vm.expectRevert(EmergencyGateWithRoles.InvalidAddress.selector);
        vm.prank(owner);
        gate.setGuardian(address(0), true);
    }

    function test_SetMonitor_Success() public {
        vm.expectEmit(true, true, false, true);
        emit MonitorSet(monitor1, true);

        vm.prank(owner);
        gate.setMonitor(monitor1, true);

        assertTrue(gate.isMonitor(monitor1));
    }

    function test_SetMonitor_MultipleMonitors() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);
        vm.prank(owner);
        gate.setMonitor(monitor2, true);

        assertTrue(gate.isMonitor(monitor1));
        assertTrue(gate.isMonitor(monitor2));
    }

    function test_SetMonitor_Unauthorized() public {
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.setMonitor(monitor1, true);
    }

    function test_SetEmergencyResponder_Success() public {
        vm.expectEmit(true, true, false, true);
        emit EmergencyResponderSet(responder1, true);

        vm.prank(owner);
        gate.setEmergencyResponder(responder1, true);

        assertTrue(gate.isEmergencyResponder(responder1));
    }

    function test_SetEmergencyResponder_Unauthorized() public {
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.setEmergencyResponder(responder1, true);
    }

    function test_GetRoles_AllRoles() public {
        vm.prank(owner);
        gate.setGuardian(user1, true);
        vm.prank(owner);
        gate.setMonitor(user1, true);
        vm.prank(owner);
        gate.setEmergencyResponder(user1, true);
        vm.prank(owner);
        gate.setException(user1, true);

        (bool isOwner, bool isGuardian, bool isMonitor, bool isResponder, bool isException) =
            gate.getRoles(user1);

        assertFalse(isOwner);  // user1 is not owner
        assertTrue(isGuardian);
        assertTrue(isMonitor);
        assertTrue(isResponder);
        assertTrue(isException);
    }

    /* ============================================================ */
    /*                    MODE MANAGEMENT TESTS                     */
    /* ============================================================ */

    function test_SetMode_ByOwner() public {
        vm.expectEmit(true, true, true, true);
        emit ModeChanged(
            EmergencyGateWithRoles.Mode.NORMAL,
            EmergencyGateWithRoles.Mode.EMERGENCY,
            owner,
            "Test emergency"
        );

        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.EMERGENCY, "Test emergency");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
        assertFalse(gate.isAutomatedEmergency(), "Manual mode change should clear automated flag");
    }

    function test_SetMode_AllModes() public {
        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.DEPOSITS_PAUSED, "Pause deposits");
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.DEPOSITS_PAUSED));

        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.WITHDRAWALS_PAUSED, "Pause withdrawals");
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.WITHDRAWALS_PAUSED));

        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.EMERGENCY, "Emergency");
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));

        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.NORMAL, "Back to normal");
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.NORMAL));
    }

    function test_SetMode_Unauthorized() public {
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.setMode(EmergencyGateWithRoles.Mode.EMERGENCY, "Unauthorized");
    }

    function test_SetMode_GuardianCannotSetMode() public {
        vm.prank(owner);
        gate.setGuardian(guardian1, true);

        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(guardian1);
        gate.setMode(EmergencyGateWithRoles.Mode.EMERGENCY, "Guardian cannot use setMode");
    }

    /* ============================================================ */
    /*                   GUARDIAN EMERGENCY TESTS                   */
    /* ============================================================ */

    function test_ActivateEmergency_ByGuardian() public {
        vm.prank(owner);
        gate.setGuardian(guardian1, true);

        vm.expectEmit(true, true, true, true);
        emit ModeChanged(
            EmergencyGateWithRoles.Mode.NORMAL,
            EmergencyGateWithRoles.Mode.EMERGENCY,
            guardian1,
            "Security incident detected"
        );

        vm.prank(guardian1);
        gate.activateEmergency("Security incident detected");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
        assertFalse(gate.isAutomatedEmergency(), "Guardian activation should not set automated flag");
        assertEq(gate.getEmergencyHistoryLength(), 1);
    }

    function test_ActivateEmergency_ByOwner() public {
        vm.prank(owner);
        gate.activateEmergency("Owner emergency");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    function test_ActivateEmergency_Unauthorized() public {
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.activateEmergency("Unauthorized");
    }

    function test_DeactivateEmergency_ByGuardian() public {
        // Activate first
        vm.prank(owner);
        gate.activateEmergency("Test");

        // Deactivate by guardian
        vm.prank(owner);
        gate.setGuardian(guardian1, true);

        vm.expectEmit(true, false, false, true);
        emit EmergencyDeactivatedByGuardian(guardian1);

        vm.prank(guardian1);
        gate.deactivateEmergency("False alarm");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.NORMAL));
        assertFalse(gate.isAutomatedEmergency());
    }

    function test_DeactivateEmergency_Unauthorized() public {
        vm.prank(owner);
        gate.activateEmergency("Test");

        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.deactivateEmergency("Unauthorized");
    }

    function test_EmergencyHistory_Tracking() public {
        vm.prank(owner);
        gate.setGuardian(guardian1, true);

        // First activation
        vm.prank(guardian1);
        gate.activateEmergency("First incident");

        // Deactivate
        vm.prank(guardian1);
        gate.deactivateEmergency("Resolved");

        // Second activation
        vm.prank(owner);
        gate.activateEmergency("Second incident");

        assertEq(gate.getEmergencyHistoryLength(), 2);

        (address activator1, uint256 timestamp1, EmergencyGateWithRoles.Mode prevMode1, string memory reason1) =
            gate.getEmergencyEvent(0);
        assertEq(activator1, guardian1);
        assertEq(uint8(prevMode1), uint8(EmergencyGateWithRoles.Mode.NORMAL));
        assertEq(reason1, "First incident");

        (address activator2,, EmergencyGateWithRoles.Mode prevMode2, string memory reason2) =
            gate.getEmergencyEvent(1);
        assertEq(activator2, owner);
        assertEq(uint8(prevMode2), uint8(EmergencyGateWithRoles.Mode.NORMAL));
        assertEq(reason2, "Second incident");
    }

    /* ============================================================ */
    /*                  MONITOR AUTOMATED TESTS                     */
    /* ============================================================ */

    function test_ActivateEmergencyAutomated_Success() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);

        vm.expectEmit(true, false, false, true);
        emit AutomatedEmergencyActivated(monitor1, "Automated threat detection");

        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Automated threat detection");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
        assertTrue(gate.isAutomatedEmergency(), "Should set automated flag");
        assertEq(gate.getEmergencyHistoryLength(), 1);
    }

    function test_ActivateEmergencyAutomated_Unauthorized() public {
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.activateEmergencyAutomated("Unauthorized");
    }

    function test_ActivateEmergencyAutomated_RateLimiting() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);

        // First activation
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("First alert");

        // Deactivate by guardian
        vm.prank(owner);
        gate.setGuardian(guardian1, true);
        vm.prank(guardian1);
        gate.deactivateEmergency("False positive");

        // Second activation too soon should fail
        vm.expectRevert(EmergencyGateWithRoles.MonitorCooldown.selector);
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Second alert too soon");
    }

    function test_ActivateEmergencyAutomated_RateLimitingAfterCooldown() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);

        // First activation
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("First alert");

        // Deactivate
        vm.prank(owner);
        gate.deactivateEmergency("Resolved");

        // Wait for cooldown
        vm.warp(block.timestamp + 5 minutes + 1);

        // Second activation should succeed
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Second alert after cooldown");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    function test_ActivateEmergencyAutomated_MultipleMonitors() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);
        vm.prank(owner);
        gate.setMonitor(monitor2, true);

        // Monitor1 activates
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Monitor1 alert");

        // Deactivate
        vm.prank(owner);
        gate.deactivateEmergency("Resolved");

        // Monitor2 can activate immediately (different monitor)
        vm.prank(monitor2);
        gate.activateEmergencyAutomated("Monitor2 alert");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    function test_MonitorCannotDeactivate() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);

        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Alert");

        // Monitor cannot deactivate
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(monitor1);
        gate.deactivateEmergency("Trying to deactivate");
    }

    /* ============================================================ */
    /*                EMERGENCY RESPONDER TESTS                     */
    /* ============================================================ */

    function test_AddExceptionDuringEmergency_Success() public {
        vm.prank(owner);
        gate.setEmergencyResponder(responder1, true);

        vm.prank(owner);
        gate.activateEmergency("Emergency");

        vm.expectEmit(true, true, true, false);
        emit ExceptionSet(user1, true, responder1);

        vm.prank(responder1);
        gate.addExceptionDuringEmergency(user1, "Recovery address");

        assertTrue(gate.isException(user1));
    }

    function test_AddExceptionDuringEmergency_NotInEmergency() public {
        vm.prank(owner);
        gate.setEmergencyResponder(responder1, true);

        vm.expectRevert(EmergencyGateWithRoles.NotInEmergency.selector);
        vm.prank(responder1);
        gate.addExceptionDuringEmergency(user1, "Not in emergency");
    }

    function test_AddExceptionDuringEmergency_Unauthorized() public {
        vm.prank(owner);
        gate.activateEmergency("Emergency");

        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.addExceptionDuringEmergency(user2, "Unauthorized");
    }

    function test_AddExceptionBatchDuringEmergency_Success() public {
        vm.prank(owner);
        gate.setEmergencyResponder(responder1, true);

        vm.prank(owner);
        gate.activateEmergency("Emergency");

        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = guardian1;

        vm.prank(responder1);
        gate.addExceptionBatchDuringEmergency(accounts, "Batch recovery");

        assertTrue(gate.isException(user1));
        assertTrue(gate.isException(user2));
        assertTrue(gate.isException(guardian1));
    }

    function test_AddExceptionDuringEmergency_ZeroAddress() public {
        vm.prank(owner);
        gate.setEmergencyResponder(responder1, true);
        vm.prank(owner);
        gate.activateEmergency("Emergency");

        vm.expectRevert(EmergencyGateWithRoles.InvalidAddress.selector);
        vm.prank(responder1);
        gate.addExceptionDuringEmergency(address(0), "Invalid");
    }

    function test_OwnerCanAlsoAddExceptionsDuringEmergency() public {
        vm.prank(owner);
        gate.activateEmergency("Emergency");

        vm.prank(owner);
        gate.addExceptionDuringEmergency(user1, "Owner adding exception");

        assertTrue(gate.isException(user1));
    }

    /* ============================================================ */
    /*                    EXCEPTION TESTS                           */
    /* ============================================================ */

    function test_SetException_Success() public {
        vm.expectEmit(true, true, true, false);
        emit ExceptionSet(user1, true, owner);

        vm.prank(owner);
        gate.setException(user1, true);

        assertTrue(gate.isException(user1));
    }

    function test_SetException_Remove() public {
        vm.prank(owner);
        gate.setException(user1, true);

        vm.prank(owner);
        gate.setException(user1, false);

        assertFalse(gate.isException(user1));
    }

    function test_SetExceptionBatch_Success() public {
        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = guardian1;

        vm.prank(owner);
        gate.setExceptionBatch(accounts, true);

        assertTrue(gate.isException(user1));
        assertTrue(gate.isException(user2));
        assertTrue(gate.isException(guardian1));
    }

    function test_SetException_Unauthorized() public {
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.setException(user2, true);
    }

    /* ============================================================ */
    /*                 GATE INTERFACE TESTS                         */
    /* ============================================================ */

    function test_GateInterface_NormalMode() public view {
        assertTrue(gate.canReceiveShares(user1));
        assertTrue(gate.canSendShares(user1));
        assertTrue(gate.canReceiveAssets(user1));
        assertTrue(gate.canSendAssets(user1));
    }

    function test_GateInterface_DepositsPausedMode() public {
        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.DEPOSITS_PAUSED, "Pause deposits");

        // Deposits blocked
        assertFalse(gate.canReceiveShares(user1));  // Cannot receive shares (from deposits)
        assertFalse(gate.canSendAssets(user1));     // Cannot send assets (deposit)

        // Withdrawals allowed
        assertTrue(gate.canSendShares(user1));      // Can send shares (withdraw)
        assertTrue(gate.canReceiveAssets(user1));   // Can receive assets (from withdrawals)
    }

    function test_GateInterface_WithdrawalsPausedMode() public {
        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.WITHDRAWALS_PAUSED, "Pause withdrawals");

        // Deposits allowed
        assertTrue(gate.canReceiveShares(user1));   // Can receive shares (from deposits)
        assertTrue(gate.canSendAssets(user1));      // Can send assets (deposit)

        // Withdrawals blocked (but transfers allowed)
        assertTrue(gate.canSendShares(user1));      // Can send shares (for transfers, not withdrawals)
        assertFalse(gate.canReceiveAssets(user1));  // Cannot receive assets (from withdrawals)
    }

    function test_GateInterface_EmergencyMode() public {
        vm.prank(owner);
        gate.activateEmergency("Emergency");

        assertFalse(gate.canReceiveShares(user1));
        assertFalse(gate.canSendShares(user1));
        assertFalse(gate.canReceiveAssets(user1));
        assertFalse(gate.canSendAssets(user1));
    }

    function test_GateInterface_ExceptionBypass() public {
        vm.prank(owner);
        gate.setException(user1, true);

        vm.prank(owner);
        gate.activateEmergency("Emergency");

        // Exception bypasses all restrictions
        assertTrue(gate.canReceiveShares(user1));
        assertTrue(gate.canSendShares(user1));
        assertTrue(gate.canReceiveAssets(user1));
        assertTrue(gate.canSendAssets(user1));
    }

    function test_GateInterface_VaultAlwaysException() public {
        vm.prank(owner);
        gate.activateEmergency("Emergency");

        assertTrue(gate.canReceiveShares(VAULT));
        assertTrue(gate.canSendShares(VAULT));
        assertTrue(gate.canReceiveAssets(VAULT));
        assertTrue(gate.canSendAssets(VAULT));
    }

    /* ============================================================ */
    /*                    VIEW FUNCTION TESTS                       */
    /* ============================================================ */

    function test_GetModeString() public {
        assertEq(gate.getModeString(), "NORMAL");

        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.DEPOSITS_PAUSED, "");
        assertEq(gate.getModeString(), "DEPOSITS_PAUSED");

        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.WITHDRAWALS_PAUSED, "");
        assertEq(gate.getModeString(), "WITHDRAWALS_PAUSED");

        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.EMERGENCY, "");
        assertEq(gate.getModeString(), "EMERGENCY");
    }

    function test_CheckPermissions_AllModes() public {
        // Normal
        (bool canDeposit, bool canWithdraw, bool canTransfer) = gate.checkPermissions(user1);
        assertTrue(canDeposit);
        assertTrue(canWithdraw);
        assertTrue(canTransfer);

        // Deposits paused
        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.DEPOSITS_PAUSED, "");
        (canDeposit, canWithdraw, canTransfer) = gate.checkPermissions(user1);
        assertFalse(canDeposit);
        assertTrue(canWithdraw);
        assertTrue(canTransfer);  // Transfers allowed when deposits paused

        // Withdrawals paused
        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.WITHDRAWALS_PAUSED, "");
        (canDeposit, canWithdraw, canTransfer) = gate.checkPermissions(user1);
        assertTrue(canDeposit);
        assertFalse(canWithdraw);
        assertTrue(canTransfer);

        // Emergency
        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.EMERGENCY, "");
        (canDeposit, canWithdraw, canTransfer) = gate.checkPermissions(user1);
        assertFalse(canDeposit);
        assertFalse(canWithdraw);
        assertFalse(canTransfer);
    }

    /* ============================================================ */
    /*                   OWNERSHIP TESTS                            */
    /* ============================================================ */

    function test_TransferOwnership_Success() public {
        address newOwner = address(0x99);

        vm.expectEmit(true, true, false, false);
        emit OwnerChanged(owner, newOwner);

        vm.prank(owner);
        gate.transferOwnership(newOwner);

        assertEq(gate.owner(), newOwner);
    }

    function test_TransferOwnership_Unauthorized() public {
        vm.expectRevert(EmergencyGateWithRoles.Unauthorized.selector);
        vm.prank(user1);
        gate.transferOwnership(user2);
    }

    function test_TransferOwnership_ZeroAddress() public {
        vm.expectRevert(EmergencyGateWithRoles.InvalidAddress.selector);
        vm.prank(owner);
        gate.transferOwnership(address(0));
    }

    /* ============================================================ */
    /*                    SCENARIO TESTS                            */
    /* ============================================================ */

    function test_Scenario_CompleteEmergencyResponse() public {
        // Setup roles
        vm.prank(owner);
        gate.setGuardian(guardian1, true);
        vm.prank(owner);
        gate.setMonitor(monitor1, true);
        vm.prank(owner);
        gate.setEmergencyResponder(responder1, true);

        // Monitor detects threat
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Share price crash detected");

        // Verify emergency mode
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
        assertTrue(gate.isAutomatedEmergency());

        // All users blocked
        assertFalse(gate.canSendAssets(user1));
        assertFalse(gate.canSendShares(user1));

        // Responder adds recovery address
        vm.prank(responder1);
        gate.addExceptionDuringEmergency(user2, "Recovery wallet");

        // Recovery wallet can operate
        assertTrue(gate.canSendAssets(user2));
        assertTrue(gate.canSendShares(user2));

        // Guardian resolves
        vm.prank(guardian1);
        gate.deactivateEmergency("Incident resolved");

        // Back to normal
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.NORMAL));
        assertTrue(gate.canSendAssets(user1));
    }

    function test_Scenario_FalsePositiveHandling() public {
        vm.prank(owner);
        gate.setGuardian(guardian1, true);
        vm.prank(owner);
        gate.setMonitor(monitor1, true);

        // Automated alert
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Potential threat");

        // Guardian investigates and determines false positive
        vm.prank(guardian1);
        gate.deactivateEmergency("False positive - all clear");

        // System returns to normal
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.NORMAL));
        assertFalse(gate.isAutomatedEmergency());

        // Monitor can trigger again after cooldown
        vm.warp(block.timestamp + 5 minutes + 1);
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Second alert");
        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    function test_Scenario_MultipleMonitorRedundancy() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);
        vm.prank(owner);
        gate.setMonitor(monitor2, true);

        // Monitor1 activates
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Monitor1 alert");

        // Guardian deactivates
        vm.prank(owner);
        gate.setGuardian(guardian1, true);
        vm.prank(guardian1);
        gate.deactivateEmergency("Checking");

        // Monitor2 can immediately activate (different monitor)
        vm.prank(monitor2);
        gate.activateEmergencyAutomated("Monitor2 confirms threat");

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
    }

    /* ============================================================ */
    /*                      EDGE CASE TESTS                         */
    /* ============================================================ */

    function test_EdgeCase_MonitorCooldownExactBoundary() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);

        vm.prank(monitor1);
        gate.activateEmergencyAutomated("First");

        vm.prank(owner);
        gate.deactivateEmergency("Clear");

        // Exactly at 5 minutes should fail
        vm.warp(block.timestamp + 5 minutes);
        vm.expectRevert(EmergencyGateWithRoles.MonitorCooldown.selector);
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("At boundary");

        // 1 second after should succeed
        vm.warp(block.timestamp + 1);
        vm.prank(monitor1);
        gate.activateEmergencyAutomated("After boundary");
    }

    function test_EdgeCase_EmergencyHistoryEmptyInitially() public view {
        assertEq(gate.getEmergencyHistoryLength(), 0);
    }

    function test_EdgeCase_AutomatedFlagClearedByManualMode() public {
        vm.prank(owner);
        gate.setMonitor(monitor1, true);

        vm.prank(monitor1);
        gate.activateEmergencyAutomated("Automated");
        assertTrue(gate.isAutomatedEmergency());

        vm.prank(owner);
        gate.setMode(EmergencyGateWithRoles.Mode.NORMAL, "Manual clear");
        assertFalse(gate.isAutomatedEmergency());
    }

    function test_EdgeCase_MultipleRolesSameAddress() public {
        vm.prank(owner);
        gate.setGuardian(user1, true);
        vm.prank(owner);
        gate.setMonitor(user1, true);
        vm.prank(owner);
        gate.setEmergencyResponder(user1, true);

        assertTrue(gate.isGuardian(user1));
        assertTrue(gate.isMonitor(user1));
        assertTrue(gate.isEmergencyResponder(user1));

        // Can use guardian powers
        vm.prank(user1);
        gate.activateEmergency("Using guardian");

        vm.prank(user1);
        gate.deactivateEmergency("Using guardian");
    }

    /* ============================================================ */
    /*                      FUZZ TESTS                              */
    /* ============================================================ */

    function testFuzz_SetException(address account) public {
        vm.assume(account != address(0));

        vm.prank(owner);
        gate.setException(account, true);
        assertTrue(gate.isException(account));
    }

    function testFuzz_GateNeverReverts(address account) public view {
        gate.canReceiveShares(account);
        gate.canSendShares(account);
        gate.canReceiveAssets(account);
        gate.canSendAssets(account);
    }

    function testFuzz_ActivateEmergencyWithReason(string calldata reason) public {
        // Filter out problematic strings
        vm.assume(bytes(reason).length < 1000);  // Reasonable length

        vm.prank(owner);
        gate.activateEmergency(reason);

        assertEq(uint8(gate.mode()), uint8(EmergencyGateWithRoles.Mode.EMERGENCY));
        assertEq(gate.getEmergencyHistoryLength(), 1);

        (,, , string memory recorded) = gate.getEmergencyEvent(0);
        assertEq(recorded, reason);
    }
}
