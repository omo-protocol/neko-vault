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
    bytes32 constant ALM_STRATEGY_ID = keccak256("alm-whype-wsthype");
    bytes idData = abi.encodePacked(ALM_STRATEGY_ID);
    uint256 constant RELATIVE_CAP = 1e18; // 100% of vault assets (1e18 = 100%)
    uint256 constant DAILY_LIMIT = 10000e18; // 10,000 tokens daily limit - this param alreadyed ignored in adapter
    address constant ALLOCATOR = 0x6D6A66C90C65b21768D67E9c69F393b887203820; // config to worker wallet address

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

        bytes32 salt = keccak256(abi.encodePacked(
            "vault-v2",
            ALM_STRATEGY_ID,
            deployer,
            asset
        ));

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
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (ALLOCATOR, true)));
        vault.setIsAllocator(ALLOCATOR, true);

        // Set caps
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);

        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, RELATIVE_CAP)));
        vault.increaseRelativeCap(idData, RELATIVE_CAP);

        // Step 6: Configure adapter
        adapter.setStrategy(
            ALM_STRATEGY_ID,
            deployer, // strategyAgent
            "", // No pre-configured data
            DAILY_LIMIT // Daily limit
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