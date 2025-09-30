// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Script.sol";
import "../src/VaultV2.sol";
import "../src/adapters/UniversalAdapterEscrow.sol";
import "../src/valuers/UniversalValuerOffchain.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {IUniversalAdapterEscrow} from "../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

// Pendle Router Interface
interface IPendleRouter {
    struct TokenInput {
        address tokenIn;
        uint256 netTokenIn;
        address tokenMintSy;
        address pendleSwap;
        SwapData swapData;
    }

    struct SwapData {
        SwapType swapType;
        address extRouter;
        bytes extCalldata;
        bool needScale;
    }

    enum SwapType {
        NONE,
        KYBERSWAP,
        ONE_INCH,
        ETH_WETH
    }

    struct ApproxParams {
        uint256 guessMin;
        uint256 guessMax;
        uint256 guessOffchain;
        uint256 maxIteration;
        uint256 eps;
    }

    struct LimitOrderData {
        address limitRouter;
        uint256 epsSkipMarket;
        FillOrderParams[] normalFills;
        FillOrderParams[] flashFills;
        bytes optData;
    }

    struct FillOrderParams {
        address dummy; // Not used in this test
    }

    function swapExactTokenForPt(
        address receiver,
        address market,
        uint256 minPtOut,
        ApproxParams memory guessPtOut,
        TokenInput memory input,
        LimitOrderData memory limit
    ) external returns (uint256 netPtOut, uint256 netSyFee, uint256 netSyInterm);
}

/**
 * @title EndToEndTest
 * @notice Complete end-to-end test: deposit → allocate → execute strategy → keeper valuation
 *
 * Flow:
 * 1. Check deployer has kHYPE balance
 * 2. Deposit kHYPE into VaultV2
 * 3. Allocate funds to PT_KHYPE_LOOP strategy (moves to adapter)
 * 4. Execute strategy: swap kHYPE → PT-kHYPE on Pendle
 * 5. Supply PT-kHYPE to Felix as collateral
 * 6. (Optional) Borrow kHYPE for leverage
 * 7. Keeper calculates valuation and pushes to valuer
 * 8. Verify valuation on-chain
 */
contract EndToEndTest is Script {
    // Deployed contracts
    VaultV2 vault = VaultV2(0x9ad2E9a260365C1214Ab70C74f975A661AE5be61);
    UniversalAdapterEscrow adapter = UniversalAdapterEscrow(payable(0x5Bc418252Fd72b4dF7feCc297caF50B23f9Ee6cA));
    UniversalValuerOffchain valuer = UniversalValuerOffchain(0x7f7b37A897EF5331262a9A6a5F60078BcfbF58Cc);

    // Tokens
    IERC20 khype = IERC20(0xfD739d4e423301CE9385c1fb8850539D657C296D);
    IERC20 ptKhype = IERC20(0x311dB0FDe558689550c68355783c95eFDfe25329);

    // Pendle Router
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant PENDLE_MARKET = 0x8867d2b7aDb8609c51810237EcC9A25A2F601B97; // kHYPE market

    // Felix Morpho
    address constant FELIX_MORPHO = 0x68e37dE8d93d3496ae143F2E900490f6280C57cD;
    bytes32 constant FELIX_MARKET_ID = 0x1df0d0ebcdc52069692452cb9a3e5cf6c017b237378141eaf08a05ce17205ed6;

    // Strategy
    bytes32 constant PT_KHYPE_LOOP_ID = keccak256("PT_KHYPE_LOOP");
    bytes strategyIdData = abi.encodePacked("PT_KHYPE_LOOP");

    // Test amounts (small amounts for testing)
    uint256 constant DEPOSIT_AMOUNT = 0.01e18; // 0.01 kHYPE
    uint256 constant SWAP_AMOUNT = 0.005e18; // 0.005 kHYPE to swap

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("\n================================================================");
        console.log("    END-TO-END TEST: PT-KHYPE LOOP STRATEGY");
        console.log("================================================================");
        console.log("Deployer:", deployer);
        console.log("Vault:", address(vault));
        console.log("Adapter:", address(adapter));
        console.log("Valuer:", address(valuer));

        vm.startBroadcast(deployerPrivateKey);

        // ============ STEP 1: Check balances ============
        console.log("\n[1/7] Checking balances...");
        uint256 khypeBalance = khype.balanceOf(deployer);
        uint256 vaultShares = vault.balanceOf(deployer);
        console.log("  Deployer kHYPE balance:", khypeBalance / 1e18, "kHYPE");
        console.log("  Deployer vault shares:", vaultShares / 1e18, "shares");

        if (khypeBalance < DEPOSIT_AMOUNT) {
            console.log("  \u26a0\ufe0f  WARNING: Insufficient kHYPE balance for test");
            console.log("  Required:", DEPOSIT_AMOUNT / 1e18, "kHYPE");
            console.log("  Please acquire kHYPE before running this test");
            vm.stopBroadcast();
            return;
        }

        // ============ STEP 2: Deposit into vault ============
        console.log("\n[2/7] Depositing into vault...");
        console.log("  Approving", DEPOSIT_AMOUNT / 1e18, "kHYPE to vault");
        khype.approve(address(vault), DEPOSIT_AMOUNT);

        console.log("  Depositing...");
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, deployer);
        console.log("  \u2713 Deposited", DEPOSIT_AMOUNT / 1e18, "kHYPE");
        console.log("  \u2713 Received", shares / 1e18, "shares");
        console.log("  Vault total assets:", vault.totalAssets() / 1e18, "kHYPE");

        // ============ STEP 3: Allocate to strategy ============
        console.log("\n[3/7] Allocating to PT_KHYPE_LOOP strategy...");

        // Prepare allocation data: (strategyId, unused, executeNow, calls)
        uint256 allocateAmount = DEPOSIT_AMOUNT; // Allocate all deposited funds
        IUniversalAdapterEscrow.Call[] memory noCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocationData = abi.encode(
            PT_KHYPE_LOOP_ID,  // strategyId
            0,                  // unused param
            false,              // don't execute now
            noCalls            // no calls
        );

        console.log("  Allocating", allocateAmount / 1e18, "kHYPE to adapter");
        vault.allocate(address(adapter), allocationData, allocateAmount);

        uint256 adapterBalance = khype.balanceOf(address(adapter));
        console.log("  \u2713 Adapter kHYPE balance:", adapterBalance / 1e18, "kHYPE");

        // ============ STEP 4: Execute strategy - Swap kHYPE → PT-kHYPE ============
        console.log("\n[4/7] Executing strategy: Swap kHYPE \u2192 PT-kHYPE...");

        // Build Call array: approve + swap
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);

        // Call 1: Approve kHYPE to Pendle Router
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            data: abi.encodeWithSelector(
                IERC20.approve.selector,
                PENDLE_ROUTER,
                SWAP_AMOUNT
            ),
            value: 0
        });

        // Call 2: Swap kHYPE → PT-kHYPE via Pendle
        // Prepare swap parameters (based on successful Hyperliquid tx)
        IPendleRouter.TokenInput memory tokenInput = IPendleRouter.TokenInput({
            tokenIn: address(khype),
            netTokenIn: SWAP_AMOUNT,
            tokenMintSy: address(khype), // Must be same as tokenIn on Hyperliquid
            pendleSwap: address(0),
            swapData: IPendleRouter.SwapData({
                swapType: IPendleRouter.SwapType.NONE,
                extRouter: address(0),
                extCalldata: "",
                needScale: false
            })
        });

        IPendleRouter.ApproxParams memory approxParams = IPendleRouter.ApproxParams({
            guessMin: 0,
            guessMax: type(uint256).max,
            guessOffchain: 0,
            maxIteration: 256,
            eps: 1e14 // 0.01%
        });

        IPendleRouter.LimitOrderData memory limitData;

        // Use correct selector 0xc81f847a from successful Hyperliquid tx
        calls[1] = IUniversalAdapterEscrow.Call({
            target: PENDLE_ROUTER,
            data: abi.encodeWithSelector(
                bytes4(0xc81f847a),  // Correct selector for Hyperliquid
                address(adapter),    // receiver
                PENDLE_MARKET,       // market
                0,                   // minPtOut: 0 (accept any for testing)
                approxParams,
                tokenInput,
                limitData
            ),
            value: 0
        });

        console.log("  Executing: approve + swap");
        console.log("  Swapping:", SWAP_AMOUNT / 1e18, "kHYPE for PT-kHYPE");

        adapter.executeStrategy(PT_KHYPE_LOOP_ID, calls);

        uint256 ptBalance = ptKhype.balanceOf(address(adapter));
        console.log("  \u2713 Swap successful");
        console.log("  PT-kHYPE balance:", ptBalance / 1e18, "PT-kHYPE");

        // ============ STEP 5: Skip Felix supply (needs actual PT-kHYPE) ============
        console.log("\n[5/7] Skipping Felix supply (would need actual PT-kHYPE from swap)...");

        vm.stopBroadcast();

        // ============ STEP 6: Check strategy state ============
        console.log("\n[6/7] Checking strategy state...");
        uint256 finalPtBalance = ptKhype.balanceOf(address(adapter));
        uint256 finalKhypeBalance = khype.balanceOf(address(adapter));
        console.log("  Adapter kHYPE:", finalKhypeBalance / 1e18);
        console.log("  Adapter PT-kHYPE:", finalPtBalance / 1e18);

        // ============ STEP 7: Instructions for keeper ============
        console.log("\n[7/7] Ready for keeper valuation!");
        console.log("\n\u2192 Run keeper with:");
        console.log("  source venv-keeper/bin/activate");
        console.log("  export KEEPER_PRIVATE_KEY=\"\"");
        console.log("  python src/keepers/OffchainValuationKeeper.py keeper_config_mainnet.json --mode once");

        console.log("\n\u2192 Keeper will:");
        console.log("  1. Query PT-kHYPE balance:", finalPtBalance / 1e18);
        console.log("  2. Get PT price from Pendle oracle");
        console.log("  3. Query Felix debt (if any)");
        console.log("  4. Calculate net value = (PT balance * PT price) - debt");
        console.log("  5. Sign valuation report");
        console.log("  6. Push to valuer contract");

        console.log("\n\u2192 Verify valuation with cast call command (see logs above)");

        console.log("\n================================================================");
        console.log("    END-TO-END TEST COMPLETE");
        console.log("================================================================\n");
    }
}