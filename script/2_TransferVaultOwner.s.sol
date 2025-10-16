// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";

/**
 * @title TransferVaultOwner
 * @notice Script to transfer ownership of VaultV2 to a new owner
 * @dev Calls the setOwner function on VaultV2 contract
 *
 * SECURITY NOTICE:
 * ================
 * - VaultV2.setOwner() is a DIRECT ownership transfer (not two-step)
 * - Once executed, ownership transfers IMMEDIATELY to the new owner
 * - ALWAYS verify the new owner address is correct before running
 * - The transaction signer MUST be the current vault owner
 *
 * ENVIRONMENT VARIABLES:
 * ======================
 * Required:
 *   - PRIVATE_KEY: Private key of the CURRENT owner
 *   - VAULT_ADDRESS: Address of the VaultV2 contract
 *   - NEW_OWNER: Address of the new owner
 *
 * USAGE EXAMPLE:
 * ==============
 * PRIVATE_KEY=0x123... \
 * VAULT_ADDRESS=0xABC... \
 * NEW_OWNER=0xDEF... \
 * forge script script/2_TransferVaultOwner.s.sol \
 *   --rpc-url https://rpc.hyperliquid.xyz/evm \
 *   --broadcast -v
 *
 * VERIFY BEFORE EXECUTING:
 * ========================
 * 1. Double-check NEW_OWNER address is correct
 * 2. Verify PRIVATE_KEY corresponds to current vault owner
 * 3. Consider doing a dry-run first (remove --broadcast flag)
 */
contract TransferVaultOwner is Script {

    address vaultAddress = 0x0000000000000000000000000000000000000000; // config to vault address
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

        // ============================================================
        // STEP 3: Display transfer details
        // ============================================================
        console.log("\n=======================================================");
        console.log("         VAULT OWNERSHIP TRANSFER");
        console.log("=======================================================");
        console.log("Vault Address:    ", vaultAddress);
        console.log("Current Owner:    ", actualOwner);
        console.log("Transaction Signer:", currentOwner);
        console.log("New Owner:        ", newOwner);
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

        console.log("\n[READY] Transferring ownership to:", newOwner);
        console.log("Press Ctrl+C to cancel, or wait to continue...\n");

        // ============================================================
        // STEP 4: Execute ownership transfer
        // ============================================================
        vm.startBroadcast(ownerPrivateKey);

        vault.setOwner(newOwner);

        vm.stopBroadcast();

        // ============================================================
        // STEP 5: Verify transfer was successful
        // ============================================================
        address finalOwner = vault.owner();

        console.log("\n=======================================================");
        console.log("         TRANSFER COMPLETE");
        console.log("=======================================================");
        console.log("Previous Owner:   ", actualOwner);
        console.log("New Owner:        ", finalOwner);

        if (finalOwner == newOwner) {
            console.log("\n[SUCCESS] Ownership transferred successfully!");
        } else {
            console.log("\n[ERROR] Ownership transfer failed!");
            console.log("Expected:", newOwner);
            console.log("Actual:  ", finalOwner);
        }

        console.log("=======================================================\n");
    }
}
