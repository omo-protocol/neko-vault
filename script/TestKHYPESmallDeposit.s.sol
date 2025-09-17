// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";

interface IERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IVaultV2 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function totalAssets() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function asset() external view returns (address);
}

contract TestKHYPESmallDeposit is Script {
    
    // DEPLOYED CONTRACTS
    address constant VAULT = 0xC4373044B9f88ad8BcA4962FcA8f13A42A127eae; // kHYPE VaultV2
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    
    // Test with smallest possible amount
    uint256 constant DEPOSIT_AMOUNT = 0.0001e18; // 0.0001 kHYPE (100000000000000 wei)
    
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        
        console.log("=== KHYPE SMALL DEPOSIT TEST ===");
        console.log("Testing with smallest possible amount for safety");
        console.log("Vault:", VAULT);
        console.log("kHYPE:", KHYPE);
        console.log("Deposit amount:", DEPOSIT_AMOUNT);
        console.log("");
        
        vm.startBroadcast(deployerPrivateKey);
        
        address deployer = vm.addr(deployerPrivateKey);
        
        // PHASE 1: CHECK BALANCES
        console.log("PHASE 1: Balance Check");
        console.log("=====================");
        
        uint256 deployerKHype = IERC20(KHYPE).balanceOf(deployer);
        uint256 vaultShares = IVaultV2(VAULT).balanceOf(deployer);
        uint256 vaultAssets = IVaultV2(VAULT).totalAssets();
        
        console.log("Deployer:", deployer);
        console.log("Deployer kHYPE balance:", deployerKHype);
        console.log("Deployer vault shares:", vaultShares);
        console.log("Vault total assets:", vaultAssets);
        
        // Check if we have enough kHYPE
        if (deployerKHype < DEPOSIT_AMOUNT) {
            console.log("ERROR: Insufficient kHYPE for test");
            console.log("Need:", DEPOSIT_AMOUNT);
            console.log("Have:", deployerKHype);
            vm.stopBroadcast();
            return;
        }
        
        // PHASE 2: SMALL DEPOSIT TEST
        console.log("");
        console.log("PHASE 2: Small kHYPE Deposit");
        console.log("============================");
        
        console.log("Approving", DEPOSIT_AMOUNT, "kHYPE to vault...");
        IERC20(KHYPE).approve(VAULT, DEPOSIT_AMOUNT);
        
        console.log("Depositing", DEPOSIT_AMOUNT, "kHYPE...");
        uint256 shares = IVaultV2(VAULT).deposit(DEPOSIT_AMOUNT, deployer);
        
        console.log("SUCCESS: Deposit completed!");
        console.log("Received shares:", shares);
        
        // PHASE 3: VERIFY RESULTS
        console.log("");
        console.log("PHASE 3: Verify Results");
        console.log("=======================");
        
        uint256 deployerKHypeAfter = IERC20(KHYPE).balanceOf(deployer);
        uint256 vaultSharesAfter = IVaultV2(VAULT).balanceOf(deployer);
        uint256 vaultAssetsAfter = IVaultV2(VAULT).totalAssets();
        
        console.log("Deployer kHYPE after:", deployerKHypeAfter);
        console.log("Deployer vault shares after:", vaultSharesAfter);
        console.log("Vault total assets after:", vaultAssetsAfter);
        
        // Calculate changes
        uint256 kHypeUsed = deployerKHype - deployerKHypeAfter;
        uint256 sharesReceived = vaultSharesAfter - vaultShares;
        uint256 assetsIncrease = vaultAssetsAfter - vaultAssets;
        
        console.log("");
        console.log("Changes:");
        console.log("  kHYPE used:", kHypeUsed);
        console.log("  Shares received:", sharesReceived);
        console.log("  Vault assets increased:", assetsIncrease);
        
        // Verify deposit worked correctly
        if (kHypeUsed == DEPOSIT_AMOUNT) {
            console.log("SUCCESS: Correct kHYPE amount deposited");
        } else {
            console.log("WARNING: kHYPE amount mismatch");
        }
        
        if (sharesReceived == shares) {
            console.log("SUCCESS: Correct shares received");
        } else {
            console.log("WARNING: Shares mismatch");
        }
        
        if (assetsIncrease >= DEPOSIT_AMOUNT * 99 / 100) { // Allow 1% tolerance
            console.log("SUCCESS: Vault assets increased correctly");
        } else {
            console.log("WARNING: Vault assets increase mismatch");
        }
        
        vm.stopBroadcast();
        
        // FINAL RESULTS
        console.log("");
        console.log("=== FINAL RESULTS ===");
        console.log("kHYPE Deposit: SUCCESS");
        console.log("Amount:", DEPOSIT_AMOUNT);
        console.log("Shares received:", shares);
        console.log("kHYPE -> VaultV2 flow: WORKING!");
        console.log("");
        console.log("Next: Test allocation to Pendle PT");
        console.log("(Requires adapter registration via timelock)");
    }
}