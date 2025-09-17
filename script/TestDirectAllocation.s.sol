// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IVaultV2 {
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function isAdapter(address adapter) external view returns (bool);
}

contract TestDirectAllocation is Script {
    
    address constant VAULT = 0xC4373044B9f88ad8BcA4962FcA8f13A42A127eae;
    address constant ADAPTER = 0xf6a5c90faC8b02C58F18e65947b8d00cD478D30d;
    uint256 constant ALLOCATE_AMOUNT = 50000000000000; // 0.00005 kHYPE
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DIRECT ALLOCATION TEST ===");
        console.log("Vault:", VAULT);
        console.log("Adapter:", ADAPTER);
        console.log("Amount:", ALLOCATE_AMOUNT);
        
        vm.startBroadcast(deployerPrivateKey);
        
        bool isRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
        console.log("Adapter registered:", isRegistered);
        
        require(isRegistered, "Adapter not registered");
        
        console.log("Calling allocate() directly...");
        
        try IVaultV2(VAULT).allocate(ADAPTER, "", ALLOCATE_AMOUNT) {
            console.log("SUCCESS: Direct allocation worked!");
        } catch Error(string memory reason) {
            console.log("FAILED: Allocation failed:", reason);
        } catch (bytes memory data) {
            console.log("FAILED: Allocation failed with data:");
            console.logBytes(data);
        }
        
        vm.stopBroadcast();
    }
}