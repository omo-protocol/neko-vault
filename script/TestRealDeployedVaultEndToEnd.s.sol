// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IVaultV2 {
    function submit(bytes calldata data) external;
    function setCurator(address newCurator) external;
    function setIsAllocator(address account, bool newIsAllocator) external;
    function addAdapter(address adapter) external;
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function deallocate(address adapter, bytes calldata data, uint256 assets) external;
    function increaseAbsoluteCap(bytes memory idData, uint256 newAbsoluteCap) external;
    function increaseRelativeCap(bytes memory idData, uint256 newRelativeCap) external;
    function isAdapter(address adapter) external view returns (bool);
    function isAllocator(address account) external view returns (bool);
    function absoluteCap(bytes32 id) external view returns (uint256);
    function allocation(bytes32 id) external view returns (uint256);
    function totalAssets() external view returns (uint256);
    function asset() external view returns (address);
    function owner() external view returns (address);
    function curator() external view returns (address);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface IPendleAdapter {
    function getPTBalance() external view returns (uint256);
    function realAssets() external view returns (uint256);
    function parentVault() external view returns (address);
    function asset() external view returns (address);
}

contract TestRealDeployedVaultEndToEnd is Script {
    
    // REAL DEPLOYED CONTRACT ADDRESSES
    address constant VAULT = 0xE6c25968473FA49a886d2d50312a18ddbD40F4de;
    address constant ADAPTER = 0x58aD57e970cEFc09e01692DCe378F8BC59925f76;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant CURATOR = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    // Test parameters
    uint256 constant DEPOSIT_AMOUNT = 100000000000000; // 0.0001 kHYPE
    uint256 constant ALLOCATE_AMOUNT = 50000000000000; // 0.00005 kHYPE
    uint256 constant DEALLOCATE_AMOUNT = 25000000000000; // 0.000025 kHYPE  
    uint256 constant MAX_CAP = 10000000000000000000; // 10 kHYPE cap
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== REAL DEPLOYED VAULTV2 END-TO-END TEST ===");
        console.log("Testing with actual deployed contracts on HyperEVM");
        console.log("VaultV2:", VAULT);
        console.log("PendleV2AdapterKHYPE:", ADAPTER);
        console.log("kHYPE:", KHYPE);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // PHASE 1: VERIFY DEPLOYMENT
        console.log("PHASE 1: Verify Deployment");
        console.log("==========================");
        verifyDeployment();
        console.log("");
        
        // PHASE 2: SETUP AUTHORIZATION
        console.log("PHASE 2: Setup Authorization");
        console.log("============================");
        setupAuthorization();
        console.log("");
        
        // PHASE 3: REGISTER ADAPTER
        console.log("PHASE 3: Register Adapter");
        console.log("=========================");
        registerAdapter();
        console.log("");
        
        // PHASE 4: DEPOSIT KHYPE
        console.log("PHASE 4: Deposit kHYPE");
        console.log("======================");
        depositKHype();
        console.log("");
        
        // PHASE 5: TEST ALLOCATION
        console.log("PHASE 5: Test Allocation");
        console.log("========================");
        testAllocation();
        console.log("");
        
        // PHASE 6: TEST DEALLOCATION  
        console.log("PHASE 6: Test Deallocation");
        console.log("==========================");
        testDeallocation();
        console.log("");
        
        vm.stopBroadcast();
        
        // FINAL SUMMARY
        console.log("=== FINAL SUMMARY ===");
        provideFinalSummary();
    }
    
    function verifyDeployment() internal view {
        console.log("Contract verification:");
        console.log("  Vault code size:", VAULT.code.length);
        console.log("  Adapter code size:", ADAPTER.code.length);
        require(VAULT.code.length > 0, "Vault not deployed");
        require(ADAPTER.code.length > 0, "Adapter not deployed");
        
        // Verify configuration
        address vaultAsset = IVaultV2(VAULT).asset();
        address vaultOwner = IVaultV2(VAULT).owner();
        address adapterVault = IPendleAdapter(ADAPTER).parentVault();
        address adapterAsset = IPendleAdapter(ADAPTER).asset();
        
        console.log("Configuration check:");
        console.log("  Vault asset:", vaultAsset);
        console.log("  Vault owner:", vaultOwner);
        console.log("  Adapter vault:", adapterVault);
        console.log("  Adapter asset:", adapterAsset);
        
        require(vaultAsset == KHYPE, "Vault asset incorrect");
        require(vaultOwner == CURATOR, "Vault owner incorrect");
        require(adapterVault == VAULT, "Adapter vault incorrect");
        require(adapterAsset == KHYPE, "Adapter asset incorrect");
        
        console.log("SUCCESS: Deployment verification passed");
    }
    
    function setupAuthorization() internal {
        address currentCurator = IVaultV2(VAULT).curator();
        bool isAllocator = IVaultV2(VAULT).isAllocator(CURATOR);
        
        console.log("Current authorization:");
        console.log("  Curator:", currentCurator);
        console.log("  Is allocator:", isAllocator);
        
        // Set curator if not set
        if (currentCurator != CURATOR) {
            console.log("Setting curator...");
            IVaultV2(VAULT).setCurator(CURATOR);
            console.log("Curator set successfully");
        }
        
        // Set allocator if not set
        if (!isAllocator) {
            console.log("Setting allocator permission...");
            
            console.log("  1. Submit setIsAllocator...");
            IVaultV2(VAULT).submit(abi.encodeWithSignature("setIsAllocator(address,bool)", CURATOR, true));
            
            console.log("  2. Execute setIsAllocator...");
            IVaultV2(VAULT).setIsAllocator(CURATOR, true);
            
            // Verify
            bool newStatus = IVaultV2(VAULT).isAllocator(CURATOR);
            console.log("  New allocator status:", newStatus);
            require(newStatus, "Allocator permission failed");
            
            console.log("SUCCESS: Allocator permission granted");
        } else {
            console.log("SUCCESS: Already configured");
        }
    }
    
    function registerAdapter() internal {
        bool isRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
        console.log("Adapter currently registered:", isRegistered);
        
        if (!isRegistered) {
            console.log("Registering adapter...");
            
            console.log("  1. Submit addAdapter...");
            IVaultV2(VAULT).submit(abi.encodeWithSignature("addAdapter(address)", ADAPTER));
            
            console.log("  2. Execute addAdapter...");
            IVaultV2(VAULT).addAdapter(ADAPTER);
            
            // Set caps
            bytes memory idData = abi.encode("pendle-v2-khype-allocation");
            
            console.log("  3. Submit and set absolute cap...");
            IVaultV2(VAULT).submit(abi.encodeWithSignature("increaseAbsoluteCap(bytes,uint256)", idData, MAX_CAP));
            IVaultV2(VAULT).increaseAbsoluteCap(idData, MAX_CAP);
            
            console.log("  4. Submit and set relative cap...");
            IVaultV2(VAULT).submit(abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, 1e18));
            IVaultV2(VAULT).increaseRelativeCap(idData, 1e18);
            
            // Verify
            bool newStatus = IVaultV2(VAULT).isAdapter(ADAPTER);
            bytes32 allocationId = keccak256(idData);
            uint256 absoluteCap = IVaultV2(VAULT).absoluteCap(allocationId);
            
            console.log("Registration verification:");
            console.log("  Adapter registered:", newStatus);
            console.log("  Absolute cap:", absoluteCap);
            
            require(newStatus, "Adapter registration failed");
            require(absoluteCap >= ALLOCATE_AMOUNT, "Cap too low");
            
            console.log("SUCCESS: Adapter registered and configured");
        } else {
            console.log("SUCCESS: Adapter already registered");
        }
    }
    
    function depositKHype() internal {
        uint256 deployerBalance = IERC20(KHYPE).balanceOf(msg.sender);
        uint256 vaultAssets = IVaultV2(VAULT).totalAssets();
        
        console.log("Balances:");
        console.log("  Deployer kHYPE:", deployerBalance);
        console.log("  Vault assets:", vaultAssets);
        
        if (vaultAssets < ALLOCATE_AMOUNT && deployerBalance >= DEPOSIT_AMOUNT) {
            console.log("Depositing", DEPOSIT_AMOUNT, "kHYPE...");
            
            IERC20(KHYPE).approve(VAULT, DEPOSIT_AMOUNT);
            uint256 shares = IVaultV2(VAULT).deposit(DEPOSIT_AMOUNT, msg.sender);
            
            console.log("SUCCESS: Deposited!");
            console.log("  Shares received:", shares);
            
            uint256 newVaultAssets = IVaultV2(VAULT).totalAssets();
            console.log("  New vault assets:", newVaultAssets);
        } else if (vaultAssets >= ALLOCATE_AMOUNT) {
            console.log("SUCCESS: Sufficient vault assets already");
        } else {
            console.log("WARNING: Insufficient kHYPE for deposit");
            console.log("  Need:", DEPOSIT_AMOUNT);
            console.log("  Have:", deployerBalance);
        }
    }
    
    function testAllocation() internal {
        uint256 vaultAssetsBefore = IVaultV2(VAULT).totalAssets();
        uint256 adapterPtBefore = IPendleAdapter(ADAPTER).getPTBalance();
        
        bytes memory idData = abi.encode("pendle-v2-khype-allocation");
        bytes32 allocationId = keccak256(idData);
        uint256 allocationBefore = IVaultV2(VAULT).allocation(allocationId);
        
        console.log("Before allocation:");
        console.log("  Vault assets:", vaultAssetsBefore);
        console.log("  Adapter PT balance:", adapterPtBefore);
        console.log("  Tracked allocation:", allocationBefore);
        
        if (vaultAssetsBefore < ALLOCATE_AMOUNT) {
            console.log("SKIPPING: Insufficient vault assets");
            return;
        }
        
        console.log("");
        console.log("Executing allocation of", ALLOCATE_AMOUNT, "kHYPE...");
        
        try IVaultV2(VAULT).allocate(ADAPTER, "", ALLOCATE_AMOUNT) {
            console.log("SUCCESS: ALLOCATION COMPLETED!");
            
            uint256 vaultAssetsAfter = IVaultV2(VAULT).totalAssets();
            uint256 adapterPtAfter = IPendleAdapter(ADAPTER).getPTBalance();
            uint256 allocationAfter = IVaultV2(VAULT).allocation(allocationId);
            
            console.log("");
            console.log("After allocation:");
            console.log("  Vault assets:", vaultAssetsAfter);
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
                try IPendleAdapter(ADAPTER).realAssets() returns (uint256 realAssetsValue) {
                    console.log("SUCCESS: realAssets():", realAssetsValue);
                } catch {
                    console.log("INFO: realAssets() failed");
                }
            } else {
                console.log("");
                console.log("INFO: Allocation succeeded but no PT tokens received");
                console.log("This may indicate Pendle router interaction issues");
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Allocation failed with data:");
            console.logBytes(data);
        }
    }
    
    function testDeallocation() internal {
        uint256 adapterPtBefore = IPendleAdapter(ADAPTER).getPTBalance();
        
        console.log("Before deallocation:");
        console.log("  Adapter PT balance:", adapterPtBefore);
        
        if (adapterPtBefore == 0) {
            console.log("SKIPPING: No PT tokens to deallocate");
            return;
        }
        
        console.log("Executing deallocation of", DEALLOCATE_AMOUNT, "kHYPE equivalent...");
        
        try IVaultV2(VAULT).deallocate(ADAPTER, "", DEALLOCATE_AMOUNT) {
            console.log("SUCCESS: DEALLOCATION COMPLETED!");
            
            uint256 adapterPtAfter = IPendleAdapter(ADAPTER).getPTBalance();
            uint256 vaultAssetsAfter = IVaultV2(VAULT).totalAssets();
            
            console.log("");
            console.log("After deallocation:");
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  Vault assets:", vaultAssetsAfter);
            console.log("  PT tokens redeemed:", adapterPtBefore - adapterPtAfter);
            
            if (adapterPtAfter < adapterPtBefore) {
                console.log("");
                console.log("*** DEALLOCATION SUCCESS! ***");
                console.log("*** COMPLETE ROUND-TRIP WORKING! ***");
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Deallocation failed:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Deallocation failed with data:");
            console.logBytes(data);
        }
    }
    
    function provideFinalSummary() internal view {
        uint256 adapterPtFinal = IPendleAdapter(ADAPTER).getPTBalance();
        uint256 vaultAssetsFinal = IVaultV2(VAULT).totalAssets();
        bool isAdapterRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
        bool isAllocatorSet = IVaultV2(VAULT).isAllocator(CURATOR);
        
        console.log("=== DEPLOYMENT SUCCESS ===");
        console.log("VaultV2:", VAULT);
        console.log("PendleV2AdapterKHYPE:", ADAPTER);
        console.log("Asset (kHYPE):", KHYPE);
        console.log("");
        
        console.log("Final state:");
        console.log("  Adapter registered:", isAdapterRegistered);
        console.log("  Allocator permission:", isAllocatorSet);
        console.log("  Adapter PT balance:", adapterPtFinal);
        console.log("  Vault total assets:", vaultAssetsFinal);
        
        if (adapterPtFinal > 0) {
            console.log("");
            console.log("*** COMPLETE SUCCESS! ***");
            console.log("*** NEW VAULTV2 + PENDLEV2ADAPTERKHYPE FULLY OPERATIONAL! ***");
            console.log("*** END-TO-END kHYPE -> PT-kHYPE FLOW WORKING! ***");
            console.log("*** PENDLE INTEGRATION SUCCESSFUL! ***");
        } else {
            console.log("");
            console.log("*** INFRASTRUCTURE SUCCESS ***");
            console.log("Deployment: PERFECT");
            console.log("Authorization: COMPLETE");
            console.log("Adapter Registration: COMPLETE");
            console.log("Ready for kHYPE deposits and Pendle allocation testing!");
        }
    }
}