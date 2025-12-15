// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";

/**
 * @title ConfigureAdapterWhitelist
 * @notice Configure function whitelists for UniversalAdapterEscrow (Step 2e)
 * @dev Run AFTER 2d_ConfigureAdapter.s.sol
 *
 * CRITICAL: UniversalAdapterEscrow requires whitelisting ALL functions that will be called
 * via executeStrategy(). Without whitelist configuration, all strategy executions will
 * REVERT with FunctionNotWhitelisted() error.
 *
 * This script configures whitelists for the PT-kHYPE loop strategy which includes:
 * - Token approvals (kHYPE, PT-kHYPE)
 * - Token view functions (balanceOf for safety checks)
 * - Pendle Router functions (swap kHYPE ↔ PT-kHYPE)
 * - Felix Morpho functions (supply, borrow, repay, withdraw)
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *
 * Usage:
 *   source .env && forge script script/2e_ConfigureAdapterWhitelist.so.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 10+ (multiple updateWhitelist calls)
 */
contract ConfigureAdapterWhitelist is Script {
    // Configuration parameters (must match deployment script)
    address constant ADAPTER_ADDRESS = 0x965b749bfA9a234ff01F996357d896f5Bfb243E0;

    // Token addresses
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant PT_KHYPE = 0x311dB0FDe558689550c68355783c95eFDfe25329;

    // Protocol addresses
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant FELIX_MORPHO = 0x68e37dE8d93d3496ae143F2E900490f6280C57cD;

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load deployed adapter address
        address adapterAddress = ADAPTER_ADDRESS;
        require(adapterAddress != address(0), "ADAPTER_ADDRESS must be set");

        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));

        console.log("\n================================================================");
        console.log("    ADAPTER WHITELIST CONFIGURATION (Step 2e)");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Adapter:", adapterAddress);
        console.log("\nToken Addresses:");
        console.log("  kHYPE:", KHYPE);
        console.log("  PT-kHYPE:", PT_KHYPE);
        console.log("\nProtocol Addresses:");
        console.log("  Pendle Router:", PENDLE_ROUTER);
        console.log("  Felix Morpho:", FELIX_MORPHO);

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // STEP 1: Whitelist Token Functions
        // ============================================================
        console.log("\n[Step 1/3] Whitelisting token functions...");

        // kHYPE token functions
        adapter.updateWhitelist(
            KHYPE,
            bytes4(keccak256("approve(address,uint256)")),
            true,
            0 // No limit for approvals
        );
        console.log("  [OK] kHYPE.approve");

        adapter.updateWhitelist(
            KHYPE,
            bytes4(keccak256("balanceOf(address)")),
            true,
            0 // No limit for view functions
        );
        console.log("  [OK] kHYPE.balanceOf (for safety checks)");

        adapter.updateWhitelist(
            KHYPE,
            bytes4(keccak256("transfer(address,uint256)")),
            true,
            0 // No limit for transfers
        );
        console.log("  [OK] kHYPE.transfer");

        // PT-kHYPE token functions
        adapter.updateWhitelist(
            PT_KHYPE,
            bytes4(keccak256("approve(address,uint256)")),
            true,
            0 // No limit for approvals
        );
        console.log("  [OK] PT-kHYPE.approve");

        adapter.updateWhitelist(
            PT_KHYPE,
            bytes4(keccak256("balanceOf(address)")),
            true,
            0 // No limit for view functions
        );
        console.log("  [OK] PT-kHYPE.balanceOf (for safety checks)");

        adapter.updateWhitelist(
            PT_KHYPE,
            bytes4(keccak256("transfer(address,uint256)")),
            true,
            0 // No limit for transfers
        );
        console.log("  [OK] PT-kHYPE.transfer");

        // ============================================================
        // STEP 2: Whitelist Pendle Router Functions
        // ============================================================
        console.log("\n[Step 2/3] Whitelisting Pendle Router functions...");

        // Swap kHYPE → PT-kHYPE
        adapter.updateWhitelist(
            PENDLE_ROUTER,
            bytes4(keccak256("swapExactTokenForPt(address,address,uint256,tuple,tuple,tuple)")),
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] Pendle.swapExactTokenForPt (kHYPE -> PT-kHYPE)");

        // Swap PT-kHYPE → kHYPE
        adapter.updateWhitelist(
            PENDLE_ROUTER,
            bytes4(keccak256("swapExactPtForToken(address,address,uint256,tuple,tuple)")),
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] Pendle.swapExactPtForToken (PT-kHYPE -> kHYPE)");

        // ============================================================
        // STEP 3: Whitelist Felix Morpho Functions (for loop strategy)
        // ============================================================
        console.log("\n[Step 3/3] Whitelisting Felix Morpho functions...");

        // Supply PT-kHYPE as collateral
        adapter.updateWhitelist(
            FELIX_MORPHO,
            bytes4(keccak256("supply(tuple,uint256,uint256,address,bytes)")),
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] Felix.supply (deposit PT-kHYPE collateral)");

        // Borrow kHYPE against collateral
        adapter.updateWhitelist(
            FELIX_MORPHO,
            bytes4(keccak256("borrow(tuple,uint256,uint256,address,address)")),
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] Felix.borrow (borrow kHYPE)");

        // Repay borrowed kHYPE
        adapter.updateWhitelist(
            FELIX_MORPHO,
            bytes4(keccak256("repay(tuple,uint256,uint256,address,bytes)")),
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] Felix.repay (repay kHYPE debt)");

        // Withdraw PT-kHYPE collateral
        adapter.updateWhitelist(
            FELIX_MORPHO,
            bytes4(keccak256("withdraw(tuple,uint256,uint256,address,address)")),
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] Felix.withdraw (withdraw PT-kHYPE collateral)");

        vm.stopBroadcast();

        // ============================================================
        // Verification
        // ============================================================
        console.log("\n================================================================");
        console.log("    WHITELIST CONFIGURATION COMPLETE!");
        console.log("================================================================");
        console.log("\nWhitelisted Functions Summary:");
        console.log("  Token Functions: 6 (approve, balanceOf, transfer for both tokens)");
        console.log("  Pendle Functions: 2 (swapExactTokenForPt, swapExactPtForToken)");
        console.log("  Felix Functions: 4 (supply, borrow, repay, withdraw)");
        console.log("  Total: 12 function whitelists configured");

        console.log("\n[SUCCESS] Adapter is now ready for PT-kHYPE loop strategy execution!");
        console.log("\nNext Steps:");
        console.log("  1. Run PTKHYPELoopEndToEnd.s.sol to test strategy execution");
        console.log("  2. Verify executeStrategy() calls work without FunctionNotWhitelisted errors");
        console.log("  3. Configure keeper for automated strategy management");

        console.log("\nIMPORTANT NOTES:");
        console.log("  - All strategy calls MUST go through whitelisted functions");
        console.log("  - Add more whitelists via adapter.updateWhitelist() as needed");
        console.log("  - Daily limits are deprecated but still configured for reference");
        console.log("================================================================\n");
    }
}
