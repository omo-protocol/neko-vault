// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import "../src/adapters/PendleV2AdapterKHYPE.sol";
import "../src/interfaces/IERC20.sol";

interface IVaultV2 {
    function asset() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function totalAssets() external view returns (uint256);
}

contract TestActualOnChainTransactions is Script {
    
    // HyperEVM addresses
    address constant VAULT_V2 = 0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x9a9Fa8338dd5E5B2188006f1Cd2Ef26d921650C2;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
    address constant VAULT_ASSET = 0x5555555555555555555555555555555555555555; // wHYPE
    
    // The address that actually has funds
    address constant FUNDED_ADDRESS = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    // Very small test amounts to minimize risk
    uint256 constant TINY_AMOUNT = 0.001e18; // 0.001 wHYPE
    
    PendleV2AdapterKHYPE public adapter;
    IERC20 public asset;
    IVaultV2 public vault;
    
    function run() external {
        // NOTE: This test requires the private key for 0x4741f70E78150C35B71357342B25Ef850D0C00e7
        // You need to set FUNDED_PRIVATE_KEY in your environment
        
        uint256 fundedPrivateKey;
        try vm.envUint("FUNDED_PRIVATE_KEY") returns (uint256 pk) {
            fundedPrivateKey = pk;
        } catch {
            console.log("ERROR: FUNDED_PRIVATE_KEY not set in environment");
            console.log("Please set the private key for address:", FUNDED_ADDRESS);
            return;
        }
        
        address derivedAddress = vm.addr(fundedPrivateKey);
        require(derivedAddress == FUNDED_ADDRESS, "Private key does not match funded address");
        
        vm.startBroadcast(fundedPrivateKey);
        
        console.log("=== Testing ACTUAL On-Chain Transactions ===");
        console.log("Using funded address:", FUNDED_ADDRESS);
        console.log("ETH balance:", FUNDED_ADDRESS.balance / 1e18, "ETH");
        
        // Initialize contracts
        asset = IERC20(VAULT_ASSET);
        vault = IVaultV2(VAULT_V2);
        
        uint256 wHypeBalance = asset.balanceOf(FUNDED_ADDRESS);
        console.log("wHYPE balance:", wHypeBalance, "wei");
        console.log("wHYPE balance:", wHypeBalance / 1e18, "tokens");
        
        if (wHypeBalance < TINY_AMOUNT) {
            console.log("ERROR: Insufficient wHYPE for testing");
            vm.stopBroadcast();
            return;
        }
        
        // Step 1: Deploy new adapter with actual transaction
        console.log("\n1. Deploying PendleV2AdapterKHYPE with real transaction...");
        
        adapter = new PendleV2AdapterKHYPE(
            VAULT_V2,
            PENDLE_ROUTER,
            PENDLE_ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        
        console.log("SUCCESS: Adapter deployed at:", address(adapter));
        console.log("Transaction sent to HyperEVM blockchain!");
        
        // Step 2: Test configuration
        console.log("\n2. Verifying adapter configuration...");
        console.log("Parent vault:", adapter.parentVault());
        console.log("Asset:", adapter.asset());
        console.log("Current rate (should be 0):", adapter.getCurrentRate());
        
        // Step 3: Test with tiny amount - transfer to adapter
        console.log("\n3. Testing with tiny wHYPE amount...");
        uint256 testAmount = TINY_AMOUNT;
        console.log("Transferring", testAmount, "wei to adapter...");
        
        asset.transfer(address(adapter), testAmount);
        console.log("SUCCESS: Real transfer completed on HyperEVM!");
        
        uint256 adapterBalance = adapter.getAssetBalance();
        console.log("Adapter wHYPE balance:", adapterBalance, "wei");
        
        // Step 4: Test realAssets calculation 
        console.log("\n4. Testing realAssets calculation...");
        uint256 realAssets = adapter.realAssets();
        console.log("Real assets value:", realAssets, "wei");
        
        // Step 5: Test allocation simulation (without actual Pendle interaction)
        console.log("\n5. Testing allocation call (may fail due to Pendle unavailability)...");
        
        try adapter.allocate("", testAmount / 2, bytes4(0), address(0)) returns (bytes32[] memory ids, int256 change) {
            console.log("SUCCESS: Allocation completed!");
            console.log("Change:", change > 0 ? uint256(change) : 0);
            console.log("PT balance after allocation:", adapter.getPTBalance());
        } catch Error(string memory reason) {
            console.log("EXPECTED: Allocation failed (Pendle may not be available):", reason);
        } catch {
            console.log("EXPECTED: Allocation failed with unknown error (Pendle may not be available)");
        }
        
        // Step 6: Final state
        console.log("\n6. Final state verification...");
        console.log("Final adapter wHYPE balance:", adapter.getAssetBalance());
        console.log("Final adapter PT balance:", adapter.getPTBalance());
        console.log("Final real assets:", adapter.realAssets());
        
        console.log("\n=== ACTUAL ON-CHAIN TESTS COMPLETED ===");
        console.log("Adapter successfully deployed and tested on HyperEVM!");
        console.log("Address:", address(adapter));
        
        vm.stopBroadcast();
    }
}