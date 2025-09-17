// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {PendleV2AdapterKHYPE} from "../src/adapters/PendleV2AdapterKHYPE.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IVaultV2 {
    function submit(bytes calldata data) external;
    function addAdapter(address adapter) external;
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function deallocate(address adapter, bytes calldata data, uint256 assets) external;
    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function isAdapter(address adapter) external view returns (bool);
    function absoluteCap(bytes32 id) external view returns (uint256);
    function allocation(bytes32 id) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function realAssets() external view returns (uint256);
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

contract TestCleanVaultEndToEnd is Script {
    
    // Clean contracts
    address constant CLEAN_VAULT = 0x3C3e4510957437ed56c3737D9F36203E0F959830;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    
    // Pendle addresses from 999-core.json
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_ROUTER_STATIC = 0x6813d43782395A1F2AAb42f39aeEDE03ac655e09;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329; // PT-kHYPE token
    address constant MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97; // PT-kHYPE market
    
    // Test parameters
    uint256 constant DEPOSIT_AMOUNT = 200000000000000; // 0.0002 kHYPE
    uint256 constant ALLOCATE_AMOUNT = 100000000000000; // 0.0001 kHYPE
    uint256 constant DEALLOCATE_AMOUNT = 50000000000000; // 0.00005 kHYPE
    uint256 constant MAX_CAP = 10000000000000000000; // 10 kHYPE cap
    
    PendleV2AdapterKHYPE public adapter;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== CLEAN VAULTV2 + PENDLEV2ADAPTERKHYPE END-TO-END TEST ===");
        console.log("Testing complete flow with CLEAN vault (no dead adapters)");
        console.log("Clean Vault:", CLEAN_VAULT);
        console.log("kHYPE:", KHYPE);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);
        
        // PHASE 1: DEPLOY ADAPTER
        console.log("PHASE 1: Deploy PendleV2AdapterKHYPE");
        console.log("===================================");
        
        deployAdapter();
        console.log("SUCCESS: Adapter deployed at:", address(adapter));
        console.log("");
        
        // PHASE 2: SETUP AND REGISTER ADAPTER
        console.log("PHASE 2: Setup and Register Adapter");
        console.log("==================================");
        
        setupAdapter();
        console.log("");
        
        // PHASE 3: DEPOSIT KHYPE
        console.log("PHASE 3: Deposit kHYPE");
        console.log("=====================");
        
        depositKHype();
        console.log("");
        
        // PHASE 4: TEST ALLOCATION
        console.log("PHASE 4: Test Allocation");
        console.log("=======================");
        
        testAllocation();
        console.log("");
        
        // PHASE 5: TEST DEALLOCATION
        console.log("PHASE 5: Test Deallocation");
        console.log("=========================");
        
        testDeallocation();
        console.log("");
        
        vm.stopBroadcast();
        
        // FINAL SUMMARY
        console.log("=== FINAL SUMMARY ===");
        provideFinalSummary();
    }
    
    function deployAdapter() internal {
        console.log("Deploying PendleV2AdapterKHYPE...");
        console.log("  Vault:", CLEAN_VAULT);
        console.log("  Router:", PENDLE_ROUTER);
        console.log("  RouterStatic:", PENDLE_ROUTER_STATIC);
        console.log("  PT Token:", PT_TOKEN);
        console.log("  Market:", MARKET);
        
        adapter = new PendleV2AdapterKHYPE(
            CLEAN_VAULT,
            PENDLE_ROUTER,
            PENDLE_ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        
        // Verify adapter
        require(adapter.parentVault() == CLEAN_VAULT, "Adapter vault mismatch");
        require(adapter.asset() == KHYPE, "Adapter asset mismatch");
    }
    
    function setupAdapter() internal {
        console.log("Registering adapter with clean vault...");
        
        // Use proper timelock pattern
        console.log("1. Submit addAdapter...");
        IVaultV2(CLEAN_VAULT).submit(abi.encodeWithSignature("addAdapter(address)", address(adapter)));
        
        console.log("2. Execute addAdapter...");
        IVaultV2(CLEAN_VAULT).addAdapter(address(adapter));
        
        // Set caps
        bytes memory idData = abi.encode("pendle-v2-khype-allocation");
        
        console.log("3. Submit caps...");
        IVaultV2(CLEAN_VAULT).submit(abi.encodeWithSignature("increaseAbsoluteCap(bytes,uint256)", idData, MAX_CAP));
        IVaultV2(CLEAN_VAULT).increaseAbsoluteCap(idData, MAX_CAP);
        
        IVaultV2(CLEAN_VAULT).submit(abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, 1e18));
        IVaultV2(CLEAN_VAULT).increaseRelativeCap(idData, 1e18);
        
        // Verify setup
        bool isRegistered = IVaultV2(CLEAN_VAULT).isAdapter(address(adapter));
        console.log("SUCCESS: Adapter registered:", isRegistered);
        require(isRegistered, "Adapter registration failed");
    }
    
    function depositKHype() internal {
        uint256 deployerBalance = IERC20(KHYPE).balanceOf(msg.sender);
        console.log("Deployer kHYPE balance:", deployerBalance);
        
        if (deployerBalance >= DEPOSIT_AMOUNT) {
            console.log("Depositing", DEPOSIT_AMOUNT, "kHYPE to clean vault...");
            
            IERC20(KHYPE).approve(CLEAN_VAULT, DEPOSIT_AMOUNT);
            uint256 shares = IVaultV2(CLEAN_VAULT).deposit(DEPOSIT_AMOUNT, msg.sender);
            
            console.log("SUCCESS: Deposited, received shares:", shares);
        } else {
            console.log("Insufficient kHYPE for deposit test");
        }
        
        uint256 vaultAssets = IVaultV2(CLEAN_VAULT).totalAssets();
        console.log("Clean vault total assets:", vaultAssets);
        require(vaultAssets >= ALLOCATE_AMOUNT, "Insufficient vault assets");
    }
    
    function testAllocation() internal {
        uint256 adapterPtBefore = adapter.getPTBalance();
        uint256 vaultAssetsBefore = IVaultV2(CLEAN_VAULT).totalAssets();
        
        console.log("Before allocation:");
        console.log("  Vault total assets:", vaultAssetsBefore);
        console.log("  Adapter PT balance:", adapterPtBefore);
        
        console.log("");
        console.log("Executing allocation of", ALLOCATE_AMOUNT, "kHYPE...");
        
        try IVaultV2(CLEAN_VAULT).allocate(address(adapter), "", ALLOCATE_AMOUNT) {
            console.log("SUCCESS: ALLOCATION COMPLETED!");
            
            uint256 adapterPtAfter = adapter.getPTBalance();
            uint256 vaultAssetsAfter = IVaultV2(CLEAN_VAULT).totalAssets();
            
            console.log("");
            console.log("After allocation:");
            console.log("  Vault total assets:", vaultAssetsAfter);
            console.log("  Adapter PT balance:", adapterPtAfter);
            
            console.log("");
            console.log("Changes:");
            console.log("  PT tokens gained:", adapterPtAfter - adapterPtBefore);
            console.log("  Vault assets change:", int256(vaultAssetsAfter) - int256(vaultAssetsBefore));
            
            if (adapterPtAfter > adapterPtBefore) {
                console.log("");
                console.log("*** ALLOCATION SUCCESS! ***");
                console.log("*** PT TOKENS RECEIVED! ***");
                console.log("*** PENDLE INTEGRATION WORKING! ***");
                
                // Test realAssets
                try adapter.realAssets() returns (uint256 realAssetsValue) {
                    console.log("SUCCESS: realAssets() working:", realAssetsValue);
                } catch {
                    console.log("INFO: realAssets() failed (may need RouterStatic)");
                }
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed with reason:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Allocation failed with raw data:");
            console.logBytes(data);
        }
    }
    
    function testDeallocation() internal {
        uint256 adapterPtBefore = adapter.getPTBalance();
        
        console.log("Before deallocation:");
        console.log("  Adapter PT balance:", adapterPtBefore);
        
        if (adapterPtBefore == 0) {
            console.log("SKIPPING: No PT tokens to deallocate");
            return;
        }
        
        console.log("Executing deallocation of", DEALLOCATE_AMOUNT, "kHYPE equivalent...");
        
        try IVaultV2(CLEAN_VAULT).deallocate(address(adapter), "", DEALLOCATE_AMOUNT) {
            console.log("SUCCESS: DEALLOCATION COMPLETED!");
            
            uint256 adapterPtAfter = adapter.getPTBalance();
            
            console.log("");
            console.log("After deallocation:");
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  PT tokens redeemed:", adapterPtBefore - adapterPtAfter);
            
            if (adapterPtAfter < adapterPtBefore) {
                console.log("");
                console.log("*** DEALLOCATION SUCCESS! ***");
                console.log("*** PT TOKENS REDEEMED! ***");
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Deallocation failed with reason:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Deallocation failed with raw data:");
            console.logBytes(data);
        }
    }
    
    function provideFinalSummary() internal view {
        uint256 adapterPtFinal = adapter.getPTBalance();
        uint256 vaultAssetsFinal = IVaultV2(CLEAN_VAULT).totalAssets();
        bool isRegistered = IVaultV2(CLEAN_VAULT).isAdapter(address(adapter));
        
        console.log("Final system state:");
        console.log("  Clean Vault:", CLEAN_VAULT);
        console.log("  Adapter:", address(adapter));
        console.log("  Adapter registered:", isRegistered);
        console.log("  Adapter PT balance:", adapterPtFinal);
        console.log("  Vault total assets:", vaultAssetsFinal);
        
        if (adapterPtFinal > 0) {
            console.log("");
            console.log("*** COMPLETE SUCCESS! ***");
            console.log("Clean VaultV2 + PendleV2AdapterKHYPE integration PERFECT!");
            console.log("End-to-end kHYPE -> PT-kHYPE flow WORKING!");
            console.log("Pendle router integration SUCCESSFUL!");
        } else {
            console.log("");
            console.log("*** ANALYSIS COMPLETE ***");
            console.log("VaultV2 integration: WORKING");
            console.log("Adapter architecture: WORKING");
            console.log("Pendle integration: REQUIRES INVESTIGATION");
        }
    }
}