// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title ConfigureFees
 * @notice Performance fee configuration (Step 2c)
 * @dev Run AFTER 2b_ConfigureCaps.s.sol
 *      Run 2d_ConfigureAdapter.s.sol next
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/curator private key
 *
 * Usage:
 *   source .env && forge script script/2c_ConfigureFees.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 4 (submit + execute for recipient, submit + execute for fee)
 *               or 0 if recipient not configured
 */
contract ConfigureFees is Script {
    // Configuration parameters
    address constant PERFORMANCE_FEE_RECIPIENT = 0xc88083Db7Fdcf1Ae52DF7E8aC89E29934677db4C;
    uint256 constant PERFORMANCE_FEE = 0.2e18; // 20%
    address constant VAULT_ADDRESS = 0x52463983595Bec55bd3b50eA98e48F285d12Cca7;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS must be set");

        VaultV2 vault = VaultV2(VAULT_ADDRESS);

        console.log("\n=================================================");
        console.log("    FEE CONFIGURATION (Step 2c)");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("VaultV2:", VAULT_ADDRESS);

        if (PERFORMANCE_FEE_RECIPIENT == address(0)) {
            console.log("\nSkipping: Performance fee recipient not configured");
            console.log("\nNext Step:");
            console.log("  Run: forge script script/2d_ConfigureAdapter.s.sol --rpc-url $RPC_URL --broadcast -v");
            return;
        }

        console.log("Transactions: 4");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Set performance fee recipient (2 transactions)
        console.log("\n[Step 1/2] Setting performance fee recipient...");
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (PERFORMANCE_FEE_RECIPIENT)));
        vault.setPerformanceFeeRecipient(PERFORMANCE_FEE_RECIPIENT);
        console.log("  Recipient set:", PERFORMANCE_FEE_RECIPIENT);

        // Step 2: Set performance fee (2 transactions)
        console.log("\n[Step 2/2] Setting performance fee...");
        vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (PERFORMANCE_FEE)));
        vault.setPerformanceFee(PERFORMANCE_FEE);
        console.log("  Fee set to:", PERFORMANCE_FEE / 1e16, "%");

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    STEP 2c COMPLETE!");
        console.log("=================================================");
        console.log("Configuration:");
        console.log("  Performance Fee Recipient:", PERFORMANCE_FEE_RECIPIENT);
        console.log("  Performance Fee:", PERFORMANCE_FEE / 1e16, "%");
        console.log("\nNext Step:");
        console.log("  Run: forge script script/2d_ConfigureAdapter.s.sol --rpc-url $RPC_URL --broadcast -v");
    }
}
