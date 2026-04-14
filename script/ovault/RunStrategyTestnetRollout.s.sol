// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {Deployment, StrategyKind} from "../../src/strategies/StrategyTypes.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

contract RunStrategyTestnetRollout is StrategyLaunchpadScriptBase {
    error InvalidStrategyKind();

    function run() external {
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
    }

    function _deployPTLoop() internal {
        (StrategyVaultFactory factory, Deployment memory deployment) = _deployPTLoopStrategy();

        console2.log("Rollout action complete: deploy PT-loop strategy");
        _logDeployment(factory, deployment);
    }

    function _logDeployment(StrategyVaultFactory factory, Deployment memory deployment) internal view {
        console2.log("Factory:", address(factory));
        console2.log("Vault:", deployment.vault);
        console2.log("Sleeve:", deployment.sleeve);
        console2.log("Controller:", deployment.controller);
        console2.log("Wrapper:", deployment.wrapper);
        console2.logBytes32(deployment.strategyId);
    }
}
