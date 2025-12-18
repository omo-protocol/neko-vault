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
 *   forge script script/1_DeployPTLoopVault.s.sol --rpc-url <RPC_URL> --broadcast -v
 */
contract DeployPTLoopVault is Script {
    // Strategy IDs
    bytes32 constant STRATEGY_ID = keccak256("hype-stack-vault");
    // Asset configuration
    address asset = 0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14; // WETH
    address vaultFactoryAddress = 0x8B9683393356EF81c4f1B639EB218EB649Ae0B38; // config to vault factory address
    address adapterFactoryAddress = 0x448853b8FDA515464aE5CD512C1759581e3c1062; // config to adapter factory address
    address valuerAddress = 0x393eC44e9C1E6783c860ae43678FE0319886268B; // config to valuer address

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
            STRATEGY_ID,
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