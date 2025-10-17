// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";

/**
 * @title ConfigureAdapter
 * @notice Adapter strategy configuration script (Step 3 after vault configuration)
 * @dev This script should be run AFTER 2_ConfigureALMVault.s.sol
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *   - ADAPTER_ADDRESS: Address of deployed UniversalAdapterEscrow
 *
 * Usage:
 *   PRIVATE_KEY=0x... ADAPTER_ADDRESS=0x... \
 *   forge script script/3_ConfigureAdapter.s.sol --rpc-url <RPC_URL> --broadcast -v
 *
 * Note: This is separated from vault configuration to avoid nonce issues
 */
contract ConfigureAdapter is Script {
    // Strategy IDs (must match deployment script)
    bytes32 constant ALM_STRATEGY_ID = keccak256("alm-whype-wsthype");
    uint256 constant DAILY_LIMIT = 10000e18; // 10,000 tokens daily limit - this param already ignored in adapter

    // Configuration parameters (must match deployment script)
    address constant ADAPTER_ADDRESS = 0xE7537bB191a6FfcD73eED7b2e720F5918Ba7E7E8; // config to adapter address

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load deployed adapter address
        address adapterAddress = ADAPTER_ADDRESS;
        require(adapterAddress != address(0), "ADAPTER_ADDRESS must be set");

        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));

        console.log("\n=================================================");
        console.log("    ADAPTER STRATEGY CONFIGURATION");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("Adapter:", adapterAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Configure adapter strategy
        console.log("\n[Step 1] Configuring adapter strategy...");
        adapter.setStrategy(
            ALM_STRATEGY_ID,
            deployer, // strategyAgent
            "", // No pre-configured data
            DAILY_LIMIT // Daily limit
        );
        console.log("  Strategy configured:");
        console.log("    Strategy ID:", vm.toString(ALM_STRATEGY_ID));
        console.log("    Strategy Agent:", deployer);
        console.log("    Daily Limit:", DAILY_LIMIT / 1e18, "tokens");

        vm.stopBroadcast();

        // Final status
        console.log("\n=================================================");
        console.log("    ADAPTER CONFIGURATION COMPLETE!");
        console.log("=================================================");
        console.log("\nAdapter Configuration Summary:");
        console.log("  Strategy ID:", vm.toString(ALM_STRATEGY_ID));
        console.log("  Strategy Agent:", deployer);
        console.log("  Daily Limit:", DAILY_LIMIT / 1e18, "tokens");

        console.log("\n[SUCCESS] Adapter is now ready for allocations!");
        console.log("\nNext Steps:");
        console.log("  1. Verify adapter configuration");
        console.log("  2. Test allocation/deallocation flows");
        console.log("  3. Transfer ownership if needed");
    }
}
