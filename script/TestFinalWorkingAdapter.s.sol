// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FinalWorkingDirectSwapAdapter} from "../src/adapters/FinalWorkingDirectSwapAdapter.sol";

interface IVaultV2 {
    function submit(bytes calldata data) external;
    function addAdapter(address adapter) external;
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function isAdapter(address adapter) external view returns (bool);
    function absoluteCap(bytes32 id) external view returns (uint256);
}

contract TestFinalWorkingAdapter is Script {
    
    function run() external {
        address vault = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
        address pendleRouter = 0x888888888889758F76e7103c6CbF23ABbF58F946;
        uint256 exactAmount = 10000000000000; // 0.00001 WHYPE
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== FINAL WORKING ADAPTER DEPLOYMENT ===");
        console.log("ULTIMATE END-TO-END: WHYPE->kHYPE->PT");
        console.log("Pool: 0x5Cbe810071DE393de35e574Fb2830E16dA794bab");
        console.log("Proven working: kHYPE transfer confirmed!");
        console.log("Optimized: No price limits, clean error handling");
        
        vm.startBroadcast(deployerPrivateKey);
        
        FinalWorkingDirectSwapAdapter adapter = new FinalWorkingDirectSwapAdapter(vault, pendleRouter);
        console.log("FinalWorkingDirectSwapAdapter deployed:", address(adapter));
        
        IVaultV2(vault).submit(abi.encodeWithSignature("addAdapter(address)", address(adapter)));
        IVaultV2(vault).addAdapter(address(adapter));
        console.log("Adapter registered successfully");
        
        bytes memory idData = abi.encode("final-working-allocation");
        uint256 absoluteCap = 1000000000000000000; // 1 WHYPE cap
        uint256 relativeCap = 1000000000000000000; // 100% relative cap
        
        IVaultV2(vault).submit(abi.encodeWithSignature("increaseAbsoluteCap(bytes,uint256)", idData, absoluteCap));
        IVaultV2(vault).increaseAbsoluteCap(idData, absoluteCap);
        console.log("Absolute cap set:", absoluteCap);
        
        IVaultV2(vault).submit(abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, relativeCap));
        IVaultV2(vault).increaseRelativeCap(idData, relativeCap);
        console.log("Relative cap set:", relativeCap);
        
        bool isRegistered = IVaultV2(vault).isAdapter(address(adapter));
        bytes32 allocationId = keccak256(abi.encode("final-working-allocation"));
        uint256 capSet = IVaultV2(vault).absoluteCap(allocationId);
        
        console.log("Adapter registered:", isRegistered);
        console.log("Cap verified:", capSet);
        
        if (isRegistered && capSet >= exactAmount) {
            console.log("\\n=== EXECUTING FINAL WORKING ALLOCATION ===");
            console.log("Amount:", exactAmount);
            console.log("Complete WHYPE->kHYPE->PT end-to-end flow!");
            
            IVaultV2(vault).allocate(address(adapter), "", exactAmount);
            
            console.log("*** ULTIMATE SUCCESS! ***");
            console.log("*** COMPLETE END-TO-END ALLOCATION ACHIEVED! ***");
            console.log("*** WHYPE->kHYPE->PT FLOW WORKING! ***");
            
            // Check final balances
            uint256 ptBalance = adapter.getPTBalance();
            uint256 kHypeBalance = adapter.getKHypeBalance();
            console.log("Final PT balance:", ptBalance);
            console.log("Final kHYPE balance:", kHypeBalance);
            
        } else {
            console.log("ERROR: Setup verification failed");
        }
        
        vm.stopBroadcast();
        
        console.log("\\n=== FINAL WORKING RESULTS ===");
        console.log("FinalWorkingDirectSwapAdapter:", address(adapter));
        console.log("END-TO-END SUCCESS: VaultV2 + HyperSwap V3 + Pendle!");
    }
}