// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";

/**
 * @title ConfigureAdapterWhitelistALM
 * @notice Configure function whitelists for UniversalAdapterEscrow - ALM Strategy (Step 2f)
 * @dev Run AFTER 2d_ConfigureAdapter.s.sol
 *
 * CRITICAL: UniversalAdapterEscrow requires whitelisting ALL functions that will be called
 * via executeStrategy(). Without whitelist configuration, all strategy executions will
 * REVERT with FunctionNotWhitelisted() error.
 *
 * This script configures whitelists for the ALM (Automated Liquidity Management) strategy:
 * - Token approvals (wHYPE, kHYPE)
 * - Token utility functions (balanceOf, transfer for safety checks)
 * - Hyperswap Router functions (Uniswap V3 fork - swap operations)
 * - Position Manager functions (mint, increase/decrease liquidity, collect fees, burn)
 *
 * Strategy Flow:
 *   1. User deposits wHYPE to vault
 *   2. Vault allocates to UniversalAdapterEscrow
 *   3. Strategy executes via whitelisted functions:
 *      a) Swap 50% wHYPE -> kHYPE (via Hyperswap Router)
 *      b) Add liquidity to wHYPE/kHYPE pool (via Position Manager)
 *      c) Mint LP position NFT
 *      d) Collect trading fees over time
 *      e) Remove liquidity and burn NFT on exit
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *
 * Usage:
 *   source .env && forge script script/2f_ConfigureAdapterWhitelist.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 15+ (multiple updateWhitelist calls)
 */
contract ConfigureAdapterWhitelistALM is Script {
    // ============================================================================
    // Configuration Parameters
    // ============================================================================

    // Adapter address (must match deployment)
    address constant ADAPTER_ADDRESS = 0x965b749bfA9a234ff01F996357d896f5Bfb243E0;

    // Token addresses
    address constant WHYPE = 0x0000000000000000000000000000000000000000; // TODO: Update with actual wHYPE address
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;

    // Hyperswap (Uniswap V3 fork) protocol addresses
    address constant HYPERSWAP_ROUTER = 0x0000000000000000000000000000000000000000; // TODO: Update with actual router
    address constant POSITION_MANAGER = 0x0000000000000000000000000000000000000000; // TODO: Update with actual position manager

    // Operation limits (per-call limits for safety)
    uint256 constant TOKEN_APPROVAL_LIMIT = 0; // Unlimited for approvals
    uint256 constant VIEW_FUNCTION_LIMIT = 0; // Unlimited for view functions
    uint256 constant SWAP_LIMIT = 100_000e18; // 100k tokens per swap operation
    uint256 constant LIQUIDITY_LIMIT = 100_000e18; // 100k tokens per liquidity operation

    // ============================================================================
    // Main Execution
    // ============================================================================

    function run() public {
        // Load deployer private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load adapter
        require(ADAPTER_ADDRESS != address(0), "ADAPTER_ADDRESS must be set");
        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(ADAPTER_ADDRESS));

        // Validate configuration
        require(WHYPE != address(0), "wHYPE address must be configured");
        require(HYPERSWAP_ROUTER != address(0), "Hyperswap Router address must be configured");
        require(POSITION_MANAGER != address(0), "Position Manager address must be configured");

        console.log("\n========================================================================");
        console.log("    ALM STRATEGY - ADAPTER WHITELIST CONFIGURATION (Step 2f)");
        console.log("========================================================================");
        console.log("\nDeployer:", deployer);
        console.log("Adapter:", ADAPTER_ADDRESS);
        console.log("\nToken Addresses:");
        console.log("  wHYPE:", WHYPE);
        console.log("  kHYPE:", KHYPE);
        console.log("\nHyperswap Protocol Addresses:");
        console.log("  Router:", HYPERSWAP_ROUTER);
        console.log("  Position Manager:", POSITION_MANAGER);
        console.log("\nOperation Limits:");
        console.log("  Swap Limit:", SWAP_LIMIT);
        console.log("  Liquidity Limit:", LIQUIDITY_LIMIT);

        vm.startBroadcast(deployerPrivateKey);

        // Execute whitelist configuration
        whitelistTokenFunctions(adapter);
        whitelistSwapFunctions(adapter);
        whitelistLiquidityFunctions(adapter);

        vm.stopBroadcast();

        // Print summary
        printSummary();
    }

    // ============================================================================
    // Whitelist Configuration Functions
    // ============================================================================

    /**
     * @notice Whitelist token functions for wHYPE and kHYPE
     * @dev Includes approve, balanceOf, transfer for both tokens
     */
    function whitelistTokenFunctions(UniversalAdapterEscrow adapter) internal {
        console.log("\n[Step 1/3] Whitelisting token functions...");

        // ========== wHYPE Token Functions ==========

        // approve(address,uint256) - Required for approving Hyperswap Router and Position Manager
        adapter.updateWhitelist(
            WHYPE,
            bytes4(keccak256("approve(address,uint256)")),
            true,
            TOKEN_APPROVAL_LIMIT
        );
        console.log("  [OK] wHYPE.approve");

        // balanceOf(address) - View function for balance checks (safety)
        adapter.updateWhitelist(
            WHYPE,
            bytes4(keccak256("balanceOf(address)")),
            true,
            VIEW_FUNCTION_LIMIT
        );
        console.log("  [OK] wHYPE.balanceOf");

        // transfer(address,uint256) - For internal token movements if needed
        adapter.updateWhitelist(
            WHYPE,
            bytes4(keccak256("transfer(address,uint256)")),
            true,
            SWAP_LIMIT
        );
        console.log("  [OK] wHYPE.transfer");

        // ========== kHYPE Token Functions ==========

        // approve(address,uint256) - Required for approving Position Manager
        adapter.updateWhitelist(
            KHYPE,
            bytes4(keccak256("approve(address,uint256)")),
            true,
            TOKEN_APPROVAL_LIMIT
        );
        console.log("  [OK] kHYPE.approve");

        // balanceOf(address) - View function for balance checks (safety)
        adapter.updateWhitelist(
            KHYPE,
            bytes4(keccak256("balanceOf(address)")),
            true,
            VIEW_FUNCTION_LIMIT
        );
        console.log("  [OK] kHYPE.balanceOf");

        // transfer(address,uint256) - For internal token movements if needed
        adapter.updateWhitelist(
            KHYPE,
            bytes4(keccak256("transfer(address,uint256)")),
            true,
            SWAP_LIMIT
        );
        console.log("  [OK] kHYPE.transfer");

        console.log("  Token functions configured: 6");
    }

    /**
     * @notice Whitelist Hyperswap Router swap functions
     * @dev Includes exactInputSingle, exactOutputSingle, exactInput, exactOutput
     */
    function whitelistSwapFunctions(UniversalAdapterEscrow adapter) internal {
        console.log("\n[Step 2/3] Whitelisting Hyperswap Router swap functions...");

        // ========== Single-Hop Swap Functions ==========

        // exactInputSingle - Swap exact input amount (wHYPE -> kHYPE)
        // Function signature: exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))
        adapter.updateWhitelist(
            HYPERSWAP_ROUTER,
            bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))")),
            true,
            SWAP_LIMIT
        );
        console.log("  [OK] Router.exactInputSingle (swap exact input)");

        // exactOutputSingle - Swap for exact output amount (wHYPE -> kHYPE)
        // Function signature: exactOutputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))
        adapter.updateWhitelist(
            HYPERSWAP_ROUTER,
            bytes4(keccak256("exactOutputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))")),
            true,
            SWAP_LIMIT
        );
        console.log("  [OK] Router.exactOutputSingle (swap exact output)");

        // ========== Multi-Hop Swap Functions (Optional but useful) ==========

        // exactInput - Multi-hop swap with exact input
        // Function signature: exactInput((bytes,address,uint256,uint256,uint256))
        adapter.updateWhitelist(
            HYPERSWAP_ROUTER,
            bytes4(keccak256("exactInput((bytes,address,uint256,uint256,uint256))")),
            true,
            SWAP_LIMIT
        );
        console.log("  [OK] Router.exactInput (multi-hop exact input)");

        // exactOutput - Multi-hop swap with exact output
        // Function signature: exactOutput((bytes,address,uint256,uint256,uint256))
        adapter.updateWhitelist(
            HYPERSWAP_ROUTER,
            bytes4(keccak256("exactOutput((bytes,address,uint256,uint256,uint256))")),
            true,
            SWAP_LIMIT
        );
        console.log("  [OK] Router.exactOutput (multi-hop exact output)");

        console.log("  Swap functions configured: 4");
    }

    /**
     * @notice Whitelist Position Manager liquidity functions
     * @dev Includes mint, increaseLiquidity, decreaseLiquidity, collect, burn, positions
     */
    function whitelistLiquidityFunctions(UniversalAdapterEscrow adapter) internal {
        console.log("\n[Step 3/3] Whitelisting Position Manager liquidity functions...");

        // ========== LP Position Management Functions ==========

        // mint - Create new LP position
        // Function signature: mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))")),
            true,
            LIQUIDITY_LIMIT
        );
        console.log("  [OK] PositionManager.mint (create LP position)");

        // increaseLiquidity - Add liquidity to existing position
        // Function signature: increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))")),
            true,
            LIQUIDITY_LIMIT
        );
        console.log("  [OK] PositionManager.increaseLiquidity (add liquidity)");

        // decreaseLiquidity - Remove liquidity from position
        // Function signature: decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))")),
            true,
            LIQUIDITY_LIMIT
        );
        console.log("  [OK] PositionManager.decreaseLiquidity (remove liquidity)");

        // collect - Collect fees and removed liquidity
        // Function signature: collect((uint256,address,uint128,uint128))
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("collect((uint256,address,uint128,uint128))")),
            true,
            VIEW_FUNCTION_LIMIT // Collecting doesn't need limits
        );
        console.log("  [OK] PositionManager.collect (collect fees)");

        // burn - Burn NFT after removing all liquidity
        // Function signature: burn(uint256)
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("burn(uint256)")),
            true,
            VIEW_FUNCTION_LIMIT // Burning doesn't need limits
        );
        console.log("  [OK] PositionManager.burn (burn NFT)");

        // ========== View Functions (Optional but useful for safety) ==========

        // positions - Read position state
        // Function signature: positions(uint256)
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("positions(uint256)")),
            true,
            VIEW_FUNCTION_LIMIT
        );
        console.log("  [OK] PositionManager.positions (read position state)");

        console.log("  Liquidity functions configured: 6");
    }

    // ============================================================================
    // Summary & Verification
    // ============================================================================

    function printSummary() internal view {
        console.log("\n========================================================================");
        console.log("    ALM STRATEGY - WHITELIST CONFIGURATION COMPLETE!");
        console.log("========================================================================");
        console.log("\nWhitelisted Functions Summary:");
        console.log("+------------------------------------------------------------------+");
        console.log("| Category               | Functions                    | Count   |");
        console.log("+------------------------------------------------------------------+");
        console.log("| Token Functions        | approve, balanceOf, transfer |   6     |");
        console.log("| Swap Functions         | exact[Input|Output][Single]  |   4     |");
        console.log("| Liquidity Functions    | mint, increase, decrease...  |   6     |");
        console.log("+------------------------------------------------------------------+");
        console.log("| TOTAL                                                  |  16     |");
        console.log("+------------------------------------------------------------------+");

        console.log("\n[SUCCESS] Adapter is now ready for ALM strategy execution!");

        console.log("\nStrategy Operations Flow:");
        console.log("  1. Deposit wHYPE -> Vault");
        console.log("  2. Allocate wHYPE -> UniversalAdapterEscrow");
        console.log("  3. Execute ALM Strategy:");
        console.log("     a) Approve wHYPE to Router");
        console.log("     b) Swap 50% wHYPE -> kHYPE (exactInputSingle)");
        console.log("     c) Approve wHYPE + kHYPE to Position Manager");
        console.log("     d) Add liquidity to pool (mint)");
        console.log("     e) Collect trading fees over time (collect)");
        console.log("     f) Remove liquidity on exit (decreaseLiquidity + collect + burn)");

        console.log("\nNext Steps:");
        console.log("  1. Run ALMHyperswapEndToEnd.s.sol to test full strategy");
        console.log("  2. Verify all executeStrategy() calls succeed");
        console.log("  3. Monitor LP position performance and fee collection");
        console.log("  4. Configure keeper for automated rebalancing (optional)");

        console.log("\nIMPORTANT NOTES:");
        console.log("  [!] Update WHYPE, HYPERSWAP_ROUTER, and POSITION_MANAGER addresses");
        console.log("  [!] All strategy calls MUST use whitelisted functions only");
        console.log("  [!] Per-call limits provide additional safety (SWAP_LIMIT, LIQUIDITY_LIMIT)");
        console.log("  [!] Add more whitelists via adapter.updateWhitelist() as needed");
        console.log("  [+] View functions (balanceOf, positions) have no limits for safety");
        console.log("  [+] Token approvals have no limits for flexibility");

        console.log("\nSecurity Considerations:");
        console.log("  - Function whitelist prevents unauthorized protocol interactions");
        console.log("  - Per-call limits protect against excessive operations");
        console.log("  - Only owner can modify whitelists via updateWhitelist()");
        console.log("  - Strategy agent can only call whitelisted functions");

        console.log("========================================================================\n");
    }
}
