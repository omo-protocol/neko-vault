// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/valuers/UniversalValuerOffchain.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";
import "../../src/VaultV2.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IUniversalValuerOffchain} from "../../src/adapters/interfaces/IUniversalValuerOffchain.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract UniversalValuerOffchainWithAdapterTest is Test {
    UniversalValuerOffchain valuer;
    UniversalAdapterEscrow adapter;
    VaultV2 vault;
    MockERC20 asset;

    address owner = address(0x1);
    address agent = address(0x2);
    bytes32 strategyId = keccak256("test-strategy");

    function setUp() public {
        // Deploy mock asset
        asset = new MockERC20("Test Token", "TEST", 18);

        // Deploy vault as owner
        vm.startPrank(owner);
        vault = new VaultV2(owner, address(asset));

        // Deploy valuer as owner (still as owner)
        valuer = new UniversalValuerOffchain(owner, address(asset));
        vm.stopPrank();

        // Deploy adapter (parentVault should be set during construction)
        adapter = new UniversalAdapterEscrow(address(vault), address(valuer), false);

        // Add adapter to vault and set permissions
        vm.startPrank(owner);
        vault.setCurator(owner);

        // Submit and execute addAdapter through timelock
        bytes memory addAdapterCall = abi.encodeWithSelector(vault.addAdapter.selector, address(adapter));
        vault.submit(addAdapterCall);

        // Fast forward past timelock if needed (default is 0 for owner)
        vm.warp(block.timestamp + 1);

        // Execute the addAdapter call
        vault.addAdapter(address(adapter));
        vm.stopPrank();

        // Configure strategy - the owner sets strategies (not the vault)
        vm.prank(owner);
        adapter.setStrategy(strategyId, agent, "", 1000e18);
    }

    function test_GetActiveStrategiesIntegration() public {
        // Get active strategies from adapter (should be empty before allocation)
        bytes32[] memory strategies = adapter.getActiveStrategies();
        assertEq(strategies.length, 0, "No active strategies before allocation");

        // Now allocate some funds to make the strategy active
        asset.mint(address(vault), 100e18);

        vm.startPrank(owner);
        // Need to set up allocator role through timelock
        bytes memory setAllocatorCall = abi.encodeWithSelector(vault.setIsAllocator.selector, owner, true);
        vault.submit(setAllocatorCall);
        vm.warp(block.timestamp + 1);
        vault.setIsAllocator(owner, true);

        // Set caps for the strategy ID - use the original string
        // The vault will hash this to get the same ID the adapter returns
        bytes memory idData = bytes("test-strategy");
        bytes memory setAbsCapCall = abi.encodeWithSelector(vault.increaseAbsoluteCap.selector, idData, 1000e18);
        vault.submit(setAbsCapCall);
        vm.warp(block.timestamp + 1);
        vault.increaseAbsoluteCap(idData, 1000e18);

        bytes memory setRelCapCall = abi.encodeWithSelector(vault.increaseRelativeCap.selector, idData, 1e18);
        vault.submit(setRelCapCall);
        vm.warp(block.timestamp + 1);
        vault.increaseRelativeCap(idData, 1e18);

        // Prepare allocation data
        bytes memory allocData = abi.encode(
            strategyId,
            100e18,
            false, // don't execute now
            new IUniversalAdapterEscrow.Call[](0)
        );

        // Allocate funds to the strategy
        vault.allocate(address(adapter), allocData, 100e18);
        vm.stopPrank();

        // Now check active strategies
        strategies = adapter.getActiveStrategies();
        assertEq(strategies.length, 1, "One active strategy after allocation");
        assertEq(strategies[0], strategyId, "Correct strategy ID");
    }

    function test_GetTotalValueCallsAdapter() public view {
        // This tests that getTotalValue can call the adapter's getActiveStrategies
        // Without reverting due to interface issues
        uint256 totalValue = valuer.getTotalValue(address(adapter));

        // Should return 0 since no value reports or assets
        assertEq(totalValue, 0);
    }

    function test_GetTotalValueWithIdleAssets() public {
        // Give adapter some idle assets
        asset.mint(address(adapter), 100e18);

        // Get total value
        uint256 totalValue = valuer.getTotalValue(address(adapter));

        // Should return idle assets since no value reports
        assertEq(totalValue, 100e18);
    }

    function test_GetTotalValueWithNonAdapter() public {
        // Deploy a simple contract that's not an adapter
        MockERC20 notAnAdapter = new MockERC20("NotAdapter", "NAD", 18);

        // Try with a contract that doesn't implement IUniversalAdapterEscrow
        // The try-catch in _getActiveStrategies will return empty array
        uint256 totalValue = valuer.getTotalValue(address(notAnAdapter));

        // Should return 0 (no strategies, no balance in asset token)
        assertEq(totalValue, 0, "Non-adapter returns 0 value");
    }

    function test_RemoveStrategyUpdatesActiveList() public {
        // First allocate funds to make strategy active
        asset.mint(address(vault), 100e18);

        vm.startPrank(owner);
        // Set allocator role through timelock
        bytes memory setAllocatorCall = abi.encodeWithSelector(vault.setIsAllocator.selector, owner, true);
        vault.submit(setAllocatorCall);
        vm.warp(block.timestamp + 1);
        vault.setIsAllocator(owner, true);

        // Set caps for the strategy ID - use the original string
        // The vault will hash this to get the same ID the adapter returns
        bytes memory idData = bytes("test-strategy");
        bytes memory setAbsCapCall = abi.encodeWithSelector(vault.increaseAbsoluteCap.selector, idData, 1000e18);
        vault.submit(setAbsCapCall);
        vm.warp(block.timestamp + 1);
        vault.increaseAbsoluteCap(idData, 1000e18);

        bytes memory setRelCapCall = abi.encodeWithSelector(vault.increaseRelativeCap.selector, idData, 1e18);
        vault.submit(setRelCapCall);
        vm.warp(block.timestamp + 1);
        vault.increaseRelativeCap(idData, 1e18);

        bytes memory allocData = abi.encode(
            strategyId,
            100e18,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );
        vault.allocate(address(adapter), allocData, 100e18);

        // Verify strategy is active
        bytes32[] memory strategies = adapter.getActiveStrategies();
        assertEq(strategies.length, 1, "One active strategy after allocation");

        // First deallocate funds (can't remove strategy with allocation)
        bytes memory deallocData = abi.encode(
            strategyId,
            0,
            false,
            new IUniversalAdapterEscrow.Call[](0) // No withdrawal calls needed
        );
        vault.deallocate(address(adapter), deallocData, 100e18);

        // Now remove the strategy
        adapter.removeStrategy(strategyId);
        vm.stopPrank();

        // Verify no active strategies
        strategies = adapter.getActiveStrategies();
        assertEq(strategies.length, 0, "No active strategies after removal");

        // Valuer should handle empty strategy list
        uint256 totalValue = valuer.getTotalValue(address(adapter));
        assertEq(totalValue, 0, "Total value is 0 after strategy removal");
    }
}