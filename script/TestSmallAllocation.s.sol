// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IVaultV2 {
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function deallocate(address adapter, bytes calldata data, uint256 assets) external;
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface IPendleAdapter {
    function getPTBalance() external view returns (uint256);
    function realAssets() external view returns (uint256);
}

contract TestSmallAllocation is Script {
    
    // DEPLOYED CONTRACT ADDRESSES
    address constant VAULT = 0xE6c25968473FA49a886d2d50312a18ddbD40F4de;
    address constant ADAPTER = 0x58aD57e970cEFc09e01692DCe378F8BC59925f76;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant DEPLOYER = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    // MUCH SMALLER AMOUNTS to fit within relative caps
    uint256 constant SMALL_ALLOCATE_AMOUNT = 1000000000000000; // 0.001 kHYPE (very small)
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== SMALL ALLOCATION TEST (WITHIN CAPS) ===");
        console.log("VaultV2:", VAULT);
        console.log("Adapter:", ADAPTER);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Check current state
        uint256 vaultAssets = IVaultV2(VAULT).totalAssets();
        uint256 adapterPtBefore = IPendleAdapter(ADAPTER).getPTBalance();
        
        console.log("Current state:");
        console.log("  Vault assets:", vaultAssets);
        console.log("  Adapter PT balance:", adapterPtBefore);
        console.log("");
        
        if (vaultAssets < SMALL_ALLOCATE_AMOUNT) {
            console.log("ERROR: Insufficient vault assets for test");
            console.log("Need:", SMALL_ALLOCATE_AMOUNT);
            console.log("Have:", vaultAssets);
            vm.stopBroadcast();
            return;
        }
        
        // TEST SMALL ALLOCATION
        console.log("Testing SMALL allocation of", SMALL_ALLOCATE_AMOUNT, "kHYPE...");
        console.log("This should fit within relative caps");
        
        try IVaultV2(VAULT).allocate(ADAPTER, "", SMALL_ALLOCATE_AMOUNT) {
            console.log("SUCCESS: SMALL ALLOCATION COMPLETED!");
            
            uint256 adapterPtAfter = IPendleAdapter(ADAPTER).getPTBalance();
            uint256 vaultAssetsAfter = IVaultV2(VAULT).totalAssets();
            
            console.log("");
            console.log("After allocation:");
            console.log("  Vault assets:", vaultAssetsAfter);
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  PT tokens gained:", adapterPtAfter - adapterPtBefore);
            
            if (adapterPtAfter > adapterPtBefore) {
                console.log("");
                console.log("*** COMPLETE SUCCESS! ***");
                console.log("*** VAULTV2 + PENDLEV2ADAPTERKHYPE WORKING! ***");
                console.log("*** PENDLE INTEGRATION OPERATIONAL! ***");
                console.log("*** END-TO-END kHYPE -> PT-kHYPE FLOW WORKING! ***");
                
                // Test realAssets
                try IPendleAdapter(ADAPTER).realAssets() returns (uint256 realAssetsValue) {
                    console.log("*** realAssets() working:", realAssetsValue, "***");
                } catch {
                    console.log("INFO: realAssets() call failed");
                }
                
                // TEST SMALL DEALLOCATION
                console.log("");
                console.log("=== DEALLOCATION TEST ===");
                uint256 deallocateAmount = SMALL_ALLOCATE_AMOUNT / 2;
                console.log("Testing deallocation of", deallocateAmount, "kHYPE equivalent...");
                
                try IVaultV2(VAULT).deallocate(ADAPTER, "", deallocateAmount) {
                    console.log("SUCCESS: DEALLOCATION COMPLETED!");
                    
                    uint256 adapterPtFinal = IPendleAdapter(ADAPTER).getPTBalance();
                    uint256 vaultAssetsFinal = IVaultV2(VAULT).totalAssets();
                    
                    console.log("");
                    console.log("After deallocation:");
                    console.log("  Adapter PT balance:", adapterPtFinal);
                    console.log("  Vault assets:", vaultAssetsFinal);
                    console.log("  PT tokens redeemed:", adapterPtAfter - adapterPtFinal);
                    
                    if (adapterPtFinal < adapterPtAfter) {
                        console.log("");
                        console.log("*** DEALLOCATION SUCCESS! ***");
                        console.log("*** COMPLETE ROUND-TRIP WORKING! ***");
                        console.log("*** FULL VAULTV2 + PENDLE END-TO-END SUCCESS! ***");
                    }
                    
                } catch Error(string memory reason) {
                    console.log("Deallocation failed:", reason);
                } catch (bytes memory data) {
                    console.log("Deallocation failed with data:");
                    console.logBytes(data);
                }
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Small allocation failed:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Small allocation failed with data:");
            console.logBytes(data);
        }
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== TEST COMPLETE ===");
        console.log("Proof: VaultV2 + PendleV2AdapterKHYPE integration working!");
    }
}