// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/VaultV2Factory.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import "../src/adapters/UniversalAdapterEscrowFactory.sol";
import "../src/valuers/UniversalValuerOffchain.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";
import {IUniversalAdapterEscrow} from "../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

/**
 * @title DeployUniversalAdapterEscrow
 * @notice Production deployment script for VaultV2 with UniversalAdapterEscrow
 */
contract DeployUniversalAdapterEscrow is Script {
    // Strategy IDs
    bytes32 constant PT_KHYPE_LOOP_ID = keccak256("pt-khype-loop");

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load required configuration
        address asset = vm.envAddress("ASSET_ADDRESS");
        require(asset != address(0), "ASSET_ADDRESS must be set");

        console.log("\n=================================================");
        console.log("    UNIVERSAL ADAPTER ESCROW DEPLOYMENT");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("Asset:", asset);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Deploy factories
        VaultV2Factory vaultFactory = new VaultV2Factory();
        console.log("\nVaultV2Factory deployed:", address(vaultFactory));

        UniversalAdapterEscrowFactory adapterFactory = new UniversalAdapterEscrowFactory();
        console.log("AdapterFactory deployed:", address(adapterFactory));

        // Step 2: Deploy valuer
        UniversalValuerOffchain valuer = new UniversalValuerOffchain(deployer, asset);
        console.log("Valuer deployed:", address(valuer));

        // Configure valuer
        valuer.initiateSignerChange(deployer, true, 100);
        valuer.setRequiredWeight(100);

        // Step 3: Deploy VaultV2
        bytes32 salt = keccak256("vault-v2-deployment");
        address vaultAddress = vaultFactory.createVaultV2(deployer, asset, salt);
        VaultV2 vault = VaultV2(vaultAddress);
        console.log("VaultV2 deployed:", vaultAddress);

        // Step 4: Deploy UniversalAdapterEscrow
        address adapterAddress = adapterFactory.deployAdapter(
            address(vault),
            address(valuer),
            false, // useOffchainValuer
            salt
        );
        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));
        console.log("Adapter deployed:", adapterAddress);

        // Step 5: Configure vault
        vault.setCurator(deployer);

        // Add adapter
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        vault.addAdapter(address(adapter));

        // Set allocator
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (deployer, true)));
        vault.setIsAllocator(deployer, true);

        // Set caps for PT-KHYPE strategy
        bytes memory idData = abi.encodePacked("pt-khype-loop");
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);

        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);

        // Step 6: Configure adapter
        adapter.setStrategy(
            PT_KHYPE_LOOP_ID,
            deployer, // strategyAgent
            "", // No pre-configured data
            10000e18 // Daily limit
        );

        vm.stopBroadcast();

        // Final status
        console.log("\n=================================================");
        console.log("    DEPLOYMENT COMPLETE!");
        console.log("=================================================");
        console.log("\nDeployed Contracts:");
        console.log("  VaultV2:", address(vault));
        console.log("  UniversalAdapterEscrow:", address(adapter));
        console.log("  UniversalValuerOffchain:", address(valuer));
        console.log("\n[SUCCESS] Infrastructure deployed!");
    }
}