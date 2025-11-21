// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import "../src/adapters/UniversalAdapterEscrowFactory.sol";
import {IVaultV2} from "../src/interfaces/IVaultV2.sol";

/**
 * @title RemoveAdapterAddNewAdapter
 * @notice Remove old adapter with alm-whype-sthype strategy and add a new one
 * @dev This script:
 *      1. Removes the old adapter from VaultV2
 *      2. Deploys a new UniversalAdapterEscrow (or uses existing)
 *      3. Adds the new adapter to VaultV2
 *      4. Configures the new adapter with alm-whype-sthype strategy
 *
 * Usage:
 *   PRIVATE_KEY=0x... \
 *   VAULT_ADDRESS=0x... \
 *   OLD_ADAPTER_ADDRESS=0x... \
 *   VALUER_ADDRESS=0x... \
 *   FACTORY_ADDRESS=0x... \
 *   forge script script/2g_RemoveAdapterAddNewAdapter.s.sol --rpc-url <RPC_URL> --broadcast -v
 *
 * Optional: Set NEW_ADAPTER_ADDRESS to skip deployment and use existing adapter
 */
contract RemoveAdapterAddNewAdapter is Script {
    // Strategy ID for ALM WHYPE-stHYPE
    bytes32 constant ALM_WHYPE_STHYPE_ID = keccak256("alm-whype-sthype");

    function run() public {
        // Load configuration from environment
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        address vaultAddress = 0x52463983595Bec55bd3b50eA98e48F285d12Cca7; // vm.envAddress("VAULT_ADDRESS");
        address oldAdapterAddress = 0xE7537bB191a6FfcD73eED7b2e720F5918Ba7E7E8; // vm.envAddress("OLD_ADAPTER_ADDRESS");

        // Optional: use existing new adapter instead of deploying
        address newAdapterAddress = 0x6320338670E98d9379469550845886D61271dFDe; // vm.envOr("NEW_ADAPTER_ADDRESS", address(0));

        require(vaultAddress != address(0), "VAULT_ADDRESS must be set");
        require(oldAdapterAddress != address(0), "OLD_ADAPTER_ADDRESS must be set");

        VaultV2 vault = VaultV2(vaultAddress);

        console.log("\n================================================================");
        console.log("    REMOVE & ADD ADAPTER - ALM WHYPE-STHYPE");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Vault:", vaultAddress);
        console.log("Old Adapter:", oldAdapterAddress);

        // Check current state
        bool isOldAdapterRegistered = vault.isAdapter(oldAdapterAddress);
        console.log("\nCurrent State:");
        console.log("  Old adapter registered:", isOldAdapterRegistered);

        if (!isOldAdapterRegistered) {
            console.log("\n[WARNING] Old adapter is not registered in vault");
            console.log("Proceeding to deploy and add new adapter only...\n");
        }

        vm.startBroadcast(deployerPrivateKey);

        // ======================================================================
        // STEP 1: Remove old adapter (if registered)
        // ======================================================================
        if (isOldAdapterRegistered) {
            console.log("\n[STEP 1/4] Removing old adapter...");

            // Check if there are any allocations to this adapter
            // Note: We can't easily check all strategy IDs, so we'll warn the user
            console.log("  [WARNING] Ensure all allocations to old adapter are deallocated first!");

            // Submit removal
            console.log("  [1a] Submitting removeAdapter timelock...");
            bytes memory removeAdapterData = abi.encodeCall(IVaultV2.removeAdapter, (oldAdapterAddress));
            vault.submit(removeAdapterData);
            console.log("    \u2713 Timelock submitted");

            // Execute removal (will only work if timelock has passed)
            console.log("  [1b] Executing removeAdapter...");
            try vault.removeAdapter(oldAdapterAddress) {
                console.log("    \u2713 Old adapter removed");
            } catch {
                console.log("    \u2717 Timelock not yet passed - will need to execute later");
                console.log("    Execute: vault.removeAdapter(", oldAdapterAddress, ")");
            }
        } else {
            console.log("\n[STEP 1/4] Skipping removal (old adapter not registered)");
        }

        // ======================================================================
        // STEP 2: Deploy new adapter (or use existing)
        // ======================================================================
        console.log("\n[STEP 2/4] Deploying new adapter...");

        UniversalAdapterEscrow newAdapter;

        console.log("  Using existing adapter:", newAdapterAddress);
        newAdapter = UniversalAdapterEscrow(payable(newAdapterAddress));

        // ======================================================================
        // STEP 3: Add new adapter to vault
        // ======================================================================
        console.log("\n[STEP 3/4] Adding new adapter to vault...");

        bool isNewAdapterRegistered = vault.isAdapter(newAdapterAddress);

        if (isNewAdapterRegistered) {
            console.log("  [INFO] New adapter already registered");
        } else {
            // Submit addition
            console.log("  [3a] Submitting addAdapter timelock...");
            bytes memory addAdapterData = abi.encodeCall(IVaultV2.addAdapter, (newAdapterAddress));
            vault.submit(addAdapterData);
            console.log("    \u2713 Timelock submitted");

            // Execute addition (will only work if timelock has passed)
            console.log("  [3b] Executing addAdapter...");
            try vault.addAdapter(newAdapterAddress) {
                console.log("    \u2713 New adapter added");
            } catch {
                console.log("    \u2717 Timelock not yet passed - will need to execute later");
                console.log("    Execute: vault.addAdapter(", newAdapterAddress, ")");
            }
        }

        // ======================================================================
        // STEP 4: Configure new adapter with alm-whype-sthype strategy
        // ======================================================================
        console.log("\n[STEP 4/4] Configuring ALM WHYPE-STHYPE strategy...");

        // Check if strategy already configured
        (address currentAgent,,,,,bool isActive) = newAdapter.strategies(ALM_WHYPE_STHYPE_ID);

        if (isActive && currentAgent != address(0)) {
            console.log("  [INFO] Strategy already configured");
            console.log("    Agent:", currentAgent);
        } else {
            console.log("  Setting strategy on new adapter...");
            newAdapter.setStrategy(
                ALM_WHYPE_STHYPE_ID,
                deployer,              // strategy agent
                "",                     // no pre-configured data
                type(uint256).max       // no daily limit
            );
            console.log("    \u2713 Strategy configured");
            console.log("    Strategy ID: alm-whype-sthype");
            console.log("    Agent:", deployer);
        }

        vm.stopBroadcast();

        // ======================================================================
        // FINAL STATUS
        // ======================================================================
        console.log("\n================================================================");
        console.log("    OPERATION COMPLETE");
        console.log("================================================================");

        bool finalOldRegistered = vault.isAdapter(oldAdapterAddress);
        bool finalNewRegistered = vault.isAdapter(newAdapterAddress);

        console.log("\nFinal State:");
        console.log("  Old adapter registered:", finalOldRegistered);
        console.log("  New adapter registered:", finalNewRegistered);
        console.log("\nNew Adapter:", newAdapterAddress);
        console.log("Strategy ID:", vm.toString(ALM_WHYPE_STHYPE_ID));

        if (!finalOldRegistered && finalNewRegistered) {
            console.log("\n  \u2713\u2713\u2713 SUCCESS: OLD ADAPTER REMOVED, NEW ADAPTER ADDED \u2713\u2713\u2713");
        } else if (finalOldRegistered && finalNewRegistered) {
            console.log("\n  \u26A0 PARTIAL: Timelock may still be pending for removal");
            console.log("    Wait for timelock period, then execute removeAdapter manually");
        } else if (!finalOldRegistered && !finalNewRegistered) {
            console.log("\n  \u26A0 PARTIAL: Timelock may still be pending for addition");
            console.log("    Wait for timelock period, then execute addAdapter manually");
        }

        console.log("\nNext Steps:");
        console.log("1. Configure function whitelists for ALM protocol on new adapter");
        console.log("2. Set vault caps for alm-whype-sthype strategy if needed");
        console.log("3. Allocate funds to the new adapter");
        console.log("================================================================\n");
    }
}
