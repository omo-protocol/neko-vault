// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {console2} from "forge-std/console2.sol";
import {Script} from "forge-std/Script.sol";
import {RemotePpsSnapshotSender} from "../../src/ovault/RemotePpsSnapshotSender.sol";

contract DeployStrategyRemotePpsReporter is Script {
    function run() external returns (address reporter) {
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address vaultManager = vm.envOr("VAULT_MANAGER", owner);
        address sleeve = vm.envAddress("SLEEVE");
        address endpoint = vm.envAddress("LZ_ENDPOINT");

        vm.startBroadcast(privateKey);
        reporter = address(new RemotePpsSnapshotSender(owner, vaultManager, sleeve, endpoint));
        vm.stopBroadcast();

        console2.log("Remote PPS reporter deployed:", reporter);
    }
}
