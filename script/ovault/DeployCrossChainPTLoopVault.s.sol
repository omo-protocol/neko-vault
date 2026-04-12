// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {Deployment} from "../../src/strategies/StrategyTypes.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

contract DeployCrossChainPTLoopVault is StrategyLaunchpadScriptBase {
    function run() external {
        (StrategyVaultFactory factory, Deployment memory deployment) = _deployPTLoopStrategy();

        console2.log("PT-loop cross-chain vault deployed");
        _logDeployment(factory, deployment);
    }
}
