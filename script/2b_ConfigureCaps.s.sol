// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title ConfigureCaps
 * @notice Caps configuration - absolute and relative caps (Step 2b)
 * @dev Run AFTER 2a_ConfigureVaultCore.s.sol
 *      Run 2c_ConfigureFees.s.sol next
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/curator private key
 *
 * Usage:
 *   source .env && forge script script/2b_ConfigureCaps.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 4 (submit + execute for absolute cap, submit + execute for relative cap)
 */
contract ConfigureCaps is Script {
     // Pass the STRING, let VaultV2 hash it
    bytes idData = bytes("alm-whype-sthype");
    uint256 constant RELATIVE_CAP = 1e18; // 100%

    // Configuration parameters
    address constant VAULT_ADDRESS = 0x9ad2E9a260365C1214Ab70C74f975A661AE5be61;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS must be set");

        VaultV2 vault = VaultV2(VAULT_ADDRESS);

        console.log("\n=================================================");
        console.log("    CAPS CONFIGURATION (FIXED)");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("VaultV2:", VAULT_ADDRESS);
        console.log("Strategy String: alm-whype-sthype");

        // Calculate what the hash will be
        bytes32 expectedHash = keccak256(bytes("alm-whype-sthype"));
        console.log("Expected Hash:");
        console.logBytes32(expectedHash);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Set absolute cap (2 transactions)
        console.log("\n[Step 1/2] Setting absolute cap...");
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);
        console.log("  Absolute cap set to MAX");

        // Step 2: Set relative cap (2 transactions)
        console.log("\n[Step 2/2] Setting relative cap...");
        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, RELATIVE_CAP)));
        vault.increaseRelativeCap(idData, RELATIVE_CAP);
        console.log("  Relative cap set to:", RELATIVE_CAP / 1e16, "%");

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    CAPS SET SUCCESSFULLY!");
        console.log("=================================================");
        console.log("Caps stored under:");
        console.logBytes32(expectedHash);
        console.log("\nNext Step:");
        console.log("  Verify with: cast call <vault> \"caps(bytes32)(uint256,uint256)\" <hash>");
    }
}
