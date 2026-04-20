// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {MultiLegController} from "../src/controllers/cross_venue/MultiLegController.sol";
import {PtLoopController} from "../src/controllers/cross_venue/PtLoopController.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";

/// @notice Fresh Ritual-side control plane: MultiLeg + PtLoop templates + ArchetypeFactory.
///         Both templates include the post-2026-04 fixes — `perCallHttpBudget` for
///         schedule-renewal accuracy, and `withdrawRitualWallet` for rescue of system-wallet
///         balances. Deploy order: templates first (sentinels mark themselves initialized via
///         constructor), then factory references their addresses.
///
///         Env:
///           PRIVATE_KEY — deployer / owner of the ArchetypeFactory
contract DeployRitualControlPlane is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);
        MultiLegController mlTemplate = new MultiLegController();
        PtLoopController ptTemplate = new PtLoopController();
        ArchetypeFactory factory = new ArchetypeFactory(deployer, address(mlTemplate), address(ptTemplate));
        vm.stopBroadcast();

        console.log("=== Ritual control plane deployed ===");
        console.log("MultiLeg template: ", address(mlTemplate));
        console.log("PtLoop template:   ", address(ptTemplate));
        console.log("ArchetypeFactory:  ", address(factory));
        console.log("Owner:             ", deployer);
    }
}
