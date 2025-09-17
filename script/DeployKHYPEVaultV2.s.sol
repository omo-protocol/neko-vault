// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VaultV2Factory} from "../src/VaultV2Factory.sol";

contract DeployKHYPEVaultV2 is Script {
    
    // HyperEVM addresses
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant CURATOR = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DEPLOYING KHYPE VAULT V2 ===");
        console.log("kHYPE asset:", KHYPE);
        console.log("Curator:", CURATOR);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy VaultV2Factory if needed (or use existing one)
        VaultV2Factory factory;
        try vm.envAddress("VAULT_V2_FACTORY") returns (address existingFactory) {
            factory = VaultV2Factory(existingFactory);
            console.log("Using existing VaultV2Factory:", address(factory));
        } catch {
            factory = new VaultV2Factory();
            console.log("VaultV2Factory deployed:", address(factory));
        }
        
        // Deploy kHYPE VaultV2
        bytes32 salt = keccak256(abi.encode("khype-vault-v2", block.timestamp));
        
        address vaultV2 = factory.createVaultV2(
            CURATOR,        // owner/curator
            KHYPE,          // asset (kHYPE)
            salt           // salt for deterministic address
        );
        
        console.log("kHYPE VaultV2 deployed:", vaultV2);
        console.log("");
        console.log("SUCCESS: kHYPE VaultV2 ready for testing!");
        console.log("Asset:", KHYPE);
        console.log("Curator:", CURATOR);
        
        vm.stopBroadcast();
    }
}