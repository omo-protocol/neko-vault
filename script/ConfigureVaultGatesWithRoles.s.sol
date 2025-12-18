// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/gates/EmergencyGateWithRoles.sol";
import "../src/VaultV2.sol";
import "../src/interfaces/IVaultV2.sol";

/// @title ConfigureVaultGatesWithRoles
/// @notice Script to configure EmergencyGateWithRoles on VaultV2 (REQUIRES TIMELOCK!)
/// @dev This script SUBMITS the gate configuration - you must WAIT for timelock then EXECUTE
///
/// USAGE:
///   1. Deploy EmergencyGateWithRoles first (using DeployGate.s.sol)
///   2. Set VAULT_ADDRESS and GATE_ADDRESS in environment
///   3. Run this script to SUBMIT gate changes (curator only)
///   4. Wait for timelock to expire
///   5. Run ExecuteVaultGatesWithRoles to activate gates
///
/// EXAMPLE:
///   export VAULT_ADDRESS="0x..."
///   export GATE_ADDRESS="0x..."
///   forge script script/ConfigureVaultGatesWithRoles.s.sol:ConfigureVaultGatesWithRoles --rpc-url $RPC_URL --broadcast
contract ConfigureVaultGatesWithRoles is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address gateAddress = vm.envAddress("GATE_ADDRESS");

        VaultV2 vault = VaultV2(vaultAddress);
        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== VAULT GATE CONFIGURATION (WITH ROLES) ===");
        console.log("Vault:", vaultAddress);
        console.log("Gate:", gateAddress);
        console.log("Gate Mode:", gate.getModeString());
        console.log("Gate Owner:", gate.owner());
        console.log("Vault Curator:", vault.curator());

        // Check timelocks
        uint256 receiveSharesTimelock = vault.timelock(IVaultV2.setReceiveSharesGate.selector);
        uint256 sendSharesTimelock = vault.timelock(IVaultV2.setSendSharesGate.selector);
        uint256 receiveAssetsTimelock = vault.timelock(IVaultV2.setReceiveAssetsGate.selector);
        uint256 sendAssetsTimelock = vault.timelock(IVaultV2.setSendAssetsGate.selector);

        console.log("\nTimelocks:");
        console.log("  receiveSharesGate:", receiveSharesTimelock, "seconds");
        console.log("  sendSharesGate:", sendSharesTimelock, "seconds");
        console.log("  receiveAssetsGate:", receiveAssetsTimelock, "seconds");
        console.log("  sendAssetsGate:", sendAssetsTimelock, "seconds");

        vm.startBroadcast(deployerPrivateKey);

        // Encode gate change data
        bytes memory data1 = abi.encodeWithSelector(
            IVaultV2.setReceiveSharesGate.selector,
            gateAddress
        );
        bytes memory data2 = abi.encodeWithSelector(
            IVaultV2.setSendSharesGate.selector,
            gateAddress
        );
        bytes memory data3 = abi.encodeWithSelector(
            IVaultV2.setReceiveAssetsGate.selector,
            gateAddress
        );
        bytes memory data4 = abi.encodeWithSelector(
            IVaultV2.setSendAssetsGate.selector,
            gateAddress
        );

        // Submit all gate changes
        console.log("\nSubmitting gate changes...");

        console.log("1. Submitting setReceiveSharesGate...");
        vault.submit(data1);
        uint256 executableAt1 = vault.executableAt(data1);
        console.log("   Executable at:", executableAt1);

        console.log("2. Submitting setSendSharesGate...");
        vault.submit(data2);
        uint256 executableAt2 = vault.executableAt(data2);
        console.log("   Executable at:", executableAt2);

        console.log("3. Submitting setReceiveAssetsGate...");
        vault.submit(data3);
        uint256 executableAt3 = vault.executableAt(data3);
        console.log("   Executable at:", executableAt3);

        console.log("4. Submitting setSendAssetsGate...");
        vault.submit(data4);
        uint256 executableAt4 = vault.executableAt(data4);
        console.log("   Executable at:", executableAt4);

        vm.stopBroadcast();

        // Calculate wait times
        uint256 maxExecutableAt = executableAt1;
        if (executableAt2 > maxExecutableAt) maxExecutableAt = executableAt2;
        if (executableAt3 > maxExecutableAt) maxExecutableAt = executableAt3;
        if (executableAt4 > maxExecutableAt) maxExecutableAt = executableAt4;

        uint256 waitTime = maxExecutableAt > block.timestamp ? maxExecutableAt - block.timestamp : 0;

        console.log("\n=== SUBMISSION COMPLETE ===");
        console.log("Current timestamp:", block.timestamp);
        console.log("Executable after:", maxExecutableAt);
        console.log("Wait time:", waitTime, "seconds");
        console.log("Wait time:", waitTime / 3600, "hours");

        console.log("\n=== NEXT STEPS ===");
        console.log("1. Wait for", waitTime / 3600, "hours");
        console.log("2. Run execute script:");
        console.log("   forge script script/ConfigureVaultGatesWithRoles.s.sol:ExecuteVaultGatesWithRoles --rpc-url $RPC_URL --broadcast");
    }
}

/// @title ExecuteVaultGatesWithRoles
/// @notice Script to EXECUTE gate configuration after timelock expires
contract ExecuteVaultGatesWithRoles is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address gateAddress = vm.envAddress("GATE_ADDRESS");

        VaultV2 vault = VaultV2(vaultAddress);
        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== EXECUTING GATE CONFIGURATION (WITH ROLES) ===");
        console.log("Vault:", vaultAddress);
        console.log("Gate:", gateAddress);
        console.log("Current timestamp:", block.timestamp);

        // Check current gates
        console.log("\nCurrent Gates:");
        console.log("  receiveSharesGate:", vault.receiveSharesGate());
        console.log("  sendSharesGate:", vault.sendSharesGate());
        console.log("  receiveAssetsGate:", vault.receiveAssetsGate());
        console.log("  sendAssetsGate:", vault.sendAssetsGate());

        vm.startBroadcast(deployerPrivateKey);

        console.log("\nExecuting gate changes...");

        console.log("1. Setting receiveSharesGate...");
        vault.setReceiveSharesGate(gateAddress);

        console.log("2. Setting sendSharesGate...");
        vault.setSendSharesGate(gateAddress);

        console.log("3. Setting receiveAssetsGate...");
        vault.setReceiveAssetsGate(gateAddress);

        console.log("4. Setting sendAssetsGate...");
        vault.setSendAssetsGate(gateAddress);

        vm.stopBroadcast();

        // Verify gates
        console.log("\nNew Gates:");
        console.log("  receiveSharesGate:", vault.receiveSharesGate());
        console.log("  sendSharesGate:", vault.sendSharesGate());
        console.log("  receiveAssetsGate:", vault.receiveAssetsGate());
        console.log("  sendAssetsGate:", vault.sendAssetsGate());

        console.log("\n=== EXECUTION COMPLETE ===");
        console.log("EmergencyGateWithRoles is now active!");
        console.log("Current mode:", gate.getModeString());

        // Show permissions info
        console.log("\n=== GATE PERMISSIONS ===");
        console.log("Owner:", gate.owner());
        console.log("\nTo manage roles:");
        console.log("  gate.setGuardian(address, true)   - Can activate/deactivate emergency");
        console.log("  gate.setMonitor(address, true)    - Can only activate emergency (automated)");
        console.log("  gate.setEmergencyResponder(address, true) - Can add exceptions during emergency");
    }
}

/// @title SetGateMode
/// @notice Script to change gate mode (owner only)
/// @dev Modes: 0=NORMAL, 1=DEPOSITS_PAUSED, 2=WITHDRAWALS_PAUSED, 3=EMERGENCY
///
/// MODE BEHAVIOR:
///   NORMAL (0)             - All operations allowed
///   DEPOSITS_PAUSED (1)    - Deposits BLOCKED, Withdrawals ALLOWED
///   WITHDRAWALS_PAUSED (2) - Withdrawals BLOCKED, Deposits ALLOWED
///   EMERGENCY (3)          - All operations BLOCKED
///
/// EXAMPLE:
///   GATE_ADDRESS=0x... MODE=1 REASON="Pausing deposits" forge script script/ConfigureVaultGatesWithRoles.s.sol:SetGateMode --rpc-url $RPC_URL --broadcast
contract SetGateMode is Script {

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address gateAddress = vm.envAddress("GATE_ADDRESS");
        uint8 newMode = uint8(vm.envUint("MODE"));
        string memory reason = vm.envOr("REASON", string("Mode change via script"));

        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== CHANGING GATE MODE ===");
        console.log("Gate:", gateAddress);
        console.log("Current Mode:", gate.getModeString());
        console.log("New Mode:", newMode);
        console.log("Reason:", reason);

        string memory newModeStr;
        if (newMode == 0) newModeStr = "NORMAL (all operations allowed)";
        else if (newMode == 1) newModeStr = "DEPOSITS_PAUSED (deposits blocked, withdrawals allowed)";
        else if (newMode == 2) newModeStr = "WITHDRAWALS_PAUSED (withdrawals blocked, deposits allowed)";
        else if (newMode == 3) newModeStr = "EMERGENCY (all operations blocked)";
        else revert("Invalid mode");

        console.log("New Mode Description:", newModeStr);

        vm.startBroadcast(deployerPrivateKey);

        gate.setMode(EmergencyGateWithRoles.Mode(newMode), reason);

        vm.stopBroadcast();

        console.log("\n=== MODE CHANGED ===");
        console.log("New Mode:", gate.getModeString());
    }
}

/// @title ActivateEmergencyWithRoles
/// @notice Script to activate emergency mode (guardian/owner)
contract ActivateEmergencyWithRoles is Script {

    function run() external {
        address gateAddress = vm.envAddress("GATE_ADDRESS");
        string memory reason = vm.envOr("REASON", string("Emergency activated via script"));

        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== ACTIVATING EMERGENCY MODE ===");
        console.log("Gate:", gateAddress);
        console.log("Current Mode:", gate.getModeString());
        console.log("Reason:", reason);

        vm.startBroadcast();

        gate.activateEmergency(reason);

        vm.stopBroadcast();

        console.log("\n=== EMERGENCY MODE ACTIVE ===");
        console.log("New Mode:", gate.getModeString());
        console.log("All vault operations blocked (except exceptions)");
    }
}

/// @title DeactivateEmergencyWithRoles
/// @notice Script to deactivate emergency mode (guardian/owner)
contract DeactivateEmergencyWithRoles is Script {

    function run() external {
        address gateAddress = vm.envAddress("GATE_ADDRESS");
        string memory reason = vm.envOr("REASON", string("Emergency deactivated via script"));

        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== DEACTIVATING EMERGENCY MODE ===");
        console.log("Gate:", gateAddress);
        console.log("Current Mode:", gate.getModeString());

        vm.startBroadcast();

        gate.deactivateEmergency(reason);

        vm.stopBroadcast();

        console.log("\n=== NORMAL MODE RESTORED ===");
        console.log("New Mode:", gate.getModeString());
        console.log("All vault operations allowed");
    }
}

/// @title SetupGateRoles
/// @notice Script to setup guardian/monitor/responder roles
///
/// EXAMPLE:
///   GATE_ADDRESS=0x... GUARDIAN=0x... MONITOR=0x... forge script script/ConfigureVaultGatesWithRoles.s.sol:SetupGateRoles --rpc-url $RPC_URL --broadcast
contract SetupGateRoles is Script {

    function run() external {
        address gateAddress = vm.envAddress("GATE_ADDRESS");

        // Optional role addresses
        address guardian = vm.envOr("GUARDIAN", address(0));
        address monitor = vm.envOr("MONITOR", address(0));
        address responder = vm.envOr("RESPONDER", address(0));

        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== SETTING UP GATE ROLES ===");
        console.log("Gate:", gateAddress);
        console.log("Owner:", gate.owner());

        vm.startBroadcast();

        if (guardian != address(0)) {
            console.log("Setting guardian:", guardian);
            gate.setGuardian(guardian, true);
        }

        if (monitor != address(0)) {
            console.log("Setting monitor:", monitor);
            gate.setMonitor(monitor, true);
        }

        if (responder != address(0)) {
            console.log("Setting emergency responder:", responder);
            gate.setEmergencyResponder(responder, true);
        }

        vm.stopBroadcast();

        console.log("\n=== ROLES CONFIGURED ===");
        if (guardian != address(0)) {
            console.log("Guardian", guardian, ":", gate.isGuardian(guardian));
        }
        if (monitor != address(0)) {
            console.log("Monitor", monitor, ":", gate.isMonitor(monitor));
        }
        if (responder != address(0)) {
            console.log("Responder", responder, ":", gate.isEmergencyResponder(responder));
        }
    }
}

/// @title AddException
/// @notice Script to add exception address that bypasses gate restrictions
///
/// EXAMPLE:
///   GATE_ADDRESS=0x... EXCEPTION=0x... forge script script/ConfigureVaultGatesWithRoles.s.sol:AddException --rpc-url $RPC_URL --broadcast
contract AddException is Script {

    function run() external {
        address gateAddress = vm.envAddress("GATE_ADDRESS");
        address exception = vm.envAddress("EXCEPTION");

        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== ADDING EXCEPTION ===");
        console.log("Gate:", gateAddress);
        console.log("Exception address:", exception);

        vm.startBroadcast();

        gate.setException(exception, true);

        vm.stopBroadcast();

        console.log("\n=== EXCEPTION ADDED ===");
        console.log("Address", exception, "now bypasses all gate restrictions");
        console.log("isException:", gate.isException(exception));
    }
}
