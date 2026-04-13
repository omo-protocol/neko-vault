// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {Deployment, StrategyKind} from "../../src/strategies/StrategyTypes.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

contract RunStrategyTestnetRollout is StrategyLaunchpadScriptBase {
    uint256 internal constant ACTION_DEPLOY_STRATEGY = 0;
    uint256 internal constant ACTION_DEPLOY_SPOKE_OFT = 1;
    uint256 internal constant ACTION_CONFIGURE_OMNICHAIN = 2;
    uint256 internal constant ACTION_DEPLOY_REMOTE_PPS_REPORTER = 3;

    error InvalidRolloutAction();
    error InvalidStrategyKind();

    function run() external {
        uint256 action = vm.envUint("ROLLOUT_ACTION");

        if (action == ACTION_DEPLOY_STRATEGY) {
            _deployStrategy();
            return;
        }

        if (action == ACTION_DEPLOY_SPOKE_OFT) {
            _deploySpokeOFT();
            return;
        }

        if (action == ACTION_CONFIGURE_OMNICHAIN) {
            _configureOmnichain();
            return;
        }

        if (action == ACTION_DEPLOY_REMOTE_PPS_REPORTER) {
            _deployRemotePpsReporter();
            return;
        }

        revert InvalidRolloutAction();
    }

    function _deployStrategy() internal {
        uint256 strategyKind = vm.envUint("STRATEGY_KIND");

        if (strategyKind == uint256(StrategyKind.DeltaNeutral)) {
            _deployDeltaNeutral();
            return;
        }

        if (strategyKind == uint256(StrategyKind.PTLoop)) {
            _deployPTLoop();
            return;
        }

        revert InvalidStrategyKind();
    }

    function _deployDeltaNeutral() internal {
        (StrategyVaultFactory factory, Deployment memory deployment) = _deployDeltaNeutralStrategy();

        console2.log("Rollout action complete: deploy delta-neutral strategy");
        _logDeployment(factory, deployment);
        _logNextPhaseHint();
    }

    function _deployPTLoop() internal {
        (StrategyVaultFactory factory, Deployment memory deployment) = _deployPTLoopStrategy();

        console2.log("Rollout action complete: deploy PT-loop strategy");
        _logDeployment(factory, deployment);
        _logNextPhaseHint();
    }

    function _deploySpokeOFT() internal {
        (address assetOFTAddress, address shareOFTAddress) = _deploySpokeOFTAction();

        console2.log("Rollout action complete: deploy spoke OFTs");
        console2.log("AssetOFT:", assetOFTAddress);
        console2.log("ShareOFT:", shareOFTAddress);
        _logNextPhaseHint();
    }

    function _configureOmnichain() internal {
        address localAssetOFT = vm.envAddress("LOCAL_ASSET_OFT");
        bool configureShare = vm.envExists("LOCAL_SHARE_OFT");
        address localShareOFT = configureShare ? vm.envAddress("LOCAL_SHARE_OFT") : address(0);
        uint32[] memory remoteEids = _loadUint32Array("REMOTE_EIDS");
        _configureOmnichainAction();
        _configureRemotePpsPeersAction();

        console2.log("Rollout action complete: configure omnichain peers/options");
        console2.log("LocalAssetOFT:", localAssetOFT);
        console2.log("LocalShareOFT:", localShareOFT);
        console2.log("ConfiguredRemoteCount:", remoteEids.length);
    }

    function _deployRemotePpsReporter() internal {
        address reporter = _deployRemotePpsReporterAction();

        console2.log("Rollout action complete: deploy remote PPS reporter");
        console2.log("RemotePpsReporter:", reporter);
    }
}
