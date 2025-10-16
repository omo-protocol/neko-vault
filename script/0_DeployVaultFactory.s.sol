// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2Factory.sol";

/**
 * @title DeployVaultFactory
 * @notice Deploys only the VaultV2Factory contract
 * @dev This factory can be reused across multiple vault deployments
 *
 * Usage:
 *   PRIVATE_KEY=0x... forge script script/DeployVaultFactory.s.sol --rpc-url <RPC_URL> --broadcast -v
 */
contract DeployVaultFactory is Script {
    function run() public returns (address) {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n=================================================");
        console.log("    VAULT FACTORY DEPLOYMENT");
        console.log("=================================================");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy VaultV2Factory
        VaultV2Factory vaultFactory = new VaultV2Factory();
        console.log("\nVaultV2Factory deployed:", address(vaultFactory));

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    DEPLOYMENT COMPLETE!");
        console.log("=================================================");
        console.log("\nDeployed Contract:");
        console.log("  VaultV2Factory:", address(vaultFactory));
        console.log("\n[SUCCESS] Factory deployed!");
        console.log("\nTo use this factory in other scripts, set:");
        console.log("  export VAULT_FACTORY_ADDRESS=", address(vaultFactory));

        return address(vaultFactory);
    }
}
