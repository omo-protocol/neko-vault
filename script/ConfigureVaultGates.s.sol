// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/gates/EmergencyGate.sol";
import "../src/VaultV2.sol";
import "../src/interfaces/IVaultV2.sol";

/// @title ConfigureVaultGates
/// @notice Script to configure EmergencyGate on VaultV2 (REQUIRES TIMELOCK!)
/// @dev This script SUBMITS the gate configuration - you must WAIT for timelock then EXECUTE
///
/// USAGE:
///   1. Deploy EmergencyGate first (using DeployEmergencyGate.s.sol)
///   2. Set VAULT_ADDRESS and GATE_ADDRESS in environment
///   3. Run this script to SUBMIT gate changes (curator only)
///   4. Wait for timelock to expire
///   5. Run execute script or call vault functions directly to activate gates
///
/// EXAMPLE:
///   export VAULT_ADDRESS="0x..."
///   export GATE_ADDRESS="0x..."
///   forge script script/ConfigureVaultGates.s.sol --rpc-url $RPC_URL --broadcast
contract ConfigureVaultGates is Script {

    function run() external {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address gateAddress = vm.envAddress("GATE_ADDRESS");

        VaultV2 vault = VaultV2(vaultAddress);
        EmergencyGate gate = EmergencyGate(gateAddress);

        console.log("=== VAULT GATE CONFIGURATION ===");
        console.log("Vault:", vaultAddress);
        console.log("Gate:", gateAddress);
        console.log("Gate Mode:", gate.getModeString());
        console.log("Curator:", vault.curator());

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

        vm.startBroadcast();

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
        console.log("   forge script script/ExecuteVaultGates.s.sol --rpc-url $RPC_URL --broadcast");
        console.log("3. Or call vault functions directly:");
        console.log("   vault.setReceiveSharesGate(", gateAddress, ")");
        console.log("   vault.setSendSharesGate(", gateAddress, ")");
        console.log("   vault.setReceiveAssetsGate(", gateAddress, ")");
        console.log("   vault.setSendAssetsGate(", gateAddress, ")");
    }
}

/// @title ExecuteVaultGates
/// @notice Script to EXECUTE gate configuration after timelock expires
contract ExecuteVaultGates is Script {

    function run() external {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address gateAddress = vm.envAddress("GATE_ADDRESS");

        VaultV2 vault = VaultV2(vaultAddress);

        console.log("=== EXECUTING GATE CONFIGURATION ===");
        console.log("Vault:", vaultAddress);
        console.log("Gate:", gateAddress);
        console.log("Current timestamp:", block.timestamp);

        // Check current gates
        console.log("\nCurrent Gates:");
        console.log("  receiveSharesGate:", vault.receiveSharesGate());
        console.log("  sendSharesGate:", vault.sendSharesGate());
        console.log("  receiveAssetsGate:", vault.receiveAssetsGate());
        console.log("  sendAssetsGate:", vault.sendAssetsGate());

        vm.startBroadcast();

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
        console.log("EmergencyGate is now active!");
        console.log("Current mode:", EmergencyGate(gateAddress).getModeString());
        console.log("\nIn emergency, call:");
        console.log("  EmergencyGate(", gateAddress, ").activateEmergency()");
    }
}

/// @title EmergencyActivation
/// @notice Quick script to activate emergency mode (gate owner only)
contract EmergencyActivation is Script {

    function run() external {
        address gateAddress = vm.envAddress("GATE_ADDRESS");
        EmergencyGate gate = EmergencyGate(gateAddress);

        console.log("=== ACTIVATING EMERGENCY MODE ===");
        console.log("Gate:", gateAddress);
        console.log("Current Mode:", gate.getModeString());

        vm.startBroadcast();

        gate.activateEmergency();

        vm.stopBroadcast();

        console.log("New Mode:", gate.getModeString());
        console.log("\n=== EMERGENCY MODE ACTIVE ===");
        console.log("All vault operations blocked (except exceptions)");
    }
}

/// @title EmergencyDeactivation
/// @notice Quick script to deactivate emergency mode (gate owner only)
contract EmergencyDeactivation is Script {

    function run() external {
        address gateAddress = vm.envAddress("GATE_ADDRESS");
        EmergencyGate gate = EmergencyGate(gateAddress);

        console.log("=== DEACTIVATING EMERGENCY MODE ===");
        console.log("Gate:", gateAddress);
        console.log("Current Mode:", gate.getModeString());

        vm.startBroadcast();

        gate.deactivateEmergency();

        vm.stopBroadcast();

        console.log("New Mode:", gate.getModeString());
        console.log("\n=== NORMAL MODE RESTORED ===");
        console.log("All vault operations allowed");
    }
}
