// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title UpdateAllocator
 * @notice Update allocator address for VaultV2 using timelock pattern
 */
contract UpdateAllocator is Script {
    VaultV2 vault = VaultV2(0x9ad2E9a260365C1214Ab70C74f975A661AE5be61);

    address constant OLD_ALLOCATOR = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    address constant NEW_ALLOCATOR = 0x6D6A66C90C65b21768D67E9c69F393b887203820;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n================================================================");
        console.log("    UPDATE ALLOCATOR");
        console.log("================================================================");
        console.log("Vault:", address(vault));
        console.log("Deployer:", deployer);
        console.log("Old Allocator:", OLD_ALLOCATOR);
        console.log("New Allocator:", NEW_ALLOCATOR);

        vm.startBroadcast(deployerPrivateKey);

        // Check current curator
        address curator = vault.curator();
        console.log("\nCurrent curator:", curator);

        // Step 1: Remove old allocator
        console.log("\n[1/4] Submitting removal of old allocator...");
        bytes memory removeData = abi.encodeCall(IVaultV2.setIsAllocator, (OLD_ALLOCATOR, false));
        vault.submit(removeData);
        console.log("  \u2713 Submitted");

        console.log("\n[2/4] Executing removal...");
        vault.setIsAllocator(OLD_ALLOCATOR, false);
        console.log("  \u2713 Old allocator removed");

        // Step 2: Add new allocator
        console.log("\n[3/4] Submitting addition of new allocator...");
        bytes memory addData = abi.encodeCall(IVaultV2.setIsAllocator, (NEW_ALLOCATOR, true));
        vault.submit(addData);
        console.log("  \u2713 Submitted");

        console.log("\n[4/4] Executing addition...");
        vault.setIsAllocator(NEW_ALLOCATOR, true);
        console.log("  \u2713 New allocator added");

        vm.stopBroadcast();

        // Verify changes
        bool oldIsAllocator = vault.isAllocator(OLD_ALLOCATOR);
        bool newIsAllocator = vault.isAllocator(NEW_ALLOCATOR);

        console.log("\n================================================================");
        console.log("    VERIFICATION");
        console.log("================================================================");
        console.log("Old allocator status:", oldIsAllocator ? "ACTIVE" : "REMOVED");
        console.log("New allocator status:", newIsAllocator ? "ACTIVE" : "INACTIVE");

        if (!oldIsAllocator && newIsAllocator) {
            console.log("\n  \u2713\u2713\u2713 ALLOCATOR UPDATE SUCCESSFUL \u2713\u2713\u2713");
        } else {
            console.log("\n  \u26a0\ufe0f  WARNING: Verification failed!");
        }

        console.log("\n================================================================");
        console.log("    UPDATE COMPLETE");
        console.log("================================================================\n");
    }
}
