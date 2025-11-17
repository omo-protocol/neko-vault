// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {VaultV2} from "../../src/VaultV2.sol";
import {AssetOFT} from "../../src/ovault/AssetOFT.sol";
import {ShareOFTAdapter} from "../../src/ovault/ShareOFTAdapter.sol";
import {VaultComposerSync} from "../../src/ovault/VaultComposerSync.sol";

/// @title DeployHub
/// @notice Deploys the complete OVault infrastructure on HyperEVM (hub chain)
/// @dev Deployment order:
///      1. AssetOFT (underlying asset, e.g., USDT)
///      2. VaultV2 (ERC-4626 vault)
///      3. ShareOFTAdapter (lockbox for vault shares)
///      4. VaultComposerSync (orchestrates cross-chain operations)
///
/// @dev Environment variables required:
///      - PRIVATE_KEY: Deployer private key
///      - LZ_ENDPOINT_HYPEREVM: LayerZero endpoint on HyperEVM
///      - VAULT_OWNER: VaultV2 owner address
///      - VAULT_NAME: Vault name (e.g., "Morpho USDT Vault")
///      - VAULT_SYMBOL: Vault symbol (e.g., "mUSDT")
///      - ASSET_NAME: Asset name (e.g., "USD Tether")
///      - ASSET_SYMBOL: Asset symbol (e.g., "USDT")
///
/// @dev After deployment:
///      1. Configure LayerZero peers (connect to spoke chains)
///      2. Set DVNs and executors for security
///      3. Initialize vault (set curator, allocators, caps, etc.)
///      4. Mint initial asset liquidity (if needed)
contract DeployHub is Script {
    function run() external {
        // Load environment variables with defaults for testing
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0x1));
        address lzEndpoint = vm.envOr(
            "LZ_ENDPOINT_HYPEREVM",
            address(0x1a44076050125825900e736c501f859c50fE728c)
        ); // Default testnet endpoint
        address vaultOwner = vm.envOr(
            "VAULT_OWNER",
            vm.addr(deployerPrivateKey)
        );
        string memory vaultName = vm.envOr(
            "VAULT_NAME",
            string("Morpho USDT Vault")
        );
        string memory vaultSymbol = vm.envOr("VAULT_SYMBOL", string("mUSDT"));
        string memory assetName = vm.envOr("ASSET_NAME", string("USD Tether"));
        string memory assetSymbol = vm.envOr("ASSET_SYMBOL", string("USDT"));

        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);
        console2.log("LayerZero Endpoint:", lzEndpoint);
        console2.log("Vault Owner:", vaultOwner);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Asset OFT
        console2.log("\n=== Deploying Asset OFT ===");
        AssetOFT assetOFT = new AssetOFT(
            assetName,
            assetSymbol,
            lzEndpoint,
            deployer
        );
        console2.log("AssetOFT deployed at:", address(assetOFT));

        // 2. Deploy VaultV2
        console2.log("\n=== Deploying VaultV2 ===");
        VaultV2 vault = new VaultV2(vaultOwner, address(assetOFT));
        vault.setName(vaultName);
        vault.setSymbol(vaultSymbol);
        console2.log("VaultV2 deployed at:", address(vault));

        // 3. Deploy Share OFT Adapter
        console2.log("\n=== Deploying Share OFT Adapter ===");
        ShareOFTAdapter shareAdapter = new ShareOFTAdapter(
            address(vault), // vault shares token
            lzEndpoint,
            deployer
        );
        console2.log("ShareOFTAdapter deployed at:", address(shareAdapter));

        // 4. Deploy Vault Composer Sync
        console2.log("\n=== Deploying Vault Composer Sync ===");
        VaultComposerSync composer = new VaultComposerSync(
            address(vault),
            address(assetOFT),
            address(shareAdapter)
        );
        console2.log("VaultComposerSync deployed at:", address(composer));

        vm.stopBroadcast();

        // Print summary
        console2.log("\n=== DEPLOYMENT SUMMARY (HUB CHAIN) ===");
        console2.log("AssetOFT:           ", address(assetOFT));
        console2.log("VaultV2:            ", address(vault));
        console2.log("ShareOFTAdapter:    ", address(shareAdapter));
        console2.log("VaultComposerSync:  ", address(composer));

        console2.log("\n=== NEXT STEPS ===");
        console2.log(
            "1. Deploy spoke contracts on Arbitrum/Plasma (use DeploySpoke.s.sol)"
        );
        console2.log("2. Configure LayerZero peers (setPeer on each OFT)");
        console2.log("3. Set DVNs and executors for security");
        console2.log(
            "4. Initialize vault (curator, allocators, adapters, caps)"
        );
        console2.log("5. Mint initial asset liquidity if needed");
    }
}
