// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/adapters/PendleV2AdapterKHYPE.sol";
import "../src/interfaces/IERC20.sol";

contract TestRealAllocation is Script {
    
    // Live deployed adapter from previous test
    address constant DEPLOYED_ADAPTER = 0x448853b8FDA515464aE5CD512C1759581e3c1062;
    address constant VAULT_ASSET = 0x5555555555555555555555555555555555555555; // wHYPE
    
    uint256 constant TINY_ALLOCATION = 5000000000000; // 0.000005 wHYPE (half of what's in adapter)
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== Testing REAL Allocation with Live Adapter ===");
        console.log("Using deployed adapter:", DEPLOYED_ADAPTER);
        console.log("Deployer:", deployer);
        
        PendleV2AdapterKHYPE adapter = PendleV2AdapterKHYPE(DEPLOYED_ADAPTER);
        IERC20 asset = IERC20(VAULT_ASSET);
        
        // Check current state
        console.log("\n1. Current adapter state:");
        uint256 currentAssetBalance = adapter.getAssetBalance();
        uint256 currentPTBalance = adapter.getPTBalance();
        uint256 currentRealAssets = adapter.realAssets();
        
        console.log("Asset balance:", currentAssetBalance, "wei");
        console.log("PT balance:", currentPTBalance, "wei");
        console.log("Real assets:", currentRealAssets, "wei");
        
        if (currentAssetBalance == 0) {
            console.log("No assets in adapter - transferring tiny amount...");
            asset.transfer(DEPLOYED_ADAPTER, TINY_ALLOCATION);
            console.log("Transferred:", TINY_ALLOCATION, "wei");
            currentAssetBalance = adapter.getAssetBalance();
            console.log("New asset balance:", currentAssetBalance, "wei");
        }
        
        // Try allocation
        console.log("\n2. Attempting REAL allocation...");
        uint256 allocationAmount = currentAssetBalance / 2; // Use half of available balance
        console.log("Allocation amount:", allocationAmount, "wei");
        
        try adapter.allocate("", allocationAmount, bytes4(0), address(0)) returns (bytes32[] memory ids, int256 change) {
            console.log("SUCCESS: Real allocation completed on HyperEVM!");
            console.log("Allocation IDs length:", ids.length);
            console.log("Change:", change > 0 ? uint256(change) : 0);
            
            // Check state after allocation
            uint256 afterAssetBalance = adapter.getAssetBalance();
            uint256 afterPTBalance = adapter.getPTBalance();
            uint256 afterRealAssets = adapter.realAssets();
            
            console.log("\n3. State after allocation:");
            console.log("Asset balance:", afterAssetBalance, "wei");
            console.log("PT balance:", afterPTBalance, "wei");
            console.log("Real assets:", afterRealAssets, "wei");
            
            if (afterPTBalance > currentPTBalance) {
                console.log("SUCCESS: PT tokens received!");
                console.log("PT gained:", afterPTBalance - currentPTBalance, "wei");
            }
            
        } catch Error(string memory reason) {
            console.log("Allocation failed (expected if Pendle unavailable):", reason);
        } catch (bytes memory lowLevelData) {
            console.log("Allocation failed with low-level error:");
            console.logBytes(lowLevelData);
        }
        
        console.log("\n=== REAL ALLOCATION TEST COMPLETED ===");
        
        vm.stopBroadcast();
    }
}