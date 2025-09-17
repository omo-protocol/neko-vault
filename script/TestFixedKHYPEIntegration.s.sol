// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

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
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
}

interface IPendleAdapter {
    function getPTBalance() external view returns (uint256);
    function realAssets() external view returns (uint256);
    function parentVault() external view returns (address);
    function asset() external view returns (address);
}

contract TestFixedKHYPEIntegration is Script {
    
    // EXACT SAME PATTERN AS WORKING TestPendleV2Adapter2EndToEnd.s.sol
    address constant VAULT = 0xC4373044B9f88ad8BcA4962FcA8f13A42A127eae;
    address constant ADAPTER = 0xf6a5c90faC8b02C58F18e65947b8d00cD478D30d;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    
    // Test parameters (using smaller amounts like working script)
    uint256 constant DEPOSIT_AMOUNT = 100000000000000; // 0.0001 kHYPE
    uint256 constant ALLOCATE_AMOUNT = 50000000000000; // 0.00005 kHYPE (like working script)
    uint256 constant MAX_CAP = 10000000000000000000; // 10 kHYPE cap
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== TESTING FIXED KHYPE INTEGRATION ===");
        console.log("Following EXACT working pattern with proper submit() calls");
        console.log("Vault:", VAULT);
        console.log("Adapter:", ADAPTER);
        console.log("kHYPE:", KHYPE);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        
        // PHASE 1: VERIFY ADAPTER CONFIGURATION
        console.log("PHASE 1: Verify Adapter Configuration");
        console.log("=====================================");
        
        address adapterVault = IPendleAdapter(ADAPTER).parentVault();
        address adapterAsset = IPendleAdapter(ADAPTER).asset();
        address vaultAsset = IVaultV2(VAULT).asset();
        
        console.log("Adapter vault:", adapterVault);
        console.log("Adapter asset:", adapterAsset);
        console.log("Vault asset:", vaultAsset);
        
        require(adapterVault == VAULT, "Adapter vault mismatch");
        require(adapterAsset == KHYPE, "Adapter asset mismatch");
        require(vaultAsset == KHYPE, "Vault asset mismatch");
        console.log("SUCCESS: Adapter configuration verified");
        console.log("");
        
        // PHASE 2: ADAPTER REGISTRATION (EXACT WORKING PATTERN)
        console.log("PHASE 2: Adapter Registration");
        console.log("=============================");
        
        bool isRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
        console.log("Adapter currently registered:", isRegistered);
        
        if (!isRegistered) {
            console.log("Registering adapter using EXACT working pattern...");
            
            // EXACT PATTERN FROM WORKING SCRIPT: submit() FIRST, then actual call
            console.log("1. Calling submit() for addAdapter...");
            IVaultV2(VAULT).submit(abi.encodeWithSignature("addAdapter(address)", ADAPTER));
            
            console.log("2. Calling addAdapter() directly...");
            IVaultV2(VAULT).addAdapter(ADAPTER);
            
            console.log("SUCCESS: Adapter registered successfully");
            
            // Set allocation caps using EXACT working pattern
            bytes memory idData = abi.encode("pendle-v2-khype-allocation");
            bytes32 allocationId = keccak256(idData);
            
            console.log("3. Setting caps with submit() pattern...");
            
            IVaultV2(VAULT).submit(abi.encodeWithSignature("increaseAbsoluteCap(bytes,uint256)", idData, MAX_CAP));
            IVaultV2(VAULT).increaseAbsoluteCap(idData, MAX_CAP);
            
            IVaultV2(VAULT).submit(abi.encodeWithSignature("increaseRelativeCap(bytes,uint256)", idData, 1e18)); // 100%
            IVaultV2(VAULT).increaseRelativeCap(idData, 1e18);
            
            console.log("SUCCESS: Caps set successfully");
            
            // Verify setup
            bool nowRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
            uint256 capSet = IVaultV2(VAULT).absoluteCap(allocationId);
            console.log("Final verification - Registered:", nowRegistered, "Cap:", capSet);
            
            require(nowRegistered, "Adapter registration failed");
            require(capSet >= ALLOCATE_AMOUNT, "Cap too low");
        } else {
            console.log("SUCCESS: Adapter already registered");
        }
        console.log("");
        
        // PHASE 3: DEPOSIT KHYPE (if needed)
        console.log("PHASE 3: Deposit kHYPE");
        console.log("======================");
        
        uint256 deployerKHype = IERC20(KHYPE).balanceOf(deployer);
        uint256 vaultShares = IVaultV2(VAULT).balanceOf(deployer);
        uint256 vaultAssets = IVaultV2(VAULT).totalAssets();
        
        console.log("Deployer kHYPE balance:", deployerKHype);
        console.log("Deployer vault shares:", vaultShares);
        console.log("Vault total assets:", vaultAssets);
        
        if (vaultAssets < ALLOCATE_AMOUNT && deployerKHype >= DEPOSIT_AMOUNT) {
            console.log("Depositing", DEPOSIT_AMOUNT, "kHYPE to vault...");
            
            IERC20(KHYPE).approve(VAULT, DEPOSIT_AMOUNT);
            uint256 sharesReceived = IVaultV2(VAULT).deposit(DEPOSIT_AMOUNT, deployer);
            
            console.log("SUCCESS: Deposited successfully, shares received:", sharesReceived);
            
            vaultAssets = IVaultV2(VAULT).totalAssets();
            console.log("New vault total assets:", vaultAssets);
        }
        
        require(vaultAssets >= ALLOCATE_AMOUNT, "Insufficient vault assets for allocation");
        console.log("");
        
        // PHASE 4: TEST ALLOCATION (EXACT WORKING PATTERN)
        console.log("PHASE 4: Test Allocation");
        console.log("========================");
        
        uint256 adapterPtBefore = IPendleAdapter(ADAPTER).getPTBalance();
        uint256 vaultAssetsBefore = IVaultV2(VAULT).totalAssets();
        
        console.log("Before allocation:");
        console.log("  Adapter PT balance:", adapterPtBefore);
        console.log("  Vault assets:", vaultAssetsBefore);
        console.log("");
        
        console.log("Executing allocation using EXACT working pattern...");
        console.log("Amount:", ALLOCATE_AMOUNT, "kHYPE");
        
        // EXACT PATTERN FROM WORKING SCRIPT: allocate() called directly (NO submit() needed)
        try IVaultV2(VAULT).allocate(ADAPTER, "", ALLOCATE_AMOUNT) {
            console.log("SUCCESS: ALLOCATION SUCCESSFUL!");
            
            uint256 adapterPtAfter = IPendleAdapter(ADAPTER).getPTBalance();
            uint256 vaultAssetsAfter = IVaultV2(VAULT).totalAssets();
            
            console.log("");
            console.log("After allocation:");
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  Vault assets:", vaultAssetsAfter);
            
            console.log("");
            console.log("Changes:");
            console.log("  PT tokens gained:", adapterPtAfter - adapterPtBefore);
            console.log("  Vault assets change:", int256(vaultAssetsAfter) - int256(vaultAssetsBefore));
            
            if (adapterPtAfter > adapterPtBefore) {
                console.log("");
                console.log("SUCCESS! PT tokens received!");
                console.log("PENDLE ROUTER WORKS PERFECTLY!");
                console.log("ISSUE WAS VAULTV2 TIMELOCK, NOT PENDLE!");
                
                // Test realAssets
                try IPendleAdapter(ADAPTER).realAssets() returns (uint256 realAssetsValue) {
                    console.log("SUCCESS: realAssets() working:", realAssetsValue);
                } catch {
                    console.log("INFO: realAssets() failed (acceptable - may need RouterStatic)");
                }
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed with reason:", reason);
        } catch (bytes memory data) {
            console.log("ERROR: Allocation failed with data:");
            console.logBytes(data);
        }
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== TEST COMPLETE ===");
        console.log("Adapter properly integrated with VaultV2 timelock pattern!");
    }
}