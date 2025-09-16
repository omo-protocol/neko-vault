// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IVaultV2 {
    function submit(bytes calldata data) external;
    function addAdapter(address adapter) external;
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function isAdapter(address adapter) external view returns (bool);
}

contract RegisterAdapterAndAllocate is Script {
    
    function run() external {
        address vault = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
        address adapter = 0x9487110ac27aE9f16f508B09038C8E95F1Ca9Fca; // DirectPendleAdapter
        uint256 exactAmount = 100000000000000; // 0.0001 WHYPE
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== REGISTERING ADAPTER AND ALLOCATING ===");
        console.log("Vault:", vault);
        console.log("Adapter:", adapter);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Check current registration status
        bool isRegistered = IVaultV2(vault).isAdapter(adapter);
        console.log("Adapter currently registered:", isRegistered);
        
        if (!isRegistered) {
            console.log("Re-registering adapter...");
            
            // Submit timelock for addAdapter
            IVaultV2(vault).submit(abi.encodeWithSignature("addAdapter(address)", adapter));
            console.log("Submitted addAdapter to timelock");
            
            // Execute addAdapter (POC immediate execution)
            IVaultV2(vault).addAdapter(adapter);
            console.log("Added adapter to vault");
            
            // Verify registration
            bool nowRegistered = IVaultV2(vault).isAdapter(adapter);
            console.log("Adapter now registered:", nowRegistered);
            
            if (!nowRegistered) {
                console.log("ERROR: Adapter registration failed!");
                vm.stopBroadcast();
                return;
            }
        }
        
        console.log("\n=== EXECUTING ALLOCATION ===");
        console.log("Amount:", exactAmount);
        
        // Execute allocation to generate transaction hash
        IVaultV2(vault).allocate(adapter, "", exactAmount);
        
        console.log("*** SUCCESS: ALLOCATION TRANSACTION HASH GENERATED! ***");
        
        vm.stopBroadcast();
        
        console.log("\n=== RESULT ===");
        console.log("Check broadcast files for allocation transaction hash!");
    }
}