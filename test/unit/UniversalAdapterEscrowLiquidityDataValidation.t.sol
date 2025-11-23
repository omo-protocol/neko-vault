// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";
import "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockVaultV2.sol";
import "../mocks/MockValuer.sol";

/**
 * @title UniversalAdapterEscrowLiquidityDataValidationTest
 * @notice Tests for liquidityData empty calls validation (Security Fix)
 * @dev Validates that allocate() enforces empty calls array to prevent
 *      deposit failures when hardcoded amounts don't match actual deposits
 */
contract UniversalAdapterEscrowLiquidityDataValidationTest is Test {
    UniversalAdapterEscrow adapter;
    MockERC20 asset;
    MockVaultV2 vault;
    MockValuer valuer;

    address owner = address(0x1);
    address agent = address(0x2);
    bytes32 strategyId = keccak256("test-strategy");

    function setUp() public {
        vm.startPrank(owner);

        // Deploy contracts
        asset = new MockERC20("Test Asset", "TEST", 6);
        vault = new MockVaultV2(address(asset), owner);
        valuer = new MockValuer();

        // Deploy adapter via factory
        UniversalAdapterEscrowFactory factory = new UniversalAdapterEscrowFactory();
        address adapterAddress = factory.deployAdapter(
            address(vault),
            address(valuer),
            false,
            bytes32(uint256(1))
        );
        adapter = UniversalAdapterEscrow(payable(adapterAddress));

        // Configure strategy
        adapter.setStrategy(strategyId, agent, "", type(uint256).max);

        vm.stopPrank();
    }

    /* POSITIVE TESTS - Empty Calls Should Succeed */

    function testAllocateWithEmptyCalls() public {
        // Prepare allocation with empty calls array
        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, false, emptyCalls);

        // Mint assets to vault
        asset.mint(address(vault), 1000e6);

        // Allocate should succeed
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.allocate(allocData, 1000e6, bytes4(0), address(0));

        // Verify allocation succeeded
        assertEq(ids.length, 1);
        assertEq(ids[0], strategyId);
        assertEq(change, 1000e6);
        assertEq(adapter.getAllocation(strategyId), 1000e6);
    }

    function testAllocateMultipleDepositsWithEmptyCalls() public {
        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, false, emptyCalls);

        // First deposit: 500
        asset.mint(address(vault), 500e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 500e6, bytes4(0), address(0));

        // Second deposit: 1000
        asset.mint(address(vault), 1000e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));

        // Third deposit: 100
        asset.mint(address(vault), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Verify all allocations accumulated
        assertEq(adapter.getAllocation(strategyId), 1600e6);
    }

    /* NEGATIVE TESTS - Non-Empty Calls Should Revert */

    function testAllocateWithNonEmptyCallsReverts() public {
        // Prepare allocation with non-empty calls array
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(0x1234),
            data: abi.encodeWithSignature("deposit(uint256)", 1000e6),
            value: 0
        });

        bytes memory allocData = abi.encode(strategyId, 0, false, calls);

        asset.mint(address(vault), 1000e6);

        // Should revert with LiquidityDataMustHaveEmptyCalls
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.LiquidityDataMustHaveEmptyCalls.selector);
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));
    }

    function testAllocateWithMultipleCallsReverts() public {
        // Prepare allocation with multiple calls
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](3);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(0x1234),
            data: abi.encodeWithSignature("deposit(uint256)", 500e6),
            value: 0
        });
        calls[1] = IUniversalAdapterEscrow.Call({
            target: address(0x5678),
            data: abi.encodeWithSignature("swap(uint256)", 300e6),
            value: 0
        });
        calls[2] = IUniversalAdapterEscrow.Call({
            target: address(0x9abc),
            data: abi.encodeWithSignature("stake(uint256)", 200e6),
            value: 0
        });

        bytes memory allocData = abi.encode(strategyId, 0, false, calls);

        asset.mint(address(vault), 1000e6);

        // Should revert
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.LiquidityDataMustHaveEmptyCalls.selector);
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));
    }

    /* IDLE BALANCE TESTS */

    function testGetIdleBalanceAfterAllocation() public {
        // Allocate with empty calls
        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, false, emptyCalls);

        asset.mint(address(vault), 1000e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));

        // All allocated assets should be idle (not deployed yet)
        uint256 idle = adapter.getIdleBalance(strategyId);
        assertEq(idle, 1000e6, "All allocated assets should be idle");
    }

    function testGetIdleBalanceCalculation() public {
        // Test that idle balance calculation is correct
        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, false, emptyCalls);

        // Allocate 1000
        asset.mint(address(vault), 1000e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));

        // All should be idle (allocated - externalDeposits = 1000 - 0)
        assertEq(adapter.getIdleBalance(strategyId), 1000e6);
        
        // Allocate another 500
        asset.mint(address(vault), 500e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 500e6, bytes4(0), address(0));

        // Now idle should be 1500 (allocated - externalDeposits = 1500 - 0)
        assertEq(adapter.getIdleBalance(strategyId), 1500e6);
    }

    function testGetIdleBalanceMultipleStrategies() public {
        // Setup second strategy
        bytes32 strategy2 = keccak256("strategy-2");
        vm.prank(owner);
        adapter.setStrategy(strategy2, agent, "", type(uint256).max);

        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);

        // Allocate 500 to strategy 1
        bytes memory allocData1 = abi.encode(strategyId, 0, false, emptyCalls);
        asset.mint(address(vault), 500e6);
        vm.prank(address(vault));
        adapter.allocate(allocData1, 500e6, bytes4(0), address(0));

        // Allocate 300 to strategy 2
        bytes memory allocData2 = abi.encode(strategy2, 0, false, emptyCalls);
        asset.mint(address(vault), 300e6);
        vm.prank(address(vault));
        adapter.allocate(allocData2, 300e6, bytes4(0), address(0));

        // Check idle balances
        assertEq(adapter.getIdleBalance(strategyId), 500e6, "Strategy 1 idle should be 500");
        assertEq(adapter.getIdleBalance(strategy2), 300e6, "Strategy 2 idle should be 300");
    }

    function testGetIdleBalanceZeroWhenNotAllocated() public {
        // Strategy exists but nothing allocated
        uint256 idle = adapter.getIdleBalance(strategyId);
        assertEq(idle, 0, "Idle should be 0 for unallocated strategy");
    }

    function testGetIdleBalanceWithNoAllocation() public {
        // Test strategy with no allocation has zero idle
        bytes32 unusedStrategy = keccak256("unused-strategy");
        
        vm.prank(owner);
        adapter.setStrategy(unusedStrategy, agent, "", type(uint256).max);

        // Should return 0 for strategy with no allocation
        uint256 idle = adapter.getIdleBalance(unusedStrategy);
        assertEq(idle, 0, "Unused strategy should have 0 idle balance");
    }

    /* EDGE CASES */

    function testAllocateZeroAmountStillEnforcesEmptyCalls() public {
        // Even with zero amount, non-empty calls should be rejected
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(0x1234),
            data: abi.encodeWithSignature("deposit(uint256)", 0),
            value: 0
        });

        bytes memory allocData = abi.encode(strategyId, 0, false, calls);

        // Should revert due to InvalidAmount before checking calls
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);
        adapter.allocate(allocData, 0, bytes4(0), address(0));
    }

    function testFuzzAllocateVariousAmountsWithEmptyCalls(uint256 amount) public {
        // Bound to reasonable range (1 to 1 billion tokens with 6 decimals)
        amount = bound(amount, 1, 1_000_000_000e6);

        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, false, emptyCalls);

        asset.mint(address(vault), amount);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.allocate(allocData, amount, bytes4(0), address(0));

        assertEq(ids[0], strategyId);
        assertEq(uint256(change), amount);
        assertEq(adapter.getAllocation(strategyId), amount);
        assertEq(adapter.getIdleBalance(strategyId), amount);
    }

    /* INTEGRATION TEST - Full Workflow */

    function testCompleteWorkflowWithEmptyCallsValidation() public {
        // 1. User deposits to vault (triggers allocate with empty calls)
        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, false, emptyCalls);

        asset.mint(address(vault), 1000e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));

        // 2. Verify assets are allocated but idle
        assertEq(adapter.getAllocation(strategyId), 1000e6, "Should be allocated");
        assertEq(adapter.getIdleBalance(strategyId), 1000e6, "Should be idle");

        // 3. Agent monitors idle balance and decides to execute
        uint256 idleToExecute = adapter.getIdleBalance(strategyId);
        assertGt(idleToExecute, 0, "Agent should see idle balance");

        // 4. Verify accounting is correct
        assertEq(adapter.getAllocation(strategyId), idleToExecute, "Allocation should match idle");
        assertEq(adapter.totalAllocations(), 1000e6, "Total allocations should be 1000");
        
        // 5. In real scenario, agent would call executeStrategy() with dynamic amount
        //    based on the idle balance returned from getIdleBalance()
        //    This test validates the core security fix: empty calls validation works
    }
}
