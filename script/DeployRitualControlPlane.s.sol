// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";
import {MultiLegController} from "../src/controllers/cross_venue/MultiLegController.sol";
import {PtLoopController} from "../src/controllers/cross_venue/PtLoopController.sol";

/// @notice Deploys Ritual-side control plane in three separate txs to stay under EIP-3860:
///         1. MultiLegController template
///         2. PtLoopController template
///         3. ArchetypeFactory referencing both templates
///
///         Env vars:
///           PRIVATE_KEY — deployer
///           OWNER       — ArchetypeFactory admin (rotates templates)
contract DeployRitualControlPlane is Script {
    function run() external {
        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address owner_ = vm.envAddress("OWNER");

        vm.startBroadcast(deployerPk);
        MultiLegController multiLegTemplate = new MultiLegController();
        PtLoopController ptLoopTemplate = new PtLoopController();
        ArchetypeFactory factory =
            new ArchetypeFactory(owner_, address(multiLegTemplate), address(ptLoopTemplate));
        vm.stopBroadcast();

        console.log("=== Ritual Control Plane Deployed ===");
        console.log("MultiLegController template:", address(multiLegTemplate));
        console.log("PtLoopController  template:", address(ptLoopTemplate));
        console.log("ArchetypeFactory:           ", address(factory));
        console.log("");
        console.log("Next: factory.createMultiLeg(params, salt) / createPtLoop(params, salt)");
    }
}
