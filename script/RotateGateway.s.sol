// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import {BaseExecutionGateway} from "../src/base/BaseExecutionGateway.sol";
import {BaseStrategyModule} from "../src/base/BaseStrategyModule.sol";

/// @notice Deploys a fresh `BaseExecutionGateway` with cycleId-only replay protection
///         (removes `usedNonces` mapping that caused nonce=0 lockups when Ritual tick tx
///         reverted after async precompile dispatched) and re-points the Module at it.
contract RotateGateway is Script {
    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address module = vm.envAddress("MODULE");
        address vault = vm.envAddress("VAULT");
        address asset = vm.envAddress("ASSET");
        address signer = vm.envAddress("SIGNER");
        uint256 threshold = vm.envOr("THRESHOLD", uint256(1));

        vm.startBroadcast(pk);

        BaseExecutionGateway g = new BaseExecutionGateway(
            vm.addr(pk),         // owner (deployer)
            vault,
            asset,
            module,
            "NekoBaseGateway",
            "1"
        );
        g.setSigner(signer, true);
        g.setThreshold(threshold);

        BaseStrategyModule(module).setGateway(address(g));

        vm.stopBroadcast();

        console.log("=== New Gateway deployed & wired ===");
        console.log("Gateway:   ", address(g));
        console.log("Module:    ", module);
        console.log("Signer:    ", signer);
        console.log("Threshold: ", threshold);
    }
}
