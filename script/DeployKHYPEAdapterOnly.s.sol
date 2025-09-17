// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PendleV2AdapterKHYPE} from "../src/adapters/PendleV2AdapterKHYPE.sol";

contract DeployKHYPEAdapterOnly is Script {
    
    // Use the newly deployed kHYPE vault
    address constant VAULT = 0xC4373044B9f88ad8BcA4962FcA8f13A42A127eae;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DEPLOYING PENDLE V2 ADAPTER KHYPE ===");
        console.log("Vault:", VAULT);
        console.log("Pendle Router:", PENDLE_ROUTER);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy PendleV2AdapterKHYPE
        PendleV2AdapterKHYPE adapter = new PendleV2AdapterKHYPE(
            VAULT,
            PENDLE_ROUTER,
            PENDLE_ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        
        console.log("PendleV2AdapterKHYPE deployed:", address(adapter));
        console.log("");
        console.log("SUCCESS: Adapter deployed on HyperEVM!");
        
        vm.stopBroadcast();
    }
}