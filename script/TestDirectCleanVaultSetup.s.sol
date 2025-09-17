// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PendleV2AdapterKHYPE} from "../src/adapters/PendleV2AdapterKHYPE.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IVaultV2 {
    function addAdapter(address adapter) external;
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function isAdapter(address adapter) external view returns (bool);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

contract TestDirectCleanVaultSetup is Script {
    
    // Clean contracts
    address constant CLEAN_VAULT = 0x3C3e4510957437ed56c3737D9F36203E0F959830;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    
    // Pendle addresses
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x6813d43782395A1F2AAb42f39aeEDE03ac655e09;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97;
    
    uint256 constant DEPOSIT_AMOUNT = 100000000000000; // 0.0001 kHYPE
    uint256 constant ALLOCATE_AMOUNT = 50000000000000; // 0.00005 kHYPE
    uint256 constant MAX_CAP = 1000000000000000000; // 1 kHYPE cap
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DIRECT CLEAN VAULT SETUP TEST ===");
        console.log("Trying direct calls without timelock");
        console.log("Clean Vault:", CLEAN_VAULT);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy adapter
        console.log("\n1. Deploying adapter...");
        PendleV2AdapterKHYPE adapter = new PendleV2AdapterKHYPE(
            CLEAN_VAULT,
            PENDLE_ROUTER,
            PENDLE_ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        console.log("Adapter deployed:", address(adapter));
        
        // Try direct addAdapter (no submit)
        console.log("\n2. Adding adapter directly...");
        try IVaultV2(CLEAN_VAULT).addAdapter(address(adapter)) {
            console.log("SUCCESS: Adapter added directly!");
            
            // Set caps directly  
            console.log("\n3. Setting caps directly...");
            bytes memory idData = abi.encode("pendle-v2-khype-allocation");
            
            try IVaultV2(CLEAN_VAULT).increaseAbsoluteCap(idData, MAX_CAP) {
                console.log("Absolute cap set successfully");
            } catch Error(string memory reason) {
                console.log("Absolute cap failed:", reason);
            }
            
            try IVaultV2(CLEAN_VAULT).increaseRelativeCap(idData, 1e18) {
                console.log("Relative cap set successfully");
            } catch Error(string memory reason) {
                console.log("Relative cap failed:", reason);
            }
            
        } catch Error(string memory reason) {
            console.log("FAILED: addAdapter failed:", reason);
        }
        
        // Verify setup
        console.log("\n4. Verification:");
        bool isRegistered = IVaultV2(CLEAN_VAULT).isAdapter(address(adapter));
        console.log("Adapter registered:", isRegistered);
        
        if (isRegistered) {
            // Test deposit
            console.log("\n5. Testing deposit...");
            uint256 balance = IERC20(KHYPE).balanceOf(msg.sender);
            console.log("kHYPE balance:", balance);
            
            if (balance >= DEPOSIT_AMOUNT) {
                IERC20(KHYPE).approve(CLEAN_VAULT, DEPOSIT_AMOUNT);
                uint256 shares = IVaultV2(CLEAN_VAULT).deposit(DEPOSIT_AMOUNT, msg.sender);
                console.log("Deposited successfully, shares:", shares);
                
                // Test allocation
                console.log("\n6. Testing allocation...");
                uint256 vaultAssets = IVaultV2(CLEAN_VAULT).totalAssets();
                console.log("Vault assets:", vaultAssets);
                
                if (vaultAssets >= ALLOCATE_AMOUNT) {
                    uint256 ptBefore = adapter.getPTBalance();
                    console.log("PT balance before:", ptBefore);
                    
                    try IVaultV2(CLEAN_VAULT).allocate(address(adapter), "", ALLOCATE_AMOUNT) {
                        uint256 ptAfter = adapter.getPTBalance();
                        console.log("SUCCESS: Allocation worked!");
                        console.log("PT balance after:", ptAfter);
                        console.log("PT gained:", ptAfter - ptBefore);
                        
                        if (ptAfter > ptBefore) {
                            console.log("\n*** COMPLETE SUCCESS! ***");
                            console.log("*** PENDLE INTEGRATION WORKING! ***");
                        }
                        
                    } catch Error(string memory reason) {
                        console.log("Allocation failed:", reason);
                    } catch (bytes memory data) {
                        console.log("Allocation failed with data:");
                        console.logBytes(data);
                    }
                }
            }
        }
        
        vm.stopBroadcast();
    }
}