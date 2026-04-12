// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {ChainManifest, Deployment, VenueConfig} from "../../src/strategies/StrategyTypes.sol";

abstract contract StrategyLaunchpadScriptBase is Script {
    error InvalidManifestConfig();

    function _loadChainManifests() internal view returns (ChainManifest[] memory manifests) {
        uint256[] memory chainIds = vm.envUint("MANIFEST_CHAIN_IDS", ",");
        uint256[] memory lzEids = vm.envUint("MANIFEST_LZ_EIDS", ",");
        address[] memory sleeves = vm.envAddress("MANIFEST_SLEEVES", ",");
        address[] memory assetOFTs = vm.envAddress("MANIFEST_ASSET_OFTS", ",");
        address[] memory shareOFTs = vm.envAddress("MANIFEST_SHARE_OFTS", ",");
        bool[] memory isHome = vm.envBool("MANIFEST_IS_HOME", ",");

        uint256 length = chainIds.length;
        if (
            length == 0 || lzEids.length != length || sleeves.length != length || assetOFTs.length != length
                || shareOFTs.length != length || isHome.length != length
        ) revert InvalidManifestConfig();

        manifests = new ChainManifest[](length);
        uint256 homeCount;
        for (uint256 i; i < length; i++) {
            manifests[i] = ChainManifest({
                chainId: chainIds[i],
                lzEid: uint32(lzEids[i]),
                sleeve: sleeves[i],
                assetOFT: assetOFTs[i],
                shareOFT: shareOFTs[i],
                isHomeChain: isHome[i]
            });
            if (isHome[i]) homeCount++;
        }

        if (homeCount != 1) revert InvalidManifestConfig();
    }

    function _loadVenueConfig() internal view returns (VenueConfig memory) {
        return VenueConfig({
            venueId: vm.envBytes32("VENUE_ID"),
            venue: vm.envAddress("VENUE"),
            helper: vm.envOr("VENUE_HELPER", address(0)),
            usesLayerZero: vm.envBool("USES_LAYER_ZERO")
        });
    }

    function _logDeployment(StrategyVaultFactory factory, Deployment memory deployment) internal view {
        console2.log("Vault:", deployment.vault);
        console2.log("Sleeve:", deployment.sleeve);
        console2.log("Controller:", deployment.controller);
        console2.log("Wrapper:", deployment.wrapper);
        console2.log("WithdrawalQueue:", factory.withdrawalQueueOf(deployment.vault));
        console2.log("WithdrawalSettlementComposer:", factory.withdrawalSettlementComposerOf(deployment.vault));
        console2.log("ShareOFTAdapter:", factory.shareOFTAdapterOf(deployment.vault));
        console2.log("VaultComposerSync:", factory.vaultComposerSyncOf(deployment.vault));
    }
}
