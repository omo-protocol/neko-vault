// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VaultV2} from "../src/VaultV2.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function symbol() external view returns (string memory);
}

contract DeployCleanKHYPEVault is Script {
    
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant CURATOR = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DEPLOYING CLEAN KHYPE VAULTV2 ===");
        console.log("kHYPE Token:", KHYPE);
        console.log("Curator:", CURATOR);
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);
        
        // Verify kHYPE token
        string memory symbol = IERC20(KHYPE).symbol();
        console.log("Token symbol:", symbol);
        
        // Deploy clean VaultV2
        console.log("\nDeploying VaultV2...");
        VaultV2 vault = new VaultV2(
            CURATOR,    // owner
            KHYPE       // asset (kHYPE)
        );
        
        console.log("SUCCESS: Clean VaultV2 deployed!");
        console.log("Address:", address(vault));
        
        // Verify deployment
        address vaultAsset = vault.asset();
        address vaultOwner = vault.owner();
        
        console.log("\nVerification:");
        console.log("  Asset:", vaultAsset);
        console.log("  Owner:", vaultOwner);
        console.log("  Asset matches:", vaultAsset == KHYPE);
        console.log("  Owner matches:", vaultOwner == CURATOR);
        
        require(vaultAsset == KHYPE, "Asset verification failed");
        require(vaultOwner == CURATOR, "Owner verification failed");
        
        vm.stopBroadcast();
        
        console.log("\n=== DEPLOYMENT COMPLETE ===");
        console.log("Clean kHYPE VaultV2:", address(vault));
        console.log("Ready for PendleV2AdapterKHYPE integration!");
    }
}