// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

contract ConfigureStrategyOmnichain is StrategyLaunchpadScriptBase {
    function run() external {
        address localAssetOFT = vm.envAddress("LOCAL_ASSET_OFT");
        address localShareOFT = vm.envExists("LOCAL_SHARE_OFT") ? vm.envAddress("LOCAL_SHARE_OFT") : address(0);
        uint32[] memory remoteEids = _loadUint32Array("REMOTE_EIDS");

        _configureOmnichainAction();

        console2.log("Configured omnichain peers for asset OFT:", localAssetOFT);
        console2.log("Configured omnichain peers for share OFT:", localShareOFT);
        console2.log("Configured remote count:", remoteEids.length);
    }
}
