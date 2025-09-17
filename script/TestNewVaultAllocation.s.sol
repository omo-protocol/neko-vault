// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

interface IVaultV2 {
    function submit(bytes calldata data) external;
    function setIsAllocator(address account, bool newIsAllocator) external;
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function isAllocator(address account) external view returns (bool);
    function isAdapter(address adapter) external view returns (bool);
    function totalAssets() external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function asset() external view returns (address);
    function curator() external view returns (address);
}

interface IPendleAdapter {
    function getPTBalance() external view returns (uint256);
    function realAssets() external view returns (uint256);
}

contract TestNewVaultAllocation is Script {
    
    // Deployed contract addresses 
    address constant VAULT = 0x2A4e73Ad27fd8386ec79F4576Cae5EB8aE8cf807;
    address constant ADAPTER = 0x9f3e3F6837aB46e2CB51d33B344D8fBD94c6bFD7;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant DEPLOYER = 0x4741f70E78150C35B71357342B25Ef850D0C00e7;
    
    uint256 constant DEPOSIT_AMOUNT = 100000000000000; // 0.0001 kHYPE
    uint256 constant ALLOCATE_AMOUNT = 50000000000000; // 0.00005 kHYPE
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== TESTING NEW VAULTV2 ALLOCATION ===");
        console.log("Vault:", VAULT);
        console.log("Adapter:", ADAPTER);
        console.log("kHYPE:", KHYPE);
        console.log("Deployer:", DEPLOYER);
        console.log("");
        
        // Check if contracts exist
        console.log("Contract verification:");
        console.log("  Vault code size:", VAULT.code.length);
        console.log("  Adapter code size:", ADAPTER.code.length);
        
        if (VAULT.code.length == 0) {
            console.log("ERROR: Vault contract does not exist!");
            return;
        }
        
        if (ADAPTER.code.length == 0) {
            console.log("ERROR: Adapter contract does not exist!");
            return;
        }
        
        console.log("SUCCESS: Both contracts exist");
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        // PHASE 1: VERIFY SETUP
        console.log("PHASE 1: Verify Setup");
        console.log("=====================");
        
        verifySetup();
        console.log("");
        
        // PHASE 2: SETUP ALLOCATOR
        console.log("PHASE 2: Setup Allocator");
        console.log("========================");
        
        setupAllocator();
        console.log("");
        
        // PHASE 3: TEST ALLOCATION
        console.log("PHASE 3: Test Allocation");
        console.log("========================");
        
        testAllocation();
        
        vm.stopBroadcast();
    }
    
    function verifySetup() internal view {
        address vaultAsset = IVaultV2(VAULT).asset();
        address curator = IVaultV2(VAULT).curator();
        bool adapterRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
        
        console.log("Vault configuration:");
        console.log("  Asset:", vaultAsset);
        console.log("  Curator:", curator);
        console.log("  Asset is kHYPE:", vaultAsset == KHYPE);
        console.log("  Curator is deployer:", curator == DEPLOYER);
        console.log("  Adapter registered:", adapterRegistered);
        
        require(vaultAsset == KHYPE, "Vault asset incorrect");
        require(curator == DEPLOYER, "Curator incorrect");
        require(adapterRegistered, "Adapter not registered");
        
        console.log("SUCCESS: Setup verification passed");
    }
    
    function setupAllocator() internal {
        bool isCurrentlyAllocator = IVaultV2(VAULT).isAllocator(DEPLOYER);
        console.log("Current allocator status:", isCurrentlyAllocator);
        
        if (!isCurrentlyAllocator) {
            console.log("Setting allocator permission...");
            
            console.log("1. Submit setIsAllocator...");
            IVaultV2(VAULT).submit(abi.encodeWithSignature("setIsAllocator(address,bool)", DEPLOYER, true));
            
            console.log("2. Execute setIsAllocator...");
            IVaultV2(VAULT).setIsAllocator(DEPLOYER, true);
            
            // Verify
            bool newStatus = IVaultV2(VAULT).isAllocator(DEPLOYER);
            console.log("New allocator status:", newStatus);
            require(newStatus, "Allocator permission not set");
            
            console.log("SUCCESS: Allocator permission set");
        } else {
            console.log("SUCCESS: Already an allocator");
        }
    }
    
    function testAllocation() internal {
        uint256 deployerBalance = IERC20(KHYPE).balanceOf(msg.sender);
        uint256 vaultAssets = IVaultV2(VAULT).totalAssets();
        
        console.log("Pre-allocation status:");
        console.log("  Deployer kHYPE balance:", deployerBalance);
        console.log("  Vault total assets:", vaultAssets);
        
        // Deposit if needed and possible
        if (vaultAssets < ALLOCATE_AMOUNT && deployerBalance >= DEPOSIT_AMOUNT) {
            console.log("");
            console.log("Depositing kHYPE...");
            IERC20(KHYPE).approve(VAULT, DEPOSIT_AMOUNT);
            uint256 shares = IVaultV2(VAULT).deposit(DEPOSIT_AMOUNT, msg.sender);
            console.log("Deposited successfully, shares:", shares);
            
            vaultAssets = IVaultV2(VAULT).totalAssets();
            console.log("New vault assets:", vaultAssets);
        }
        
        if (vaultAssets < ALLOCATE_AMOUNT) {
            console.log("SKIPPING: Insufficient vault assets for allocation test");
            console.log("Need:", ALLOCATE_AMOUNT);
            console.log("Have:", vaultAssets);
            return;
        }
        
        // Test allocation
        console.log("");
        console.log("Testing allocation...");
        uint256 adapterPtBefore = IPendleAdapter(ADAPTER).getPTBalance();
        console.log("Adapter PT balance before:", adapterPtBefore);
        
        try IVaultV2(VAULT).allocate(ADAPTER, "", ALLOCATE_AMOUNT) {
            console.log("SUCCESS: ALLOCATION COMPLETED!");
            
            uint256 adapterPtAfter = IPendleAdapter(ADAPTER).getPTBalance();
            uint256 vaultAssetsAfter = IVaultV2(VAULT).totalAssets();
            
            console.log("");
            console.log("After allocation:");
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  Vault total assets:", vaultAssetsAfter);
            console.log("  PT tokens gained:", adapterPtAfter - adapterPtBefore);
            
            if (adapterPtAfter > adapterPtBefore) {
                console.log("");
                console.log("*** COMPLETE SUCCESS! ***");
                console.log("*** NEW VAULTV2 + PENDLEV2ADAPTERKHYPE WORKING! ***");
                console.log("*** END-TO-END kHYPE -> PT-kHYPE FLOW OPERATIONAL! ***");
            } else {
                console.log("");
                console.log("INFO: Allocation succeeded but no PT tokens received");
                console.log("This may indicate Pendle router integration issues");
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Allocation failed with data:");
            console.logBytes(data);
        }
    }
}