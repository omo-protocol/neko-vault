// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";

/**
 * @title ConfigureAdapter
 * @notice Adapter strategy configuration (Step 2d)
 * @dev Run AFTER 2c_ConfigureFees.s.sol
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *
 * Usage:
 *   source .env && forge script script/2d_ConfigureAdapter.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 1 (adapter.setStrategy)
 */
contract ConfigureAdapter is Script {
    // Strategy IDs (must match deployment script)
    bytes32 constant ALM_STRATEGY_ID = keccak256("alm-whype-sthype");
    uint256 constant DAILY_LIMIT = 10000e18; // 10,000 tokens daily limit - this param already ignored in adapter

    // Configuration parameters (must match deployment script)
    address constant ADAPTER_ADDRESS = 0x5Bc418252Fd72b4dF7feCc297caF50B23f9Ee6cA; // config to adapter address

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load deployed adapter address
        address adapterAddress = ADAPTER_ADDRESS;
        require(adapterAddress != address(0), "ADAPTER_ADDRESS must be set");

        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));

        console.log("\n=================================================");
        console.log("    ADAPTER CONFIGURATION (Step 2d)");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("Adapter:", adapterAddress);
        console.log("Transactions: 1");

        vm.startBroadcast(deployerPrivateKey);

        // Configure adapter strategy
        console.log("\n[Step 1/1] Configuring adapter strategy...");
        adapter.setStrategy(
            ALM_STRATEGY_ID,
            0x28572bC31Dc4f271d2377c47632ebfcB4CDf8e88, // strategyAgent
            "", // No pre-configured data
            DAILY_LIMIT // Daily limit
        );
        console.log("  Strategy configured:");
        console.log("    Strategy ID:", vm.toString(ALM_STRATEGY_ID));
        console.log("    Strategy Agent:", deployer);
        console.log("    Daily Limit:", DAILY_LIMIT / 1e18, "tokens");

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    STEP 2d COMPLETE!");
        console.log("=================================================");
        console.log("Configuration:");
        console.log("  Strategy ID:", vm.toString(ALM_STRATEGY_ID));
        console.log("  Strategy Agent:", deployer);

        console.log("\n[SUCCESS] All vault configuration complete!");
        console.log("\nNext Steps:");
        console.log("  1. Test deposit/withdraw flows");
        console.log("  2. Test allocation/deallocation");
        console.log("  3. Transfer ownership (script/3_TransferVaultOwner.s.sol)");
    }
}
