// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/gates/EmergencyGateWithRoles.sol";

/**
 * @title TransferGateOwnership
 * @notice Script to transfer ownership of EmergencyGateWithRoles to a new owner
 * @dev Calls the transferOwnership function on EmergencyGateWithRoles contract
 *
 * SECURITY NOTICE:
 * ================
 * - EmergencyGateWithRoles.transferOwnership() is a DIRECT ownership transfer (not two-step)
 * - Once executed, ownership transfers IMMEDIATELY to the new owner
 * - ALWAYS verify the gate address and new owner are correct before running
 * - The transaction signer MUST be the current gate owner
 *
 * ENVIRONMENT VARIABLES:
 * ======================
 * Required:
 *   - PRIVATE_KEY: Private key of the CURRENT owner
 *
 * USAGE EXAMPLE:
 * ==============
 * # Dry-run first (no --broadcast flag)
 * PRIVATE_KEY=0x123... \
 * forge script script/TransferGateOwnership.s.sol \
 *   --rpc-url https://rpc.hyperliquid.xyz/evm -v
 *
 * # Execute transfer
 * PRIVATE_KEY=0x123... \
 * forge script script/TransferGateOwnership.s.sol \
 *   --rpc-url https://rpc.hyperliquid.xyz/evm \
 *   --broadcast -v
 *
 * VERIFY BEFORE EXECUTING:
 * ========================
 * 1. Configure GATE_ADDRESS below to the correct gate contract
 * 2. Verify NEW_OWNER address is correct (allocator address)
 * 3. Verify PRIVATE_KEY corresponds to current gate owner
 * 4. Do a dry-run first (remove --broadcast flag)
 */
contract TransferGateOwnership is Script {

    // ============================================================
    // CONFIGURATION - MODIFY BEFORE RUNNING
    // ============================================================

    /// @notice Address of the EmergencyGateWithRoles contract to transfer
    /// @dev MUST be configured before running the script
    address gateAddress = 0x619F0b4999259031b7002A85f9b03615d7Cb3C0e; // <-- CONFIGURE THIS

    /// @notice New owner address (allocator)
    address constant newOwner = 0x47E33C31F253F98E389AC9163a30d3BFF1235352;

    // ============================================================

    function run() public {
        // ============================================================
        // STEP 1: Load environment variables
        // ============================================================
        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");
        address signer = vm.addr(ownerPrivateKey);

        // Validate addresses
        require(gateAddress != address(0), "GATE_ADDRESS cannot be zero - configure in script");
        require(newOwner != address(0), "NEW_OWNER cannot be zero");

        // ============================================================
        // STEP 2: Load gate and verify current state
        // ============================================================
        EmergencyGateWithRoles gate = EmergencyGateWithRoles(gateAddress);
        address currentOwner = gate.owner();

        // ============================================================
        // STEP 3: Display transfer details
        // ============================================================
        console.log("\n=======================================================");
        console.log("       EMERGENCY GATE OWNERSHIP TRANSFER");
        console.log("=======================================================");
        console.log("Gate Address:       ", gateAddress);
        console.log("Vault (protected):  ", gate.vault());
        console.log("Current Mode:       ", gate.getModeString());
        console.log("-------------------------------------------------------");
        console.log("Current Owner:      ", currentOwner);
        console.log("Transaction Signer: ", signer);
        console.log("New Owner:          ", newOwner);
        console.log("=======================================================");

        // Verify the signer is the current owner
        if (signer != currentOwner) {
            console.log("\n[ERROR] Transaction signer is NOT the current owner!");
            console.log("Expected owner:", currentOwner);
            console.log("Your address:  ", signer);
            revert("Unauthorized: signer must be current gate owner");
        }

        // Warn if new owner is the same as current owner
        if (newOwner == currentOwner) {
            console.log("\n[WARNING] New owner is the same as current owner!");
            console.log("This transaction will have no effect.");
        }

        console.log("\n[READY] Transferring gate ownership to:", newOwner);
        console.log("Press Ctrl+C to cancel, or wait to continue...\n");

        // ============================================================
        // STEP 4: Execute ownership transfer
        // ============================================================
        vm.startBroadcast(ownerPrivateKey);

        gate.transferOwnership(newOwner);
        console.log("[TX] Ownership transferred to:", newOwner);

        vm.stopBroadcast();

        // ============================================================
        // STEP 5: Verify transfer was successful
        // ============================================================
        address finalOwner = gate.owner();

        console.log("\n=======================================================");
        console.log("              TRANSFER COMPLETE");
        console.log("=======================================================");
        console.log("Previous Owner:     ", currentOwner);
        console.log("New Owner:          ", finalOwner);

        bool success = (finalOwner == newOwner);

        if (success) {
            console.log("\n[SUCCESS] Gate ownership transferred successfully!");
        } else {
            console.log("\n[ERROR] Ownership transfer failed!");
            console.log("Expected:", newOwner);
            console.log("Actual:  ", finalOwner);
        }

        console.log("=======================================================");

        // Post-transfer verification command
        console.log("\nVerify on-chain with:");
        console.log("cast call", gateAddress, '"owner()" --rpc-url https://rpc.hyperliquid.xyz/evm');
        console.log("\n=======================================================\n");
    }
}
