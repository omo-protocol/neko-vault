// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {StrategyLaunchpadScriptBase} from "./StrategyLaunchpadScriptBase.s.sol";

contract DeployStrategySpokeOFT is StrategyLaunchpadScriptBase {
    function run() external {
        (address assetOFTAddress, address shareOFTAddress) = _deploySpokeOFTAction();

        console2.log("Strategy spoke OFTs deployed");
        console2.log("AssetOFT:", assetOFTAddress);
        console2.log("ShareOFT:", shareOFTAddress);
    }
}
