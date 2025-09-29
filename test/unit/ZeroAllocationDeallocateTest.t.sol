// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockVaultV2} from "../mocks/MockVaultV2.sol";
import {MockValuer} from "../mocks/MockValuer.sol";

/**
 * @title ZeroAllocationDeallocateTest
 * @notice Tests that deallocate works with strategies having 0 allocation
 * @dev Verifies users can withdraw idle assets and profits even from unallocated strategies
 */
contract ZeroAllocationDeallocateTest is Test {
    UniversalAdapterEscrow adapter;
    MockVaultV2 vault;
    MockERC20 asset;
    MockValuer valuer;

    address owner = address(0x1);
    address agent = address(0x2);

    bytes32 constant STRATEGY_1 = keccak256("STRATEGY_1");
    bytes32 constant STRATEGY_2 = keccak256("STRATEGY_2");

    function setUp() public {
        asset = new MockERC20("USDC", "USDC", 6);
        valuer = new MockValuer();
        vault = new MockVaultV2(address(asset), owner);

        adapter = new UniversalAdapterEscrow(
            address(vault),
            address(valuer),
            false
        );

        vm.startPrank(owner);
        vault.addAdapter(address(adapter));
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.setStrategy(STRATEGY_2, agent, "", 1000e6);
        vm.stopPrank();

        asset.mint(address(vault), 1000000e6);
    }

    function testDeallocateFromZeroAllocationStrategy() public {
        // Setup: Allocate to STRATEGY_1, but not STRATEGY_2
        asset.mint(address(adapter), 500e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            500e6,
            bytes4(0),
            address(0)
        );

        // Verify initial state
        assertEq(adapter.getAllocation(STRATEGY_1), 500e6, "Strategy 1 should have allocation");
        assertEq(adapter.getAllocation(STRATEGY_2), 0, "Strategy 2 should have 0 allocation");

        // Add some idle/profit assets directly to the adapter
        asset.mint(address(adapter), 200e6);
        uint256 totalBalance = asset.balanceOf(address(adapter));
        assertEq(totalBalance, 700e6, "Adapter should have 700e6 total");

        // Test 1: Should be able to deallocate from STRATEGY_2 even though it has 0 allocation
        // This represents withdrawing idle assets or profits
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_2, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            100e6,
            bytes4(0),
            address(0)
        );

        // Verify the withdrawal succeeded
        assertEq(ids[0], STRATEGY_2, "Should return STRATEGY_2 ID");
        assertEq(change, -100e6, "Should report 100e6 withdrawn");
        assertEq(adapter.getAllocation(STRATEGY_2), 0, "Strategy 2 allocation should remain 0");

        console2.log("[PASS] Successfully withdrew 100e6 from strategy with 0 allocation");
    }

    function testDeallocateMoreThanAllocationButLessThonBalance() public {
        // Setup: Allocate 300e6 to STRATEGY_1
        asset.mint(address(adapter), 300e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            300e6,
            bytes4(0),
            address(0)
        );

        // Add profits/yield - 200e6 extra
        asset.mint(address(adapter), 200e6);
        assertEq(asset.balanceOf(address(adapter)), 500e6, "Should have 500e6 total");

        // Test: Try to withdraw 450e6 from STRATEGY_1 (more than allocated, but less than balance)
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            450e6,
            bytes4(0),
            address(0)
        );

        // Should succeed and withdraw the full 450e6
        assertEq(ids[0], STRATEGY_1, "Should return STRATEGY_1 ID");
        assertEq(change, -450e6, "Should withdraw full amount including profits");
        assertEq(adapter.getAllocation(STRATEGY_1), 0, "Strategy allocation should be zeroed");

        console2.log("[PASS] Successfully withdrew profits beyond allocated amount");
    }

    function testIdleAssetsAccessible() public {
        // Test scenario: No allocations, but adapter has idle assets (maybe from failed allocations, fees, etc.)

        // Add idle assets directly to adapter (simulating various scenarios)
        asset.mint(address(adapter), 150e6);

        // Verify no allocations exist
        assertEq(adapter.totalAllocations(), 0, "Should have 0 total allocations");
        assertEq(adapter.getActiveStrategies().length, 0, "Should have 0 active strategies");
        assertEq(asset.balanceOf(address(adapter)), 150e6, "Should have 150e6 idle assets");

        // Should be able to withdraw idle assets using any strategy ID
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            100e6,
            bytes4(0),
            address(0)
        );

        assertEq(ids[0], STRATEGY_1, "Should return STRATEGY_1 ID");
        assertEq(change, -100e6, "Should withdraw idle assets");
        assertEq(adapter.getAllocation(STRATEGY_1), 0, "Strategy should remain with 0 allocation");

        console2.log("[PASS] Successfully accessed idle assets");
    }

    function testEmergencyWithdrawal() public {
        // Setup: Normal operation with allocation
        asset.mint(address(adapter), 400e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            400e6,
            bytes4(0),
            address(0)
        );

        // Add extra balance (profits/yield)
        asset.mint(address(adapter), 100e6);

        // Emergency: Want to withdraw everything possible using any strategy
        uint256 availableBalance = asset.balanceOf(address(adapter));
        assertEq(availableBalance, 500e6, "Should have 500e6 available");

        // Try emergency withdrawal from STRATEGY_2 (which has 0 allocation)
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_2, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            500e6, // Try to withdraw everything
            bytes4(0),
            address(0)
        );

        // Should withdraw the full available balance
        assertEq(ids[0], STRATEGY_2, "Should return STRATEGY_2 ID");
        assertEq(change, -500e6, "Should withdraw full available balance");
        assertEq(adapter.getAllocation(STRATEGY_2), 0, "STRATEGY_2 should remain 0");
        // STRATEGY_1 allocation tracking remains unchanged since we deallocated from STRATEGY_2
        assertEq(adapter.getAllocation(STRATEGY_1), 400e6, "STRATEGY_1 allocation unchanged");
        // But totalAllocations should be properly adjusted
        assertEq(adapter.totalAllocations(), 400e6, "Total allocations should remain 400e6");

        console2.log("[PASS] Emergency withdrawal successful");
    }
}