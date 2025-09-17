// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IVaultV2 {
    function setCurator(address newCurator) external;
    function setAllocator(address newAllocator) external;
    function owner() external view returns (address);
    function curator() external view returns (address);
    function allocator() external view returns (address);
}

contract SetupCleanVaultAuth is Script {
    
    address constant CLEAN_VAULT = 0x3C3e4510957437ed56c3737D9F36203E0F959830;
    address constant DEPLOYER = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== SETTING UP CLEAN VAULT AUTHORIZATION ===");
        console.log("Clean Vault:", CLEAN_VAULT);
        console.log("Deployer:", DEPLOYER);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Set curator (owner can set curator)
        console.log("Setting curator to deployer...");
        IVaultV2(CLEAN_VAULT).setCurator(DEPLOYER);
        
        // Set allocator (owner can set allocator)
        console.log("Setting allocator to deployer...");  
        IVaultV2(CLEAN_VAULT).setAllocator(DEPLOYER);
        
        vm.stopBroadcast();
        
        // Verify
        console.log("");
        console.log("=== VERIFICATION ===");
        address owner = IVaultV2(CLEAN_VAULT).owner();
        address curator = IVaultV2(CLEAN_VAULT).curator();
        address allocator = IVaultV2(CLEAN_VAULT).allocator();
        
        console.log("Owner:", owner);
        console.log("Curator:", curator);
        console.log("Allocator:", allocator);
        
        console.log("");
        console.log("Authorization setup:");
        console.log("  Owner == Deployer:", owner == DEPLOYER);
        console.log("  Curator == Deployer:", curator == DEPLOYER);
        console.log("  Allocator == Deployer:", allocator == DEPLOYER);
        
        if (owner == DEPLOYER && curator == DEPLOYER && allocator == DEPLOYER) {
            console.log("");
            console.log("SUCCESS: All roles set correctly!");
            console.log("Clean vault ready for end-to-end test!");
        }
    }
}