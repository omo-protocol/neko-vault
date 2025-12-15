// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import "../src/adapters/UniversalAdapterEscrowFactory.sol";
import "../src/VaultV2.sol";
import "../src/valuers/UniversalValuerOffchain.sol";

/**
 * @title DeployALMAdapter
 * @notice Deploy UniversalAdapterEscrow for ALM WHYPE-stHYPE strategy
 * @dev Deploys adapter with "alm-whype-sthype" strategy ID
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   VAULT_ADDRESS=0x... \
 *   VALUER_ADDRESS=0x... \
 *   FACTORY_ADDRESS=0x... \
 *   forge script script/2_DeployALMAdapter.s.sol --rpc-url <RPC_URL> --broadcast -v
 */
contract DeployALMAdapter is Script {
    // Strategy ID for ALM WHYPE-stHYPE
    bytes32 constant ALM_WHYPE_STHYPE_ID = keccak256("alm-whype-sthype");

    function run() public {
        // Load configuration from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address vaultAddress = 0x52463983595Bec55bd3b50eA98e48F285d12Cca7; // vm.envAddress("VAULT_ADDRESS");
        address valuerAddress = 0x6efFaDBbA88Fd0152dAe3dEDF72B7Ca1d6f0E657; // vm.envAddress("VALUER_ADDRESS");
        address factoryAddress = 0x06e02e736509A6C52ccE64be86E58022218f7255; // vm.envAddress("FACTORY_ADDRESS");

        require(vaultAddress != address(0), "VAULT_ADDRESS must be set");
        require(valuerAddress != address(0), "VALUER_ADDRESS must be set");
        require(factoryAddress != address(0), "FACTORY_ADDRESS must be set");

        console.log("\n================================================================");
        console.log("    DEPLOY ALM WHYPE-STHYPE ADAPTER");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Vault:", vaultAddress);
        console.log("Valuer:", valuerAddress);
        console.log("Factory:", factoryAddress);

        vm.startBroadcast(deployerPrivateKey);

        UniversalAdapterEscrowFactory factory = UniversalAdapterEscrowFactory(factoryAddress);

        // Deploy adapter using factory with CREATE2
        console.log("\n[1/2] Deploying adapter...");
        bytes32 salt = keccak256("alm-whype-sthype-adapter-v1");
        address adapterAddress = factory.deployAdapter(
            vaultAddress,
            valuerAddress,
            true,  // useOffchainValuer
            salt
        );
        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));
        console.log("  Adapter:", adapterAddress);

        // Register ALM WHYPE-stHYPE strategy
        console.log("\n[2/2] Registering ALM WHYPE-stHYPE strategy...");
        adapter.setStrategy(
            ALM_WHYPE_STHYPE_ID,
            deployer,              // strategy agent (can execute strategy)
            "",                     // no pre-configured data
            type(uint256).max       // no daily limit
        );
        console.log("  Strategy ID: alm-whype-sthype");
        console.log("  Agent:", deployer);

        vm.stopBroadcast();

        console.log("\n================================================================");
        console.log("    DEPLOYMENT COMPLETE");
        console.log("================================================================");
        console.log("\nAdapter:", adapterAddress);
        console.log("Strategy ID:", vm.toString(ALM_WHYPE_STHYPE_ID));
        console.log("\nNext Steps:");
        console.log("1. Configure function whitelists for ALM protocol");
        console.log("2. Add adapter to vault (if not already done)");
        console.log("3. Set vault caps for the strategy");
        console.log("================================================================\n");
    }
}
