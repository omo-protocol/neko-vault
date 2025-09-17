// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VaultV2} from "../src/VaultV2.sol";
import {PendleV2AdapterKHYPE} from "../src/adapters/PendleV2AdapterKHYPE.sol";

interface IERC20 {
    function symbol() external view returns (string memory);
}

contract DeployOnlyNewVaultV2 is Script {
    
    // Addresses
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant CURATOR = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    // Pendle addresses
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x6813d43782395A1F2AAb42f39aeEDE03ac655e09;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DEPLOYING NEW VAULTV2 + ADAPTER ===");
        console.log("kHYPE:", KHYPE);
        console.log("Curator/Owner:", CURATOR);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy VaultV2
        console.log("\n1. Deploying VaultV2...");
        VaultV2 vault = new VaultV2(CURATOR, KHYPE);
        console.log("VaultV2 deployed at:", address(vault));
        
        // Verify VaultV2
        require(vault.asset() == KHYPE, "Vault asset incorrect");
        require(vault.owner() == CURATOR, "Vault owner incorrect");
        
        // Deploy Adapter
        console.log("\n2. Deploying PendleV2AdapterKHYPE...");
        PendleV2AdapterKHYPE adapter = new PendleV2AdapterKHYPE(
            address(vault),
            PENDLE_ROUTER,
            PENDLE_ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        console.log("Adapter deployed at:", address(adapter));
        
        // Verify Adapter
        require(adapter.parentVault() == address(vault), "Adapter vault incorrect");
        require(adapter.asset() == KHYPE, "Adapter asset incorrect");
        
        vm.stopBroadcast();
        
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("VaultV2:", address(vault));
        console.log("PendleV2AdapterKHYPE:", address(adapter));
        console.log("Ready for registration and testing!");
    }
}