// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/gates/EmergencyGateWithRoles.sol";
import "../src/VaultV2.sol";
import "../src/interfaces/IVaultV2.sol";

/**
 * @title DeployGate
 * @notice Deploys EmergencyGateWithRoles and configures it according to Option Vault SOP
 *
 * FULL DEPLOYMENT FLOW (Option Vault SOP):
 *   Step 1: Deploy gate + configure mode + add MPC exception + submit timelock
 *   Step 2: Wait for timelock to expire
 *   Step 3: Run ExecuteGateConfiguration to activate gates on vault
 *
 * USAGE:
 *   PRIVATE_KEY=0x... VAULT_ADDRESS=0x... MPC_WALLET=0x... forge script script/DeployGate.s.sol:DeployGate --rpc-url <RPC_URL> --broadcast -v
 *
 * OPTIONAL ENV VARS:
 *   MODE=2              (default: 2 = WITHDRAWALS_PAUSED per Option Vault SOP)
 *   REASON="..."        (reason for mode setting)
 *
 * MODES:
 *   0 = NORMAL            (all operations allowed)
 *   1 = DEPOSITS_PAUSED   (deposits blocked, withdrawals allowed)
 *   2 = WITHDRAWALS_PAUSED (withdrawals blocked, deposits allowed) [DEFAULT for Option Vault]
 *   3 = EMERGENCY         (all operations blocked)
 */
contract DeployGate is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address mpcWallet = vm.envAddress("MPC_WALLET");
        address owner = vm.addr(deployerPrivateKey);

        // Default mode = 2 (WITHDRAWALS_PAUSED) per Option Vault SOP
        uint8 mode = uint8(vm.envOr("MODE", uint256(2)));
        string memory reason = vm.envOr("REASON", string("Allow deposits, block withdrawals except MPC"));

        VaultV2 vault = VaultV2(vaultAddress);

        console.log("=== OPTION VAULT SOP: DEPLOY & CONFIGURE GATE ===");
        console.log("");
        console.log("--- Configuration ---");
        console.log("Vault:", vaultAddress);
        console.log("Owner:", owner);
        console.log("MPC Wallet:", mpcWallet);
        console.log("Initial Mode:", mode);
        console.log("Vault Curator:", vault.curator());

        vm.startBroadcast(deployerPrivateKey);

        // ==========================================
        // STEP 1: Deploy EmergencyGateWithRoles
        // ==========================================
        console.log("");
        console.log("--- Step 1: Deploying EmergencyGateWithRoles ---");

        EmergencyGateWithRoles gate = new EmergencyGateWithRoles(
            vaultAddress,
            owner,
            EmergencyGateWithRoles.Mode(0) // Deploy in NORMAL mode first
        );
        console.log("Gate deployed at:", address(gate));

        // ==========================================
        // STEP 4.1: Set Gate Mode (SOP Step 4.1)
        // ==========================================
        console.log("");
        console.log("--- Step 4.1: Set Gate Mode ---");
        console.log("Setting mode to:", mode);
        console.log("Reason:", reason);

        gate.setMode(EmergencyGateWithRoles.Mode(mode), reason);
        console.log("Mode set successfully:", gate.getModeString());

        // ==========================================
        // STEP 4.2: Add MPC Wallet as Exception (SOP Step 4.2)
        // ==========================================
        console.log("");
        console.log("--- Step 4.2: Add MPC Wallet as Exception ---");
        console.log("Adding MPC wallet:", mpcWallet);

        gate.setException(mpcWallet, true);
        console.log("MPC wallet exception set:", gate.isException(mpcWallet));

    }
}

/**
 * @title ExecuteGateConfiguration
 * @notice Executes gate configuration after timelock expires (SOP Steps 4.3 & 4.4 execution)
 *
 * USAGE:
 *   PRIVATE_KEY=0x... VAULT_ADDRESS=0x... GATE_ADDRESS=0x... forge script script/DeployGate.s.sol:ExecuteGateConfiguration --rpc-url <RPC_URL> --broadcast -v
 */
contract ExecuteGateConfiguration is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address gateAddress = vm.envAddress("GATE_ADDRESS");

        VaultV2 vault = VaultV2(vaultAddress);
        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== OPTION VAULT SOP: EXECUTE GATE CONFIGURATION ===");
        console.log("");
        console.log("Vault:", vaultAddress);
        console.log("Gate:", gateAddress);
        console.log("Gate Mode:", gate.getModeString());
        console.log("Current timestamp:", block.timestamp);

        // Check current gates
        console.log("");
        console.log("--- Current Gates (before execution) ---");
        console.log("receiveSharesGate:", vault.receiveSharesGate());
        console.log("sendSharesGate:", vault.sendSharesGate());
        console.log("receiveAssetsGate:", vault.receiveAssetsGate());
        console.log("sendAssetsGate:", vault.sendAssetsGate());

        vm.startBroadcast(deployerPrivateKey);

        console.log("");
        console.log("--- Executing Gate Changes ---");

        console.log("1. Setting receiveSharesGate...");
        vault.setReceiveSharesGate(gateAddress);

        console.log("2. Setting sendSharesGate...");
        vault.setSendSharesGate(gateAddress);

        console.log("3. Setting receiveAssetsGate (SOP 4.4)...");
        vault.setReceiveAssetsGate(gateAddress);

        console.log("4. Setting sendAssetsGate (SOP 4.3)...");
        vault.setSendAssetsGate(gateAddress);

        vm.stopBroadcast();

        // Verify gates
        console.log("");
        console.log("--- New Gates (after execution) ---");
        console.log("receiveSharesGate:", vault.receiveSharesGate());
        console.log("sendSharesGate:", vault.sendSharesGate());
        console.log("receiveAssetsGate:", vault.receiveAssetsGate());
        console.log("sendAssetsGate:", vault.sendAssetsGate());

        console.log("");
        console.log("=== GATE CONFIGURATION COMPLETE ===");
        console.log("EmergencyGateWithRoles is now active!");
        console.log("Gate Mode:", gate.getModeString());
        console.log("Gate Owner:", gate.owner());

        // Show current permissions
        console.log("");
        console.log("--- Gate Behavior (Mode:", gate.getModeString(), ") ---");
        EmergencyGateWithRoles.Mode currentMode = gate.mode();
        if (uint8(currentMode) == 2) { // WITHDRAWALS_PAUSED
            console.log("  - Deposits: ALLOWED");
            console.log("  - Withdrawals: BLOCKED (except MPC/exceptions)");
        }
    }
}

/**
 * @title VerifyGateStatus
 * @notice Utility script to verify gate configuration status
 *
 * USAGE:
 *   VAULT_ADDRESS=0x... GATE_ADDRESS=0x... forge script script/DeployGate.s.sol:VerifyGateStatus --rpc-url <RPC_URL>
 */
contract VerifyGateStatus is Script {
    function run() external view {
        address vaultAddress = vm.envAddress("VAULT_ADDRESS");
        address gateAddress = vm.envAddress("GATE_ADDRESS");

        VaultV2 vault = VaultV2(vaultAddress);
        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);

        console.log("=== GATE STATUS VERIFICATION ===");
        console.log("");
        console.log("--- Gate Contract ---");
        console.log("Address:", gateAddress);
        console.log("Mode:", gate.getModeString());
        console.log("Owner:", gate.owner());
        console.log("Vault (immutable):", gate.vault());

        console.log("");
        console.log("--- Vault Gates ---");
        console.log("receiveSharesGate:", vault.receiveSharesGate());
        console.log("sendSharesGate:", vault.sendSharesGate());
        console.log("receiveAssetsGate:", vault.receiveAssetsGate());
        console.log("sendAssetsGate:", vault.sendAssetsGate());

        bool allGatesSet =
            vault.receiveSharesGate() == gateAddress &&
            vault.sendSharesGate() == gateAddress &&
            vault.receiveAssetsGate() == gateAddress &&
            vault.sendAssetsGate() == gateAddress;

        console.log("");
        console.log("--- Status ---");
        if (allGatesSet) {
            console.log("All gates correctly configured!");
        } else {
            console.log("WARNING: Not all gates are set to this gate address!");
            console.log("Run ExecuteGateConfiguration after timelock expires.");
        }
    }
}
