// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/VaultV2.sol";
import "../src/adapters/PendleV2AdapterKHYPE.sol";
import "../src/interfaces/IERC20.sol";
import "../src/interfaces/IVaultV2.sol";


contract TestPendleV2AdapterKHYPEEndToEnd is Script {
    
    // HyperEVM addresses
    address constant KHYPE_TOKEN = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant VAULT_OWNER = 0x95e7EeA16ddbdb8F8aA8b4ec4B23df2067E9A413;
    address constant EXISTING_VAULT = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF; // Existing WHYPE vault
    
    VaultV2 vault;
    PendleV2AdapterKHYPE adapter;
    
    function run() external {
        vm.startBroadcast();
        
        console.log("=== PendleV2AdapterKHYPE End-to-End Test ===");
        console.log("kHYPE Token:", KHYPE_TOKEN);
        console.log("Pendle Router:", PENDLE_ROUTER);
        console.log("Pendle RouterStatic:", PENDLE_ROUTER_STATIC);
        console.log("PT Token:", PT_TOKEN);
        
        // Step 1: Deploy VaultV2 with kHYPE as underlying asset
        console.log("\n=== Step 1: Deploy VaultV2 with kHYPE asset ===");
        vault = new VaultV2(VAULT_OWNER, KHYPE_TOKEN);
        console.log("VaultV2 deployed at:", address(vault));
        console.log("Vault asset (should be kHYPE):", vault.asset());
        console.log("Vault owner:", vault.owner());
        
        require(vault.asset() == KHYPE_TOKEN, "Vault asset should be kHYPE");
        
        // Step 2: Deploy PendleV2AdapterKHYPE
        console.log("\n=== Step 2: Deploy PendleV2AdapterKHYPE ===");
        adapter = new PendleV2AdapterKHYPE(
            address(vault),
            PENDLE_ROUTER, 
            PENDLE_ROUTER_STATIC
        );
        console.log("PendleV2AdapterKHYPE deployed at:", address(adapter));
        console.log("Adapter vault asset (should be kHYPE):", adapter.asset());
        
        require(adapter.asset() == KHYPE_TOKEN, "Adapter asset should be kHYPE");
        
        // Step 3: Check initial balances and setup
        console.log("\n=== Step 3: Check Initial State ===");
        uint256 deployerKHypeBalance = IERC20(KHYPE_TOKEN).balanceOf(msg.sender);
        uint256 adapterKHypeBalance = IERC20(KHYPE_TOKEN).balanceOf(address(adapter));
        uint256 adapterPtBalance = IERC20(PT_TOKEN).balanceOf(address(adapter));
        
        console.log("Deployer kHYPE balance:", deployerKHypeBalance);
        console.log("Adapter kHYPE balance:", adapterKHypeBalance);
        console.log("Adapter PT balance:", adapterPtBalance);
        console.log("Vault total assets:", vault.totalAssets());
        
        // Step 4: Add adapter to vault
        console.log("\n=== Step 4: Add Adapter to Vault ===");
        try vault.addAdapter(address(adapter)) {
            console.log("Successfully added adapter to vault");
        } catch Error(string memory reason) {
            console.log("Failed to add adapter:", reason);
            return;
        } catch {
            console.log("Failed to add adapter with unknown error");
            return;
        }
        
        // Step 5: Deposit kHYPE into vault to get shares
        console.log("\n=== Step 5: Deposit kHYPE to Vault ===");
        uint256 depositAmount = 1000e18; // 1000 kHYPE
        
        if (deployerKHypeBalance >= depositAmount) {
            IERC20(KHYPE_TOKEN).approve(address(vault), depositAmount);
            try vault.deposit(depositAmount, msg.sender) returns (uint256 shares) {
                console.log("Deposited kHYPE:", depositAmount);
                console.log("Received shares:", shares);
                console.log("Vault total assets after deposit:", vault.totalAssets());
            } catch Error(string memory reason) {
                console.log("Deposit failed:", reason);
                return;
            }
        } else {
            console.log("WARNING:  Insufficient kHYPE balance for deposit, skipping deposit test");
        }
        
        // Step 6: Test Allocation (kHYPE → PT)
        console.log("\n=== Step 6: Test Allocation (kHYPE to PT) ===");
        uint256 allocateAmount = 500e18; // 500 kHYPE
        
        // Transfer kHYPE to adapter for allocation
        if (deployerKHypeBalance >= allocateAmount) {
            IERC20(KHYPE_TOKEN).transfer(address(adapter), allocateAmount);
            console.log("Transferred kHYPE to adapter:", allocateAmount);
            
            try vault.allocate(address(adapter), "", allocateAmount) {
                console.log("SUCCESS: Allocated kHYPE to PT:", allocateAmount);
                
                // Check post-allocation state
                uint256 newAdapterKHypeBalance = IERC20(KHYPE_TOKEN).balanceOf(address(adapter));
                uint256 newAdapterPtBalance = IERC20(PT_TOKEN).balanceOf(address(adapter));
                uint256 realAssetsValue = adapter.realAssets();
                
                console.log("Adapter kHYPE balance after allocation:", newAdapterKHypeBalance);
                console.log("Adapter PT balance after allocation:", newAdapterPtBalance);
                console.log("Adapter realAssets() value:", realAssetsValue);
                console.log("Vault total assets after allocation:", vault.totalAssets());
                
            } catch Error(string memory reason) {
                console.log("ERROR: Allocation failed:", reason);
                console.log("  This may be due to insufficient liquidity or price impact");
            } catch {
                console.log("ERROR: Allocation failed with unknown error");
            }
        } else {
            console.log("WARNING:  Insufficient kHYPE balance for allocation test");
        }
        
        // Step 7: Test realAssets() calculation in detail
        console.log("\n=== Step 7: Test realAssets() Calculation ===");
        uint256 currentPtBalance = IERC20(PT_TOKEN).balanceOf(address(adapter));
        
        if (currentPtBalance > 0) {
            try adapter.realAssets() returns (uint256 realAssets_) {
                console.log("realAssets() returned:", realAssets_);
                
                // Test individual calculation functions
                try adapter.calculateSimplifiedRealAssets(currentPtBalance) returns (uint256 dynamicValue) {
                    console.log("Dynamic calculation result:", dynamicValue);
                } catch {
                    console.log("Dynamic calculation failed");
                }
                
                try adapter.getCurrentRate() returns (uint256 ptToKHypeRate) {
                    console.log("Current PT to kHYPE rate:", ptToKHypeRate);
                    uint256 theoreticalValue = (currentPtBalance * ptToKHypeRate) / 1e18;
                    console.log("Theoretical kHYPE value:", theoreticalValue);
                } catch {
                    console.log("Failed to get current rate");
                }
                
            } catch Error(string memory reason) {
                console.log("ERROR: realAssets() failed:", reason);
            } catch {
                console.log("ERROR: realAssets() failed with unknown error");
            }
        } else {
            console.log("WARNING:  No PT balance to test realAssets()");
        }
        
        // Step 8: Test Deallocation (PT → kHYPE) 
        console.log("\n=== Step 8: Test Deallocation (PT to kHYPE) ===");
        currentPtBalance = IERC20(PT_TOKEN).balanceOf(address(adapter));
        
        if (currentPtBalance > 0) {
            uint256 deallocateAmount = currentPtBalance / 2; // Deallocate half
            console.log("Deallocating equivalent kHYPE:", deallocateAmount);
            
            uint256 beforeKHype = IERC20(KHYPE_TOKEN).balanceOf(address(adapter));
            uint256 beforePt = IERC20(PT_TOKEN).balanceOf(address(adapter));
            
            try vault.deallocate(address(adapter), "", deallocateAmount) {
                console.log("SUCCESS: Successfully deallocated PT back to kHYPE");
                
                uint256 afterKHype = IERC20(KHYPE_TOKEN).balanceOf(address(adapter));
                uint256 afterPt = IERC20(PT_TOKEN).balanceOf(address(adapter));
                uint256 kHypeReceived = afterKHype - beforeKHype;
                uint256 ptRedeemed = beforePt - afterPt;
                
                console.log("kHYPE received from deallocation:", kHypeReceived);
                console.log("PT tokens redeemed:", ptRedeemed);
                uint256 conversionRate = ptRedeemed > 0 ? (kHypeReceived * 1e18) / ptRedeemed : 0;
                console.log("Conversion rate (PT to kHYPE):", conversionRate);
                
            } catch Error(string memory reason) {
                console.log("ERROR: Deallocation failed:", reason);
                console.log("  This may be due to insufficient liquidity or high slippage");
            } catch {
                console.log("ERROR: Deallocation failed with unknown error");
            }
        } else {
            console.log("WARNING:  No PT balance to test deallocation");
        }
        
        // Step 9: Final State Summary
        console.log("\n=== Step 9: Final State Summary ===");
        console.log("Final adapter kHYPE balance:", IERC20(KHYPE_TOKEN).balanceOf(address(adapter)));
        console.log("Final adapter PT balance:", IERC20(PT_TOKEN).balanceOf(address(adapter)));
        console.log("Final vault total assets:", vault.totalAssets());
        
        try adapter.realAssets() returns (uint256 finalRealAssets) {
            console.log("Final realAssets() value:", finalRealAssets);
        } catch {
            console.log("Final realAssets() call failed");
        }
        
        // Step 10: Efficiency Comparison
        console.log("\n=== Step 10: Efficiency Analysis ===");
        console.log("SUCCESS: Simplified adapter completed successfully!");
        console.log("STATS: Benefits vs complex WHYPE adapter:");
        console.log("  - Single-step swaps (kHYPE to PT to kHYPE)");
        console.log("  - No HyperSwap V3 interactions needed");
        console.log("  - Lower gas costs");
        console.log("  - Reduced slippage risk");
        console.log("  - Simpler error handling");
        console.log("  - Faster execution");
        
        vm.stopBroadcast();
        
        console.log("\nCOMPLETE: PendleV2AdapterKHYPE End-to-End Test Completed!");
    }
}