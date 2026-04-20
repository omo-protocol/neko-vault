// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";
import "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockVaultV2.sol";
import "../mocks/MockValuer.sol";
import {MockAgent} from "../mocks/MockAgent.sol";

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
    address agent;
    bytes32 strategyId = keccak256("test-strategy");

    function setUp() public {
        agent = address(new MockAgent());

        vm.startPrank(owner);

        // Deploy contracts
        asset = new MockERC20("Test Asset", "TEST", 6);
        vault = new MockVaultV2(address(asset), owner);
        valuer = new MockValuer();

        // Deploy adapter via factory
        UniversalAdapterEscrowFactory factory = new UniversalAdapterEscrowFactory();
        address adapterAddress = factory.deployAdapter(address(vault), bytes32(uint256(1)));
        adapter = UniversalAdapterEscrow(payable(adapterAddress));

        // Configure strategy
        adapter.setStrategy(strategyId, agent, "", type(uint256).max);

        vm.stopPrank();
    }

    /* POSITIVE TESTS - Empty Calls Should Succeed */

    function testAllocateWithEmptyCalls() public {
        // Prepare allocation with empty calls array
        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, emptyCalls);

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
        bytes memory allocData = abi.encode(strategyId, 0, emptyCalls);

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

        bytes memory allocData = abi.encode(strategyId, 0, calls);

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

        bytes memory allocData = abi.encode(strategyId, 0, calls);

        asset.mint(address(vault), 1000e6);

        // Should revert
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.LiquidityDataMustHaveEmptyCalls.selector);
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));
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

        bytes memory allocData = abi.encode(strategyId, 0, calls);

        // Should revert due to InvalidAmount before checking calls
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);
        adapter.allocate(allocData, 0, bytes4(0), address(0));
    }

    function testFuzzAllocateVariousAmountsWithEmptyCalls(uint256 amount) public {
        // Bound to reasonable range (1 to 1 billion tokens with 6 decimals)
        amount = bound(amount, 1, 1_000_000_000e6);

        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, emptyCalls);

        asset.mint(address(vault), amount);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.allocate(allocData, amount, bytes4(0), address(0));

        assertEq(ids[0], strategyId);
        assertEq(uint256(change), amount);
        assertEq(adapter.getAllocation(strategyId), amount);
    }

    /* INTEGRATION TEST - Full Workflow */

    function testCompleteWorkflowWithEmptyCallsValidation() public {
        // 1. User deposits to vault (triggers allocate with empty calls)
        IUniversalAdapterEscrow.Call[] memory emptyCalls = new IUniversalAdapterEscrow.Call[](0);
        bytes memory allocData = abi.encode(strategyId, 0, emptyCalls);

        asset.mint(address(vault), 1000e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));

        // 2. Verify assets are allocated but idle
        assertEq(adapter.getAllocation(strategyId), 1000e6, "Should be allocated");

        // 3. Verify accounting is correct
        assertEq(adapter.totalAllocations(), 1000e6, "Total allocations should be 1000");
    }
}
