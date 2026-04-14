// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockVaultV2} from "../mocks/MockVaultV2.sol";
import {MockValuer} from "../mocks/MockValuer.sol";
import {MockAgent} from "../mocks/MockAgent.sol";

/**
 * @title ZeroAllocationDeallocateTest
 * @notice Tests deallocate behavior with security fix preventing cap bypass
 * @dev SECURITY FIX: change now equals allocationDecrease (not actualAmount) to prevent
 *      accounting drift that could enable cap bypass and withdrawal DoS.
 *
 *      Key behavior changes:
 *      - Deallocating from 0-allocation strategy returns change=0
 *      - Deallocating more than allocation returns change=-allocation (capped)
 *      - This ensures VaultV2's global caps[id] decreases by actual exposure change
 */
contract ZeroAllocationDeallocateTest is Test {
    UniversalAdapterEscrow adapter;
    MockVaultV2 vault;
    MockERC20 asset;
    MockValuer valuer;

    address owner = address(0x1);
    address agent;

    bytes32 constant STRATEGY_1 = keccak256("STRATEGY_1");
    bytes32 constant STRATEGY_2 = keccak256("STRATEGY_2");

    function setUp() public {
        agent = address(new MockAgent());

        asset = new MockERC20("USDC", "USDC", 6);
        valuer = new MockValuer();
        vault = new MockVaultV2(address(asset), owner);

        adapter = new UniversalAdapterEscrow(address(vault));

        vm.startPrank(owner);
        vault.addAdapter(address(adapter));
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.setStrategy(STRATEGY_2, agent, "", 1000e6);
        vm.stopPrank();

        asset.mint(address(vault), 1000000e6);
    }

    function testDeallocateFromZeroAllocationStrategy() public {
        // SECURITY FIX: Deallocating from a strategy with 0 allocation returns change=0
        // This prevents cap bypass via accounting drift

        // Setup: Allocate to STRATEGY_1, but not STRATEGY_2
        asset.mint(address(adapter), 500e6);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 500e6, bytes4(0), address(0));

        // Verify initial state
        assertEq(adapter.getAllocation(STRATEGY_1), 500e6, "Strategy 1 should have allocation");
        assertEq(adapter.getAllocation(STRATEGY_2), 0, "Strategy 2 should have 0 allocation");

        // Add some idle/profit assets directly to the adapter
        asset.mint(address(adapter), 200e6);
        uint256 totalBalance = asset.balanceOf(address(adapter));
        assertEq(totalBalance, 700e6, "Adapter should have 700e6 total");

        // SECURITY FIX: Deallocating from STRATEGY_2 (0 allocation) returns change=0
        // The tokens can still be transferred by VaultV2, but cap accounting stays accurate
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_2, 0, new IUniversalAdapterEscrow.Call[](0)), 100e6, bytes4(0), address(0)
        );

        // change=0 because allocationDecrease=min(100e6, 0)=0
        assertEq(ids[0], STRATEGY_2, "Should return STRATEGY_2 ID");
        assertEq(change, 0, "Change should be 0 (no allocation to decrease)");
        assertEq(adapter.getAllocation(STRATEGY_2), 0, "Strategy 2 allocation should remain 0");

        console2.log("[PASS] Zero allocation returns change=0 (prevents cap bypass)");
    }

    function testDeallocateMoreThanAllocationButLessThanBalance() public {
        // SECURITY FIX: Deallocating more than allocation caps change at allocation
        // This prevents VaultV2's global caps from decreasing more than actual exposure

        // Setup: Allocate 300e6 to STRATEGY_1
        asset.mint(address(adapter), 300e6);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 300e6, bytes4(0), address(0));

        // Add profits/yield - 200e6 extra
        asset.mint(address(adapter), 200e6);
        assertEq(asset.balanceOf(address(adapter)), 500e6, "Should have 500e6 total");

        // Try to withdraw 450e6 from STRATEGY_1 (more than allocated, but less than balance)
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 450e6, bytes4(0), address(0)
        );

        // SECURITY FIX: change is capped at allocation (300e6), not requested (450e6)
        // VaultV2 will still transfer 450e6 tokens, but cap accounting is accurate
        assertEq(ids[0], STRATEGY_1, "Should return STRATEGY_1 ID");
        assertEq(change, -300e6, "Change capped at allocation (prevents cap bypass)");
        assertEq(adapter.getAllocation(STRATEGY_1), 0, "Strategy allocation should be zeroed");

        console2.log("[PASS] Change capped at allocation amount");
    }

    function testIdleAssetsAccessible() public {
        // SECURITY FIX: Idle assets can be transferred but change=0 for cap accounting

        // Add idle assets directly to adapter (simulating donations, etc.)
        asset.mint(address(adapter), 150e6);

        // Verify no allocations exist
        assertEq(adapter.totalAllocations(), 0, "Should have 0 total allocations");
        assertEq(adapter.getActiveStrategies().length, 0, "Should have 0 active strategies");
        assertEq(asset.balanceOf(address(adapter)), 150e6, "Should have 150e6 idle assets");

        // Deallocate from strategy with 0 allocation
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 100e6, bytes4(0), address(0)
        );

        // SECURITY FIX: change=0 because no allocation to decrease
        // Tokens can still be transferred by VaultV2
        assertEq(ids[0], STRATEGY_1, "Should return STRATEGY_1 ID");
        assertEq(change, 0, "Change should be 0 (no allocation)");
        assertEq(adapter.getAllocation(STRATEGY_1), 0, "Strategy should remain with 0 allocation");

        console2.log("[PASS] Idle assets accessible, change=0 for accurate cap accounting");
    }

    function testEmergencyWithdrawal() public {
        // SECURITY FIX: Emergency withdrawal from wrong strategy returns change=0

        // Setup: Normal operation with allocation
        asset.mint(address(adapter), 400e6);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 400e6, bytes4(0), address(0));

        // Add extra balance (profits/yield)
        asset.mint(address(adapter), 100e6);

        uint256 availableBalance = asset.balanceOf(address(adapter));
        assertEq(availableBalance, 500e6, "Should have 500e6 available");

        // Try emergency withdrawal from STRATEGY_2 (which has 0 allocation)
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_2, 0, new IUniversalAdapterEscrow.Call[](0)), 500e6, bytes4(0), address(0)
        );

        // SECURITY FIX: change=0 because STRATEGY_2 has 0 allocation
        // To properly withdraw, use the strategy with allocation (STRATEGY_1)
        assertEq(ids[0], STRATEGY_2, "Should return STRATEGY_2 ID");
        assertEq(change, 0, "Change should be 0 (STRATEGY_2 has no allocation)");
        assertEq(adapter.getAllocation(STRATEGY_2), 0, "STRATEGY_2 should remain 0");
        assertEq(adapter.getAllocation(STRATEGY_1), 400e6, "STRATEGY_1 allocation unchanged");
        assertEq(adapter.totalAllocations(), 400e6, "Total allocations unchanged");

        console2.log("[PASS] Wrong strategy returns change=0, use correct strategy for proper accounting");
    }

    function testProperEmergencyWithdrawalFromCorrectStrategy() public {
        // Correct approach: withdraw from the strategy that has the allocation

        // Setup: Normal operation with allocation
        asset.mint(address(adapter), 400e6);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 400e6, bytes4(0), address(0));

        // Add extra balance (profits/yield)
        asset.mint(address(adapter), 100e6);

        // Proper approach: withdraw from STRATEGY_1 which has the allocation
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)),
            500e6, // Request more than allocation
            bytes4(0),
            address(0)
        );

        // change is capped at allocation (400e6)
        assertEq(ids[0], STRATEGY_1, "Should return STRATEGY_1 ID");
        assertEq(change, -400e6, "Change capped at allocation");
        assertEq(adapter.getAllocation(STRATEGY_1), 0, "STRATEGY_1 allocation zeroed");
        assertEq(adapter.totalAllocations(), 0, "Total allocations should be 0");

        console2.log("[PASS] Proper withdrawal from correct strategy");
    }
}
