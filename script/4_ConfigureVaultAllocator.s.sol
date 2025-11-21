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
contract ConfigureVaultAllocator is Script {
    // Configuration parameters
    // forge script script/4_ConfigureVaultAllocator.s.sol:ConfigureVaultAllocator --rpc-url https://rpc.hyperliquid.xyz/evm --broadcast -v
    address constant ALLOCATOR = 0x28572bC31Dc4f271d2377c47632ebfcB4CDf8e88;
    address constant VAULT_ADDRESS = 0xFC16fDd831d784F5293271f9EfDf67Af4214a747;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS must be set");

        VaultV2 vault = VaultV2(VAULT_ADDRESS);

        console.log("\n=================================================");
        console.log("    VAULT CORE CONFIGURATION (Step 2a)");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("VaultV2:", VAULT_ADDRESS);
        console.log("Transactions: 4");

        vm.startBroadcast(deployerPrivateKey);

        // Step 2: Set allocator (2 transactions)
        console.log("\n[Step 2/2] Setting allocator...");
        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (ALLOCATOR, true)));
        vault.setIsAllocator(ALLOCATOR, true);
        console.log("  Allocator set:", ALLOCATOR);

        vm.stopBroadcast();

       
        console.log("  Allocator:", ALLOCATOR);
    }
}
