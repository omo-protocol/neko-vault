// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrowFactory.sol";

/**
 * @title DeployAdapterFactory
 * @notice Deploys only the UniversalAdapterEscrowFactory contract
 * @dev This factory can be reused across multiple adapter deployments
 *
 * Usage:
 *   PRIVATE_KEY=0x... forge script script/1_DeployAdapterFactory.s.sol --rpc-url <RPC_URL> --broadcast -v
 */
contract DeployAdapterFactory is Script {
    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n=================================================");
        console.log("    ADAPTER FACTORY DEPLOYMENT");
        console.log("=================================================");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy UniversalAdapterEscrowFactory
        UniversalAdapterEscrowFactory adapterFactory = new UniversalAdapterEscrowFactory();
        console.log("\nUniversalAdapterEscrowFactory deployed:", address(adapterFactory));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    DEPLOYMENT COMPLETE!");
        console.log("=================================================");
        console.log("\nDeployed Contract:");
        console.log("  UniversalAdapterEscrowFactory:", address(adapterFactory));
        console.log("\n[SUCCESS] Adapter factory deployed!");
    }
}
