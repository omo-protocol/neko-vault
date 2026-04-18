// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";
import {MultiLegController} from "../src/controllers/cross_venue/MultiLegController.sol";

/// @notice Redeploys MultiLegController template (after hex-decode + lib refresh)
///         and swaps it into the existing ArchetypeFactory. MultiLegSubmitLib must be
///         redeployed FIRST via `forge create` and its address passed in via --libraries.
contract RedeployMultiLegFull is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address factoryAddr = vm.envAddress("FACTORY");

        vm.startBroadcast(pk);
        MultiLegController template = new MultiLegController();
        ArchetypeFactory(factoryAddr).setTemplate(ArchetypeFactory.Archetype.MultiLeg, address(template));
        vm.stopBroadcast();

        console.log("=== MultiLeg template redeployed ===");
        console.log("New template:", address(template));
        console.log("Factory:     ", factoryAddr);
    }
}
