// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (c) 2025 Morpho Association
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {VaultV2} from "../src/VaultV2.sol";
import {MorphoMarketV1AdapterFactory} from "../src/adapters/MorphoMarketV1AdapterFactory.sol";
import {MorphoVaultV1AdapterFactory} from "../src/adapters/MorphoVaultV1AdapterFactory.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title ConfigureVaultV2
 * @notice Post-deployment configuration script for VaultV2 based on INSTRUCTIONS.md
 * @dev Handles role setup, adapter creation, and timelock submissions
 */
contract ConfigureVaultV2 is Script {
    struct ConfigParams {
        address vault;
        address curator;
        address allocator;
        address sentinel;
        address morphoMarketAdapterFactory;
        address morphoVaultAdapterFactory;
        address morphoAddress;
        address morphoVaultAddress;
        uint256 timelockDelay;
    }

    /**
     * @notice Configure vault roles and initial setup
     */
    function configureRoles() external {
        ConfigParams memory config = _loadConfigParams();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        
        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(ownerPrivateKey);

        VaultV2 vault = VaultV2(config.vault);

        // Set curator
        if (config.curator != address(0)) {
            vault.setCurator(config.curator);
            console.log("[SUCCESS] Set curator to:", config.curator);
        }

        // Set allocator
        if (config.allocator != address(0)) {
            vault.setIsAllocator(config.allocator, true);
            console.log("[SUCCESS] Set allocator:", config.allocator);
        }

        // Set sentinel
        if (config.sentinel != address(0)) {
            vault.setIsSentinel(config.sentinel, true);
            console.log("[SUCCESS] Set sentinel:", config.sentinel);
        }

        vm.stopBroadcast();
    }

    /**
     * @notice Create adapters for the vault
     */
    function createAdapters() external returns (address morphoMarketAdapter, address morphoVaultAdapter) {
        ConfigParams memory config = _loadConfigParams();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Create MorphoMarketV1Adapter
        if (config.morphoMarketAdapterFactory != address(0) && config.morphoAddress != address(0)) {
            MorphoMarketV1AdapterFactory factory = MorphoMarketV1AdapterFactory(config.morphoMarketAdapterFactory);
            morphoMarketAdapter = factory.createMorphoMarketV1Adapter(config.vault, config.morphoAddress);
            console.log("[SUCCESS] Created MorphoMarketV1Adapter:", morphoMarketAdapter);
        }

        // Create MorphoVaultV1Adapter
        if (config.morphoVaultAdapterFactory != address(0) && config.morphoVaultAddress != address(0)) {
            MorphoVaultV1AdapterFactory factory = MorphoVaultV1AdapterFactory(config.morphoVaultAdapterFactory);
            morphoVaultAdapter = factory.createMorphoVaultV1Adapter(config.vault, config.morphoVaultAddress);
            console.log("[SUCCESS] Created MorphoVaultV1Adapter:", morphoVaultAdapter);
        }

        vm.stopBroadcast();
        return (morphoMarketAdapter, morphoVaultAdapter);
    }

    /**
     * @notice Submit timelock to enable an adapter
     */
    function submitEnableAdapterTimelock(address adapter) external {
        ConfigParams memory config = _loadConfigParams();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        require(adapter != address(0), "Invalid adapter address");
        
        uint256 curatorPrivateKey = vm.envUint("CURATOR_PRIVATE_KEY");
        vm.startBroadcast(curatorPrivateKey);

        VaultV2 vault = VaultV2(config.vault);
        
        // Submit timelock for addAdapter
        bytes memory data = abi.encodeWithSelector(vault.addAdapter.selector, adapter);
        vault.submit(data);
        
        console.log("[SUCCESS] Submitted timelock to enable adapter:", adapter);
        console.log("Wait", config.timelockDelay, "seconds before executing");

        vm.stopBroadcast();
    }

    /**
     * @notice Execute previously submitted timelock
     */
    function executeTimelock(bytes4 selector, bytes calldata data) external {
        ConfigParams memory config = _loadConfigParams();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        
        uint256 executorPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(executorPrivateKey);

        VaultV2 vault = VaultV2(config.vault);
        // Execute the function directly - timelock is checked automatically
        (bool success,) = address(vault).call(data);
        require(success, "Execution failed");
        
        console.log("[SUCCESS] Executed timelock for selector:", vm.toString(selector));

        vm.stopBroadcast();
    }

    /**
     * @notice Submit timelock to set absolute caps
     */
    function submitSetCapsTimelock(bytes32[] calldata ids, uint256[] calldata caps) external {
        ConfigParams memory config = _loadConfigParams();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        require(ids.length == caps.length, "Array length mismatch");
        
        uint256 curatorPrivateKey = vm.envUint("CURATOR_PRIVATE_KEY");
        vm.startBroadcast(curatorPrivateKey);

        VaultV2 vault = VaultV2(config.vault);
        
        // Submit timelock for increaseAbsoluteCap (individual caps)
        for (uint256 i = 0; i < ids.length; i++) {
            bytes memory idData = abi.encode(ids[i]);
            bytes memory data = abi.encodeWithSelector(vault.increaseAbsoluteCap.selector, idData, caps[i]);
            vault.submit(data);
        }
        
        console.log("[SUCCESS] Submitted timelock to set caps for", ids.length, "ids");
        console.log("Wait", config.timelockDelay, "seconds before executing");

        vm.stopBroadcast();
    }

    /**
     * @notice Get pending timelock info
     */
    function getPendingTimelock(bytes memory data) external view {
        ConfigParams memory config = _loadConfigParams();
        require(config.vault != address(0), "VAULT_ADDRESS not set");
        
        VaultV2 vault = VaultV2(config.vault);
        uint256 validAt = vault.executableAt(data);
        bytes4 selector = bytes4(data);
        uint256 pending = vault.pendingCount(selector);
        
        console.log("Pending timelock for selector:", vm.toString(selector));
        console.log("Valid at timestamp:", validAt);
        console.log("Current timestamp:", block.timestamp);
        console.log("Pending count:", pending);
        
        if (validAt > 0 && block.timestamp >= validAt) {
            console.log("[READY] Timelock can be executed");
        } else if (validAt > 0) {
            console.log("[WAITING]", validAt - block.timestamp, "seconds remaining");
        } else {
            console.log("[NONE] No pending timelock");
        }
    }

    /**
     * @notice Load configuration parameters from environment
     */
    function _loadConfigParams() internal view returns (ConfigParams memory config) {
        config.vault = vm.envAddress("VAULT_ADDRESS");
        config.curator = vm.envOr("VAULT_CURATOR", address(0));
        config.allocator = vm.envOr("VAULT_ALLOCATOR", address(0));
        config.sentinel = vm.envOr("VAULT_SENTINEL", address(0));
        config.morphoMarketAdapterFactory = vm.envOr("MORPHO_MARKET_ADAPTER_FACTORY", address(0));
        config.morphoVaultAdapterFactory = vm.envOr("MORPHO_VAULT_ADAPTER_FACTORY", address(0));
        config.morphoAddress = vm.envOr("MORPHO_ADDRESS", address(0));
        config.morphoVaultAddress = vm.envOr("MORPHO_VAULT_ADDRESS", address(0));
        config.timelockDelay = vm.envOr("TIMELOCK_DELAY", uint256(1 days));
    }
}