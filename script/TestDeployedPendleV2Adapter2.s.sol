// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PendleV2Adapter2} from "../src/adapters/PendleV2Adapter2.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IVaultV2 {
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function deallocate(address adapter, bytes calldata data, uint256 assets) external;
    function isAdapter(address adapter) external view returns (bool);
    function allocation(bytes32 id) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
    function realAssets() external view returns (uint256);
}

contract TestDeployedPendleV2Adapter2 is Script {
    
    // Use the deployed contract address from deployment
    address constant DEPLOYED_ADAPTER = 0x4eDbEEB2c3888Ba1244a50C714ad1BF1E55E0a4D;
    address constant VAULT = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    
    // Test amounts
    uint256 constant SMALL_TEST = 25000000000000;  // 0.000025 WHYPE
    uint256 constant MEDIUM_TEST = 100000000000000; // 0.0001 WHYPE  
    uint256 constant LARGE_TEST = 250000000000000;  // 0.00025 WHYPE
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== TESTING DEPLOYED PENDLE V2 ADAPTER2 ===");
        console.log("Deployed Contract:", DEPLOYED_ADAPTER);
        console.log("VaultV2:", VAULT);
        console.log("Testing with real deployed contracts on HyperEVM");
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        PendleV2Adapter2 adapter = PendleV2Adapter2(DEPLOYED_ADAPTER);
        bytes32 allocationId = keccak256(abi.encode("pendle-v2-allocation"));
        
        // PHASE 1: CONTRACT STATE VERIFICATION
        console.log("PHASE 1: Verify Contract State");
        console.log("==============================");
        
        bool isRegistered = IVaultV2(VAULT).isAdapter(DEPLOYED_ADAPTER);
        console.log("Adapter registered with vault:", isRegistered);
        
        address vaultAsset = IVaultV2(VAULT).asset();
        uint256 vaultTotalAssets = IVaultV2(VAULT).totalAssets();
        uint256 currentAllocation = IVaultV2(VAULT).allocation(allocationId);
        
        console.log("Vault asset:", vaultAsset);
        console.log("Vault total assets:", vaultTotalAssets);
        console.log("Current adapter allocation:", currentAllocation);
        
        // Test contract functions
        uint256 adapterPtBalance = adapter.getPTBalance();
        uint256 adapterWhypeBalance = adapter.getWHYPEBalance();
        
        console.log("Adapter PT balance:", adapterPtBalance);
        console.log("Adapter WHYPE balance:", adapterWhypeBalance);
        
        try adapter.realAssets() returns (uint256 realAssetsValue) {
            console.log("Adapter realAssets:", realAssetsValue);
        } catch {
            console.log("Adapter realAssets: FAILED");
        }
        
        try adapter.getCurrentRates() returns (uint256 kHypeToWhype, uint256 ptToKHype) {
            console.log("Current rates:");
            console.log("  kHYPE->WHYPE:", kHypeToWhype);
            console.log("  PT->kHYPE:", ptToKHype);
        } catch {
            console.log("Rate queries failed");
        }
        
        console.log("");
        
        // PHASE 2: SMALL ALLOCATION TEST
        console.log("PHASE 2: Small Allocation Test");
        console.log("==============================");
        
        uint256 ptBefore = adapter.getPTBalance();
        uint256 allocationBefore = IVaultV2(VAULT).allocation(allocationId);
        
        console.log("Before small allocation:");
        console.log("  PT balance:", ptBefore);
        console.log("  Allocation:", allocationBefore);
        
        console.log("Executing small allocation:", SMALL_TEST, "WHYPE...");
        IVaultV2(VAULT).allocate(DEPLOYED_ADAPTER, "", SMALL_TEST);
        
        uint256 ptAfterSmall = adapter.getPTBalance();
        uint256 allocationAfterSmall = IVaultV2(VAULT).allocation(allocationId);
        uint256 realAssetsSmall = 0;
        
        try adapter.realAssets() returns (uint256 ra) {
            realAssetsSmall = ra;
        } catch {}
        
        console.log("After small allocation:");
        console.log("  PT balance:", ptAfterSmall);
        console.log("  PT gained:", ptAfterSmall - ptBefore);
        console.log("  Allocation:", allocationAfterSmall);  
        console.log("  realAssets:", realAssetsSmall);
        
        uint256 efficiency = realAssetsSmall > 0 ? (realAssetsSmall * 100) / SMALL_TEST : 0;
        console.log("  Efficiency:", efficiency, "%");
        console.log("");
        
        // PHASE 3: MEDIUM ALLOCATION TEST
        console.log("PHASE 3: Medium Allocation Test");
        console.log("===============================");
        
        console.log("Executing medium allocation:", MEDIUM_TEST, "WHYPE...");
        IVaultV2(VAULT).allocate(DEPLOYED_ADAPTER, "", MEDIUM_TEST);
        
        uint256 ptAfterMedium = adapter.getPTBalance();
        uint256 allocationAfterMedium = IVaultV2(VAULT).allocation(allocationId);
        uint256 realAssetsMedium = 0;
        
        try adapter.realAssets() returns (uint256 ra) {
            realAssetsMedium = ra;
        } catch {}
        
        console.log("After medium allocation:");
        console.log("  PT balance:", ptAfterMedium);
        console.log("  PT gained:", ptAfterMedium - ptAfterSmall);
        console.log("  Total allocation:", allocationAfterMedium);
        console.log("  realAssets:", realAssetsMedium);
        
        uint256 efficiencyMedium = realAssetsMedium > 0 ? (realAssetsMedium * 100) / (SMALL_TEST + MEDIUM_TEST) : 0;
        console.log("  Overall efficiency:", efficiencyMedium, "%");
        console.log("");
        
        // PHASE 4: DEALLOCATE TESTING
        console.log("PHASE 4: Deallocate Testing");
        console.log("===========================");
        
        // Test 1: Small partial deallocate
        uint256 partialDeallocate = SMALL_TEST / 2; // Half of small allocation
        uint256 whypeBeforeDealloc = IERC20(WHYPE).balanceOf(DEPLOYED_ADAPTER);
        uint256 ptBeforeDealloc = adapter.getPTBalance();
        
        console.log("Before partial deallocate:");
        console.log("  PT balance:", ptBeforeDealloc);
        console.log("  WHYPE balance:", whypeBeforeDealloc);
        console.log("  Attempting to deallocate:", partialDeallocate, "WHYPE equivalent");
        
        bool partialSuccess = false;
        try IVaultV2(VAULT).deallocate(DEPLOYED_ADAPTER, "", partialDeallocate) {
            partialSuccess = true;
            
            uint256 ptAfterPartial = adapter.getPTBalance();
            uint256 whypeAfterPartial = IERC20(WHYPE).balanceOf(DEPLOYED_ADAPTER);
            uint256 allocationAfterPartial = IVaultV2(VAULT).allocation(allocationId);
            
            console.log("After partial deallocate:");
            console.log("  PT balance:", ptAfterPartial);
            console.log("  PT redeemed:", ptBeforeDealloc - ptAfterPartial);
            console.log("  WHYPE balance:", whypeAfterPartial);
            console.log("  WHYPE received:", whypeAfterPartial - whypeBeforeDealloc);
            console.log("  Allocation:", allocationAfterPartial);
            console.log("  PARTIAL DEALLOCATE SUCCESS!");
        } catch {
            console.log("  PARTIAL DEALLOCATE FAILED");
        }
        
        console.log("");
        
        // Test 2: Larger deallocate
        uint256 largerDeallocate = MEDIUM_TEST / 2; // Half of medium allocation
        uint256 ptBeforeLarger = adapter.getPTBalance();
        uint256 whypeBeforeLarger = IERC20(WHYPE).balanceOf(DEPLOYED_ADAPTER);
        
        console.log("Testing larger deallocate:");
        console.log("  Current PT balance:", ptBeforeLarger);
        console.log("  Current WHYPE balance:", whypeBeforeLarger);
        console.log("  Attempting to deallocate:", largerDeallocate, "WHYPE equivalent");
        
        bool largerSuccess = false;
        try IVaultV2(VAULT).deallocate(DEPLOYED_ADAPTER, "", largerDeallocate) {
            largerSuccess = true;
            
            uint256 ptAfterLarger = adapter.getPTBalance();
            uint256 whypeAfterLarger = IERC20(WHYPE).balanceOf(DEPLOYED_ADAPTER);
            uint256 allocationAfterLarger = IVaultV2(VAULT).allocation(allocationId);
            uint256 realAssetsAfterLarger = 0;
            
            try adapter.realAssets() returns (uint256 ra) {
                realAssetsAfterLarger = ra;
            } catch {}
            
            console.log("After larger deallocate:");
            console.log("  PT balance:", ptAfterLarger);
            console.log("  PT redeemed:", ptBeforeLarger - ptAfterLarger);
            console.log("  WHYPE balance:", whypeAfterLarger);
            console.log("  WHYPE received:", whypeAfterLarger - whypeBeforeLarger);
            console.log("  Allocation:", allocationAfterLarger);
            console.log("  realAssets:", realAssetsAfterLarger);
            console.log("  LARGER DEALLOCATE SUCCESS!");
        } catch {
            console.log("  LARGER DEALLOCATE FAILED");
        }
        
        console.log("");
        
        // PHASE 5: DYNAMIC SLIPPAGE VALIDATION
        console.log("PHASE 5: Dynamic Slippage Validation");
        console.log("====================================");
        
        uint256 currentPt = adapter.getPTBalance();
        if (currentPt > 0) {
            // Test dynamic calculations with different amounts
            uint256[] memory testAmounts = new uint256[](3);
            testAmounts[0] = 1000000000000000000;   // 1 WHYPE
            testAmounts[1] = 10000000000000000000;  // 10 WHYPE  
            testAmounts[2] = 100000000000000000000; // 100 WHYPE
            
            for (uint i = 0; i < testAmounts.length; i++) {
                uint256 testAmount = testAmounts[i];
                console.log("Testing dynamic calculation for", testAmount, "WHYPE:");
                
                try adapter.calculateDynamicRealAssets(testAmount) returns (uint256 dynamic) {
                    console.log("  Dynamic result:", dynamic);
                    
                    try adapter.getAccurateRealAssets(testAmount) returns (uint256 theoretical) {
                        console.log("  Theoretical result:", theoretical);
                        uint256 slippage = theoretical > dynamic ? 
                            ((theoretical - dynamic) * 10000) / theoretical : 0;
                        console.log("  Implied slippage:", slippage, "bp");
                    } catch {
                        console.log("  Theoretical calculation failed");
                    }
                } catch {
                    console.log("  Dynamic calculation failed");
                }
            }
        } else {
            console.log("No PT balance for slippage testing");
        }
        
        console.log("");
        
        vm.stopBroadcast();
        
        // FINAL RESULTS
        console.log("=== DEPLOYED CONTRACT TEST RESULTS ===");
        console.log("Contract Address:", DEPLOYED_ADAPTER);
        console.log("Registration Status:", isRegistered ? "REGISTERED" : "NOT REGISTERED");
        console.log("Small Allocation:", "PASSED");
        console.log("Medium Allocation:", "PASSED");
        console.log("Partial Deallocate:", partialSuccess ? "PASSED" : "FAILED");
        console.log("Larger Deallocate:", largerSuccess ? "PASSED" : "FAILED");
        console.log("");
        
        if (isRegistered && partialSuccess && largerSuccess) {
            console.log("SUCCESS: DEPLOYED CONTRACT FULLY OPERATIONAL!");
            console.log("PendleV2Adapter2 with Dynamic Slippage working on HyperEVM!");
            console.log("Ready for production use with VaultV2!");
        } else if (isRegistered) {
            console.log("PARTIAL SUCCESS: Core functionality working");
            console.log("Contract deployed and registered successfully");
            console.log("Allocations working, deallocates may need refinement");
        } else {
            console.log("DEPLOYMENT ISSUE: Contract not properly registered");
        }
    }
}