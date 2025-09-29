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
 * @title GasOptimizationTest
 * @notice Tests the gas optimization for totalAllocations tracking
 * @dev Verifies that the O(1) totalAllocations state variable correctly replaces the O(n) loop
 */
contract GasOptimizationTest is Test {
    UniversalAdapterEscrow adapter;
    MockVaultV2 vault;
    MockERC20 asset;
    MockValuer valuer;

    address owner = address(0x1);
    address agent = address(0x2);

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

        // Setup multiple strategies to test gas with many active strategies
        for (uint256 i = 0; i < 20; i++) {
            bytes32 strategyId = keccak256(abi.encode("STRATEGY", i));
            adapter.setStrategy(strategyId, agent, "", 10000e6);
        }
        vm.stopPrank();

        asset.mint(address(vault), 1000000e6);
    }

    function testTotalAllocationsTracking() public {
        // Test 1: Initial state
        assertEq(adapter.totalAllocations(), 0, "Should start with 0 total allocations");

        // Test 2: Single allocation
        bytes32 strategy1 = keccak256(abi.encode("STRATEGY", 0));
        asset.mint(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(strategy1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            100e6,
            bytes4(0),
            address(0)
        );
        assertEq(adapter.totalAllocations(), 100e6, "Total should be 100e6 after first allocation");
        assertEq(adapter.getAllocation(strategy1), 100e6, "Strategy 1 should have 100e6");

        // Test 3: Multiple allocations
        bytes32 strategy2 = keccak256(abi.encode("STRATEGY", 1));
        asset.mint(address(adapter), 200e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(strategy2, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            200e6,
            bytes4(0),
            address(0)
        );
        assertEq(adapter.totalAllocations(), 300e6, "Total should be 300e6 after second allocation");
        assertEq(adapter.getAllocation(strategy2), 200e6, "Strategy 2 should have 200e6");

        // Test 4: Additional allocation to existing strategy
        asset.mint(address(adapter), 50e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(strategy1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            50e6,
            bytes4(0),
            address(0)
        );
        assertEq(adapter.totalAllocations(), 350e6, "Total should be 350e6 after additional allocation");
        assertEq(adapter.getAllocation(strategy1), 150e6, "Strategy 1 should have 150e6");

        // Test 5: Partial deallocation
        vm.prank(address(vault));
        adapter.deallocate(
            abi.encode(strategy1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            50e6,
            bytes4(0),
            address(0)
        );
        assertEq(adapter.totalAllocations(), 300e6, "Total should be 300e6 after partial deallocation");
        assertEq(adapter.getAllocation(strategy1), 100e6, "Strategy 1 should have 100e6");

        // Test 6: Full deallocation
        vm.prank(address(vault));
        adapter.deallocate(
            abi.encode(strategy2, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            200e6,
            bytes4(0),
            address(0)
        );
        assertEq(adapter.totalAllocations(), 100e6, "Total should be 100e6 after full deallocation");
        assertEq(adapter.getAllocation(strategy2), 0, "Strategy 2 should have 0");

        // Test 7: Verify active strategies list
        bytes32[] memory activeStrategies = adapter.getActiveStrategies();
        assertEq(activeStrategies.length, 1, "Should have 1 active strategy");
        assertEq(activeStrategies[0], strategy1, "Active strategy should be strategy1");
    }

    function testGasEfficiencyWithManyStrategies() public {
        // Allocate to many strategies to show gas efficiency
        uint256 gasBefore;
        uint256 gasUsed;

        // Allocate to 10 strategies first
        for (uint256 i = 0; i < 10; i++) {
            bytes32 strategyId = keccak256(abi.encode("STRATEGY", i));
            asset.mint(address(adapter), 10e6);
            vm.prank(address(vault));
            adapter.allocate(
                abi.encode(strategyId, 0, false, new IUniversalAdapterEscrow.Call[](0)),
                10e6,
                bytes4(0),
                address(0)
            );
        }

        // Now measure gas for the 11th allocation
        bytes32 strategy11 = keccak256(abi.encode("STRATEGY", 10));
        asset.mint(address(adapter), 10e6);

        gasBefore = gasleft();
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(strategy11, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            10e6,
            bytes4(0),
            address(0)
        );
        gasUsed = gasBefore - gasleft();

        console2.log("Gas used for allocation with 10 existing strategies:", gasUsed);

        // Allocate to 5 more strategies
        for (uint256 i = 11; i < 16; i++) {
            bytes32 strategyId = keccak256(abi.encode("STRATEGY", i));
            asset.mint(address(adapter), 10e6);
            vm.prank(address(vault));
            adapter.allocate(
                abi.encode(strategyId, 0, false, new IUniversalAdapterEscrow.Call[](0)),
                10e6,
                bytes4(0),
                address(0)
            );
        }

        // Measure gas for the 17th allocation
        bytes32 strategy17 = keccak256(abi.encode("STRATEGY", 16));
        asset.mint(address(adapter), 10e6);

        gasBefore = gasleft();
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(strategy17, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            10e6,
            bytes4(0),
            address(0)
        );
        gasUsed = gasBefore - gasleft();

        console2.log("Gas used for allocation with 16 existing strategies:", gasUsed);

        // With the old O(n) loop, gas would increase significantly
        // With O(1) totalAllocations, gas should remain relatively constant
    }

    function testTotalAllocationsAccuracy() public {
        // Verify that totalAllocations exactly matches the sum of individual allocations
        uint256 expectedTotal = 0;

        // Allocate to multiple strategies with varying amounts
        uint256[] memory amounts = new uint256[](5);
        amounts[0] = 100e6;
        amounts[1] = 250e6;
        amounts[2] = 75e6;
        amounts[3] = 300e6;
        amounts[4] = 125e6;

        for (uint256 i = 0; i < amounts.length; i++) {
            bytes32 strategyId = keccak256(abi.encode("STRATEGY", i));
            asset.mint(address(adapter), amounts[i]);

            vm.prank(address(vault));
            adapter.allocate(
                abi.encode(strategyId, 0, false, new IUniversalAdapterEscrow.Call[](0)),
                amounts[i],
                bytes4(0),
                address(0)
            );

            expectedTotal += amounts[i];
            assertEq(adapter.totalAllocations(), expectedTotal, "Total should match cumulative allocations");
        }

        // Verify final total
        assertEq(adapter.totalAllocations(), 850e6, "Final total should be 850e6");

        // Verify by summing individual strategy allocations
        uint256 manualTotal = 0;
        for (uint256 i = 0; i < amounts.length; i++) {
            bytes32 strategyId = keccak256(abi.encode("STRATEGY", i));
            manualTotal += adapter.getAllocation(strategyId);
        }
        assertEq(adapter.totalAllocations(), manualTotal, "Total should match manual sum");
    }
}