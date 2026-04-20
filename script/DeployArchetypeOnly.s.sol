// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {ArchetypeFactory} from "../src/factories/ArchetypeFactory.sol";

/// @notice Deploy ONLY ArchetypeFactory pointing to existing templates. Workaround for Ritual's
///         per-tx gas limit that's below what MultiLegController deploy needs (~5M) but plenty
///         for the small factory contract (~0.5M gas). Set MULTILEG_TEMPLATE + PTLOOP_TEMPLATE
///         to existing deployed addresses.
contract DeployArchetypeOnly is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address owner_ = vm.envAddress("OWNER");
        address ml = vm.envAddress("MULTILEG_TEMPLATE");
        address pt = vm.envAddress("PTLOOP_TEMPLATE");

        vm.startBroadcast(pk);
        ArchetypeFactory f = new ArchetypeFactory(owner_, ml, pt);
        vm.stopBroadcast();

        console.log("ArchetypeFactory:", address(f));
        console.log("  multiLegTemplate:", ml);
        console.log("  ptLoopTemplate:  ", pt);
    }
}
