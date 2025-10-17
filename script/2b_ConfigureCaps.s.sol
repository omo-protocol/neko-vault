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
    // Strategy IDs (must match deployment script)
    bytes32 constant ALM_STRATEGY_ID = keccak256("alm-whype-sthype");
    bytes idData = abi.encodePacked(ALM_STRATEGY_ID);
    uint256 constant RELATIVE_CAP = 1e18; // 100%

    // Configuration parameters
    address constant VAULT_ADDRESS = 0x52463983595Bec55bd3b50eA98e48F285d12Cca7;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS must be set");

        VaultV2 vault = VaultV2(VAULT_ADDRESS);

        console.log("\n=================================================");
        console.log("    CAPS CONFIGURATION (Step 2b)");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("VaultV2:", VAULT_ADDRESS);
        console.log("Transactions: 4");

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
        console.log("    STEP 2b COMPLETE!");
        console.log("=================================================");
        console.log("Configuration:");
        console.log("  Absolute Cap: MAX");
        console.log("  Relative Cap:", RELATIVE_CAP / 1e16, "%");
        console.log("\nNext Step:");
        console.log("  Run: forge script script/2c_ConfigureFees.s.sol --rpc-url $RPC_URL --broadcast -v");
    }
}
