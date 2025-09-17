// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IVaultV2 {
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function isAllocator(address account) external view returns (bool);
    function setIsAllocator(address account, bool newIsAllocator) external;
    function totalAssets() external view returns (uint256);
}

contract TestBasicAllocation is Script {
    
    address constant VAULT = 0xC4373044B9f88ad8BcA4962FcA8f13A42A127eae;
    address constant ADAPTER = 0xf6a5c90faC8b02C58F18e65947b8d00cD478D30d;
    uint256 constant TEST_AMOUNT = 0.0001e18; // Very small amount
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== BASIC ALLOCATION TEST ===");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);
        
        // Check if allocator
        bool isAlloc = IVaultV2(VAULT).isAllocator(deployer);
        console.log("Is allocator:", isAlloc);
        
        if (!isAlloc) {
            console.log("Trying to set allocator...");
            try IVaultV2(VAULT).setIsAllocator(deployer, true) {
                console.log("SUCCESS: Set as allocator");
            } catch Error(string memory reason) {
                console.log("Failed to set allocator:", reason);
            } catch (bytes memory) {
                console.log("Failed to set allocator: unknown error");
            }
        }
        
        // Check vault assets
        uint256 assets = IVaultV2(VAULT).totalAssets();
        console.log("Vault assets:", assets);
        
        if (assets >= TEST_AMOUNT) {
            console.log("Attempting allocation...");
            try IVaultV2(VAULT).allocate(ADAPTER, "", TEST_AMOUNT) {
                console.log("SUCCESS: Allocation completed");
            } catch Error(string memory reason) {
                console.log("Allocation failed:", reason);
            } catch (bytes memory lowLevelData) {
                console.log("Allocation failed with data:");
                console.logBytes(lowLevelData);
            }
        } else {
            console.log("Insufficient vault assets for allocation");
        }
        
        vm.stopBroadcast();
    }
}