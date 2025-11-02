// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/gates/EmergencyGate.sol";

/// @title EmergencyGateTest
/// @notice Comprehensive test suite for EmergencyGate
contract EmergencyGateTest is Test {
    EmergencyGate public gate;

    address public constant VAULT = address(0x1);
    address public owner = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);
    address public emergencyMultisig = address(0x5);

    event ModeChanged(EmergencyGate.Mode oldMode, EmergencyGate.Mode newMode, address indexed changedBy);
    event OwnerChanged(address indexed oldOwner, address indexed newOwner);
    event ExceptionSet(address indexed account, bool isException);

    function setUp() public {
        gate = new EmergencyGate(VAULT, owner, EmergencyGate.Mode.NORMAL);
    }

    /* DEPLOYMENT TESTS */

    function test_Deployment() public {
        assertEq(gate.vault(), VAULT);
        assertEq(gate.owner(), owner);
        assertEq(uint8(gate.mode()), uint8(EmergencyGate.Mode.NORMAL));
        assertTrue(gate.isException(VAULT), "Vault should be exception");
    }

    function test_RevertWhen_DeployWithZeroVault() public {
        vm.expectRevert(EmergencyGate.InvalidAddress.selector);
        new EmergencyGate(address(0), owner, EmergencyGate.Mode.NORMAL);
    }

    function test_RevertWhen_DeployWithZeroOwner() public {
        vm.expectRevert(EmergencyGate.InvalidAddress.selector);
        new EmergencyGate(VAULT, address(0), EmergencyGate.Mode.NORMAL);
    }

    /* MODE TESTS */

    function test_SetMode_Normal() public {
        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.EMERGENCY);
        assertEq(uint8(gate.mode()), uint8(EmergencyGate.Mode.EMERGENCY));

        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.NORMAL);
        assertEq(uint8(gate.mode()), uint8(EmergencyGate.Mode.NORMAL));
    }

    function test_SetMode_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ModeChanged(EmergencyGate.Mode.NORMAL, EmergencyGate.Mode.EMERGENCY, owner);

        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.EMERGENCY);
    }

    function test_RevertWhen_SetMode_NotOwner() public {
        vm.expectRevert(EmergencyGate.Unauthorized.selector);
        vm.prank(user1);
        gate.setMode(EmergencyGate.Mode.EMERGENCY);
    }

    function test_ActivateEmergency() public {
        vm.prank(owner);
        gate.activateEmergency();
        assertEq(uint8(gate.mode()), uint8(EmergencyGate.Mode.EMERGENCY));
    }

    function test_DeactivateEmergency() public {
        vm.prank(owner);
        gate.activateEmergency();

        vm.prank(owner);
        gate.deactivateEmergency();
        assertEq(uint8(gate.mode()), uint8(EmergencyGate.Mode.NORMAL));
    }

    /* EXCEPTION TESTS */

    function test_SetException() public {
        assertFalse(gate.isException(user1));

        vm.prank(owner);
        gate.setException(user1, true);
        assertTrue(gate.isException(user1));

        vm.prank(owner);
        gate.setException(user1, false);
        assertFalse(gate.isException(user1));
    }

    function test_SetException_EmitsEvent() public {
        vm.expectEmit(true, true, true, true);
        emit ExceptionSet(user1, true);

        vm.prank(owner);
        gate.setException(user1, true);
    }

    function test_RevertWhen_SetException_NotOwner() public {
        vm.expectRevert(EmergencyGate.Unauthorized.selector);
        vm.prank(user1);
        gate.setException(user2, true);
    }

    function test_RevertWhen_SetException_ZeroAddress() public {
        vm.expectRevert(EmergencyGate.InvalidAddress.selector);
        vm.prank(owner);
        gate.setException(address(0), true);
    }

    function test_SetExceptionBatch() public {
        address[] memory accounts = new address[](3);
        accounts[0] = user1;
        accounts[1] = user2;
        accounts[2] = emergencyMultisig;

        vm.prank(owner);
        gate.setExceptionBatch(accounts, true);

        assertTrue(gate.isException(user1));
        assertTrue(gate.isException(user2));
        assertTrue(gate.isException(emergencyMultisig));
    }

    /* GATE INTERFACE TESTS - NORMAL MODE */

    function test_NormalMode_AllowsEverything() public {
        assertTrue(gate.canReceiveShares(user1), "Should allow receiving shares");
        assertTrue(gate.canSendShares(user1), "Should allow sending shares");
        assertTrue(gate.canReceiveAssets(user1), "Should allow receiving assets");
        assertTrue(gate.canSendAssets(user1), "Should allow sending assets");
    }

    /* GATE INTERFACE TESTS - DEPOSIT_ONLY MODE */

    function test_DepositOnlyMode_BlocksDeposits_AllowsWithdrawals() public {
        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.DEPOSIT_ONLY);

        // Deposits blocked
        assertFalse(gate.canSendAssets(user1), "Should block sending assets (deposit)");

        // Withdrawals allowed
        assertTrue(gate.canSendShares(user1), "Should allow sending shares (withdraw)");

        // Receiving shares allowed (from withdrawal)
        assertTrue(gate.canReceiveShares(user1), "Should allow receiving shares");

        // Receiving assets blocked
        assertFalse(gate.canReceiveAssets(user1), "Should block receiving assets");
    }

    /* GATE INTERFACE TESTS - WITHDRAWAL_ONLY MODE */

    function test_WithdrawalOnlyMode_AllowsDeposits_BlocksWithdrawals() public {
        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.WITHDRAWAL_ONLY);

        // Deposits allowed
        assertTrue(gate.canSendAssets(user1), "Should allow sending assets (deposit)");
        assertTrue(gate.canSendShares(user1), "Should allow sending shares");
        assertTrue(gate.canReceiveAssets(user1), "Should allow receiving assets");

        // Receiving shares blocked (deposit would give shares)
        assertFalse(gate.canReceiveShares(user1), "Should block receiving shares (deposit)");
    }

    /* GATE INTERFACE TESTS - EMERGENCY MODE */

    function test_EmergencyMode_BlocksEverything() public {
        vm.prank(owner);
        gate.activateEmergency();

        assertFalse(gate.canReceiveShares(user1), "Should block receiving shares");
        assertFalse(gate.canSendShares(user1), "Should block sending shares");
        assertFalse(gate.canReceiveAssets(user1), "Should block receiving assets");
        assertFalse(gate.canSendAssets(user1), "Should block sending assets");
    }

    /* EXCEPTION TESTS IN DIFFERENT MODES */

    function test_Exception_BypassesAllRestrictions() public {
        // Set exception
        vm.prank(owner);
        gate.setException(emergencyMultisig, true);

        // Activate emergency mode
        vm.prank(owner);
        gate.activateEmergency();

        // Regular user blocked
        assertFalse(gate.canSendAssets(user1), "Regular user should be blocked");

        // Exception allowed
        assertTrue(gate.canReceiveShares(emergencyMultisig), "Exception should receive shares");
        assertTrue(gate.canSendShares(emergencyMultisig), "Exception should send shares");
        assertTrue(gate.canReceiveAssets(emergencyMultisig), "Exception should receive assets");
        assertTrue(gate.canSendAssets(emergencyMultisig), "Exception should send assets");
    }

    function test_VaultAlwaysException() public {
        vm.prank(owner);
        gate.activateEmergency();

        // Vault should always bypass restrictions
        assertTrue(gate.canReceiveShares(VAULT), "Vault should receive shares");
        assertTrue(gate.canSendShares(VAULT), "Vault should send shares");
        assertTrue(gate.canReceiveAssets(VAULT), "Vault should receive assets");
        assertTrue(gate.canSendAssets(VAULT), "Vault should send assets");
    }

    /* CHECK PERMISSIONS TESTS */

    function test_CheckPermissions_NormalMode() public {
        (bool canDeposit, bool canWithdraw, bool canTransfer) = gate.checkPermissions(user1);
        assertTrue(canDeposit, "Should allow deposits");
        assertTrue(canWithdraw, "Should allow withdrawals");
        assertTrue(canTransfer, "Should allow transfers");
    }

    function test_CheckPermissions_DepositOnlyMode() public {
        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.DEPOSIT_ONLY);

        (bool canDeposit, bool canWithdraw, bool canTransfer) = gate.checkPermissions(user1);
        assertFalse(canDeposit, "Should block deposits");
        assertTrue(canWithdraw, "Should allow withdrawals");
        assertFalse(canTransfer, "Should block transfers");
    }

    function test_CheckPermissions_WithdrawalOnlyMode() public {
        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.WITHDRAWAL_ONLY);

        (bool canDeposit, bool canWithdraw, bool canTransfer) = gate.checkPermissions(user1);
        assertTrue(canDeposit, "Should allow deposits");
        assertFalse(canWithdraw, "Should block withdrawals");
        assertTrue(canTransfer, "Should allow transfers");
    }

    function test_CheckPermissions_EmergencyMode() public {
        vm.prank(owner);
        gate.activateEmergency();

        (bool canDeposit, bool canWithdraw, bool canTransfer) = gate.checkPermissions(user1);
        assertFalse(canDeposit, "Should block deposits");
        assertFalse(canWithdraw, "Should block withdrawals");
        assertFalse(canTransfer, "Should block transfers");
    }

    function test_CheckPermissions_Exception() public {
        vm.prank(owner);
        gate.setException(emergencyMultisig, true);

        vm.prank(owner);
        gate.activateEmergency();

        (bool canDeposit, bool canWithdraw, bool canTransfer) = gate.checkPermissions(emergencyMultisig);
        assertTrue(canDeposit, "Exception should allow deposits");
        assertTrue(canWithdraw, "Exception should allow withdrawals");
        assertTrue(canTransfer, "Exception should allow transfers");
    }

    /* VIEW FUNCTIONS TESTS */

    function test_GetModeString() public {
        assertEq(gate.getModeString(), "NORMAL");

        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.DEPOSIT_ONLY);
        assertEq(gate.getModeString(), "DEPOSIT_ONLY");

        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.WITHDRAWAL_ONLY);
        assertEq(gate.getModeString(), "WITHDRAWAL_ONLY");

        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.EMERGENCY);
        assertEq(gate.getModeString(), "EMERGENCY");
    }

    /* OWNERSHIP TESTS */

    function test_TransferOwnership() public {
        address newOwner = address(0x99);

        vm.expectEmit(true, true, true, true);
        emit OwnerChanged(owner, newOwner);

        vm.prank(owner);
        gate.transferOwnership(newOwner);

        assertEq(gate.owner(), newOwner);
    }

    function test_RevertWhen_TransferOwnership_NotOwner() public {
        vm.expectRevert(EmergencyGate.Unauthorized.selector);
        vm.prank(user1);
        gate.transferOwnership(user2);
    }

    function test_RevertWhen_TransferOwnership_ZeroAddress() public {
        vm.expectRevert(EmergencyGate.InvalidAddress.selector);
        vm.prank(owner);
        gate.transferOwnership(address(0));
    }

    /* NEVER REVERT TESTS */

    function test_NeverReverts_CanReceiveShares() public view {
        // Should never revert, even with invalid addresses
        gate.canReceiveShares(address(0));
        gate.canReceiveShares(address(type(uint160).max));
    }

    function test_NeverReverts_CanSendShares() public view {
        gate.canSendShares(address(0));
        gate.canSendShares(address(type(uint160).max));
    }

    function test_NeverReverts_CanReceiveAssets() public view {
        gate.canReceiveAssets(address(0));
        gate.canReceiveAssets(address(type(uint160).max));
    }

    function test_NeverReverts_CanSendAssets() public view {
        gate.canSendAssets(address(0));
        gate.canSendAssets(address(type(uint160).max));
    }

    /* SCENARIO TESTS */

    function test_Scenario_EmergencyActivation() public {
        // Normal operations
        assertTrue(gate.canSendAssets(user1));
        assertTrue(gate.canSendShares(user1));

        // Emergency detected
        vm.prank(owner);
        gate.activateEmergency();

        // All users blocked
        assertFalse(gate.canSendAssets(user1));
        assertFalse(gate.canSendShares(user1));

        // Add emergency responder
        vm.prank(owner);
        gate.setException(emergencyMultisig, true);

        // Emergency responder can operate
        assertTrue(gate.canSendAssets(emergencyMultisig));
        assertTrue(gate.canSendShares(emergencyMultisig));

        // Recovery
        vm.prank(owner);
        gate.deactivateEmergency();

        // All users restored
        assertTrue(gate.canSendAssets(user1));
        assertTrue(gate.canSendShares(user1));
    }

    function test_Scenario_SelectiveDepositBlocking() public {
        // Block new deposits
        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.DEPOSIT_ONLY);

        // User 1 cannot deposit
        assertFalse(gate.canSendAssets(user1));

        // But can still withdraw
        assertTrue(gate.canSendShares(user1));

        // Whitelist user 2 for deposits
        vm.prank(owner);
        gate.setException(user2, true);

        // User 2 can deposit
        assertTrue(gate.canSendAssets(user2));
        assertTrue(gate.canSendShares(user2));
    }

    /* GAS TESTS */

    function test_Gas_CanReceiveShares() public view {
        uint256 gasBefore = gasleft();
        gate.canReceiveShares(user1);
        uint256 gasUsed = gasBefore - gasleft();

        // Should use minimal gas (no loops, minimal storage reads)
        // Note: Gas costs have increased with newer EVM versions
        assertLt(gasUsed, 15000, "Should use < 15000 gas");
    }

    function test_Gas_SetMode() public {
        uint256 gasBefore = gasleft();
        vm.prank(owner);
        gate.setMode(EmergencyGate.Mode.EMERGENCY);
        uint256 gasUsed = gasBefore - gasleft();

        // Should be reasonable for state change + event
        assertLt(gasUsed, 50000, "Should use < 50000 gas");
    }
}
