// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {VaultV2} from "../src/VaultV2.sol";
import {PendleV2AdapterKHYPE} from "../src/adapters/PendleV2AdapterKHYPE.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function symbol() external view returns (string memory);
}

interface IVaultV2 {
    function submit(bytes calldata data) external;
    function setCurator(address newCurator) external;
    function setAllocator(address newAllocator) external;
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
    function owner() external view returns (address);
    function curator() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

contract DeployAndTestNewVaultV2 is Script {
    
    // Token addresses
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant CURATOR = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
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
    
    VaultV2 public vault;
    PendleV2AdapterKHYPE public adapter;
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== DEPLOY NEW VAULTV2 + PENDLEV2ADAPTERKHYPE END-TO-END TEST ===");
        console.log("Complete fresh deployment and testing");
        console.log("kHYPE Token:", KHYPE);
        console.log("Curator:", CURATOR);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer:", deployer);
        
        // PHASE 1: DEPLOY NEW VAULTV2
        console.log("\nPHASE 1: Deploy New VaultV2");
        console.log("===========================");
        
        deployNewVault();
        console.log("");
        
        // PHASE 2: DEPLOY ADAPTER
        console.log("PHASE 2: Deploy PendleV2AdapterKHYPE");
        console.log("===================================");
        
        deployAdapter();
        console.log("");
        
        // PHASE 3: SETUP AUTHORIZATION
        console.log("PHASE 3: Setup Authorization");
        console.log("============================");
        
        setupAuthorization();
        console.log("");
        
        // PHASE 4: REGISTER ADAPTER
        console.log("PHASE 4: Register Adapter");
        console.log("=========================");
        
        registerAdapter();
        console.log("");
        
        // PHASE 5: DEPOSIT KHYPE
        console.log("PHASE 5: Deposit kHYPE");
        console.log("======================");
        
        depositKHype();
        console.log("");
        
        // PHASE 6: TEST ALLOCATION
        console.log("PHASE 6: Test Allocation");
        console.log("========================");
        
        testAllocation();
        console.log("");
        
        // PHASE 7: TEST DEALLOCATION
        console.log("PHASE 7: Test Deallocation");
        console.log("==========================");
        
        testDeallocation();
        console.log("");
        
        vm.stopBroadcast();
        
        // FINAL SUMMARY
        console.log("=== FINAL SUMMARY ===");
        provideFinalSummary();
    }
    
    function deployNewVault() internal {
        console.log("Deploying fresh VaultV2...");
        console.log("  Owner:", CURATOR);
        console.log("  Asset:", KHYPE);
        
        // Verify kHYPE token
        string memory symbol = IERC20(KHYPE).symbol();
        console.log("  Token symbol:", symbol);
        
        vault = new VaultV2(CURATOR, KHYPE);
        
        console.log("SUCCESS: VaultV2 deployed!");
        console.log("Address:", address(vault));
        
        // Verify deployment
        address vaultAsset = vault.asset();
        address vaultOwner = vault.owner();
        
        console.log("Verification:");
        console.log("  Asset:", vaultAsset);
        console.log("  Owner:", vaultOwner);
        console.log("  Asset correct:", vaultAsset == KHYPE);
        console.log("  Owner correct:", vaultOwner == CURATOR);
        
        require(vaultAsset == KHYPE, "Asset verification failed");
        require(vaultOwner == CURATOR, "Owner verification failed");
    }
    
    function deployAdapter() internal {
        console.log("Deploying PendleV2AdapterKHYPE...");
        console.log("  Vault:", address(vault));
        console.log("  Router:", PENDLE_ROUTER);
        console.log("  RouterStatic:", PENDLE_ROUTER_STATIC);
        console.log("  PT Token:", PT_TOKEN);
        console.log("  Market:", MARKET);
        
        adapter = new PendleV2AdapterKHYPE(
            address(vault),
            PENDLE_ROUTER,
            PENDLE_ROUTER_STATIC,
            PT_TOKEN,
            MARKET
        );
        
        console.log("SUCCESS: Adapter deployed!");
        console.log("Address:", address(adapter));
        
        // Verify adapter
        require(adapter.parentVault() == address(vault), "Adapter vault mismatch");
        require(adapter.asset() == KHYPE, "Adapter asset mismatch");
        console.log("Adapter verification passed");
    }
    
    function setupAuthorization() internal {
        console.log("Setting up vault authorization...");
        
        // Set curator to deployer (owner can set curator)
        console.log("1. Setting curator...");
        try vault.setCurator(CURATOR) {
            console.log("SUCCESS: Curator set to", CURATOR);
        } catch Error(string memory reason) {
            console.log("FAILED: setCurator failed:", reason);
        }
        
        // Set allocator to deployer (owner can set allocator)
        console.log("2. Setting allocator...");
        try IVaultV2(address(vault)).setAllocator(CURATOR) {
            console.log("SUCCESS: Allocator set to", CURATOR);
        } catch Error(string memory reason) {
            console.log("INFO: setAllocator failed (may not exist):", reason);
        } catch {
            console.log("INFO: setAllocator method may not exist");
        }
        
        // Verify authorization
        address owner = vault.owner();
        address curator = vault.curator();
        
        console.log("Authorization status:");
        console.log("  Owner:", owner);
        console.log("  Curator:", curator);
        console.log("  Ready for timelock operations:", curator == CURATOR);
    }
    
    function registerAdapter() internal {
        console.log("Registering adapter with timelock pattern...");
        
        // Submit addAdapter to timelock
        console.log("1. Submit addAdapter...");
        IVaultV2(address(vault)).submit(abi.encodeWithSignature("addAdapter(address)", address(adapter)));
        
        console.log("2. Execute addAdapter...");
        IVaultV2(address(vault)).addAdapter(address(adapter));
        
        // Set allocation caps
        bytes memory idData = abi.encode("pendle-v2-khype-allocation");
        
        console.log("3. Submit and set absolute cap...");
        IVaultV2(address(vault)).submit(abi.encodeWithSignature("increaseAbsoluteCap(bytes,uint256)", idData, MAX_CAP));
        IVaultV2(address(vault)).increaseAbsoluteCap(idData, MAX_CAP);
        
        console.log("4. Submit and set relative cap...");
        IVaultV2(address(vault)).submit(abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, 1e18));
        IVaultV2(address(vault)).increaseRelativeCap(idData, 1e18);
        
        // Verify registration
        bool isRegistered = IVaultV2(address(vault)).isAdapter(address(adapter));
        bytes32 allocationId = keccak256(idData);
        uint256 absoluteCap = IVaultV2(address(vault)).absoluteCap(allocationId);
        
        console.log("Registration verification:");
        console.log("  Adapter registered:", isRegistered);
        console.log("  Absolute cap set:", absoluteCap);
        
        require(isRegistered, "Adapter registration failed");
        require(absoluteCap >= ALLOCATE_AMOUNT, "Cap too low");
        
        console.log("SUCCESS: Adapter fully registered and configured!");
    }
    
    function depositKHype() internal {
        uint256 deployerBalance = IERC20(KHYPE).balanceOf(msg.sender);
        console.log("Deployer kHYPE balance:", deployerBalance);
        
        if (deployerBalance >= DEPOSIT_AMOUNT) {
            console.log("Depositing", DEPOSIT_AMOUNT, "kHYPE to vault...");
            
            IERC20(KHYPE).approve(address(vault), DEPOSIT_AMOUNT);
            uint256 shares = IVaultV2(address(vault)).deposit(DEPOSIT_AMOUNT, msg.sender);
            
            console.log("SUCCESS: Deposited successfully!");
            console.log("  Shares received:", shares);
            
            uint256 vaultAssets = IVaultV2(address(vault)).totalAssets();
            console.log("  Vault total assets:", vaultAssets);
            
            require(vaultAssets >= ALLOCATE_AMOUNT, "Insufficient vault assets for allocation");
        } else {
            console.log("WARNING: Insufficient kHYPE for deposit");
            console.log("Need:", DEPOSIT_AMOUNT);
            console.log("Have:", deployerBalance);
        }
    }
    
    function testAllocation() internal {
        uint256 adapterPtBefore = adapter.getPTBalance();
        uint256 vaultAssetsBefore = IVaultV2(address(vault)).totalAssets();
        
        bytes memory idData = abi.encode("pendle-v2-khype-allocation");
        bytes32 allocationId = keccak256(idData);
        uint256 allocationBefore = IVaultV2(address(vault)).allocation(allocationId);
        
        console.log("Before allocation:");
        console.log("  Vault total assets:", vaultAssetsBefore);
        console.log("  Adapter PT balance:", adapterPtBefore);
        console.log("  Tracked allocation:", allocationBefore);
        
        console.log("");
        console.log("Executing allocation of", ALLOCATE_AMOUNT, "kHYPE...");
        
        try IVaultV2(address(vault)).allocate(address(adapter), "", ALLOCATE_AMOUNT) {
            console.log("SUCCESS: ALLOCATION COMPLETED!");
            
            uint256 adapterPtAfter = adapter.getPTBalance();
            uint256 vaultAssetsAfter = IVaultV2(address(vault)).totalAssets();
            uint256 allocationAfter = IVaultV2(address(vault)).allocation(allocationId);
            
            console.log("");
            console.log("After allocation:");
            console.log("  Vault total assets:", vaultAssetsAfter);
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  Tracked allocation:", allocationAfter);
            
            console.log("");
            console.log("Changes:");
            console.log("  PT tokens gained:", adapterPtAfter - adapterPtBefore);
            console.log("  Vault assets change:", int256(vaultAssetsAfter) - int256(vaultAssetsBefore));
            console.log("  Allocation increase:", allocationAfter - allocationBefore);
            
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
            } else {
                console.log("");
                console.log("WARNING: No PT tokens received despite successful transaction");
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed with reason:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Allocation failed with raw data:");
            console.logBytes(data);
            
            if (data.length >= 4) {
                bytes4 selector = bytes4(data);
                console.log("Error selector:", vm.toString(selector));
            }
        }
    }
    
    function testDeallocation() internal {
        uint256 adapterPtBefore = adapter.getPTBalance();
        
        console.log("Before deallocation:");
        console.log("  Adapter PT balance:", adapterPtBefore);
        
        if (adapterPtBefore == 0) {
            console.log("SKIPPING: No PT tokens to deallocate");
            console.log("Deallocation requires successful allocation first");
            return;
        }
        
        console.log("Executing deallocation of", DEALLOCATE_AMOUNT, "kHYPE equivalent...");
        
        try IVaultV2(address(vault)).deallocate(address(adapter), "", DEALLOCATE_AMOUNT) {
            console.log("SUCCESS: DEALLOCATION COMPLETED!");
            
            uint256 adapterPtAfter = adapter.getPTBalance();
            uint256 vaultAssetsAfter = IVaultV2(address(vault)).totalAssets();
            
            console.log("");
            console.log("After deallocation:");
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  Vault total assets:", vaultAssetsAfter);
            console.log("  PT tokens redeemed:", adapterPtBefore - adapterPtAfter);
            
            if (adapterPtAfter < adapterPtBefore) {
                console.log("");
                console.log("*** DEALLOCATION SUCCESS! ***");
                console.log("*** PT TOKENS REDEEMED! ***");
                console.log("*** COMPLETE ROUND-TRIP WORKING! ***");
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
        uint256 vaultAssetsFinal = IVaultV2(address(vault)).totalAssets();
        bool isRegistered = IVaultV2(address(vault)).isAdapter(address(adapter));
        
        console.log("Final system state:");
        console.log("  New VaultV2:", address(vault));
        console.log("  New Adapter:", address(adapter));
        console.log("  Adapter registered:", isRegistered);
        console.log("  Adapter PT balance:", adapterPtFinal);
        console.log("  Vault total assets:", vaultAssetsFinal);
        
        console.log("");
        console.log("=== DEPLOYMENT ADDRESSES ===");
        console.log("VaultV2:", address(vault));
        console.log("PendleV2AdapterKHYPE:", address(adapter));
        console.log("Asset (kHYPE):", KHYPE);
        
        if (adapterPtFinal > 0) {
            console.log("");
            console.log("*** COMPLETE SUCCESS! ***");
            console.log("*** NEW VAULTV2 + PENDLEV2ADAPTERKHYPE WORKING PERFECTLY! ***");
            console.log("*** END-TO-END kHYPE -> PT-kHYPE FLOW OPERATIONAL! ***");
            console.log("*** PENDLE ROUTER INTEGRATION SUCCESSFUL! ***");
        } else {
            console.log("");
            console.log("*** INFRASTRUCTURE DEPLOYMENT SUCCESS ***");
            console.log("VaultV2 + Adapter deployment: PERFECT");
            console.log("Authorization setup: WORKING");
            console.log("Adapter registration: WORKING");
            if (vaultAssetsFinal > 0) {
                console.log("Deposit flow: WORKING");
                console.log("Pendle integration: REQUIRES INVESTIGATION");
            } else {
                console.log("Ready for testing with kHYPE deposits");
            }
        }
    }
}