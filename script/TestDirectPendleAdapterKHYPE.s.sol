// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/VaultV2.sol";
import "../src/adapters/PendleV2AdapterKHYPE.sol";
import "../src/interfaces/IERC20.sol";

contract TestDirectPendleAdapterKHYPE is Script {
    
    // HyperEVM addresses
    address constant KHYPE_TOKEN = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    
    // Test amounts - start with very small amounts
    uint256 constant TEST_AMOUNT = 1e18; // 1 kHYPE
    
    VaultV2 vault;
    PendleV2AdapterKHYPE adapter;
    
    function run() external {
        vm.startBroadcast();
        
        console.log("=== Direct PendleV2AdapterKHYPE Allocation/Deallocation Test ===");
        console.log("Test amount (kHYPE):", TEST_AMOUNT);
        
        // Step 1: Deploy mock vault to act as caller
        console.log("\n=== Step 1: Deploy Mock Vault ===");
        vault = new VaultV2(msg.sender, KHYPE_TOKEN);
        console.log("Mock vault deployed at:", address(vault));
        
        // Step 2: Deploy adapter
        console.log("\n=== Step 2: Deploy Adapter ===");
        adapter = new PendleV2AdapterKHYPE(
            address(vault),
            PENDLE_ROUTER, 
            PENDLE_ROUTER_STATIC
        );
        console.log("Adapter deployed at:", address(adapter));
        
        // Step 3: Check initial balances
        console.log("\n=== Step 3: Initial Balances ===");
        uint256 deployerKHype = IERC20(KHYPE_TOKEN).balanceOf(msg.sender);
        uint256 adapterKHype = IERC20(KHYPE_TOKEN).balanceOf(address(adapter));
        uint256 adapterPT = IERC20(PT_TOKEN).balanceOf(address(adapter));
        
        console.log("Deployer kHYPE balance:", deployerKHype);
        console.log("Adapter kHYPE balance:", adapterKHype);
        console.log("Adapter PT balance:", adapterPT);
        
        if (deployerKHype < TEST_AMOUNT) {
            console.log("ERROR: Insufficient kHYPE balance for test");
            console.log("Need:", TEST_AMOUNT);
            console.log("Have:", deployerKHype);
            vm.stopBroadcast();
            return;
        }
        
        // Step 4: Transfer kHYPE to adapter for allocation test
        console.log("\n=== Step 4: Prepare for Allocation ===");
        IERC20(KHYPE_TOKEN).transfer(address(adapter), TEST_AMOUNT);
        console.log("Transferred kHYPE to adapter:", TEST_AMOUNT);
        
        uint256 adapterKHypeAfterTransfer = IERC20(KHYPE_TOKEN).balanceOf(address(adapter));
        console.log("Adapter kHYPE balance after transfer:", adapterKHypeAfterTransfer);
        
        // Step 5: Test direct allocation (adapter as msg.sender won't work, need vault to call)
        console.log("\n=== Step 5: Test Allocation via Vault Call ===");
        
        // We need to call the adapter from the vault's perspective
        // Since we own the vault, we can make the call
        
        try this.testAllocation(address(adapter), TEST_AMOUNT) {
            console.log("SUCCESS: Allocation call completed");
            
            // Check balances after allocation
            uint256 newAdapterKHype = IERC20(KHYPE_TOKEN).balanceOf(address(adapter));
            uint256 newAdapterPT = IERC20(PT_TOKEN).balanceOf(address(adapter));
            
            console.log("Adapter kHYPE after allocation:", newAdapterKHype);
            console.log("Adapter PT after allocation:", newAdapterPT);
            console.log("PT tokens received:", newAdapterPT);
            
            if (newAdapterPT > 0) {
                console.log("SUCCESS: Received PT tokens from allocation!");
                
                // Test realAssets calculation
                try adapter.realAssets() returns (uint256 realAssets_) {
                    console.log("realAssets() value:", realAssets_);
                } catch {
                    console.log("realAssets() call failed");
                }
                
                // Step 6: Test deallocation
                console.log("\n=== Step 6: Test Deallocation ===");
                
                uint256 deallocateAmount = newAdapterPT / 2; // Deallocate half
                console.log("Attempting to deallocate PT equivalent to kHYPE:", deallocateAmount);
                
                try this.testDeallocation(address(adapter), deallocateAmount) {
                    console.log("SUCCESS: Deallocation call completed");
                    
                    uint256 finalAdapterKHype = IERC20(KHYPE_TOKEN).balanceOf(address(adapter));
                    uint256 finalAdapterPT = IERC20(PT_TOKEN).balanceOf(address(adapter));
                    uint256 kHypeRecovered = finalAdapterKHype - newAdapterKHype;
                    uint256 ptRedeemed = newAdapterPT - finalAdapterPT;
                    
                    console.log("Final adapter kHYPE:", finalAdapterKHype);
                    console.log("Final adapter PT:", finalAdapterPT);
                    console.log("kHYPE recovered:", kHypeRecovered);
                    console.log("PT redeemed:", ptRedeemed);
                    
                    if (kHypeRecovered > 0) {
                        console.log("SUCCESS: Recovered kHYPE from PT deallocation!");
                        uint256 conversionRate = ptRedeemed > 0 ? (kHypeRecovered * 1e18) / ptRedeemed : 0;
                        console.log("PT->kHYPE conversion rate:", conversionRate);
                    }
                    
                } catch Error(string memory reason) {
                    console.log("ERROR: Deallocation failed:", reason);
                } catch {
                    console.log("ERROR: Deallocation failed with unknown error");
                }
                
            } else {
                console.log("WARNING: No PT tokens received - allocation may have failed");
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed:", reason);
            
            // Check if it's an authorization error
            if (keccak256(bytes(reason)) == keccak256(bytes("NotAuthorized()"))) {
                console.log("This is expected - adapter requires vault as caller");
                console.log("Let's test with proper vault integration");
                
                // Alternative: Test the internal functions directly if possible
                this.testInternalFunctions();
            }
        } catch {
            console.log("ERROR: Allocation failed with unknown error");
        }
        
        vm.stopBroadcast();
        
        console.log("\n=== Test Summary ===");
        console.log("Adapter contract deployed and basic functions tested");
        console.log("Full allocation/deallocation requires proper vault integration");
    }
    
    // Helper function to test allocation (called from vault context)
    function testAllocation(address adapterAddr, uint256 amount) external {
        require(msg.sender == address(this), "Must be called from script");
        
        PendleV2AdapterKHYPE testAdapter = PendleV2AdapterKHYPE(adapterAddr);
        
        // This will fail with NotAuthorized since we're not the vault
        testAdapter.allocate("", amount, bytes4(0), msg.sender);
    }
    
    // Helper function to test deallocation (called from vault context) 
    function testDeallocation(address adapterAddr, uint256 amount) external {
        require(msg.sender == address(this), "Must be called from script");
        
        PendleV2AdapterKHYPE testAdapter = PendleV2AdapterKHYPE(adapterAddr);
        
        // This will fail with NotAuthorized since we're not the vault
        testAdapter.deallocate("", amount, bytes4(0), msg.sender);
    }
    
    // Test internal calculation functions
    function testInternalFunctions() external view {
        console.log("\n=== Testing Internal Functions ===");
        
        // Test rate calculation if RouterStatic is available
        try adapter.getCurrentRate() returns (uint256 rate) {
            console.log("Current PT->kHYPE rate from RouterStatic:", rate);
            
            // Test simulation functions
            try adapter.calculateSimplifiedRealAssets(1000e18) returns (uint256 simulated) {
                console.log("Simulated realAssets for 1000 PT:", simulated);
            } catch {
                console.log("Simulation failed - may be due to RouterStatic unavailability");
            }
            
        } catch {
            console.log("RouterStatic not available - expected on HyperEVM");
        }
        
        console.log("Internal function testing completed");
    }
}