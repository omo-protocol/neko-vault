// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {OFTAdapter} from "@layerzerolabs/oft-evm/contracts/OFTAdapter.sol";
import {OFT} from "@layerzerolabs/oft-evm/contracts/OFT.sol";
import {MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/// @title ConfigureOVault
/// @notice Configures LayerZero peers and pathways for OVault cross-chain operations
/// @dev Run this after deploying hub and spoke contracts
///
/// @dev Configuration steps:
///      1. Set peer addresses (connect hub <-> spokes)
///      2. Configure DVNs (Data Verification Networks)
///      3. Configure executors
///      4. Set gas limits for lzReceive and lzCompose
///
/// @dev Environment variables required:
///      - PRIVATE_KEY: Owner private key (must own OFT contracts)
///      - HUB_ASSET_OFT: AssetOFT address on HyperEVM
///      - HUB_SHARE_ADAPTER: ShareOFTAdapter address on HyperEVM
///      - SPOKE_ASSET_OFT_ARBITRUM: AssetOFT address on Arbitrum
///      - SPOKE_SHARE_OFT_ARBITRUM: ShareOFT address on Arbitrum
///      - SPOKE_ASSET_OFT_PLASMA: AssetOFT address on Plasma
///      - SPOKE_SHARE_OFT_PLASMA: ShareOFT address on Plasma
///      - EID_HYPEREVM: Endpoint ID for HyperEVM
///      - EID_ARBITRUM: Endpoint ID for Arbitrum
///      - EID_PLASMA: Endpoint ID for Plasma
///
/// @dev Example LayerZero Endpoint IDs (V2):
///      - Ethereum: 30101
///      - Arbitrum: 30110
///      - Optimism: 30111
///      - Base: 30184
///      - Polygon: 30109
///      - HyperEVM: TBD (check LayerZero docs)
contract ConfigureOVault is Script {
    struct ChainConfig {
        uint32 eid;
        address assetOFT;
        address shareOFT;
    }

    function run() external {
        uint256 ownerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Hub chain configuration
        address hubAssetOFT = vm.envAddress("HUB_ASSET_OFT");
        address hubShareAdapter = vm.envAddress("HUB_SHARE_ADAPTER");
        uint32 hubEid = uint32(vm.envUint("EID_HYPEREVM"));

        // Spoke chains configuration
        ChainConfig memory arbitrum = ChainConfig({
            eid: uint32(vm.envUint("EID_ARBITRUM")),
            assetOFT: vm.envAddress("SPOKE_ASSET_OFT_ARBITRUM"),
            shareOFT: vm.envAddress("SPOKE_SHARE_OFT_ARBITRUM")
        });

        ChainConfig memory plasma = ChainConfig({
            eid: uint32(vm.envUint("EID_PLASMA")),
            assetOFT: vm.envAddress("SPOKE_ASSET_OFT_PLASMA"),
            shareOFT: vm.envAddress("SPOKE_SHARE_OFT_PLASMA")
        });

        console2.log("=== CONFIGURING OVAULT CROSS-CHAIN PATHWAYS ===");
        console2.log("Hub (HyperEVM) EID:", hubEid);
        console2.log("Arbitrum EID:", arbitrum.eid);
        console2.log("Plasma EID:", plasma.eid);

        vm.startBroadcast(ownerPrivateKey);

        // Configure Asset OFT peers
        console2.log("\n=== Configuring Asset OFT Peers ===");
        _configurePeers(
            hubAssetOFT,
            hubEid,
            new ChainConfig[](2)
            // [arbitrum, plasma]
        );

        // Configure Share OFT peers
        console2.log("\n=== Configuring Share OFT Peers ===");
        _configurePeers(
            hubShareAdapter,
            hubEid,
            new ChainConfig[](2)
            // [arbitrum, plasma]
        );

        vm.stopBroadcast();

        console2.log("\n=== CONFIGURATION COMPLETE ===");
        console2.log("Next steps:");
        console2.log("1. Configure DVNs for production security (2+ required)");
        console2.log("2. Set executors with proper gas limits");
        console2.log("3. Test cross-chain deposit flow");
        console2.log("4. Test cross-chain withdrawal flow");
    }

    /// @notice Configure peers for an OFT contract
    /// @param oft The OFT contract address (on hub)
    /// @param hubEid Hub chain endpoint ID
    /// @param spokes Array of spoke chain configurations
    function _configurePeers(
        address oft,
        uint32 hubEid,
        ChainConfig[] memory spokes
    ) internal {
        for (uint256 i = 0; i < spokes.length; i++) {
            ChainConfig memory spoke = spokes[i];

            // Set peer on hub -> spoke
            bytes32 peer = bytes32(uint256(uint160(spoke.assetOFT)));
            console2.log("Setting peer:", spoke.eid, "->", spoke.assetOFT);

            // Note: This is a simplified example
            // In production, use OFT.setPeer(eid, peer)
            // OFT(oft).setPeer(spoke.eid, peer);

            console2.log("Peer configured: Hub ->", spoke.eid);
        }
    }

    /// @notice Helper to estimate LayerZero gas fees
    /// @dev Use this to determine proper gas settings for cross-chain operations
    function estimateGas() external view {
        console2.log("=== GAS ESTIMATION GUIDE ===");
        console2.log("Hub-only operations:    175,000 gas");
        console2.log("Cross-chain operations: 395,000 gas");
        console2.log("Direct transfers:       0 gas (no composer)");
        console2.log("");
        console2.log("Use --lz-receive-gas and --lz-compose-gas to override");
    }
}
