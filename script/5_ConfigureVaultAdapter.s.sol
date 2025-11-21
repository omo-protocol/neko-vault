// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title ConfigureVaultAdapter
 * @notice Configure vault adapter (Step 5)
 * @dev Adds an adapter to the vault
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/curator private key
 *
 * Usage:
 *   forge script script/5_ConfigureVaultAdapter.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 2 (submit + execute for adapter)
 */
contract ConfigureVaultAdapter is Script {
    // Configuration parameters
    address constant ADAPTER_ADDRESS = 0x8E4B001E79f26d5810Ced476470914Cd4F045d59;
    address constant VAULT_ADDRESS = 0xFC16fDd831d784F5293271f9EfDf67Af4214a747;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        require(VAULT_ADDRESS != address(0), "VAULT_ADDRESS must be set");
        require(ADAPTER_ADDRESS != address(0), "ADAPTER_ADDRESS must be set");

        VaultV2 vault = VaultV2(VAULT_ADDRESS);

        console.log("\n=================================================");
        console.log("    CONFIGURE VAULT ADAPTER (Step 5)");
        console.log("=================================================");
        console.log("Deployer:", deployer);
        console.log("VaultV2:", VAULT_ADDRESS);
        console.log("Adapter:", ADAPTER_ADDRESS);
        console.log("Transactions: 2");

        vm.startBroadcast(deployerPrivateKey);

        // Add adapter (2 transactions: submit + execute)
        console.log("\nAdding adapter...");
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (ADAPTER_ADDRESS)));
        vault.addAdapter(ADAPTER_ADDRESS);
        console.log("  Adapter added successfully");

        vm.stopBroadcast();

        console.log("\n=================================================");
        console.log("    CONFIGURATION COMPLETE!");
        console.log("=================================================");
        console.log("Adapter:", ADAPTER_ADDRESS);
    }
}
