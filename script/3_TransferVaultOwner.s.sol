// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";

/**
 * @title TransferVaultOwner
 * @notice Script to transfer ownership of VaultV2 to a new owner and optionally set curator
 * @dev Calls the setOwner and optionally setCurator functions on VaultV2 contract
 *
 * SECURITY NOTICE:
 * ================
 * - VaultV2.setOwner() is a DIRECT ownership transfer (not two-step)
 * - Once executed, ownership transfers IMMEDIATELY to the new owner
 * - ALWAYS verify the new owner and curator addresses are correct before running
 * - The transaction signer MUST be the current vault owner
 *
 * ENVIRONMENT VARIABLES:
 * ======================
 * Required:
 *   - PRIVATE_KEY: Private key of the CURRENT owner
 *   - VAULT_ADDRESS: Address of the VaultV2 contract
 *   - NEW_OWNER: Address of the new owner
 *
 * Optional:
 *   - NEW_CURATOR: Address of the new curator (if not set, curator remains unchanged)
 *
 * USAGE EXAMPLE:
 * ==============
 * # Transfer ownership only
 * PRIVATE_KEY=0x123... \
 * VAULT_ADDRESS=0xABC... \
 * NEW_OWNER=0xDEF... \
 * forge script script/2_TransferVaultOwner.s.sol \
 *   --rpc-url https://rpc.hyperliquid.xyz/evm \
 *   --broadcast -v
 *
 * # Transfer ownership and set curator
 * PRIVATE_KEY=0x123... \
 * VAULT_ADDRESS=0xABC... \
 * NEW_OWNER=0xDEF... \
 * NEW_CURATOR=0xCUR... \
 * forge script script/2_TransferVaultOwner.s.sol \
 *   --rpc-url https://rpc.hyperliquid.xyz/evm \
 *   --broadcast -v
 *
 * VERIFY BEFORE EXECUTING:
 * ========================
 * 1. Double-check NEW_OWNER address is correct
 * 2. Double-check NEW_CURATOR address is correct (if setting)
 * 3. Verify PRIVATE_KEY corresponds to current vault owner
 * 4. Consider doing a dry-run first (remove --broadcast flag)
 */
contract TransferVaultOwner is Script {

    address vaultAddress = 0x0000000000000000000000000000000000000000; // config to vault address
    address constant newCurator = 0x0000000000000000000000000000000000000000; // config to new curator address (optional, 0x0 = no change)
    address newOwner = 0x0000000000000000000000000000000000000000; // config to new owner address

    function run() public {
        // ============================================================
        // STEP 1: Load environment variables
        // ============================================================
        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");
        address currentOwner = vm.addr(ownerPrivateKey);

        // Validate addresses
        require(vaultAddress != address(0), "VAULT_ADDRESS cannot be zero");
        require(newOwner != address(0), "NEW_OWNER cannot be zero");

        // ============================================================
        // STEP 2: Load vault and verify current state
        // ============================================================
        VaultV2 vault = VaultV2(vaultAddress);
        address actualOwner = vault.owner();
        address currentCurator = vault.curator();

        // ============================================================
        // STEP 3: Display transfer details
        // ============================================================
        console.log("\n=======================================================");
        console.log("         VAULT OWNERSHIP & CURATOR TRANSFER");
        console.log("=======================================================");
        console.log("Vault Address:      ", vaultAddress);
        console.log("Current Owner:      ", actualOwner);
        console.log("Transaction Signer: ", currentOwner);
        console.log("New Owner:          ", newOwner);
        console.log("-------------------------------------------------------");
        console.log("Current Curator:    ", currentCurator);
        if (newCurator != address(0)) {
            console.log("New Curator:        ", newCurator);
        } else {
            console.log("New Curator:         (no change)");
        }
        console.log("=======================================================");

        // Verify the signer is the current owner
        if (currentOwner != actualOwner) {
            console.log("\n[ERROR] Transaction signer is NOT the current owner!");
            console.log("Expected owner:", actualOwner);
            console.log("Your address:  ", currentOwner);
            revert("Unauthorized: signer must be current owner");
        }

        // Warn if new owner is the same as current owner
        if (newOwner == actualOwner) {
            console.log("\n[WARNING] New owner is the same as current owner!");
            console.log("This transaction will have no effect.");
        }

        if (newCurator != address(0)) {
            console.log("\n[READY] Transferring ownership to:", newOwner);
            console.log("[READY] Setting curator to:", newCurator);
        } else {
            console.log("\n[READY] Transferring ownership to:", newOwner);
            console.log("[READY] Curator will remain unchanged");
        }
        console.log("Press Ctrl+C to cancel, or wait to continue...\n");

        // ============================================================
        // STEP 4: Execute ownership transfer and set curator
        // ============================================================
        vm.startBroadcast(ownerPrivateKey);

        // Set curator after owner transfer (if specified)
        if (newCurator != address(0)) {
            vault.setCurator(newCurator);
            console.log("[TX] Curator set to:", newCurator);
        }

        // Transfer ownership first
        vault.setOwner(newOwner);
        console.log("[TX] Ownership transferred to:", newOwner);

        vm.stopBroadcast();

        // ============================================================
        // STEP 5: Verify transfer was successful
        // ============================================================
        address finalOwner = vault.owner();
        address finalCurator = vault.curator();

        console.log("\n=======================================================");
        console.log("         TRANSFER COMPLETE");
        console.log("=======================================================");
        console.log("OWNERSHIP:");
        console.log("  Previous Owner:   ", actualOwner);
        console.log("  New Owner:        ", finalOwner);

        bool ownerSuccess = (finalOwner == newOwner);
        bool curatorSuccess = true; // Default to true if no curator change

        if (ownerSuccess) {
            console.log("  [SUCCESS] Ownership transferred successfully!");
        } else {
            console.log("  [ERROR] Ownership transfer failed!");
            console.log("  Expected:", newOwner);
            console.log("  Actual:  ", finalOwner);
        }

        console.log("\nCURATOR:");
        console.log("  Previous Curator: ", currentCurator);
        console.log("  New Curator:      ", finalCurator);

        if (newCurator != address(0)) {
            curatorSuccess = (finalCurator == newCurator);
            if (curatorSuccess) {
                console.log("  [SUCCESS] Curator set successfully!");
            } else {
                console.log("  [ERROR] Curator setting failed!");
                console.log("  Expected:", newCurator);
                console.log("  Actual:  ", finalCurator);
            }
        } else {
            console.log("  [INFO] Curator unchanged (not specified)");
        }

        console.log("=======================================================");

        if (ownerSuccess && curatorSuccess) {
            console.log("\n[SUCCESS] All changes completed successfully!\n");
        } else {
            console.log("\n[ERROR] Some changes failed!\n");
        }

        console.log("=======================================================\n");
    }
}
