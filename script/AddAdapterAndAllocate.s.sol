// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IVaultV2 {
    function submit(bytes calldata data) external;
    function addAdapter(address adapter) external;
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
}

contract AddAdapterAndAllocate is Script {
    
    function run() external {
        address vault = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
        address adapter = 0x9487110ac27aE9f16f508B09038C8E95F1Ca9Fca; // DirectPendleAdapter with working config
        uint256 exactAmount = 100000000000000; // 0.0001 WHYPE
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== ADDING ADAPTER AND ALLOCATING ===");
        console.log("Vault:", vault);
        console.log("Adapter:", adapter);
        console.log("Amount:", exactAmount);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Submit timelock data
        IVaultV2(vault).submit(abi.encodeWithSignature("addAdapter(address)", adapter));
        console.log("Submitted addAdapter to timelock");
        
        // Add adapter (POC - immediate execution)
        IVaultV2(vault).addAdapter(adapter);
        console.log("Added adapter to vault");
        
        // Set absolute cap for adapter allocations
        console.log("\n=== SETTING ABSOLUTE CAP ===");
        // Use the predictable allocation ID from the adapter
        bytes memory idData = abi.encode("direct-pendle-allocation");
        uint256 absoluteCap = 1000000000000000000; // 1 WHYPE cap
        
        IVaultV2(vault).submit(abi.encodeWithSignature("increaseAbsoluteCap(bytes,uint256)", idData, absoluteCap));
        console.log("Submitted increaseAbsoluteCap to timelock");
        
        IVaultV2(vault).increaseAbsoluteCap(idData, absoluteCap);
        console.log("Set absolute cap:", absoluteCap);
        console.log("For ID data: direct-pendle-allocation");
        
        // Execute allocation - this will generate the transaction hash we need
        console.log("\n=== EXECUTING ALLOCATION FOR TRANSACTION HASH ===");
        IVaultV2(vault).allocate(adapter, "", exactAmount);
        console.log("*** ALLOCATION TRANSACTION HASH GENERATED! ***");
        
        vm.stopBroadcast();
        
        console.log("\n=== SUCCESS ===");
        console.log("Transaction hash generated for allocation call");
        console.log("Check broadcast files for the hash");
    }
}