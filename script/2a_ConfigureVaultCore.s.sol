// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title ConfigureVaultCore
 * @notice Core vault configuration - adapter and allocator (Step 2a)
 * @dev Run AFTER 1_DeployALMVault.s.sol
 *      Run 2b_ConfigureCaps.s.sol next
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/curator private key
 *
 * Usage:
 *   source .env && forge script script/2a_ConfigureVaultCore.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 4 (submit + execute for adapter, submit + execute for allocator)
 */
contract ConfigureVaultCore is Script {
    // Configuration parameters
    address constant ALLOCATOR = 0x39CEDbBe01471Edc329FD7C8149C0a744634F65D;
    address constant VAULT_ADDRESS = 0x52463983595Bec55bd3b50eA98e48F285d12Cca7;
    address constant ADAPTER_ADDRESS = 0xE7537bB191a6FfcD73eED7b2e720F5918Ba7E7E8;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS must be set");
        require(ADAPTER_ADDRESS != address(0), "ADAPTER_ADDRESS must be set");

        VaultV2 vault = VaultV2(VAULT_ADDRESS);
        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(ADAPTER_ADDRESS));

        console.log("\n=================================================");
        console.log("    VAULT CORE CONFIGURATION (Step 2a)");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("VaultV2:", VAULT_ADDRESS);
        console.log("Adapter:", ADAPTER_ADDRESS);
        console.log("Transactions: 4");

        vm.startBroadcast(deployerPrivateKey);

        // Step 1: Add adapter (2 transactions)
        console.log("\n[Step 1/2] Adding adapter...");
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        vault.addAdapter(address(adapter));
        console.log("  Adapter added successfully");

        // Step 2: Set allocator (2 transactions)
        console.log("\n[Step 2/2] Setting allocator...");
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (ALLOCATOR, true)));
        vault.setIsAllocator(ALLOCATOR, true);
        console.log("  Allocator set:", ALLOCATOR);

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    STEP 2a COMPLETE!");
        console.log("=================================================");
        console.log("Configuration:");
        console.log("  Adapter:", address(adapter));
        console.log("  Allocator:", ALLOCATOR);
        console.log("\nNext Step:");
        console.log("  Run: forge script script/2b_ConfigureCaps.s.sol --rpc-url $RPC_URL --broadcast -v");
    }
}
