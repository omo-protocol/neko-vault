// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AssetOFT} from "../../src/ovault/AssetOFT.sol";
import {ShareOFT} from "../../src/ovault/ShareOFT.sol";

/// @title DeploySpoke
/// @notice Deploys OVault infrastructure on spoke chains (Arbitrum, Plasma, etc.)
/// @dev Deployment order:
///      1. AssetOFT (same asset as hub, enables bridging)
///      2. ShareOFT (represents vault shares on this chain)
///
/// @dev Environment variables required:
///      - PRIVATE_KEY: Deployer private key
///      - LZ_ENDPOINT_SPOKE: LayerZero endpoint on spoke chain
///      - ASSET_NAME: Asset name (must match hub)
///      - ASSET_SYMBOL: Asset symbol (must match hub)
///      - SHARE_NAME: Share name (e.g., "Morpho USDT Vault Shares")
///      - SHARE_SYMBOL: Share symbol (e.g., "mUSDT")
///
/// @dev After deployment:
///      1. Configure LayerZero peers (connect to hub and other spokes)
///      2. Set DVNs and executors for security
///      3. Users can now deposit/withdraw from this chain!
contract DeploySpoke is Script {
    function run() external {
        // Load environment variables with defaults for testing
        uint256 deployerPrivateKey = vm.envOr("PRIVATE_KEY", uint256(0x1));
        address lzEndpoint = vm.envOr(
            "LZ_ENDPOINT_SPOKE",
            address(0x6EDCE65403992e310A62460808c4b910D972f10f)
        ); // Default testnet endpoint
        string memory assetName = vm.envOr("ASSET_NAME", string("USD Tether"));
        string memory assetSymbol = vm.envOr("ASSET_SYMBOL", string("USDT"));
        string memory shareName = vm.envOr(
            "SHARE_NAME",
            string("Morpho USDT Vault Shares")
        );
        string memory shareSymbol = vm.envOr("SHARE_SYMBOL", string("mUSDT"));

        address deployer = vm.addr(deployerPrivateKey);
        console2.log("Deployer:", deployer);
        console2.log("LayerZero Endpoint:", lzEndpoint);

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

        // 2. Deploy Share OFT
        console2.log("\n=== Deploying Share OFT ===");
        ShareOFT shareOFT = new ShareOFT(
            shareName,
            shareSymbol,
            lzEndpoint,
            deployer
        );
        console2.log("ShareOFT deployed at:", address(shareOFT));

        vm.stopBroadcast();

        // Print summary
        console2.log("\n=== DEPLOYMENT SUMMARY (SPOKE CHAIN) ===");
        console2.log("AssetOFT:  ", address(assetOFT));
        console2.log("ShareOFT:  ", address(shareOFT));

        console2.log("\n=== NEXT STEPS ===");
        console2.log("1. Configure LayerZero peers to connect to hub chain");
        console2.log(
            "2. Configure LayerZero peers to connect to other spoke chains (optional)"
        );
        console2.log("3. Set DVNs and executors for security");
        console2.log("4. Users can deposit/withdraw cross-chain!");
    }
}
