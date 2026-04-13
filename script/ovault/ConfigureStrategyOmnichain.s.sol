// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

interface ILayerZeroPeerConfig {
    function setPeer(uint32 eid, bytes32 peer) external;
}

contract ConfigureStrategyOmnichain is StrategyLaunchpadScriptBase {
    function run() external {
        address localAssetOFT = vm.envAddress("LOCAL_ASSET_OFT");
        address localShareOFT = vm.envExists("LOCAL_SHARE_OFT") ? vm.envAddress("LOCAL_SHARE_OFT") : address(0);
        uint32[] memory remoteEids = _loadUint32Array("REMOTE_EIDS");

        _configureOmnichainAction();
        _configureRemotePpsPeers();

        console2.log("Configured omnichain peers for asset OFT:", localAssetOFT);
        console2.log("Configured omnichain peers for share OFT:", localShareOFT);
        console2.log("Configured remote count:", remoteEids.length);
    }

    function _configureRemotePpsPeers() internal {
        if (!vm.envExists("LOCAL_REMOTE_PPS_SYNC") || !vm.envExists("REMOTE_REMOTE_PPS_SYNCS")) return;

        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address localRemotePpsSync = vm.envAddress("LOCAL_REMOTE_PPS_SYNC");
        uint32[] memory remoteEids = _loadUint32Array("REMOTE_EIDS");
        address[] memory remoteRemotePpsSyncs = vm.envAddress("REMOTE_REMOTE_PPS_SYNCS", ",");
        if (remoteEids.length == 0 || remoteRemotePpsSyncs.length != remoteEids.length) revert InvalidPeerConfig();

        vm.startBroadcast(privateKey);
        for (uint256 i; i < remoteEids.length; i++) {
            ILayerZeroPeerConfig(localRemotePpsSync).setPeer(
                remoteEids[i], bytes32(uint256(uint160(remoteRemotePpsSyncs[i])))
            );
        }
        vm.stopBroadcast();
    }
}
