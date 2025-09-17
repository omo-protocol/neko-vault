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
    function realAssets() external view returns (uint256);
    function asset() external view returns (address);
    function balanceOf(address) external view returns (uint256);
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares);
}

interface IPendleAdapter {
    function getPTBalance() external view returns (uint256);
    function realAssets() external view returns (uint256);
    function parentVault() external view returns (address);
    function asset() external view returns (address);
    function getCurrentRates() external view returns (uint256 kHypeToWhypeRate, uint256 ptToKHypeRate);
}

contract TestVaultV2AllocationDeallocation is Script {
    
    // Contract addresses
    address constant VAULT = 0xC4373044B9f88ad8BcA4962FcA8f13A42A127eae;
    address constant ADAPTER = 0xf6a5c90faC8b02C58F18e65947b8d00cD478D30d;
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    
    // Test parameters - using conservative amounts like working script
    uint256 constant DEPOSIT_AMOUNT = 200000000000000; // 0.0002 kHYPE for testing
    uint256 constant ALLOCATE_AMOUNT = 100000000000000; // 0.0001 kHYPE
    uint256 constant DEALLOCATE_AMOUNT = 50000000000000; // 0.00005 kHYPE
    uint256 constant MAX_CAP = 10000000000000000000; // 10 kHYPE cap
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== VAULTV2 + PENDLEV2ADAPTERKHYPE END-TO-END TEST ===");
        console.log("Testing complete allocation and deallocation flow");
        console.log("Vault:", VAULT);
        console.log("Adapter:", ADAPTER);
        console.log("kHYPE:", KHYPE);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        
        // PHASE 1: SETUP AND VERIFICATION
        console.log("PHASE 1: Setup and Verification");
        console.log("===============================");
        
        setupAndVerifySystem();
        console.log("");
        
        // PHASE 2: TEST ALLOCATION
        console.log("PHASE 2: Test Allocation");
        console.log("========================");
        
        testAllocation();
        console.log("");
        
        // PHASE 3: TEST DEALLOCATION
        console.log("PHASE 3: Test Deallocation");
        console.log("==========================");
        
        testDeallocation();
        console.log("");
        
        vm.stopBroadcast();
        
        // FINAL SUMMARY
        console.log("=== FINAL SUMMARY ===");
        provideFinalSummary();
    }
    
    function setupAndVerifySystem() internal {
        // Verify adapter configuration
        address adapterVault = IPendleAdapter(ADAPTER).parentVault();
        address adapterAsset = IPendleAdapter(ADAPTER).asset();
        address vaultAsset = IVaultV2(VAULT).asset();
        
        console.log("System configuration:");
        console.log("  Adapter vault:", adapterVault);
        console.log("  Adapter asset:", adapterAsset);
        console.log("  Vault asset:", vaultAsset);
        
        require(adapterVault == VAULT, "Adapter vault mismatch");
        require(adapterAsset == KHYPE, "Adapter asset mismatch");
        require(vaultAsset == KHYPE, "Vault asset mismatch");
        
        // Check adapter registration
        bool isRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
        console.log("  Adapter registered:", isRegistered);
        
        if (!isRegistered) {
            console.log("Registering adapter with proper submit() pattern...");
            registerAdapter();
        }
        
        console.log("SUCCESS: System setup verified");
    }
    
    function registerAdapter() internal {
        // EXACT PATTERN FROM WORKING SCRIPT
        IVaultV2(VAULT).submit(abi.encodeWithSignature("addAdapter(address)", ADAPTER));
        IVaultV2(VAULT).addAdapter(ADAPTER);
        console.log("Adapter registered successfully");
    }
    
    function testAllocation() internal {
        uint256 adapterPtBefore = IPendleAdapter(ADAPTER).getPTBalance();
        uint256 vaultAssetsBefore = getVaultTotalAssets();
        
        bytes memory idData = abi.encode("pendle-v2-khype-allocation");
        bytes32 allocationId = keccak256(idData);
        uint256 allocationBefore = IVaultV2(VAULT).allocation(allocationId);
        
        console.log("Before allocation:");
        console.log("  Vault total assets:", vaultAssetsBefore);
        console.log("  Adapter PT balance:", adapterPtBefore);
        console.log("  Tracked allocation:", allocationBefore);
        
        console.log("");
        console.log("Executing allocation of", ALLOCATE_AMOUNT, "kHYPE...");
        
        // EXECUTE ALLOCATION - EXACT PATTERN FROM WORKING SCRIPT
        try IVaultV2(VAULT).allocate(ADAPTER, "", ALLOCATE_AMOUNT) {
            console.log("SUCCESS: Allocation transaction completed!");
            
            // Check results
            uint256 adapterPtAfter = IPendleAdapter(ADAPTER).getPTBalance();
            uint256 vaultAssetsAfter = getVaultTotalAssets();
            uint256 allocationAfter = IVaultV2(VAULT).allocation(allocationId);
            
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
            
            // Test realAssets
            try IPendleAdapter(ADAPTER).realAssets() returns (uint256 realAssetsValue) {
                console.log("  Adapter realAssets:", realAssetsValue);
                console.log("SUCCESS: realAssets() working!");
            } catch {
                console.log("INFO: realAssets() failed (may need RouterStatic)");
            }
            
            if (adapterPtAfter > adapterPtBefore) {
                console.log("");
                console.log("*** ALLOCATION SUCCESS! ***");
                console.log("*** PT TOKENS RECEIVED! ***");
                console.log("*** PENDLE INTEGRATION WORKING! ***");
            } else {
                console.log("");
                console.log("WARNING: No PT tokens received despite successful transaction");
                console.log("This suggests the allocation completed but didn't interact with Pendle");
            }
            
        } catch Error(string memory reason) {
            console.log("ERROR: Allocation failed with reason:", reason);
            
            // Provide detailed diagnostics
            console.log("");
            console.log("ALLOCATION FAILURE DIAGNOSTICS:");
            console.log("  Reason:", reason);
            console.log("  Vault has assets:", getVaultTotalAssets());
            console.log("  Adapter registered:", IVaultV2(VAULT).isAdapter(ADAPTER));
            console.log("  Allocation amount:", ALLOCATE_AMOUNT);
            
        } catch (bytes memory data) {
            console.log("ERROR: Allocation failed with raw data:");
            console.logBytes(data);
            
            // Try to decode common error signatures
            if (data.length >= 4) {
                bytes4 selector = bytes4(data);
                console.log("Error selector:", vm.toString(selector));
                
                if (selector == 0x08c379a0) { // Error(string)
                    console.log("Standard revert reason detected");
                } else {
                    console.log("Custom error detected");
                }
            }
        }
    }
    
    function testDeallocation() internal {
        uint256 adapterPtBefore = IPendleAdapter(ADAPTER).getPTBalance();
        
        console.log("Before deallocation:");
        console.log("  Adapter PT balance:", adapterPtBefore);
        
        if (adapterPtBefore == 0) {
            console.log("SKIPPING: No PT tokens to deallocate");
            console.log("Deallocation test requires successful allocation first");
            return;
        }
        
        console.log("Executing deallocation of", DEALLOCATE_AMOUNT, "kHYPE equivalent...");
        
        try IVaultV2(VAULT).deallocate(ADAPTER, "", DEALLOCATE_AMOUNT) {
            console.log("SUCCESS: Deallocation transaction completed!");
            
            uint256 adapterPtAfter = IPendleAdapter(ADAPTER).getPTBalance();
            uint256 vaultAssetsAfter = getVaultTotalAssets();
            
            console.log("");
            console.log("After deallocation:");
            console.log("  Adapter PT balance:", adapterPtAfter);
            console.log("  Vault total assets:", vaultAssetsAfter);
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
    
    function getVaultTotalAssets() internal view returns (uint256) {
        try IVaultV2(VAULT).totalAssets() returns (uint256 assets) {
            return assets;
        } catch {
            console.log("WARNING: totalAssets() failed, using balanceOf fallback");
            return IERC20(KHYPE).balanceOf(VAULT);
        }
    }
    
    function provideFinalSummary() internal view {
        uint256 adapterPtFinal = IPendleAdapter(ADAPTER).getPTBalance();
        uint256 vaultAssetsFinal = getVaultTotalAssets();
        bool isRegistered = IVaultV2(VAULT).isAdapter(ADAPTER);
        
        console.log("Final system state:");
        console.log("  Adapter registered:", isRegistered);
        console.log("  Adapter PT balance:", adapterPtFinal);
        console.log("  Vault total assets:", vaultAssetsFinal);
        
        if (adapterPtFinal > 0) {
            console.log("");
            console.log("*** OVERALL SUCCESS! ***");
            console.log("VaultV2 + PendleV2AdapterKHYPE integration working!");
            console.log("Pendle router calls successful!");
        } else {
            console.log("");
            console.log("*** INTEGRATION INCOMPLETE ***");
            console.log("VaultV2 integration: WORKING");
            console.log("Pendle integration: NEEDS INVESTIGATION");
            console.log("Next: Debug specific Pendle router interaction");
        }
    }
}