// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/libraries/ConstantsLib.sol";

/**
 * @title SetMaxRate
 * @notice Set the maxRate on VaultV2 to allow interest accrual
 * @dev Must be called by an allocator address
 *
 * Problem:
 *   - When maxRate = 0, totalAssets() is capped at the cached _totalAssets value
 *   - This prevents the vault from recognizing interest/gains from adapters
 *   - Formula: newTotalAssets = min(realAssets, _totalAssets + interest_at_maxRate)
 *
 * Solution:
 *   - Set maxRate to MAX_MAX_RATE (200% APR) to allow full interest accrual
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Allocator private key (must be an allocator on the vault)
 *   - RPC_URL: Network RPC endpoint
 *
 * Usage:
 *   source .env && forge script script/SetMaxRate.s.sol --rpc-url $RPC_URL --broadcast -v
 */
contract SetMaxRate is Script {
    // Configuration - UPDATE THESE VALUES
    address constant VAULT_ADDRESS = 0xf317CEcaf2973D1C1a323784c2eE2Fdd544Ea359;
    
    // MAX_MAX_RATE = 200e16 / 365 days = ~63419583967529 per second
    // This allows up to 200% APR interest accrual rate
    uint256 constant NEW_MAX_RATE = MAX_MAX_RATE;

    function run() public {
        uint256 allocatorPrivateKey = vm.envUint("PRIVATE_KEY");
        address allocator = vm.addr(allocatorPrivateKey);

        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS must be set");

        VaultV2 vault = VaultV2(VAULT_ADDRESS);

        console.log("\n=================================================");
        console.log("    SET MAX RATE");
        console.log("=================================================");
        console.log("Allocator:", allocator);
        console.log("VaultV2:", VAULT_ADDRESS);
        console.log("Current maxRate:", vault.maxRate());
        console.log("New maxRate:", NEW_MAX_RATE);
        console.log("MAX_MAX_RATE:", MAX_MAX_RATE);

        // Verify caller is an allocator
        // require(vault.isAllocator(allocator), "Caller is not an allocator");

        vm.startBroadcast(allocatorPrivateKey);

        // Set the maxRate to MAX_MAX_RATE
        console.log("\n[Setting maxRate...]");
        vault.setMaxRate(NEW_MAX_RATE);
        console.log("  maxRate set successfully");

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    MAX RATE SET COMPLETE!");
        console.log("=================================================");
        console.log("New maxRate:", vault.maxRate());
        console.log("\nThe vault can now accrue interest up to 200% APR.");
        console.log("totalAssets() will now reflect real adapter values.");
    }
}
