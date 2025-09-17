// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IVaultV2 {
    function timelock(bytes4) external view returns (uint256);
    function executableAt(bytes memory) external view returns (uint256);
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function submit(bytes calldata data) external;
    function allocation(bytes32 id) external view returns (uint256);
    function relativeCap(bytes32 id) external view returns (uint256);
}

contract FixRelativeCapIssue is Script {
    
    address constant VAULT = 0xE6c25968473FA49a886d2d50312a18ddbD40F4de;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== FIXING RELATIVE CAP ISSUE ===");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Check current status
        bytes memory idData = abi.encode("pendle-v2-khype-allocation");
        bytes32 allocationId = keccak256(idData);
        
        uint256 currentRelativeCap = IVaultV2(VAULT).relativeCap(allocationId);
        console.log("Current relative cap:", currentRelativeCap);
        
        // Check timelock
        bytes4 selector = IVaultV2.increaseRelativeCap.selector;
        uint256 timelockDuration = IVaultV2(VAULT).timelock(selector);
        console.log("Timelock duration for increaseRelativeCap:", timelockDuration);
        
        // Submit increase relative cap to 100% (1e18)
        uint256 newRelativeCap = 1e18; // 100%
        bytes memory submitData = abi.encodeWithSelector(
            IVaultV2.increaseRelativeCap.selector,
            idData,
            newRelativeCap
        );
        
        // Check if already submitted
        uint256 executableTime = IVaultV2(VAULT).executableAt(submitData);
        console.log("Executable at:", executableTime);
        console.log("Current timestamp:", block.timestamp);
        
        if (executableTime == 0) {
            console.log("Submitting increaseRelativeCap...");
            IVaultV2(VAULT).submit(submitData);
            console.log("Successfully submitted!");
            
            // Check new executable time
            executableTime = IVaultV2(VAULT).executableAt(submitData);
            console.log("New executable at:", executableTime);
        }
        
        if (block.timestamp >= executableTime && executableTime > 0) {
            console.log("Executing increaseRelativeCap...");
            try IVaultV2(VAULT).increaseRelativeCap(idData, newRelativeCap) {
                console.log("SUCCESS: Relative cap increased!");
                
                uint256 newCap = IVaultV2(VAULT).relativeCap(allocationId);
                console.log("New relative cap:", newCap);
                
            } catch Error(string memory reason) {
                console.log("ERROR:", reason);
            } catch (bytes memory data) {
                console.log("ERROR with data:");
                console.logBytes(data);
            }
        } else {
            console.log("Cannot execute yet, need to wait until:", executableTime);
        }
        
        vm.stopBroadcast();
        
        console.log("=== DONE ===");
    }
}