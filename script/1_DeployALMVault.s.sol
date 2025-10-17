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
 * @title DeployALMVault
 * @notice Lightweight deployment script for VaultV2 with UniversalAdapterEscrow (Step 1)
 * @dev Uses existing infrastructure deployed by 0_DeployInfrastructure.s.sol
 *
 * Prerequisites:
 *   Run 0_DeployInfrastructure.s.sol first to deploy factories and valuer
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer private key
 *   - VAULT_FACTORY_ADDRESS: Address of deployed VaultV2Factory
 *   - ADAPTER_FACTORY_ADDRESS: Address of deployed UniversalAdapterEscrowFactory
 *   - VALUER_ADDRESS: Address of deployed UniversalValuerOffchain
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   VAULT_FACTORY_ADDRESS=0x... \
 *   ADAPTER_FACTORY_ADDRESS=0x... \
 *   VALUER_ADDRESS=0x... \
 *   forge script script/1_DeployALMVault.s.sol --rpc-url <RPC_URL> --broadcast -v
 */
contract DeployALMVault is Script {
    // Strategy IDs (must match 0_DeployInfrastructure.s.sol)
    bytes32 constant ALM_STRATEGY_ID = keccak256("alm-whype-sthype");

    // Asset configuration
    address asset = 0x5555555555555555555555555555555555555555; // WHYPE
    address vaultFactoryAddress = 0xA51F4C9eFc32853b85aaB3F8BF4c2FbDD4a9C4FD; // config to vault factory address
    address adapterFactoryAddress = 0xa1C151cd69De3bb49B974d0F4A38DB3c68D2868f; // config to adapter factory address
    address valuerAddress = 0x6efFaDBbA88Fd0152dAe3dEDF72B7Ca1d6f0E657; // config to valuer address

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load infrastructure addresses from environment or use defaults
        // address vaultFactoryAddress = vm.envOr("VAULT_FACTORY_ADDRESS", address(0x0cFDf4B65cd36b85D6e66AE87D75eFE4260c883E));
        // address adapterFactoryAddress = vm.envOr("ADAPTER_FACTORY_ADDRESS", address(0));
        // address valuerAddress = vm.envOr("VALUER_ADDRESS", address(0));

        // Validate required addresses
        require(vaultFactoryAddress != address(0), "VAULT_FACTORY_ADDRESS must be set");
        require(adapterFactoryAddress != address(0), "ADAPTER_FACTORY_ADDRESS must be set");
        require(valuerAddress != address(0), "VALUER_ADDRESS must be set");
        require(asset != address(0), "Asset address must be set");

        // Create deterministic salt
        bytes32 salt = keccak256(abi.encodePacked(
            "vault-v2",
            ALM_STRATEGY_ID,
            deployer,
            asset
        ));

        vm.startBroadcast(deployerPrivateKey);

        // Load infrastructure contracts
        VaultV2Factory vaultFactory = VaultV2Factory(vaultFactoryAddress);
        UniversalAdapterEscrowFactory adapterFactory = UniversalAdapterEscrowFactory(adapterFactoryAddress);

        // Step 1: Deploy VaultV2
        console.log("\n[Step 1] Deploying VaultV2...");
        address vaultAddress = vaultFactory.createVaultV2(deployer, asset, salt);
        VaultV2 vault = VaultV2(vaultAddress);
        console.log("  VaultV2:", vaultAddress);

        // Step 2: Deploy UniversalAdapterEscrow
        console.log("\n[Step 2] Deploying UniversalAdapterEscrow...");
        address adapterAddress = adapterFactory.deployAdapter(
            address(vault),
            valuerAddress,
            false, // useOffchainValuer
            salt
        );
        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));
        console.log("  Adapter:", adapterAddress);

        // Step 3: Set curator (required for configuration)
        console.log("\n[Step 3] Setting curator...");
        vault.setCurator(deployer);
        console.log("  Curator set:", deployer);

        vm.stopBroadcast();

        // Final status
        console.log("\n=================================================");
        console.log("    VAULT DEPLOYMENT COMPLETE!");
        console.log("=================================================");
        console.log("\nDeployed Contracts:");
        console.log("  VaultV2:", address(vault));
        console.log("  UniversalAdapterEscrow:", address(adapter));
    }
}