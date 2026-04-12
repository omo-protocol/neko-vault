// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {AssetOFT} from "../../src/ovault/AssetOFT.sol";
import {ShareOFT} from "../../src/ovault/ShareOFT.sol";

contract DeployStrategySpokeOFT is Script {
    function run() external {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address delegate = vm.envOr("DELEGATE", vm.addr(privateKey));
        address endpoint = vm.envAddress("LZ_ENDPOINT");
        bool deployAssetOFT = vm.envOr("DEPLOY_ASSET_OFT", true);

        address assetOFTAddress = vm.envOr("EXISTING_ASSET_OFT", address(0));
        address shareOFTAddress;

        vm.startBroadcast(privateKey);

        if (deployAssetOFT) {
            assetOFTAddress =
                address(new AssetOFT(vm.envString("ASSET_NAME"), vm.envString("ASSET_SYMBOL"), endpoint, delegate));
        }

        shareOFTAddress =
            address(new ShareOFT(vm.envString("SHARE_NAME"), vm.envString("SHARE_SYMBOL"), endpoint, delegate));

        vm.stopBroadcast();

        console2.log("Strategy spoke OFTs deployed");
        console2.log("AssetOFT:", assetOFTAddress);
        console2.log("ShareOFT:", shareOFTAddress);
    }
}
