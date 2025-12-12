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

        // SECURITY FIX Issue #1 (FIXING_ISSUES.md): Now reverts instead of returning empty
        // This prevents gas-manipulation attacks where attacker uses low gas to cause
        // getActiveStrategies() to fail and manipulate share price
        vm.expectRevert("StrategyEnumerationFailed");
        valuer.getTotalValue(address(notAnAdapter));
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

    /* SECURITY FIX: getValue(ESCROW_TOTAL_ID) INTEGRATION TESTS */

    /// @notice Test that getValue(ESCROW_TOTAL_ID) returns the same value as getTotalValue(escrow)
    /// This is the core fix for the API mismatch between UniversalAdapterEscrow and UniversalValuerOffchain
    function test_getValue_EscrowTotalId_EqualsGetTotalValue() public {
        // Compute the ESCROW_TOTAL ID for the adapter
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));

        // Register the ESCROW_TOTAL ID (this is what the adapter does in constructor when useOffchainValuer=true)
        vm.prank(address(adapter));
        valuer.registerEscrowTotal(escrowTotalId);

        // Give adapter some idle assets
        asset.mint(address(adapter), 100e18);

        // Both functions should return the same value
        uint256 valueViaGetValue = valuer.getValue(escrowTotalId);
        uint256 valueViaGetTotalValue = valuer.getTotalValue(address(adapter));

        assertEq(valueViaGetValue, valueViaGetTotalValue, "getValue(ESCROW_TOTAL_ID) should equal getTotalValue(escrow)");
        assertEq(valueViaGetValue, 100e18, "Should return idle balance");
    }

    /// @notice Test getValue(ESCROW_TOTAL_ID) returns aggregated strategy values plus idle balance
    function test_getValue_EscrowTotalId_ReturnsAggregatedValue() public {
        // Setup signer
        uint256 signerKey = 0x1234;
        address signer = vm.addr(signerKey);

        vm.startPrank(owner);
        valuer.initiateSignerChange(signer, true, 100);
        valuer.setRequiredWeight(100);
        vm.stopPrank();

        // Compute and register the ESCROW_TOTAL ID
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));
        vm.prank(address(adapter));
        valuer.registerEscrowTotal(escrowTotalId);

        // Allocate funds to make the strategy active
        asset.mint(address(vault), 100e18);

        vm.startPrank(owner);
        bytes memory setAllocatorCall = abi.encodeWithSelector(vault.setIsAllocator.selector, owner, true);
        vault.submit(setAllocatorCall);
        vm.warp(block.timestamp + 1);
        vault.setIsAllocator(owner, true);

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
        vm.stopPrank();

        // Update the strategy value in the valuer
        bytes32 hash = keccak256(abi.encode(
            strategyId,
            500e18, // value
            95,     // confidence
            1,      // nonce
            block.timestamp + 1 hours, // expiry
            block.chainid,
            address(valuer)
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            hash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedHash);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);

        valuer.updateValue(strategyId, 500e18, 95, 1, block.timestamp + 1 hours, signatures);

        // Get idle balance in adapter
        uint256 idleBalance = asset.balanceOf(address(adapter));

        // getValue(ESCROW_TOTAL_ID) should return strategy value + idle balance
        uint256 totalValue = valuer.getValue(escrowTotalId);
        assertEq(totalValue, 500e18 + idleBalance, "Should return strategy value + idle balance");
    }

    /// @notice Test that unregistered ESCROW_TOTAL IDs still revert (security)
    function test_getValue_UnregisteredEscrowTotalId_RevertsValueTooStale() public {
        // Compute ESCROW_TOTAL ID but don't register it
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));

        // Should revert because it's not registered (treated as regular strategy ID with no report)
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.getValue(escrowTotalId);
    }

    /// @notice Test getValue(ESCROW_TOTAL_ID) returns idle balance when all strategies are stale
    function test_getValue_EscrowTotalId_ReturnsIdleBalanceWhenAllStale() public {
        // Setup signer
        uint256 signerKey = 0x1234;
        address signer = vm.addr(signerKey);

        vm.startPrank(owner);
        valuer.initiateSignerChange(signer, true, 100);
        valuer.setRequiredWeight(100);
        vm.stopPrank();

        // Register ESCROW_TOTAL ID
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));
        vm.prank(address(adapter));
        valuer.registerEscrowTotal(escrowTotalId);

        // Allocate funds to make strategy active
        asset.mint(address(vault), 100e18);

        vm.startPrank(owner);
        bytes memory setAllocatorCall = abi.encodeWithSelector(vault.setIsAllocator.selector, owner, true);
        vault.submit(setAllocatorCall);
        vm.warp(block.timestamp + 1);
        vault.setIsAllocator(owner, true);

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
        vm.stopPrank();

        // Update strategy value
        bytes32 hash = keccak256(abi.encode(
            strategyId,
            500e18,
            95,
            1,
            block.timestamp + 1 hours,
            block.chainid,
            address(valuer)
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            hash
        ));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedHash);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);

        valuer.updateValue(strategyId, 500e18, 95, 1, block.timestamp + 1 hours, signatures);

        // Fast forward past ABSOLUTE_MAX_STALENESS (48 hours)
        vm.warp(block.timestamp + 49 hours);

        // Get idle balance in adapter
        uint256 idleBalance = asset.balanceOf(address(adapter));

        // getValue(ESCROW_TOTAL_ID) should return just idle balance since strategy value is stale
        uint256 totalValue = valuer.getValue(escrowTotalId);
        assertEq(totalValue, idleBalance, "Should return only idle balance when strategies are stale");
    }
}