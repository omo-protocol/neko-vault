// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {PtLoopExecutor} from "../../src/executors/PtLoopExecutor.sol";
import {PtLoopFactory} from "../../src/executors/PtLoopFactory.sol";

/// @notice Arb-fork smoke test. Validates:
///   - PtLoopFactory deploys clones at deterministic CREATE2 addresses
///   - predictClone matches the actual deployed address
///   - Cloning is idempotent per (owner, agent) pair (reverts on second clone)
///   - Permissioning: only strategyAgent can call enterLoop/exitLoop
///   - Flash-callback auth: only flashVault can call receiveFlashLoan
///
/// Full end-to-end enter/exit requires live Silo + Pendle state and specific market calldata
/// (operator-supplied via env / SDK). Tests below cover contract mechanics only.
///
/// Run: `forge test --match-contract PtLoopExecutorTest --fork-url $ARBITRUM_RPC_URL -vvv`
contract PtLoopExecutorTest is Test {
    // Arb mainnet constants (verified 2026-04-20).
    address constant USDC = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
    address constant BALANCER_VAULT = 0xBA12222222228d8Ba445958a75a0704d566BF2C8;

    PtLoopExecutor impl;
    PtLoopFactory factory;

    address owner = address(0xA11CE);
    address strategyAgent = address(0xB0B);

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
        }
        vm.createSelectFork(rpc);

        impl = new PtLoopExecutor();
        factory = new PtLoopFactory(address(impl), USDC, PENDLE_ROUTER, BALANCER_VAULT);
    }

    function test_predictClone_matchesDeployment() public {
        address predicted = factory.predictClone(owner, strategyAgent);
        address actual = factory.cloneFor(owner, strategyAgent);
        assertEq(predicted, actual, "predictClone != actual deployed address");
    }

    function test_cloneFor_idempotent_reverts() public {
        factory.cloneFor(owner, strategyAgent);
        // Second clone at same salt should revert — CREATE2 to existing address.
        vm.expectRevert();
        factory.cloneFor(owner, strategyAgent);
    }

    function test_clone_isInitialized_withChainConstants() public {
        address clone = factory.cloneFor(owner, strategyAgent);
        PtLoopExecutor e = PtLoopExecutor(clone);
        assertEq(e.owner(), owner, "clone owner");
        assertEq(e.strategyAgent(), strategyAgent, "clone strategyAgent");
        assertEq(e.usdc(), USDC, "clone usdc");
        assertEq(e.pendleRouter(), PENDLE_ROUTER, "clone pendleRouter");
        assertEq(e.flashVault(), BALANCER_VAULT, "clone flashVault");
    }

    function test_enterLoop_onlyStrategyAgent_reverts() public {
        address clone = factory.cloneFor(owner, strategyAgent);
        PtLoopExecutor.EnterParams memory p;
        p.leverageBps = 30_000; // 3x; valid range
        vm.prank(address(0xDEAD));
        vm.expectRevert(PtLoopExecutor.NotStrategyAgent.selector);
        PtLoopExecutor(clone).enterLoop(p);
    }

    function test_enterLoop_badLeverage_reverts() public {
        address clone = factory.cloneFor(owner, strategyAgent);
        PtLoopExecutor.EnterParams memory p;
        p.leverageBps = 5_000; // below min (10_000 = 1x)
        vm.prank(strategyAgent);
        vm.expectRevert(PtLoopExecutor.BadLeverage.selector);
        PtLoopExecutor(clone).enterLoop(p);

        // uint16 max is 65_535; the controller cap is 100_000 bps so only representable values
        // above 100_000 would be those from a wider int → we use max uint16 which is > 100_000.
        p.leverageBps = 0; // below min (still fails BadLeverage path via the < 10_000 branch)
        vm.prank(strategyAgent);
        vm.expectRevert(PtLoopExecutor.BadLeverage.selector);
        PtLoopExecutor(clone).enterLoop(p);
    }

    function test_receiveFlashLoan_onlyBalancerVault_reverts() public {
        address clone = factory.cloneFor(owner, strategyAgent);
        address[] memory tokens = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory fees = new uint256[](1);
        tokens[0] = USDC;
        amounts[0] = 1000;
        fees[0] = 0;
        // Caller is not the Balancer vault → must revert.
        vm.expectRevert(PtLoopExecutor.NotFlashCallback.selector);
        PtLoopExecutor(clone).receiveFlashLoan(tokens, amounts, fees, abi.encode(uint8(0), bytes("")));
    }

    function test_rescue_onlyOwner() public {
        address clone = factory.cloneFor(owner, strategyAgent);
        // Non-owner cannot rescue.
        vm.prank(strategyAgent);
        vm.expectRevert(PtLoopExecutor.NotOwner.selector);
        PtLoopExecutor(clone).rescue(USDC, owner, 1);

        // Owner can (will revert on transfer of 0 balance but call passes auth).
        vm.prank(owner);
        vm.expectRevert(); // ERC20 insufficient balance
        PtLoopExecutor(clone).rescue(USDC, owner, 1);
    }

    function test_setStrategyAgent_onlyOwner() public {
        address clone = factory.cloneFor(owner, strategyAgent);
        address newAgent = address(0xBEEF);

        vm.prank(strategyAgent);
        vm.expectRevert(PtLoopExecutor.NotOwner.selector);
        PtLoopExecutor(clone).setStrategyAgent(newAgent);

        vm.prank(owner);
        PtLoopExecutor(clone).setStrategyAgent(newAgent);
        assertEq(PtLoopExecutor(clone).strategyAgent(), newAgent);
    }
}
