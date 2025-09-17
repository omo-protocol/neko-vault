// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/adapters/PendleV2AdapterKHYPE.sol";
import "../src/interfaces/IERC20.sol";

interface IVaultV2 {
    function asset() external view returns (address);
    function allocate(address adapter, bytes calldata data, uint256 assets) external returns (bytes32[] memory, int256);
    function deallocate(address adapter, bytes calldata data, uint256 assets) external returns (bytes32[] memory, int256);
    function totalAssets() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256);
}

contract TestRealAllocationDeallocation is Script {
    
    // Deployed adapter address from previous test
    address constant ADAPTER_ADDRESS = 0xaE9bEA922FE1E8AA9128D53BB7CdCC0D3f936bcE;
    address constant VAULT_V2 = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
    address constant VAULT_ASSET = 0x5555555555555555555555555555555555555555; // wHYPE
    
    // Test with very small amounts to minimize risk
    uint256 constant TEST_AMOUNT = 0.0001e18; // 0.0001 wHYPE
    uint256 constant MIN_TEST_AMOUNT = 0.00001e18; // 0.00001 wHYPE as fallback
    
    PendleV2AdapterKHYPE public adapter;
    IVaultV2 public vault;
    IERC20 public asset;
    address public deployer;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== Testing Real Allocation/Deallocation with Fixed Adapter ===");
        console.log("Deployer:", deployer);
        console.log("Using existing adapter:", ADAPTER_ADDRESS);
        
        // Initialize contracts
        initializeContracts();
        
        // Check balances and determine test amount
        uint256 testAmount = determineTestAmount();
        
        if (testAmount == 0) {
            console.log("ERROR: No funds available for testing");
            vm.stopBroadcast();
            return;
        }
        
        // Step 1: Deposit into vault to get shares
        depositIntoVault(testAmount);
        
        // Step 2: Test allocation
        testAllocation(testAmount);
        
        // Step 3: Test realAssets after allocation
        testRealAssetsWithPT();
        
        // Step 4: Test deallocation
        testDeallocation(testAmount);
        
        // Step 5: Final state validation
        validateFinalState();
        
        console.log("\n=== ALL REAL FUND TESTS COMPLETED ===");
        
        vm.stopBroadcast();
    }
    
    function initializeContracts() internal {
        console.log("\n1. Initializing contracts...");
        
        adapter = PendleV2AdapterKHYPE(ADAPTER_ADDRESS);
        vault = IVaultV2(VAULT_V2);
        asset = IERC20(VAULT_ASSET);
        
        console.log("SUCCESS: Adapter:", address(adapter));
        console.log("SUCCESS: Vault:", address(vault));
        console.log("SUCCESS: Asset:", address(asset));
    }
    
    function determineTestAmount() internal view returns (uint256) {
        console.log("\n2. Determining test amount...");
        
        uint256 assetBalance = asset.balanceOf(deployer);
        console.log("Available asset balance:", assetBalance, "wei");
        console.log("Available asset balance:", assetBalance / 1e18, "tokens");
        
        if (assetBalance >= TEST_AMOUNT) {
            console.log("SUCCESS: Using standard test amount:", TEST_AMOUNT / 1e18, "tokens");
            return TEST_AMOUNT;
        } else if (assetBalance >= MIN_TEST_AMOUNT) {
            console.log("SUCCESS: Using minimum test amount:", MIN_TEST_AMOUNT / 1e18, "tokens");
            return MIN_TEST_AMOUNT;
        } else if (assetBalance > 1000) { // At least 1000 wei
            uint256 safeAmount = assetBalance / 2; // Use half of available balance
            console.log("SUCCESS: Using safe amount:", safeAmount, "wei");
            return safeAmount;
        } else {
            console.log("ERROR: Insufficient funds for testing");
            return 0;
        }
    }
    
    function depositIntoVault(uint256 testAmount) internal {
        console.log("\n3. Depositing into vault...");
        
        uint256 beforeBalance = asset.balanceOf(deployer);
        uint256 beforeShares = vault.balanceOf(deployer);
        
        // Approve vault to spend our asset
        asset.approve(address(vault), testAmount);
        console.log("SUCCESS: Approved vault to spend", testAmount, "wei");
        
        try vault.deposit(testAmount, deployer) returns (uint256 shares) {
            console.log("SUCCESS: Deposited", testAmount, "wei");
            console.log("SUCCESS: Received", shares, "shares");
            
            uint256 afterBalance = asset.balanceOf(deployer);
            uint256 afterShares = vault.balanceOf(deployer);
            
            console.log("Asset balance change:", beforeBalance - afterBalance, "wei");
            console.log("Vault shares change:", afterShares - beforeShares, "shares");
        } catch Error(string memory reason) {
            console.log("ERROR: Deposit failed:", reason);
        } catch {
            console.log("ERROR: Deposit failed with unknown error");
        }
    }
    
    function testAllocation(uint256 testAmount) internal {
        console.log("\n4. Testing allocation...");
        
        // Use a smaller amount for allocation to be safe
        uint256 allocateAmount = testAmount / 2;
        if (allocateAmount == 0) allocateAmount = 1; // At least 1 wei
        
        console.log("Attempting to allocate:", allocateAmount, "wei");
        
        uint256 beforeAdapterAssets = adapter.realAssets();
        uint256 beforeAdapterBalance = asset.balanceOf(address(adapter));
        uint256 beforePTBalance = adapter.getPTBalance();
        
        console.log("Before allocation - Adapter real assets:", beforeAdapterAssets);
        console.log("Before allocation - Adapter asset balance:", beforeAdapterBalance);
        console.log("Before allocation - Adapter PT balance:", beforePTBalance);
        
        // Transfer asset to adapter first (simulating vault behavior)
        asset.transfer(address(adapter), allocateAmount);
        console.log("SUCCESS: Transferred", allocateAmount, "wei to adapter");
        
        try adapter.allocate("", allocateAmount, bytes4(0), address(0)) returns (bytes32[] memory ids, int256 change) {
            console.log("SUCCESS: Allocation completed");
            console.log("Allocation IDs length:", ids.length);
            console.log("Allocation change:", change > 0 ? uint256(change) : 0, "positive change");
            
            uint256 afterAdapterAssets = adapter.realAssets();
            uint256 afterAdapterBalance = asset.balanceOf(address(adapter));
            uint256 afterPTBalance = adapter.getPTBalance();
            
            console.log("After allocation - Adapter real assets:", afterAdapterAssets);
            console.log("After allocation - Adapter asset balance:", afterAdapterBalance);
            console.log("After allocation - Adapter PT balance:", afterPTBalance);
            
            if (afterPTBalance > beforePTBalance) {
                console.log("SUCCESS: PT balance increased by:", afterPTBalance - beforePTBalance);
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed:", reason);
        } catch {
            console.log("ERROR: Allocation failed with unknown error");
        }
    }
    
    function testRealAssetsWithPT() internal view {
        console.log("\n5. Testing realAssets with PT balance...");
        
        uint256 ptBalance = adapter.getPTBalance();
        uint256 realAssets = adapter.realAssets();
        uint256 currentRate = adapter.getCurrentRate();
        
        console.log("Current PT balance:", ptBalance);
        console.log("Real assets value:", realAssets);
        console.log("Current rate:", currentRate);
        
        if (ptBalance > 0) {
            console.log("SUCCESS: Adapter has PT tokens");
            if (realAssets > 0) {
                console.log("SUCCESS: realAssets calculation working with PT");
            } else {
                console.log("WARNING: realAssets returned 0 despite having PT");
            }
        } else {
            console.log("WARNING: No PT tokens after allocation");
        }
    }
    
    function testDeallocation(uint256 testAmount) internal {
        console.log("\n6. Testing deallocation...");
        
        uint256 ptBalance = adapter.getPTBalance();
        if (ptBalance == 0) {
            console.log("WARNING: No PT to deallocate");
            return;
        }
        
        // Try to deallocate a small amount
        uint256 deallocateAmount = testAmount / 4; // Even smaller amount
        if (deallocateAmount == 0) deallocateAmount = 1;
        
        console.log("Attempting to deallocate equivalent of:", deallocateAmount, "wei");
        
        uint256 beforeAssetBalance = asset.balanceOf(address(adapter));
        uint256 beforePTBalance = adapter.getPTBalance();
        
        try adapter.deallocate("", deallocateAmount, bytes4(0), address(0)) returns (bytes32[] memory ids, int256 change) {
            console.log("SUCCESS: Deallocation completed");
            console.log("Deallocation IDs length:", ids.length);
            console.log("Deallocation change:", change < 0 ? uint256(-change) : 0, "negative change");
            
            uint256 afterAssetBalance = asset.balanceOf(address(adapter));
            uint256 afterPTBalance = adapter.getPTBalance();
            
            console.log("Asset balance change:", afterAssetBalance > beforeAssetBalance ? afterAssetBalance - beforeAssetBalance : 0);
            console.log("PT balance change:", beforePTBalance > afterPTBalance ? beforePTBalance - afterPTBalance : 0);
            
        } catch Error(string memory reason) {
            console.log("ERROR: Deallocation failed:", reason);
        } catch {
            console.log("ERROR: Deallocation failed with unknown error");
        }
    }
    
    function validateFinalState() internal view {
        console.log("\n7. Validating final state...");
        
        uint256 finalPTBalance = adapter.getPTBalance();
        uint256 finalAssetBalance = adapter.getAssetBalance();
        uint256 finalRealAssets = adapter.realAssets();
        
        console.log("Final PT balance:", finalPTBalance);
        console.log("Final asset balance:", finalAssetBalance);
        console.log("Final real assets:", finalRealAssets);
        
        console.log("SUCCESS: Final state recorded");
    }
}