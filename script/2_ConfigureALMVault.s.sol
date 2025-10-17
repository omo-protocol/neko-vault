// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title ConfigureALMVault
 * @notice Vault configuration script (Step 2 after deployment)
 * @dev This script should be run AFTER 1_DeployALMVault.s.sol
 *      Run 3_ConfigureAdapter.s.sol afterwards to configure adapter strategy
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/curator private key
 *   - VAULT_ADDRESS: Address of deployed VaultV2
 *   - ADAPTER_ADDRESS: Address of deployed UniversalAdapterEscrow
 *
 * Usage:
 *   PRIVATE_KEY=0x... VAULT_ADDRESS=0x... ADAPTER_ADDRESS=0x... \
 *   forge script script/2_ConfigureALMVault.s.sol --rpc-url <RPC_URL> --broadcast -v
 *
 * Note: Adapter strategy configuration moved to separate script to reduce nonce issues
 */
contract ConfigureALMVault is Script {
    // Strategy IDs (must match deployment script)
    bytes32 constant ALM_STRATEGY_ID = keccak256("alm-whype-sthype");
    bytes idData = abi.encodePacked(ALM_STRATEGY_ID);
    uint256 constant RELATIVE_CAP = 1e18; // 100% of vault assets (1e18 = 100%)

    // Configuration parameters (must match deployment script)
    address constant ALLOCATOR = 0x39CEDbBe01471Edc329FD7C8149C0a744634F65D; // config to worker wallet address
    address constant PERFORMANCE_FEE_RECIPIENT = 0xc88083Db7Fdcf1Ae52DF7E8aC89E29934677db4C; // config to fee recipient address
    uint256 constant PERFORMANCE_FEE = 0.2e18; // 20% performance fee (0.2e18 = 20%)
    address constant VAULT_ADDRESS = 0x52463983595Bec55bd3b50eA98e48F285d12Cca7; // config to vault address
    address constant ADAPTER_ADDRESS = 0xE7537bB191a6FfcD73eED7b2e720F5918Ba7E7E8; // config to adapter address

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load deployed contract addresses
        address vaultAddress = VAULT_ADDRESS;
        address adapterAddress = ADAPTER_ADDRESS;

        require(vaultAddress != address(0), "VAULT_ADDRESS must be set");
        require(adapterAddress != address(0), "ADAPTER_ADDRESS must be set");

        VaultV2 vault = VaultV2(vaultAddress);
        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));

        console.log("\n=================================================");
        console.log("    VAULT CONFIGURATION");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("VaultV2:", vaultAddress);
        console.log("Adapter:", adapterAddress);

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Add adapter to vault
        console.log("\n[Step 1] Adding adapter to vault...");
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        vault.addAdapter(address(adapter));
        console.log("  Adapter added successfully");

        // Step 2: Set allocator
        console.log("\n[Step 2] Setting allocator...");
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (ALLOCATOR, true)));
        vault.setIsAllocator(ALLOCATOR, true);
        console.log("  Allocator set:", ALLOCATOR);

        // Step 3: Set absolute cap
        console.log("\n[Step 3] Setting absolute cap...");
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);
        console.log("  Absolute cap set to max");

        // Step 4: Set relative cap
        console.log("\n[Step 4] Setting relative cap...");
        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, RELATIVE_CAP)));
        vault.increaseRelativeCap(idData, RELATIVE_CAP);
        console.log("  Relative cap set to:", RELATIVE_CAP / 1e16, "%");

        // Step 5: Set performance fee (if recipient is configured)
        if (PERFORMANCE_FEE_RECIPIENT != address(0)) {
            console.log("\n[Step 5] Setting performance fee...");

            // Step 5a: Set Performance Fee Recipient
            vault.submit(abi.encodeCall(IVaultV2.setPerformanceFeeRecipient, (PERFORMANCE_FEE_RECIPIENT)));
            vault.setPerformanceFeeRecipient(PERFORMANCE_FEE_RECIPIENT);
            console.log("  Performance fee recipient set:", PERFORMANCE_FEE_RECIPIENT);

            // Step 5b: Set Performance Fee
            vault.submit(abi.encodeCall(IVaultV2.setPerformanceFee, (PERFORMANCE_FEE)));
            vault.setPerformanceFee(PERFORMANCE_FEE);
            console.log("  Performance fee set to:", PERFORMANCE_FEE / 1e16, "%");
        } else {
            console.log("\n[Step 5] Skipping performance fee configuration (recipient not set)");
        }

        vm.stopBroadcast();

        // Final status
        console.log("\n=================================================");
        console.log("    VAULT CONFIGURATION COMPLETE!");
        console.log("=================================================");
        console.log("\nVault Configuration Summary:");
        console.log("  Adapter:", address(adapter));
        console.log("  Allocator:", ALLOCATOR);
        console.log("  Absolute Cap: MAX");
        console.log("  Relative Cap:", RELATIVE_CAP / 1e16, "%");
        if (PERFORMANCE_FEE_RECIPIENT != address(0)) {
            console.log("  Performance Fee Recipient:", PERFORMANCE_FEE_RECIPIENT);
            console.log("  Performance Fee:", PERFORMANCE_FEE / 1e16, "%");
        }

        console.log("\n[SUCCESS] Vault configuration complete!");
        console.log("\nNext Step:");
        console.log("  Run: forge script script/3_ConfigureAdapter.s.sol --rpc-url <RPC_URL> --broadcast -v");
        console.log("  This will configure the adapter strategy (1 transaction)");
    }
}
