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
 * @dev Uses existing VaultV2Factory if VAULT_FACTORY_ADDRESS is set, otherwise deploys new factory
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer private key
 *   - ASSET_ADDRESS: ERC20 asset address for the vault
 *
 * Optional Environment Variables:
 *   - VAULT_FACTORY_ADDRESS: Address of existing VaultV2Factory (if not set, deploys new factory)
 *
 * Usage with existing factory:
 *   PRIVATE_KEY=0x... ASSET_ADDRESS=0x... VAULT_FACTORY_ADDRESS=0x... \
 *   forge script script/DeployALMVault.s.sol --rpc-url <RPC_URL> --broadcast -v
 *
 * Usage without existing factory (will deploy new factory):
 *   PRIVATE_KEY=0x... ASSET_ADDRESS=0x... \
 *   forge script script/DeployALMVault.s.sol --rpc-url <RPC_URL> --broadcast -v
 */
contract DeployUniversalAdapterEscrow is Script {
    // Strategy IDs
    bytes32 constant PT_LOOP_STRATEGY_ID = keccak256("pt-khype-loop");
    bytes idData = abi.encodePacked(PT_LOOP_STRATEGY_ID);
    uint256 constant RELATIVE_CAP = 1e18; // 100% of vault assets (1e18 = 100%)
    uint256 constant DAILY_LIMIT = 10000e18; // 10,000 tokens daily limit - this param alreadyed ignored in adapter
    address asset = 0x5555555555555555555555555555555555555555; // WHYPE
    address vaultFactoryAddress = 0x0000000000000000000000000000000000000000; // config to vault factory address
    address constant ALLOCATOR = 0x0000000000000000000000000000000000000000; // config to worker wallet address

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(asset != address(0), "ASSET_ADDRESS must be set");

        console.log("\n=================================================");
        console.log("    UNIVERSAL ADAPTER ESCROW DEPLOYMENT");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("Asset:", asset);

        bytes32 salt = keccak256(abi.encodePacked(
            "vault-v2",
            PT_LOOP_STRATEGY_ID,
            deployer,
            asset
        ));

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Get or deploy VaultV2Factory
        VaultV2Factory vaultFactory;

        if (vaultFactoryAddress != address(0)) {
            // Use existing factory
            vaultFactory = VaultV2Factory(vaultFactoryAddress);
            console.log("\n[Using existing VaultV2Factory]");
            console.log("VaultV2Factory:", address(vaultFactory));
        } else {
            // Deploy new factory
            vaultFactory = new VaultV2Factory();
            console.log("\n[Deployed new VaultV2Factory]");
            console.log("VaultV2Factory:", address(vaultFactory));
        }

        UniversalAdapterEscrowFactory adapterFactory = new UniversalAdapterEscrowFactory();
        console.log("AdapterFactory deployed:", address(adapterFactory));

        // Step 2: Deploy valuer
        UniversalValuerOffchain valuer = new UniversalValuerOffchain(deployer, asset);
        console.log("Valuer deployed:", address(valuer));

        // Configure valuer
        valuer.initiateSignerChange(deployer, true, 100);
        valuer.setRequiredWeight(90); // 90% of required weight

        valuer.configureStrategy(
            PT_LOOP_STRATEGY_ID,
            60,        // minUpdateInterval: 1 minutes
            3600,       // maxStaleness: 1 hour
            500,        // pushThreshold: 5% change triggers update
            90          // minConfidence: 90% (must be >= defaultConfidenceThreshold)
        );

        // Set price change bounds (50% max change)
        valuer.setPriceChangeBounds(PT_LOOP_STRATEGY_ID, 5000);

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
            PT_LOOP_STRATEGY_ID,
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
        console.log("  VaultV2Factory:", address(vaultFactory), vaultFactoryAddress != address(0) ? "(existing)" : "(new)");
        console.log("  VaultV2:", address(vault));
        console.log("  UniversalAdapterEscrow:", address(adapter));
        console.log("  UniversalValuerOffchain:", address(valuer));
        console.log("\n[SUCCESS] Infrastructure deployed!");

        if (vaultFactoryAddress == address(0)) {
            console.log("\nNote: A new VaultV2Factory was deployed.");
            console.log("To reuse this factory in future deployments, set:");
            console.log("  export VAULT_FACTORY_ADDRESS=", address(vaultFactory));
        }
    }
}