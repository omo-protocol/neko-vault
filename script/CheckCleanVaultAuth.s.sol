// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IVaultV2 {
    function owner() external view returns (address);
    function curator() external view returns (address);
    function allocator() external view returns (address);
    function asset() external view returns (address);
}

contract CheckCleanVaultAuth is Script {
    
    address constant CLEAN_VAULT = 0x3C3e4510957437ed56c3737D9F36203E0F959830;
    address constant DEPLOYER = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    function run() external {
        console.log("=== CHECKING CLEAN VAULT AUTHORIZATION ===");
        console.log("Clean Vault:", CLEAN_VAULT);
        console.log("Deployer:", DEPLOYER);
        console.log("");
        
        try IVaultV2(CLEAN_VAULT).owner() returns (address owner) {
            console.log("Owner:", owner);
            console.log("Deployer is owner:", owner == DEPLOYER);
        } catch {
            console.log("Failed to get owner");
        }
        
        try IVaultV2(CLEAN_VAULT).curator() returns (address curator) {
            console.log("Curator:", curator);
            console.log("Deployer is curator:", curator == DEPLOYER);
        } catch {
            console.log("Failed to get curator (may not exist)");
        }
        
        try IVaultV2(CLEAN_VAULT).allocator() returns (address allocator) {
            console.log("Allocator:", allocator);
            console.log("Deployer is allocator:", allocator == DEPLOYER);
        } catch {
            console.log("Failed to get allocator (may not exist)");
        }
        
        address asset = IVaultV2(CLEAN_VAULT).asset();
        console.log("Asset:", asset);
    }
}