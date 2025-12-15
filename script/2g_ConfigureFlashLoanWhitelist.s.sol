// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";

/**
 * @title ConfigureFlashLoanWhitelist
 * @notice Configure function whitelists for HyperLendFlashLoanExecutor (Looper) strategy
 * @dev Run AFTER 2d_ConfigureAdapter.s.sol
 *
 * CRITICAL: UniversalAdapterEscrow requires whitelisting ALL functions that will be called
 * via executeStrategy(). Without whitelist configuration, all strategy executions will
 * REVERT with FunctionNotWhitelisted() error.
 *
 * This script configures whitelists for the PT-kHYPE loop strategy using HyperLend flashloans:
 * - HyperLendFlashLoanExecutor (Looper) functions
 * - Token transfer functions (kHYPE, wHYPE)
 *
 * Required Environment Variables:
 *   - PRIVATE_KEY: Deployer/owner private key
 *
 * Usage:
 *   source .env && forge script script/2g_ConfigureFlashLoanWhitelist.s.sol --rpc-url $RPC_URL --broadcast -v
 *
 * Transactions: 9 (multiple updateWhitelist calls)
 */
contract ConfigureFlashLoanWhitelist is Script {
    // Configuration parameters (UPDATE BEFORE DEPLOYMENT)
    address constant ADAPTER_ADDRESS = 0x7F73B9AA1f5a6cE9bBfc8F0c12889b3Cb75174e8;

    // HyperLendFlashLoanExecutor (Looper) Contract
    address constant LOOPER = 0xDA4541b388981f08b0f11E5A2Cf92Aa83532789f;

    // Token addresses
    address constant KHYPE = 0xfD739d4e423301CE9385c1fb8850539D657C296D;
    address constant WHYPE = 0x5555555555555555555555555555555555555555;
    address constant PT_KHYPE = 0xea84ca9849D9e76a78B91F221F84e9Ca065FC9f5;

    // HyperLend Pool (for view functions)
    address constant HYPERLEND_POOL = 0x00A89d7a5A02160f20150EbEA7a2b5E4879A1A8b;

    // Function selectors (from VAULT_WHITELIST.md)
    bytes4 constant SET_EMODE = 0xb94e11c6;           // setEMode(uint8)
    bytes4 constant LOOP_PT_KHYPE = 0x0f5c75a3;       // loopPtKhype(uint256,uint256,uint256)
    bytes4 constant SWAP = 0xb69cbf9f;                // swap(address,address,uint256,uint256,address,bytes)
    bytes4 constant UNWIND_POSITION = 0x27815217;    // unwindPosition(address,uint256,address,uint256)
    bytes4 constant REPAY = 0x22867d78;              // repay(address,uint256)
    bytes4 constant WITHDRAW = 0xf3fef3a3;           // withdraw(address,uint256)
    bytes4 constant RESCUE_ERC20 = 0x8cd4426d;       // rescueERC20(address,uint256)
    bytes4 constant ERC20_TRANSFER = 0xa9059cbb;     // transfer(address,uint256)

    function run() public {
        // Load private key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Load deployed adapter address
        address adapterAddress = ADAPTER_ADDRESS;
        require(adapterAddress != address(0), "ADAPTER_ADDRESS must be set");

        UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(adapterAddress));

        console.log("\n================================================================");
        console.log("    FLASHLOAN WHITELIST CONFIGURATION (Step 2g)");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Adapter:", adapterAddress);
        console.log("\nLooper Contract:");
        console.log("  HyperLendFlashLoanExecutor:", LOOPER);
        console.log("\nToken Addresses:");
        console.log("  kHYPE:", KHYPE);
        console.log("  wHYPE:", WHYPE);
        console.log("  PT-kHYPE:", PT_KHYPE);
        console.log("\nHyperLend Pool:", HYPERLEND_POOL);

        vm.startBroadcast(deployerPrivateKey);

        // ============================================================
        // STEP 1: Whitelist Looper Core Functions
        // ============================================================
        console.log("\n[Step 1/3] Whitelisting Looper core functions...");

        // setEMode - Enable E-Mode 4 for 80% LTV
        adapter.updateWhitelist(
            LOOPER,
            SET_EMODE,
            true,
            0 // No limit for mode setting
        );
        console.log("  [OK] looper.setEMode(uint8)");

        // loopPtKhype - Execute PT-kHYPE loop iteration
        adapter.updateWhitelist(
            LOOPER,
            LOOP_PT_KHYPE,
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] looper.loopPtKhype(uint256,uint256,uint256)");

        // swap - Swap tokens via LiquidSwap
        adapter.updateWhitelist(
            LOOPER,
            SWAP,
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] looper.swap(address,address,uint256,uint256,address,bytes)");

        // ============================================================
        // STEP 2: Whitelist Looper Unwind Functions
        // ============================================================
        console.log("\n[Step 2/3] Whitelisting Looper unwind functions...");

        // unwindPosition - Close position
        adapter.updateWhitelist(
            LOOPER,
            UNWIND_POSITION,
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] looper.unwindPosition(address,uint256,address,uint256)");

        // repay - Repay borrowed wHYPE
        adapter.updateWhitelist(
            LOOPER,
            REPAY,
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] looper.repay(address,uint256)");

        // withdraw - Withdraw PT-kHYPE collateral
        adapter.updateWhitelist(
            LOOPER,
            WITHDRAW,
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] looper.withdraw(address,uint256)");

        // rescueERC20 - Rescue tokens to owner
        adapter.updateWhitelist(
            LOOPER,
            RESCUE_ERC20,
            true,
            10_000e18 // 10k token limit per operation
        );
        console.log("  [OK] looper.rescueERC20(address,uint256)");

        // ============================================================
        // STEP 3: Whitelist Token Transfer Functions
        // ============================================================
        console.log("\n[Step 3/3] Whitelisting token transfer functions...");

        // kHYPE transfer - Transfer kHYPE to looper
        adapter.updateWhitelist(
            KHYPE,
            ERC20_TRANSFER,
            true,
            0 // No limit for transfers
        );
        console.log("  [OK] kHYPE.transfer(address,uint256)");

        // wHYPE transfer - Transfer wHYPE to looper (if needed for unwind)
        adapter.updateWhitelist(
            WHYPE,
            ERC20_TRANSFER,
            true,
            0 // No limit for transfers
        );
        console.log("  [OK] wHYPE.transfer(address,uint256)");

        vm.stopBroadcast();

        // ============================================================
        // Verification
        // ============================================================
        console.log("\n================================================================");
        console.log("    FLASHLOAN WHITELIST CONFIGURATION COMPLETE!");
        console.log("================================================================");
        console.log("\nWhitelisted Functions Summary:");
        console.log("  Looper Core Functions: 3 (setEMode, loopPtKhype, swap)");
        console.log("  Looper Unwind Functions: 4 (unwindPosition, repay, withdraw, rescueERC20)");
        console.log("  Token Functions: 2 (kHYPE.transfer, wHYPE.transfer)");
        console.log("  Total: 9 function whitelists configured");

        console.log("\n[SUCCESS] Adapter is now ready for HyperLend flashloan loop strategy!");

        console.log("\nFunction Call Flow (Loop Execution):");
        console.log("  1. kHYPE.transfer(looper, amount)    -> Send kHYPE to looper");
        console.log("  2. looper.setEMode(4)                -> Enable E-Mode 4");
        console.log("  3. looper.loopPtKhype(...)           -> Execute loop iteration");
        console.log("  4. looper.swap(wHYPE, kHYPE, ...)    -> Swap borrowed wHYPE to kHYPE");
        console.log("  5. Repeat steps 3-4 as needed");

        console.log("\nFunction Call Flow (Unwind Execution):");
        console.log("  1. looper.swap(kHYPE, wHYPE, ...)    -> Swap kHYPE to wHYPE");
        console.log("  2. wHYPE.transfer(looper, amount)    -> Send more wHYPE if needed");
        console.log("  3. looper.unwindPosition(...)        -> Close position");
        console.log("     OR looper.repay(...) + looper.withdraw(...)");
        console.log("  4. looper.rescueERC20(...)           -> Retrieve tokens");

        console.log("\nIMPORTANT NOTES:");
        console.log("  - The looper contract has onlyOwner modifier on all functions");
        console.log("  - Ensure the adapter is the owner of the looper contract");
        console.log("  - LiquidSwap router: 0x744489ee3d540777a66f2cf297479745e0852f7a");
        console.log("================================================================\n");
    }
}
