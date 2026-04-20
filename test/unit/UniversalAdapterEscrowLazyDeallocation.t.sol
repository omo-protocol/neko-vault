// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockVaultV2} from "../mocks/MockVaultV2.sol";
import {MockValuer} from "../mocks/MockValuer.sol";
import {MockProtocol} from "../mocks/MockProtocol.sol";
import {MockAgent} from "../mocks/MockAgent.sol";

/// @title UniversalAdapterEscrowLazyDeallocationTest
/// @notice Tests for the lazy deallocation pattern (unbounded gas fix)
contract UniversalAdapterEscrowLazyDeallocationTest is Test {
    UniversalAdapterEscrow public adapter;
    MockERC20 public asset;
    MockVaultV2 public vault;
    MockValuer public valuer;
    MockProtocol public protocol;

    address public owner = address(this);
    address public agent;
    address public user = address(0x2);

    bytes32 public constant STRATEGY_ID = keccak256("STRATEGY_1");

    // Function selectors for vault calls
    bytes4 public constant DEALLOCATE_SELECTOR = 0x4b219d16;
    bytes4 public constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8;

    event AllocationUpdated(bytes32 indexed strategyId, uint256 newAmount, int256 change);
    event PartialDeallocate(bytes32 indexed strategyId, uint256 requested, uint256 actual);
    event StrategyWithdrawn(bytes32 indexed strategyId, uint256 amount, address indexed executor);

    function setUp() public {
        // Deploy MockAgent for agent address
        agent = address(new MockAgent());

        // Deploy mocks
        asset = new MockERC20("Test Asset", "TST", 18);
        vault = new MockVaultV2(address(asset), owner);
        valuer = new MockValuer();
        protocol = new MockProtocol(address(asset));

        // Deploy adapter
        adapter = new UniversalAdapterEscrow(address(vault));

        // Setup strategy
        adapter.setStrategy(STRATEGY_ID, agent, "", 0);

        // Whitelist protocol functions
        adapter.updateWhitelist(address(protocol), protocol.deposit.selector, true, 0);
        adapter.updateWhitelist(address(protocol), protocol.withdraw.selector, true, 0);

        // Mint assets to vault
        asset.mint(address(vault), 1000e18);

        // Give vault approval to pull from adapter
        vm.prank(address(adapter));
        asset.approve(address(vault), type(uint256).max);

        // Give protocol approval to pull from adapter (for deposits)
        vm.prank(address(adapter));
        asset.approve(address(protocol), type(uint256).max);
    }

    /* ========== DEALLOCATE TESTS (Simplified O(1) Gas) ========== */

    /// @notice Test deallocate with sufficient adapter balance (happy path)
    function test_deallocate_WithSufficientBalance() public {
        uint256 allocAmount = 100e18;
        uint256 deallocAmount = 50e18;

        // Setup: Allocate assets to strategy
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Deallocate should succeed since balance covers the request
        uint256 balanceBefore = asset.balanceOf(address(adapter));
        assertEq(balanceBefore, allocAmount);

        vm.prank(address(vault));
        bytes memory deallocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.expectEmit(true, false, false, true);
        emit AllocationUpdated(STRATEGY_ID, allocAmount - deallocAmount, -int256(deallocAmount));

        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocData, deallocAmount, DEALLOCATE_SELECTOR, address(0));

        // Verify results
        assertEq(ids.length, 1);
        assertEq(ids[0], STRATEGY_ID);
        assertEq(change, -int256(deallocAmount));
        assertEq(adapter.getAllocation(STRATEGY_ID), allocAmount - deallocAmount);
        assertEq(asset.balanceOf(address(adapter)), allocAmount); // Balance unchanged (vault pulls via transferFrom)
    }

    /// @notice Test deallocate with insufficient balance reverts with InsufficientAdapterBalance
    function test_deallocate_InsufficientBalance_Reverts() public {
        uint256 allocAmount = 100e18;
        uint256 deallocAmount = 150e18; // More than available

        // Setup: Allocate assets
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Attempt to deallocate more than available
        vm.prank(address(vault));
        bytes memory deallocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalAdapterEscrow.InsufficientAdapterBalance.selector, allocAmount, deallocAmount
            )
        );

        adapter.deallocate(deallocData, deallocAmount, DEALLOCATE_SELECTOR, address(0));
    }

    /// @notice Test that withdraw selector DOES trigger auto-withdrawal (V4 security fix)
    function test_deallocate_WithdrawSelectorTriggersAutoWithdrawal() public {
        uint256 allocAmount = 100e18;
        MockAutoWithdrawController controller = new MockAutoWithdrawController(address(protocol));

        adapter.setStrategy(STRATEGY_ID, address(controller), "", 0);

        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, 40e18),
            value: 0
        });

        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(STRATEGY_ID, depositCalls);

        // With V4 fix, withdraw selector triggers auto-withdrawal to cover shortfall
        bytes memory deallocData = abi.encode(STRATEGY_ID, 2, new IUniversalAdapterEscrow.Call[](0));
        bytes4 withdrawSelector = bytes4(keccak256("withdraw(uint256,address,address)"));

        vm.prank(address(vault));
        adapter.deallocate(deallocData, 80e18, withdrawSelector, address(0));

        // Auto-withdrawal pulled 20e18 from protocol to cover shortfall (80 - 60 idle)
        // Adapter balance is 80e18 (vault pulls assets separately via transferFrom)
        assertEq(asset.balanceOf(address(adapter)), 80e18);
        // Protocol balance reduced from 40e18 to 20e18
        assertEq(protocol.balanceOf(address(adapter)), 20e18);
    }

    /// @notice Test that redeem selector DOES trigger auto-withdrawal (V4 security fix)
    function test_deallocate_RedeemSelectorTriggersAutoWithdrawal() public {
        uint256 allocAmount = 100e18;
        MockAutoWithdrawController controller = new MockAutoWithdrawController(address(protocol));

        adapter.setStrategy(STRATEGY_ID, address(controller), "", 0);

        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, 50e18),
            value: 0
        });

        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(STRATEGY_ID, depositCalls);

        // With V4 fix, redeem selector triggers auto-withdrawal to cover shortfall
        bytes memory deallocData = abi.encode(STRATEGY_ID, 2, new IUniversalAdapterEscrow.Call[](0));
        bytes4 redeemSelector = bytes4(keccak256("redeem(uint256,address,address)"));

        vm.prank(address(vault));
        adapter.deallocate(deallocData, 75e18, redeemSelector, address(0));

        // Auto-withdrawal pulled 25e18 from protocol to cover shortfall (75 - 50 idle)
        // Adapter balance is 75e18 (vault pulls assets separately via transferFrom)
        assertEq(asset.balanceOf(address(adapter)), 75e18);
        // Protocol balance reduced from 50e18 to 25e18
        assertEq(protocol.balanceOf(address(adapter)), 25e18);
    }

    /// @notice Test deallocate ignores withdrawCalls (backward compatibility)

    function test_deallocate_IgnoresWithdrawCalls() public {
        uint256 allocAmount = 100e18;
        uint256 deallocAmount = 50e18;

        // Setup
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Create deallocData with withdrawCalls (should be ignored)
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.withdraw.selector, 50e18),
            value: 0
        });

        bytes memory deallocData = abi.encode(STRATEGY_ID, 0, withdrawCalls);

        // Deallocate should succeed WITHOUT executing withdrawCalls
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocData, deallocAmount, DEALLOCATE_SELECTOR, address(0));

        // Verify withdrawCalls were NOT executed (protocol balance unchanged)
        assertEq(protocol.balanceOf(address(adapter)), 0);
        assertEq(ids.length, 1);
        assertEq(change, -int256(deallocAmount));
    }

    /// @notice Test force deallocate with partial fulfillment
    function test_forceDeallocate_PartialFulfillment() public {
        uint256 allocAmount = 100e18;
        uint256 requestedAmount = 150e18;
        uint256 availableBalance = 60e18;

        // Setup: Allocate and partially deploy to external protocol
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Agent deploys some to external protocol (use bypass for large deposits)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, 40e18),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(STRATEGY_ID, depositCalls);

        // Verify state: 60e18 in adapter, 40e18 in protocol
        assertEq(asset.balanceOf(address(adapter)), availableBalance);
        assertEq(protocol.balanceOf(address(adapter)), 40e18);

        // Force deallocate should work with slack amount
        // Slack = allocations - externalDeposits = 100e18 - 40e18 = 60e18
        // Available balance = 60e18
        // Since slack == availableBalance, this is NOT a partial deallocate (full fulfillment)
        uint256 slack = allocAmount - adapter.externalDeposits(STRATEGY_ID);
        assertEq(slack, availableBalance); // Verify test setup

        bytes memory deallocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));

        // No PartialDeallocate event expected since we can fulfill the full request
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocData, slack, FORCE_DEALLOCATE_SELECTOR, address(0));

        // Verify full fulfillment
        assertEq(ids.length, 1);
        assertEq(change, -int256(slack)); // Returns full requested amount
        assertEq(adapter.getAllocation(STRATEGY_ID), allocAmount - slack);
    }

    /// @notice Test force deallocate reverts when slack exceeds available balance
    function test_forceDeallocate_TruePartialFulfillment() public {
        uint256 allocAmount = 100e18;
        uint256 depositAmount = 70e18;
        uint256 availableBalance = 30e18;

        // Setup: Allocate and partially deploy to external protocol
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Agent deploys to external protocol
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, depositAmount),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(STRATEGY_ID, depositCalls);

        // Verify state: 30e18 in adapter, 70e18 in protocol
        assertEq(asset.balanceOf(address(adapter)), availableBalance);
        assertEq(protocol.balanceOf(address(adapter)), depositAmount);

        // Calculate slack and manually transfer some assets out to create partial scenario
        // Slack = allocations - externalDeposits = 100e18 - 70e18 = 30e18
        // We want slack > availableBalance, so let's transfer 10e18 out
        vm.prank(address(adapter));
        asset.transfer(address(0xdead), 10e18);

        uint256 newAvailableBalance = 20e18;
        assertEq(asset.balanceOf(address(adapter)), newAvailableBalance);

        // Now slack (30e18) > available balance (20e18)
        uint256 slack = allocAmount - adapter.externalDeposits(STRATEGY_ID);
        assertEq(slack, 30e18);

        bytes memory deallocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalAdapterEscrow.InsufficientAdapterBalance.selector, newAvailableBalance, slack
            )
        );
        adapter.deallocate(deallocData, slack, FORCE_DEALLOCATE_SELECTOR, address(0));
    }

    /* ========== WITHDRAW FROM STRATEGY TESTS ========== */

    /// @notice Test withdrawFromStrategy successfully pulls liquidity
    function test_withdrawFromStrategy_Success() public {
        uint256 allocAmount = 100e18;
        uint256 depositAmount = 80e18;
        uint256 withdrawAmount = 50e18;

        // Setup: Allocate and deploy to protocol
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Deploy to protocol (use bypass for large deposits >10%)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, depositAmount),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(STRATEGY_ID, depositCalls);

        // Verify initial state
        uint256 balanceBefore = asset.balanceOf(address(adapter));
        assertEq(balanceBefore, allocAmount - depositAmount);

        // Setup valuer to return correct value
        valuer.setValue(STRATEGY_ID, depositAmount - withdrawAmount);

        // Agent withdraws from protocol via withdrawFromStrategy
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.withdraw.selector, withdrawAmount),
            value: 0
        });

        vm.expectEmit(true, false, true, true);
        emit StrategyWithdrawn(STRATEGY_ID, withdrawAmount, agent);

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_ID, withdrawCalls, withdrawAmount);

        // Verify balance increased
        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, balanceBefore + withdrawAmount);
        assertEq(protocol.balanceOf(address(adapter)), depositAmount - withdrawAmount);
    }

    /// @notice Test withdrawFromStrategy enforces slippage protection
    function test_withdrawFromStrategy_SlippageFails() public {
        uint256 allocAmount = 100e18;
        uint256 depositAmount = 80e18;
        uint256 withdrawAmount = 50e18;
        uint256 minBalanceIncrease = 55e18; // More than actual withdrawn

        // Setup
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Deploy to protocol (use bypass for large deposits >10%)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, depositAmount),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(STRATEGY_ID, depositCalls);

        // Attempt withdrawal with excessive minBalanceIncrease
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.withdraw.selector, withdrawAmount),
            value: 0
        });

        vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_ID, withdrawCalls, minBalanceIncrease);
    }

    /// @notice Test withdrawFromStrategy requires balance increase
    function test_withdrawFromStrategy_NoBalanceIncrease_Reverts() public {
        uint256 allocAmount = 100e18;

        // Setup
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Attempt withdrawal with calls that don't increase balance
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, 0), // No-op
            value: 0
        });

        vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_ID, withdrawCalls, 0);
    }

    /// @notice Test withdrawFromStrategy only callable by agent or owner
    function test_withdrawFromStrategy_OnlyAgentOrOwner() public {
        uint256 allocAmount = 100e18;

        // Setup
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Unauthorized user attempts withdrawal
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.withdraw.selector, 50e18),
            value: 0
        });

        vm.expectRevert(IUniversalAdapterEscrow.NotAuthorized.selector);

        vm.prank(user);
        adapter.withdrawFromStrategy(STRATEGY_ID, withdrawCalls, 50e18);
    }

    /* ========== GAS BENCHMARKING ========== */

    /// @notice Benchmark gas usage of simplified deallocate() - should be O(1)
    function test_gas_SimplifiedDeallocate() public {
        uint256 allocAmount = 100e18;
        uint256 deallocAmount = 50e18;

        // Setup
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Benchmark deallocate gas
        bytes memory deallocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));

        uint256 gasBefore = gasleft();

        vm.prank(address(vault));
        adapter.deallocate(deallocData, deallocAmount, DEALLOCATE_SELECTOR, address(0));

        uint256 gasUsed = gasBefore - gasleft();

        // Gas should be < 100k (significantly less than old implementation)
        // Old implementation with multicalls could use 200k-3M+ gas
        emit log_named_uint("Simplified deallocate() gas:", gasUsed);
        assertLt(gasUsed, 100000, "Deallocate should use <100k gas");
    }

    /// @notice Benchmark gas of withdrawFromStrategy (not gas-constrained)
    function test_gas_WithdrawFromStrategy() public {
        uint256 allocAmount = 100e18;
        uint256 depositAmount = 80e18;
        uint256 withdrawAmount = 50e18;

        // Setup
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Deploy to protocol (use bypass for large deposits >10%)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, depositAmount),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(STRATEGY_ID, depositCalls);

        // Setup valuer
        valuer.setValue(STRATEGY_ID, depositAmount - withdrawAmount);

        // Benchmark withdrawFromStrategy gas
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.withdraw.selector, withdrawAmount),
            value: 0
        });

        uint256 gasBefore = gasleft();

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_ID, withdrawCalls, withdrawAmount);

        uint256 gasUsed = gasBefore - gasleft();

        // This function can use more gas since it's not in user withdrawal path
        emit log_named_uint("withdrawFromStrategy() gas:", gasUsed);
    }

    /* ========== LAZY DEALLOCATION WORKFLOW TEST ========== */

    /// @notice Test complete lazy deallocation workflow
    function test_lazyDeallocation_CompleteWorkflow() public {
        uint256 allocAmount = 100e18;
        uint256 depositAmount = 80e18;
        uint256 deallocAmount = 50e18;

        // Step 1: Vault allocates to adapter
        vm.prank(address(vault));
        asset.transfer(address(adapter), allocAmount);

        vm.prank(address(vault));
        bytes memory allocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Step 2: Agent deploys to external protocol (use bypass for large deposits)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.deposit.selector, depositAmount),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(STRATEGY_ID, depositCalls);

        // Verify: Only 20e18 in adapter, 80e18 in protocol
        assertEq(asset.balanceOf(address(adapter)), allocAmount - depositAmount);
        assertEq(protocol.balanceOf(address(adapter)), depositAmount);

        // Step 3: User attempts withdrawal - SHOULD FAIL (insufficient balance)
        vm.prank(address(vault));
        bytes memory deallocData = abi.encode(STRATEGY_ID, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalAdapterEscrow.InsufficientAdapterBalance.selector, allocAmount - depositAmount, deallocAmount
            )
        );

        adapter.deallocate(deallocData, deallocAmount, DEALLOCATE_SELECTOR, address(0));

        // Step 4: Agent monitors and withdraws from protocol to refill adapter
        valuer.setValue(STRATEGY_ID, depositAmount - deallocAmount);

        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSelector(protocol.withdraw.selector, deallocAmount),
            value: 0
        });

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_ID, withdrawCalls, deallocAmount);

        // Verify: Adapter balance now sufficient
        assertEq(asset.balanceOf(address(adapter)), allocAmount - depositAmount + deallocAmount);

        // Step 5: User retries withdrawal - SHOULD SUCCEED
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocData, deallocAmount, DEALLOCATE_SELECTOR, address(0));

        assertEq(ids.length, 1);
        assertEq(change, -int256(deallocAmount));
        assertEq(adapter.getAllocation(STRATEGY_ID), allocAmount - deallocAmount);
    }
}

contract MockAutoWithdrawController {
    address public immutable protocol;

    constructor(address _protocol) {
        protocol = _protocol;
    }

    function quoteCurrentAssets() external pure returns (uint256 assets, bool healthy) {
        return (0, true);
    }

    function quoteAutomaticWithdrawal(uint256 amount)
        external
        view
        returns (IUniversalAdapterEscrow.Call[] memory calls)
    {
        calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: protocol,
            data: abi.encodeWithSelector(MockProtocol.withdraw.selector, amount),
            value: 0
        });
    }
}
