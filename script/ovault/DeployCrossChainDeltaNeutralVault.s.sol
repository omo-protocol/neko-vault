// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyVaultFactory} from "../../src/factories/StrategyVaultFactory.sol";
import {Deployment} from "../../src/strategies/StrategyTypes.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

contract DeployCrossChainDeltaNeutralVault is StrategyLaunchpadScriptBase {
    function run() external {
        (StrategyVaultFactory factory, Deployment memory deployment) = _deployDeltaNeutralStrategy();

        console2.log("Delta-neutral cross-chain vault deployed");
        _logDeployment(factory, deployment);
    }
}
