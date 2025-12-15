// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/valuers/UniversalValuerOffchain.sol";

/**
 * @title DeployValuer
 * @notice Deploys the UniversalValuerOffchain contract
 *
 * Usage:
 *   PRIVATE_KEY=0x... OWNER=0x... ASSET=0x... forge script script/DeployValuer.s.sol --rpc-url <RPC_URL> --broadcast -v
 */
contract DeployValuer is Script {
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address owner = vm.envAddress("OWNER");
        address asset = vm.envAddress("ASSET");

        console.log("Deploying UniversalValuerOffchain");
        console.log("Owner:", owner);
        console.log("Asset:", asset);

        vm.startBroadcast(deployerPrivateKey);

        UniversalValuerOffchain valuer = new UniversalValuerOffchain(owner, asset);
        console.log("UniversalValuerOffchain deployed:", address(valuer));

        vm.stopBroadcast();
    }
}
