// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";

/**
 * @title ConfigureOptionVaultWhitelist
 * @notice Configure function whitelists for Option Vault strategy
 * @dev Run AFTER 2d_ConfigureAdapter.s.sol
 *
 * CRITICAL: UniversalAdapterEscrow requires whitelisting ALL functions that will be called
 * via executeStrategy(). Without whitelist configuration, all strategy executions will
 * REVERT with FunctionNotWhitelisted() error.
 *
 * This script configures whitelists for Option Vault to transfer assets to MPC wallet (EOA):
 * - ERC20 transfer function for the vault's underlying asset
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *
 * Usage:
 *   source .env && forge script script/2g_ConfigureOptionVaultWhitelist.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 1 (single updateWhitelist call)
 */
contract ConfigureOptionVaultWhitelist is Script {
    // ============================================================
    // CONFIGURATION - UPDATE BEFORE DEPLOYMENT
    // ============================================================

    // Adapter address for the Option Vault
    address constant ADAPTER_ADDRESS = address(0); // TODO: Set after deployment

    // Underlying asset token address (e.g., USDC, kHYPE, etc.)
    address constant UNDERLYING_ASSET = address(0); // TODO: Set to vault's underlying asset

    // ============================================================
    // FUNCTION SELECTORS
    // ============================================================

    // ERC20 transfer(address,uint256) selector
    bytes4 constant ERC20_TRANSFER = 0xa9059cbb;

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Validate configuration
        require(ADAPTER_ADDRESS != address(0), "ADAPTER_ADDRESS must be set");
        require(UNDERLYING_ASSET != address(0), "UNDERLYING_ASSET must be set");

        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(ADAPTER_ADDRESS));

        console.log("\n================================================================");
        console.log("    OPTION VAULT WHITELIST CONFIGURATION (Step 2g)");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Adapter:", ADAPTER_ADDRESS);
        console.log("\nConfiguration:");
        console.log("  Underlying Asset:", UNDERLYING_ASSET);

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // Whitelist ERC20 Transfer Function
        // ============================================================
        console.log("\n[Step 1/1] Whitelisting ERC20 transfer function...");

        // Allow transfer of underlying asset to MPC wallet
        // Note: The whitelist is per (target, selector) - it allows the adapter
        // to call transfer() on the underlying asset token contract.
        // The actual recipient address validation happens at strategy execution level.
        adapter.updateWhitelist(
            UNDERLYING_ASSET,
            ERC20_TRANSFER,
            true,
            0 // No limit - amount controlled by allocation logic
        );
        console.log("  [OK] asset.transfer(address,uint256)");

        vm.stopBroadcast();

        // ============================================================
        // Verification
        // ============================================================
        console.log("\n================================================================");
        console.log("    OPTION VAULT WHITELIST CONFIGURATION COMPLETE!");
        console.log("================================================================");
        console.log("\nWhitelisted Functions Summary:");
        console.log("  Token Functions: 1 (asset.transfer)");
        console.log("  Total: 1 function whitelist configured");

        console.log("\n[SUCCESS] Adapter is ready for Option Vault strategy!");

        console.log("\nFunction Call Flow (Option Strategy Execution):");
        console.log("  1. asset.transfer(recipient, amount) -> Transfer to MPC wallet (EOA)");
        console.log("  2. MPC wallet executes option trades off-chain");
        console.log("  3. Returns are sent back to adapter when strategy unwinds");

        console.log("\nSECURITY NOTES:");
        console.log("  - Only the strategy agent or owner can execute transfers");
        console.log("  - Transfer recipient is specified in the strategy call data");
        console.log("  - Ensure only trusted agents are configured for the strategy");
        console.log("================================================================\n");
    }
}
