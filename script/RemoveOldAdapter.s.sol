// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title RemoveOldAdapter
 * @notice Remove the old non-existent adapter from vault
 */
contract RemoveOldAdapter is Script {
    VaultV2 vault = VaultV2(0x9ad2E9a260365C1214Ab70C74f975A661AE5be61);
    address oldAdapter = 0x16EdC598745aE934BD0eaa35CC844C76d621CD3B;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n================================================================");
        console.log("    REMOVE OLD ADAPTER");
        console.log("================================================================");
        console.log("Vault:", address(vault));
        console.log("Old Adapter:", oldAdapter);

        // Check current state
        bool isOldAdapterRegistered = vault.isAdapter(oldAdapter);
        console.log("\nOld adapter registered:", isOldAdapterRegistered);

        if (!isOldAdapterRegistered) {
            console.log("Old adapter already removed");
            return;
        }

        vm.startBroadcast(deployerPrivateKey);

        // Submit removal
        console.log("\n[1/2] Submitting removeAdapter...");
        bytes memory removeAdapterData = abi.encodeCall(IVaultV2.removeAdapter, (oldAdapter));
        vault.submit(removeAdapterData);
        console.log("  \u2713 Submitted");

        // Execute removal
        console.log("\n[2/2] Executing removeAdapter...");
        vault.removeAdapter(oldAdapter);
        console.log("  \u2713 Old adapter removed");

        vm.stopBroadcast();

        // Verify
        bool finalIsRegistered = vault.isAdapter(oldAdapter);
        console.log("\nFinal state:");
        console.log("  Old adapter registered:", finalIsRegistered);

        if (!finalIsRegistered) {
            console.log("\n  \u2713\u2713\u2713 OLD ADAPTER REMOVED \u2713\u2713\u2713");
        }

        console.log("\n================================================================");
        console.log("    REMOVAL COMPLETE");
        console.log("================================================================\n");
    }
}