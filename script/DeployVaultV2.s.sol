// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VaultV2Factory} from "../src/VaultV2Factory.sol";
import {VaultV2} from "../src/VaultV2.sol";
import {MorphoMarketV1AdapterFactory} from "../src/adapters/MorphoMarketV1AdapterFactory.sol";
import {MorphoVaultV1AdapterFactory} from "../src/adapters/MorphoVaultV1AdapterFactory.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title DeployVaultV2
 * @notice End-to-end deployment script for VaultV2 ecosystem based on INSTRUCTIONS.md
 * @dev Deploys: VaultV2Factory, VaultV2 instance, Adapter Factories, and configures initial setup
 */
contract DeployVaultV2 is Script {
    struct DeploymentConfig {
        address owner;
        address curator;
        address allocator;
        address sentinel;
        address asset;
        bytes32 salt;
        uint256 timelockDelay;
        address morphoAddress;
        bool deployAdapters;
    }

    struct DeploymentResult {
        address vaultFactory;
        address vault;
        address morphoMarketAdapterFactory;
        address morphoVaultAdapterFactory;
    }

    function run() external returns (DeploymentResult memory result) {
        DeploymentConfig memory config = _loadConfig();
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy VaultV2Factory
        result.vaultFactory = address(new VaultV2Factory());
        console.log("[SUCCESS] VaultV2Factory deployed at:", result.vaultFactory);

        // 2. Deploy VaultV2 instance
        if (config.asset != address(0)) {
            result.vault = VaultV2Factory(result.vaultFactory).createVaultV2(
                config.owner,
                config.asset,
                config.salt
            );
            console.log("[SUCCESS] VaultV2 deployed at:", result.vault);
            console.log("  Owner:", config.owner);
            console.log("  Asset:", config.asset);
        }

        // 3. Deploy Adapter Factories
        if (config.deployAdapters) {
            result.morphoMarketAdapterFactory = address(new MorphoMarketV1AdapterFactory());
            result.morphoVaultAdapterFactory = address(new MorphoVaultV1AdapterFactory());
            
            console.log("[SUCCESS] MorphoMarketV1AdapterFactory deployed at:", result.morphoMarketAdapterFactory);
            console.log("[SUCCESS] MorphoVaultV1AdapterFactory deployed at:", result.morphoVaultAdapterFactory);
        }

        vm.stopBroadcast();

        // 4. Log next steps
        _logNextSteps(config, result);
        
        return result;
    }

    /**
     * @notice Deploy only the VaultV2Factory
     */
    function deployFactory() external returns (address factory) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        factory = address(new VaultV2Factory());
        console.log("[SUCCESS] VaultV2Factory deployed at:", factory);

        vm.stopBroadcast();
        return factory;
    }

    /**
     * @notice Deploy a VaultV2 instance using existing factory
     */
    function deployVault(
        address factory,
        address owner,
        address asset,
        bytes32 salt
    ) external returns (address vault) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        vault = VaultV2Factory(factory).createVaultV2(owner, asset, salt);
        
        console.log("[SUCCESS] VaultV2 deployed at:", vault);
        console.log("  Owner:", owner);
        console.log("  Asset:", asset);

        vm.stopBroadcast();
        return vault;
    }

    /**
     * @notice Deploy adapter factories
     */
    function deployAdapterFactories() external returns (address morphoMarket, address morphoVault) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        morphoMarket = address(new MorphoMarketV1AdapterFactory());
        morphoVault = address(new MorphoVaultV1AdapterFactory());
        
        console.log("[SUCCESS] MorphoMarketV1AdapterFactory deployed at:", morphoMarket);
        console.log("[SUCCESS] MorphoVaultV1AdapterFactory deployed at:", morphoVault);

        vm.stopBroadcast();
        return (morphoMarket, morphoVault);
    }

    /**
     * @notice Load configuration from environment variables
     */
    function _loadConfig() internal view returns (DeploymentConfig memory config) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        config.owner = vm.envOr("VAULT_OWNER", deployer);
        config.curator = vm.envOr("VAULT_CURATOR", config.owner);
        config.allocator = vm.envOr("VAULT_ALLOCATOR", config.owner);
        config.sentinel = vm.envOr("VAULT_SENTINEL", address(0));
        config.asset = vm.envOr("VAULT_ASSET", address(0));
        config.salt = vm.envOr("VAULT_SALT", bytes32(0));
        config.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(1 days));
        config.morphoAddress = vm.envOr("MORPHO_ADDRESS", address(0));
        config.deployAdapters = vm.envOr("DEPLOY_ADAPTERS", true);
    }

    /**
     * @notice Log next steps for vault configuration
     */
    function _logNextSteps(DeploymentConfig memory config, DeploymentResult memory result) internal pure {
        console.log("\n=== NEXT STEPS ===");
        console.log("\n1. Set Roles (as Owner):");
        console.log("   - vault.setCurator(", config.curator, ")");
        if (config.allocator != address(0)) {
            console.log("   - vault.setIsAllocator(", config.allocator, ", true)");
        }
        if (config.sentinel != address(0)) {
            console.log("   - vault.setIsSentinel(", config.sentinel, ", true)");
        }
        
        console.log("\n2. Create Adapters (if needed):");
        if (result.morphoMarketAdapterFactory != address(0) && config.morphoAddress != address(0)) {
            console.log("   - MorphoMarketV1AdapterFactory.createMorphoMarketV1Adapter(vault, morpho)");
        }
        
        console.log("\n3. Configure Vault (as Curator, with timelocks):");
        console.log("   - Submit timelock: vault.submit(abi.encodeWithSelector(vault.addAdapter.selector, adapter))");
        console.log("   - Submit timelock: vault.submitTimelock(setAbsoluteCap.selector, abi.encode(ids, caps))");
        console.log("   - Wait for timelock period, then execute");
        
        console.log("\n4. Test Operations:");
        console.log("   - Deposit assets to vault");
        console.log("   - Allocator calls vault.allocate(adapter, data, assets)");
        console.log("   - Check vault.totalAssets() and adapter.realAssets()");
        
        console.log("\n[WARNING] IMPORTANT: Test on testnet first!");
    }
}