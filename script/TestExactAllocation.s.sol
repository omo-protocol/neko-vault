// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
}

interface IVaultV2 {
    function allocate(address adapter, bytes calldata data, uint256 assets) external;
    function addAdapter(address adapter) external;
    function submit(bytes calldata data) external;
    function isAdapter(address adapter) external view returns (bool);
    function totalAssets() external view returns (uint256);
}

interface IPendleAdapter {
    function getPTBalance() external view returns (uint256);
    function realAssets() external view returns (uint256);
}

contract TestExactAllocation is Script {
    
    address constant VAULT = 0xC4373044B9f88ad8BcA4962FcA8f13A42A127eae;
    address constant NEW_ADAPTER = 0x74C11b5A27F90736518D078862A1Fd184D4FE957; // Exact config adapter
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant PT_TOKEN = 0x311dB0FDe558689550c68355783c95eFDfe25329;
    
    uint256 constant TEST_AMOUNT = 10000000000000; // 0.00001 kHYPE
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== TESTING EXACT PENDLE ALLOCATION ===");
        console.log("Vault:", VAULT);
        console.log("New Adapter (exact config):", NEW_ADAPTER);
        console.log("Test amount:", TEST_AMOUNT);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        
        // Check initial state
        uint256 vaultAssets = IVaultV2(VAULT).totalAssets();
        uint256 adapterPT = IPendleAdapter(NEW_ADAPTER).getPTBalance();
        uint256 deployerKHype = IERC20(KHYPE).balanceOf(deployer);
        
        console.log("Initial state:");
        console.log("  Vault assets:", vaultAssets);
        console.log("  Adapter PT balance:", adapterPT);
        console.log("  Deployer kHYPE:", deployerKHype);
        console.log("");
        
        // Register new adapter
        bool isRegistered = IVaultV2(VAULT).isAdapter(NEW_ADAPTER);
        console.log("Adapter registered:", isRegistered);
        
        if (!isRegistered) {
            console.log("Registering new adapter...");
            
            IVaultV2(VAULT).submit(abi.encodeWithSignature("addAdapter(address)", NEW_ADAPTER));
            IVaultV2(VAULT).addAdapter(NEW_ADAPTER);
            
            console.log("Adapter registered successfully");
        }
        
        // Test allocation
        console.log("Testing allocation...");
        
        try IVaultV2(VAULT).allocate(NEW_ADAPTER, "", TEST_AMOUNT) {
            console.log("SUCCESS: Allocation completed!");
            
            // Check results
            uint256 vaultAssetsAfter = IVaultV2(VAULT).totalAssets();
            uint256 adapterPTAfter = IPendleAdapter(NEW_ADAPTER).getPTBalance();
            uint256 adapterRealAssets = IPendleAdapter(NEW_ADAPTER).realAssets();
            
            console.log("");
            console.log("After allocation:");
            console.log("  Vault assets:", vaultAssetsAfter);
            console.log("  Adapter PT balance:", adapterPTAfter);
            console.log("  Adapter real assets:", adapterRealAssets);
            
            console.log("");
            console.log("Changes:");
            console.log("  PT tokens gained:", adapterPTAfter - adapterPT);
            console.log("  Vault assets change:", int256(vaultAssetsAfter) - int256(vaultAssets));
            
            if (adapterPTAfter > adapterPT) {
                console.log("SUCCESS: PT tokens received!");
                console.log("ALLOCATION WORKING!");
            }
            
        } catch Error(string memory reason) {
            console.log("Allocation failed:", reason);
        } catch (bytes memory data) {
            console.log("Allocation failed with data:");
            console.logBytes(data);
        }
        
        vm.stopBroadcast();
        
        console.log("");
        console.log("=== TEST COMPLETE ===");
    }
}