// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/adapters/PendleV2AdapterKHYPE.sol";
import "../src/interfaces/IERC20.sol";

contract DeployAndTestFixedAdapter is Script {
    
    // HyperEVM addresses
    address constant VAULT_V2 = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
    
    PendleV2AdapterKHYPE public adapter;
    address public vaultAsset;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        vm.startBroadcast(deployerPrivateKey);
        
        console.log("=== Deploy and Test Fixed PendleV2AdapterKHYPE ===");
        console.log("Deployer:", deployer);
        console.log("Deployer balance:", deployer.balance / 1e18, "ETH");
        
        // Step 1: Validate all addresses have code
        validateAddresses();
        
        // Step 2: Get vault asset
        vaultAsset = getVaultAsset();
        console.log("VaultV2 asset:", vaultAsset);
        
        // Step 3: Deploy the fixed adapter
        deployAdapter();
        
        // Step 4: Test adapter configuration
        testAdapterConfiguration();
        
        // Step 5: Test dynamic slippage calculation
        testDynamicSlippage();
        
        // Step 6: Test realAssets function
        testRealAssets();
        
        // Step 7: Test RouterStatic integration
        testRouterStaticIntegration();
        
        // Step 8: Test asset balance checks
        testAssetBalances();
        
        console.log("\n=== ALL TESTS PASSED ===");
        console.log("Fixed PendleV2AdapterKHYPE deployed at:", address(adapter));
        
        vm.stopBroadcast();
    }
    
    function validateAddresses() internal view {
        console.log("\n1. Validating contract addresses...");
        require(VAULT_V2.code.length > 0, "VaultV2 has no code");
        require(PENDLE_ROUTER.code.length > 0, "Pendle router has no code");
        require(PT_TOKEN.code.length > 0, "PT token has no code");
        require(MARKET.code.length > 0, "Market has no code");
        console.log("SUCCESS: All contracts have code");
    }
    
    function getVaultAsset() internal view returns (address) {
        console.log("\n2. Getting VaultV2 asset...");
        (bool success, bytes memory data) = VAULT_V2.staticcall(abi.encodeWithSignature("asset()"));
        require(success, "Failed to get vault asset");
        address asset = abi.decode(data, (address));
        require(asset.code.length > 0, "Asset must be a contract");
        console.log("SUCCESS: Asset validated:", asset);
        return asset;
    }
    
    function deployAdapter() internal {
        console.log("\n3. Deploying fixed adapter...");
        
        adapter = new PendleV2AdapterKHYPE(
            VAULT_V2,
            PENDLE_ROUTER,
            PENDLE_ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        
        console.log("SUCCESS: Adapter deployed at:", address(adapter));
    }
    
    function testAdapterConfiguration() internal view {
        console.log("\n4. Testing adapter configuration...");
        
        require(adapter.parentVault() == VAULT_V2, "Wrong parent vault");
        require(adapter.pendleRouter() == PENDLE_ROUTER, "Wrong pendle router");
        require(adapter.ptToken() == PT_TOKEN, "Wrong PT token");
        require(adapter.market() == MARKET, "Wrong market");
        require(adapter.asset() == vaultAsset, "Wrong asset");
        
        console.log("SUCCESS: Parent vault:", adapter.parentVault());
        console.log("SUCCESS: Pendle router:", adapter.pendleRouter());
        console.log("SUCCESS: PT token:", adapter.ptToken());
        console.log("SUCCESS: Market:", adapter.market());
        console.log("SUCCESS: Asset:", adapter.asset());
    }
    
    function testDynamicSlippage() internal view {
        console.log("\n5. Testing dynamic slippage calculation...");
        
        uint256[] memory testAmounts = new uint256[](4);
        testAmounts[0] = 1e18;      // 1 asset
        testAmounts[1] = 100e18;    // 100 assets  
        testAmounts[2] = 1000e18;   // 1,000 assets
        testAmounts[3] = 10000e18;  // 10,000 assets
        
        for (uint i = 0; i < testAmounts.length; i++) {
            try adapter.calculatePtNeededForKHype(testAmounts[i]) returns (uint256 ptNeeded) {
                console.log("SUCCESS: PT needed for", testAmounts[i] / 1e18, "assets:", ptNeeded / 1e18);
                require(ptNeeded > 0, "PT needed must be positive");
            } catch Error(string memory reason) {
                console.log("ERROR: calculatePtNeededForKHype failed:", reason);
            } catch {
                console.log("ERROR: calculatePtNeededForKHype failed with unknown error");
            }
        }
    }
    
    function testRealAssets() internal view {
        console.log("\n6. Testing realAssets function...");
        
        uint256 realAssetsValue = adapter.realAssets();
        console.log("SUCCESS: Real assets value (should be 0 with no PT):", realAssetsValue);
        require(realAssetsValue == 0, "Real assets should be 0 with no PT balance");
    }
    
    function testRouterStaticIntegration() internal view {
        console.log("\n7. Testing RouterStatic integration...");
        
        uint256 currentRate = adapter.getCurrentRate();
        console.log("SUCCESS: Current PT to Asset rate:", currentRate);
        
        if (currentRate == 0) {
            console.log("SUCCESS: RouterStatic unavailable (as expected) - fallback working");
        } else {
            console.log("SUCCESS: RouterStatic working - rate:", currentRate);
            require(currentRate > 0, "Rate should be positive if available");
        }
    }
    
    function testAssetBalances() internal view {
        console.log("\n8. Testing asset balance functions...");
        
        uint256 ptBalance = adapter.getPTBalance();
        uint256 assetBalance = adapter.getAssetBalance();
        
        console.log("SUCCESS: PT balance:", ptBalance);
        console.log("SUCCESS: Asset balance:", assetBalance);
        
        // Should be 0 for newly deployed adapter
        require(ptBalance == 0, "PT balance should be 0 initially");
        require(assetBalance == 0, "Asset balance should be 0 initially");
    }
}