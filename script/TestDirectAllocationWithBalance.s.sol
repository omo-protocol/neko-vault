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
    function isAllocator(address account) external view returns (bool);
    function isAdapter(address adapter) external view returns (bool);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface IPendleAdapter {
    function getPTBalance() external view returns (uint256);
    function realAssets() external view returns (uint256);
}

contract TestDirectAllocationWithBalance is Script {
    
    // DEPLOYED CONTRACT ADDRESSES
    address constant VAULT = 0xE6c25968473FA49a886d2d50312a18ddbD40F4de;
    address constant ADAPTER = 0x58aD57e970cEFc09e01692DCe378F8BC59925f76;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant DEPLOYER = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    uint256 constant DEPOSIT_AMOUNT = 10000000000000000; // 0.01 kHYPE (larger amount)
    uint256 constant ALLOCATE_AMOUNT = 5000000000000000; // 0.005 kHYPE
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DIRECT ALLOCATION TEST WITH BALANCE ===");
        console.log("VaultV2:", VAULT);
        console.log("Adapter:", ADAPTER);
        console.log("Deployer:", DEPLOYER);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // CHECK REAL BALANCES
        console.log("=== BALANCE CHECK ===");
        uint256 deployerKHypeBalance = IERC20(KHYPE).balanceOf(DEPLOYER);
        uint256 vaultAssets = IVaultV2(VAULT).totalAssets();
        bool isAllocator = IVaultV2(VAULT).isAllocator(DEPLOYER);
        bool isAdapterRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
        
        console.log("Deployer kHYPE balance:", deployerKHypeBalance);
        console.log("Vault total assets:", vaultAssets);
        console.log("Is allocator:", isAllocator);
        console.log("Adapter registered:", isAdapterRegistered);
        console.log("");
        
        if (deployerKHypeBalance == 0) {
            console.log("ERROR: No kHYPE balance detected");
            vm.stopBroadcast();
            return;
        }
        
        require(isAllocator, "Not an allocator");
        require(isAdapterRegistered, "Adapter not registered");
        
        // DEPOSIT KHYPE TO VAULT
        console.log("=== DEPOSIT PHASE ===");
        uint256 depositAmount = deployerKHypeBalance > DEPOSIT_AMOUNT ? DEPOSIT_AMOUNT : deployerKHypeBalance / 2;
        console.log("Depositing", depositAmount, "kHYPE to vault...");
        
        IERC20(KHYPE).approve(VAULT, depositAmount);
        uint256 shares = IVaultV2(VAULT).deposit(depositAmount, DEPLOYER);
        
        console.log("SUCCESS: Deposited successfully!");
        console.log("Shares received:", shares);
        
        uint256 newVaultAssets = IVaultV2(VAULT).totalAssets();
        console.log("New vault assets:", newVaultAssets);
        console.log("");
        
        // TEST ALLOCATION
        console.log("=== ALLOCATION PHASE ===");
        uint256 testAllocationAmount = newVaultAssets > ALLOCATE_AMOUNT ? ALLOCATE_AMOUNT : newVaultAssets / 2;
        console.log("Testing allocation of", testAllocationAmount, "kHYPE...");
        
        uint256 adapterPtBefore = IPendleAdapter(ADAPTER).getPTBalance();
        uint256 vaultAssetsBefore = IVaultV2(VAULT).totalAssets();
        
        console.log("Before allocation:");
        console.log("  Vault assets:", vaultAssetsBefore);
        console.log("  Adapter PT balance:", adapterPtBefore);
        
        try IVaultV2(VAULT).allocate(ADAPTER, "", testAllocationAmount) {
            console.log("SUCCESS: ALLOCATION COMPLETED!");
            
            uint256 adapterPtAfter = IPendleAdapter(ADAPTER).getPTBalance();
            uint256 vaultAssetsAfter = IVaultV2(VAULT).totalAssets();
            
            console.log("");
            console.log("After allocation:");
            console.log("  Vault assets:", vaultAssetsAfter);
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  PT tokens gained:", adapterPtAfter - adapterPtBefore);
            console.log("  Vault assets change:", int256(vaultAssetsAfter) - int256(vaultAssetsBefore));
            
            if (adapterPtAfter > adapterPtBefore) {
                console.log("");
                console.log("*** COMPLETE SUCCESS! ***");
                console.log("*** ALLOCATION WORKING! ***");
                console.log("*** PT TOKENS RECEIVED! ***");
                console.log("*** PENDLE INTEGRATION OPERATIONAL! ***");
                
                // Test realAssets
                try IPendleAdapter(ADAPTER).realAssets() returns (uint256 realAssetsValue) {
                    console.log("*** realAssets() working:", realAssetsValue, "***");
                } catch {
                    console.log("INFO: realAssets() call failed");
                }
                
                // TEST DEALLOCATION
                console.log("");
                console.log("=== DEALLOCATION PHASE ===");
                uint256 deallocateAmount = testAllocationAmount / 2;
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
                        console.log("*** FULL END-TO-END VAULTV2 + PENDLE FLOW OPERATIONAL! ***");
                    }
                    
                } catch Error(string memory reason) {
                    console.log("Deallocation failed:", reason);
                } catch (bytes memory data) {
                    console.log("Deallocation failed with data:");
                    console.logBytes(data);
                }
                
            } else {
                console.log("");
                console.log("*** ALLOCATION SUCCEEDED BUT NO PT TOKENS ***");
                console.log("This indicates Pendle router interaction issues");
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Allocation failed with data:");
            console.logBytes(data);
            
            if (data.length >= 4) {
                bytes4 selector = bytes4(data);
                console.log("Error selector:", vm.toString(selector));
            }
        }
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== TEST COMPLETE ===");
        console.log("VaultV2 + PendleV2AdapterKHYPE tested with real kHYPE!");
    }
}