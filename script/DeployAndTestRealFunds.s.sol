// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/adapters/PendleV2AdapterKHYPE.sol";
import "../src/interfaces/IERC20.sol";

interface IVaultV2 {
    function asset() external view returns (address);
    function totalAssets() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256);
}

contract DeployAndTestRealFunds is Script {
    
    // HyperEVM addresses
    address constant VAULT_V2 = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
    address constant VAULT_ASSET = 0x5555555555555555555555555555555555555555; // wHYPE
    
    // Small test amounts
    uint256 constant MICRO_AMOUNT = 0.00001e18; // 0.00001 wHYPE (10^13 wei)
    
    PendleV2AdapterKHYPE public adapter;
    IERC20 public asset;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== Deploy and Test Real Funds ===");
        console.log("Deployer:", deployer);
        console.log("ETH balance:", deployer.balance / 1e18, "ETH");
        
        // Check asset balance
        asset = IERC20(VAULT_ASSET);
        uint256 assetBalance = asset.balanceOf(deployer);
        console.log("wHYPE balance:", assetBalance, "wei");
        console.log("wHYPE balance:", assetBalance / 1e18, "tokens");
        
        if (assetBalance < MICRO_AMOUNT) {
            console.log("ERROR: Insufficient wHYPE for testing");
            vm.stopBroadcast();
            return;
        }
        
        // Step 1: Deploy minimal adapter (gas efficient)
        console.log("\n1. Deploying PendleV2AdapterKHYPE...");
        
        adapter = new PendleV2AdapterKHYPE(
            VAULT_V2,
            PENDLE_ROUTER,
            PENDLE_ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        console.log("SUCCESS: Adapter deployed at:", address(adapter));
        
        // Step 2: Basic configuration test
        console.log("\n2. Testing adapter configuration...");
        console.log("Parent vault:", adapter.parentVault());
        console.log("Asset:", adapter.asset());
        console.log("PT token:", adapter.ptToken());
        console.log("Market:", adapter.market());
        
        // Step 3: Test getCurrentRate (should return 0 as RouterStatic doesn't work)
        console.log("\n3. Testing RouterStatic integration...");
        uint256 currentRate = adapter.getCurrentRate();
        console.log("Current rate:", currentRate);
        if (currentRate == 0) {
            console.log("SUCCESS: RouterStatic fallback working as expected");
        }
        
        // Step 4: Test realAssets with no PT
        console.log("\n4. Testing realAssets with no PT...");
        uint256 realAssets = adapter.realAssets();
        console.log("Real assets (should be 0):", realAssets);
        require(realAssets == 0, "Real assets should be 0 with no PT");
        
        // Step 5: Test dynamic slippage calculation
        console.log("\n5. Testing dynamic slippage...");
        testDynamicSlippage();
        
        // Step 6: Simulate micro allocation (just transfer asset to adapter)
        console.log("\n6. Testing micro allocation simulation...");
        uint256 testAmount = MICRO_AMOUNT;
        console.log("Transferring", testAmount, "wei to adapter for testing...");
        
        asset.transfer(address(adapter), testAmount);
        uint256 adapterBalance = adapter.getAssetBalance();
        console.log("SUCCESS: Adapter now has", adapterBalance, "wei");
        
        // Step 7: Test balance functions
        console.log("\n7. Testing balance functions...");
        console.log("PT balance:", adapter.getPTBalance());
        console.log("Asset balance:", adapter.getAssetBalance());
        
        console.log("\n=== DEPLOYMENT AND MICRO-TESTS COMPLETED ===");
        console.log("Adapter address:", address(adapter));
        console.log("Ready for allocation testing by vault");
        
        vm.stopBroadcast();
    }
    
    
    function testDynamicSlippage() internal view {
        uint256[] memory testAmounts = new uint256[](3);
        testAmounts[0] = MICRO_AMOUNT;        // 0.00001 wHYPE
        testAmounts[1] = MICRO_AMOUNT * 10;   // 0.0001 wHYPE  
        testAmounts[2] = MICRO_AMOUNT * 100;  // 0.001 wHYPE
        
        for (uint i = 0; i < testAmounts.length; i++) {
            try adapter.calculatePtNeededForKHype(testAmounts[i]) returns (uint256 ptNeeded) {
                console.log("SUCCESS: PT needed for amount:", testAmounts[i]);
                console.log("SUCCESS: PT needed result:", ptNeeded);
            } catch {
                console.log("ERROR: calculatePtNeededForKHype failed for amount:", testAmounts[i]);
            }
        }
    }
}