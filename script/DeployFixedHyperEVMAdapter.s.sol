// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PendleV2AdapterKHYPE} from "../src/adapters/PendleV2AdapterKHYPE.sol";

contract DeployFixedHyperEVMAdapter is Script {
    
    // Addresses from 999-core.json
    address constant VAULT_ADDRESS = 0xC4373044B9f88ad8BcA4962FcA8f13A42A127eae;
    address constant PENDLE_SWAP = 0xd4F480965D2347d421F1bEC7F545682E5Ec2151D; // CORRECT router
    address constant ROUTER_STATIC = 0x6813d43782395A1F2AAb42f39aeEDE03ac655e09;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DEPLOYING FIXED HYPEREVM PENDLE ADAPTER ===");
        console.log("Using CORRECT pendleSwap router from config");
        console.log("PendleSwap (correct router):", PENDLE_SWAP);
        console.log("RouterStatic:", ROUTER_STATIC);
        console.log("PT Token:", PT_TOKEN);
        console.log("Market:", MARKET);
        console.log("Vault:", VAULT_ADDRESS);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy adapter with CORRECT router address
        PendleV2AdapterKHYPE adapter = new PendleV2AdapterKHYPE(
            VAULT_ADDRESS,
            PENDLE_SWAP,      // Use pendleSwap instead of main router
            ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        
        console.log("SUCCESS: Fixed PendleV2AdapterKHYPE deployed at:", address(adapter));
        console.log("");
        
        // Verify deployment
        console.log("Deployment verification:");
        console.log("  Vault:", adapter.parentVault());
        console.log("  PendleRouter:", adapter.pendleRouter());
        console.log("  RouterStatic:", adapter.pendleRouterStatic());
        console.log("  Asset:", adapter.asset());
        console.log("  PT Token:", adapter.ptToken());
        console.log("  Market:", adapter.market());
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== DEPLOYMENT COMPLETE ===");
        console.log("New adapter uses correct HyperEVM pendleSwap router!");
        console.log("Next step: Register this adapter with VaultV2 and test allocation");
    }
}