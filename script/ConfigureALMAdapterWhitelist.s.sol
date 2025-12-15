// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";

interface IUniversalAdapterEscrow {
    function updateWhitelist(
        address target,
        bytes4 selector,
        bool allowed,
        uint256 limit
    ) external;
}

/**
 * @title ConfigureALMAdapterWhitelist
 * @notice Configure function whitelists for ALM (Automated Liquidity Management) strategy
 * @dev This script whitelists all functions needed for the ALM WHYPE-stHYPE strategy
 *
 * CRITICAL: UniversalAdapterEscrow requires whitelisting ALL functions that will be called
 * via executeStrategy(). Without whitelist configuration, all strategy executions will
 * REVERT with FunctionNotWhitelisted() error.
 *
 * This script configures whitelists for the ALM WHYPE-stHYPE strategy which includes:
 * - Token approvals (WHYPE, stHYPE) for SwapRouter and PositionManager
 * - SwapRouter functions (exactInputSingle for WHYPE -> stHYPE swaps)
 * - PositionManager functions (mint for creating liquidity positions)
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *   - RPC_URL: Hyperliquid RPC endpoint
 *
 * Usage:
 *   source .env && forge script ConfigureALMAdapterWhitelist.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 6 (multiple updateWhitelist calls)
 */
contract ConfigureALMAdapterWhitelist is Script {
    // ============================================================
    // Configuration - ALM Strategy Addresses
    // ============================================================

    // Adapter address (ALM vault adapter)
    address constant ADAPTER_ADDRESS = 0x6320338670E98d9379469550845886D61271dFDe;

    // Token addresses
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant STHYPE = 0xfFaa4a3D97fE9107Cef8a3F48c069F577Ff76cC1;

    // Protocol addresses (from HYPERSWAP_V3.md)
    address constant SWAP_ROUTER = 0x4E2960a8cd19B467b82d26D83fAcb0fAE26b094D;
    address constant POSITION_MANAGER = 0x6eDA206207c09e5428F281761DdC0D300851fBC8;

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        IUniversalAdapterEscrow adapter = IUniversalAdapterEscrow(ADAPTER_ADDRESS);

        console.log("\n================================================================");
        console.log("    ALM ADAPTER WHITELIST CONFIGURATION");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Adapter:", ADAPTER_ADDRESS);
        console.log("\nToken Addresses:");
        console.log("  WHYPE:", WHYPE);
        console.log("  stHYPE:", STHYPE);
        console.log("\nProtocol Addresses:");
        console.log("  SwapRouter:", SWAP_ROUTER);
        console.log("  PositionManager:", POSITION_MANAGER);

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // STEP 1: Whitelist Token Approvals
        // ============================================================
        console.log("\n[Step 1/3] Whitelisting token approval functions...");

        // WHYPE token approve function
        adapter.updateWhitelist(
            WHYPE,
            bytes4(keccak256("approve(address,uint256)")),
            true,
            0 // No limit for approvals
        );
        console.log("  [OK] WHYPE.approve");

        // stHYPE token approve function
        adapter.updateWhitelist(
            STHYPE,
            bytes4(keccak256("approve(address,uint256)")),
            true,
            0 // No limit for approvals
        );
        console.log("  [OK] stHYPE.approve");

        // Optional: Whitelist balanceOf for safety checks
        adapter.updateWhitelist(
            WHYPE,
            bytes4(keccak256("balanceOf(address)")),
            true,
            0 // No limit for view functions
        );
        console.log("  [OK] WHYPE.balanceOf (for safety checks)");

        adapter.updateWhitelist(
            STHYPE,
            bytes4(keccak256("balanceOf(address)")),
            true,
            0 // No limit for view functions
        );
        console.log("  [OK] stHYPE.balanceOf (for safety checks)");

        // ============================================================
        // STEP 2: Whitelist SwapRouter Functions
        // ============================================================
        console.log("\n[Step 2/3] Whitelisting SwapRouter functions...");

        // exactInputSingle for swapping WHYPE -> stHYPE
        // Function signature: exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))
        adapter.updateWhitelist(
            SWAP_ROUTER,
            bytes4(keccak256("exactInputSingle((address,address,uint24,address,uint256,uint256,uint256,uint160))")),
            true,
            1_000e18 // 1000 token limit per swap operation
        );
        console.log("  [OK] SwapRouter.exactInputSingle (WHYPE -> stHYPE)");

        // ============================================================
        // STEP 3: Whitelist PositionManager Functions
        // ============================================================
        console.log("\n[Step 3/5] Whitelisting PositionManager functions...");

        // mint for creating new liquidity positions
        // Function signature: mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("mint((address,address,uint24,int24,int24,uint256,uint256,uint256,uint256,address,uint256))")),
            true,
            1_000e18 // 1000 token limit per mint operation
        );
        console.log("  [OK] PositionManager.mint (create liquidity position)");

        // ============================================================
        // STEP 4: Whitelist Rebalancing Functions (Collect Fees)
        // ============================================================
        console.log("\n[Step 4/5] Whitelisting rebalancing functions (collect fees)...");

        // collect for collecting fees and tokens
        // Function signature: collect((uint256,address,uint128,uint128))
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("collect((uint256,address,uint128,uint128))")),
            true,
            0 // No limit for collecting fees
        );
        console.log("  [OK] PositionManager.collect (collect fees and tokens)");

        // ============================================================
        // STEP 5: Whitelist Auto-Compound Functions
        // ============================================================
        console.log("\n[Step 5/6] Whitelisting auto-compound functions...");

        // increaseLiquidity for adding liquidity to existing position (auto-compound)
        // Function signature: increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("increaseLiquidity((uint256,uint256,uint256,uint256,uint256,uint256))")),
            true,
            0 // No limit for increasing liquidity
        );
        console.log("  [OK] PositionManager.increaseLiquidity (add fees back to position)");

        // ============================================================
        // STEP 6: Whitelist Position Closing Functions
        // ============================================================
        console.log("\n[Step 6/6] Whitelisting position closing functions...");

        // decreaseLiquidity for removing liquidity from position
        // Function signature: decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("decreaseLiquidity((uint256,uint128,uint256,uint256,uint256))")),
            true,
            0 // No limit for decreasing liquidity
        );
        console.log("  [OK] PositionManager.decreaseLiquidity (remove liquidity)");

        // burn for burning NFT position
        // Function signature: burn(uint256)
        adapter.updateWhitelist(
            POSITION_MANAGER,
            bytes4(keccak256("burn(uint256)")),
            true,
            0 // No limit for burning positions
        );
        console.log("  [OK] PositionManager.burn (burn NFT position)");

        vm.stopBroadcast();

        // ============================================================
        // Verification
        // ============================================================
        console.log("\n================================================================");
        console.log("    WHITELIST CONFIGURATION COMPLETE!");
        console.log("================================================================");
        console.log("\nWhitelisted Functions Summary:");
        console.log("  Token Approvals: 2 (WHYPE.approve, stHYPE.approve)");
        console.log("  Token Views: 2 (WHYPE.balanceOf, stHYPE.balanceOf)");
        console.log("  SwapRouter: 1 (exactInputSingle)");
        console.log("  PositionManager (Creation): 1 (mint)");
        console.log("  PositionManager (Rebalancing): 3 (collect, decreaseLiquidity, burn)");
        console.log("  PositionManager (Auto-Compound): 1 (increaseLiquidity)");
        console.log("  Total: 10 function whitelists configured");

        console.log("\n[SUCCESS] ALM Adapter is now ready for strategy execution, rebalancing, AND auto-compounding!");
        console.log("\nNext Steps:");
        console.log("  1. Test strategy execution via alm_worker.py");
        console.log("  2. Verify executeStrategy() calls work without FunctionNotWhitelisted errors");
        console.log("  3. Test rebalancing when positions go out of range");
        console.log("  4. Monitor ECS logs for successful execution");

        console.log("\nWHITELISTED OPERATIONS:");
        console.log("  Phase 1 (Approvals):");
        console.log("    - WHYPE.approve(SwapRouter, amount)");
        console.log("    - WHYPE.approve(PositionManager, amount)");
        console.log("    - stHYPE.approve(PositionManager, amount)");
        console.log("\n  Phase 2 (Swap + Mint):");
        console.log("    - SwapRouter.exactInputSingle(WHYPE -> stHYPE)");
        console.log("    - PositionManager.mint(create liquidity position)");
        console.log("\n  Phase 3 (Auto-Compound - Fee Reinvestment):");
        console.log("    - PositionManager.collect(collect accrued fees)");
        console.log("    - SwapRouter.exactInputSingle(swap to optimal ratio)");
        console.log("    - PositionManager.increaseLiquidity(add fees back to position)");
        console.log("\n  Phase 4 (Rebalancing - Out of Range):");
        console.log("    - PositionManager.collect(collect fees)");
        console.log("    - PositionManager.decreaseLiquidity(remove liquidity)");
        console.log("    - PositionManager.collect(collect remaining tokens)");
        console.log("    - PositionManager.burn(burn NFT)");

        console.log("\nIMPORTANT NOTES:");
        console.log("  - All strategy calls MUST go through whitelisted functions");
        console.log("  - Add more whitelists via adapter.updateWhitelist() as needed");
        console.log("  - Daily limits are deprecated but still configured for reference");
        console.log("================================================================\n");
    }
}
