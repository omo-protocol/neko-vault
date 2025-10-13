// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

/**
 * @title UniversalAdapterEscrowManualSyncTest
 * @notice Comprehensive tests for manual sync functions (syncExternalDeposits, getGhostAmount)
 * @dev SECURITY FIX Issue #6: Manual intervention for ghost removal after large losses
 */
contract UniversalAdapterEscrowManualSyncTest is Test {
    UniversalAdapterEscrow public adapter;
    MockERC20 public asset;
    MockValuer public valuer;
    MockVault public vault;

    address public owner = address(0x1);
    address public attacker = address(0x2);

    bytes32 public strategyId = keccak256("test-strategy");

    event ExternalDepositsSynced(address indexed syncer, uint256 oldValue, uint256 newValue);

    function setUp() public {
        asset = new MockERC20("Test Token", "TEST", 18);
        valuer = new MockValuer();
        valuer.setAsset(address(asset)); // Configure valuer to transfer tokens

        // Create a mock vault to get owner
        vault = new MockVault(address(asset), owner);

        // Deploy adapter with valuer
        adapter = new UniversalAdapterEscrow(
            address(vault),
            address(valuer),
            true // useOffchainValuer
        );

        // Setup strategy
        vm.prank(owner);
        adapter.setStrategy(strategyId, owner, "", 0);

        // Whitelist a mock protocol for deposits
        vm.prank(owner);
        adapter.updateWhitelist(address(valuer), bytes4(keccak256("deposit(uint256)")), true, 0);

        // Approve valuer to pull tokens from adapter
        vm.prank(address(adapter));
        asset.approve(address(valuer), type(uint256).max);

        // Note: We don't mint tokens here - each test will mint as needed
    }

    /* ============ GHOST AMOUNT DETECTION TESTS ============ */

    /**
     * @notice Test getGhostAmount when no ghost exists (valuer reports accurate value)
     */
    function testGetGhostAmountNoGhost() public {
        // Mint and allocate 1000 tokens
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Valuer reports accurate value (no loss)
        valuer.setReturnValue(1000e18);

        uint256 ghost = adapter.getGhostAmount();
        assertEq(ghost, 0, "No ghost should exist when valuer is accurate");
    }

    /**
     * @notice Test getGhostAmount detects small ghost (5% loss)
     */
    function testGetGhostAmountSmallGhost() public {
        // Setup: Mint and allocate 1000, simulate 5% loss
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Simulate 5% slippage loss
        // minKnownValue = 1000, but valuer reports 950 (5% loss)
        // This is within 10% tolerance, so realAssets() accepts it
        // But ghost still exists: 1000 - 950 = 50
        valuer.setReturnValue(950e18);

        uint256 ghost = adapter.getGhostAmount();
        assertEq(ghost, 50e18, "Ghost should be 50e18 (5% of 1000)");

        // Verify realAssets accepts this (within tolerance)
        uint256 reportedAssets = adapter.realAssets();
        assertEq(reportedAssets, 950e18, "realAssets should accept 5% loss");
    }

    /**
     * @notice Test getGhostAmount detects large ghost (20% loss)
     */
    function testGetGhostAmountLargeGhost() public {
        // Mint and allocate 1000, simulate 20% loss (exceeds 10% tolerance)
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Valuer reports 800 (20% loss - exceeds tolerance)
        // minKnownValue = 1000
        valuer.setReturnValue(800e18);

        // Ghost should be full 200 (20% of 1000)
        uint256 ghost = adapter.getGhostAmount();
        assertEq(ghost, 200e18, "Ghost should be 200e18 (20% of 1000)");

        // Verify realAssets rejects this and uses minimum
        uint256 reportedAssets = adapter.realAssets();
        assertEq(reportedAssets, 1000e18, "realAssets should reject 20% loss and use minimum");
    }

    /**
     * @notice Test getGhostAmount with profits (no ghost)
     */
    function testGetGhostAmountWithProfits() public {
        // Mint and allocate 1000
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Valuer reports profits (1100)
        valuer.setReturnValue(1100e18);

        uint256 ghost = adapter.getGhostAmount();
        assertEq(ghost, 0, "No ghost when valuer reports profits");
    }

    /* ============ MANUAL SYNC TESTS ============ */

    /**
     * @notice Test successful sync reduces ghost amount
     */
    function testSyncExternalDepositsReducesGhost() public {
        // Setup: Mint and create 20% loss scenario
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Simulate external deposit tracking
        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(800e18)
        );

        // State: balance=200, totalExternalDeposits=800, minKnown=1000
        // Simulate 20% loss: real value is now 800 (200 balance + 600 external value)
        valuer.setReturnValue(800e18);

        // Verify ghost exists
        uint256 ghostBefore = adapter.getGhostAmount();
        assertEq(ghostBefore, 200e18, "Ghost should be 200e18 before sync");

        // Calculate correct external deposits: valuerValue - balance = 800 - 200 = 600
        uint256 correctExternalDeposits = 600e18;

        // Sync to remove ghost
        vm.expectEmit(true, false, false, true);
        emit ExternalDepositsSynced(owner, 800e18, correctExternalDeposits);

        vm.prank(owner);
        adapter.syncExternalDeposits(correctExternalDeposits);

        // Verify ghost is removed
        uint256 ghostAfter = adapter.getGhostAmount();
        assertEq(ghostAfter, 0, "Ghost should be removed after sync");

        // Verify totalExternalDeposits is updated
        assertEq(adapter.totalExternalDeposits(), correctExternalDeposits, "totalExternalDeposits should be updated");
    }

    /**
     * @notice Test sync reverts if trying to increase (security check)
     */
    function testSyncRevertsIfIncreasing() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Try to increase totalExternalDeposits (should revert)
        uint256 currentTotal = adapter.totalExternalDeposits();
        uint256 attemptedIncrease = currentTotal + 100e18;

        vm.prank(owner);
        vm.expectRevert("Can only reduce ghost");
        adapter.syncExternalDeposits(attemptedIncrease);
    }

    /**
     * @notice Test sync reverts if new value too far below valuer (safety check)
     */
    function testSyncRevertsIfTooFarBelowValuer() public {
        // Setup: Mint and allocate 1000
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Valuer reports 1000 (accurate)
        valuer.setReturnValue(1000e18);

        // State: balance=1000, totalExternalDeposits=0
        // Try to sync to a value that would create: newMinKnown = 1000 + 0 = 1000 (OK)
        // But let's try something that would be too low

        // If we set externalDeposits to 0, newMinKnown = 1000 + 0 = 1000
        // 80% of 1000 = 800, valuer=1000, so 1000 >= 800 ✓ (should pass)

        // To make it fail, we need valuer < 80% of newMinKnown
        // newMinKnown = balance + newExternal
        // For valuer=1000, we need newMinKnown > 1250 (so 80% = 1000)
        // newMinKnown = 1000 + newExternal > 1250
        // newExternal > 250

        // But we can only reduce, so this test needs different setup
        // Let's set up with external deposits first

        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(500e18)
        );

        // Now: balance=500, totalExternalDeposits=500, minKnown=1000
        // Valuer reports 1000
        valuer.setReturnValue(1000e18);

        // Try to sync to 600 (reducing from 500... wait, that's increasing!)
        // Let me recalculate: We need to REDUCE totalExternalDeposits
        // Current: 500
        // Try to set to: 100 (reducing by 400)
        // newMinKnown = 500 + 100 = 600
        // 80% of 600 = 480
        // Valuer = 1000
        // Check: 1000 >= 480 ✓ (passes)

        // To fail the check, we need valuer < 80% of newMinKnown
        // Let's make valuer report low value
        valuer.setReturnValue(400e18); // Valuer reports 400

        // Try to sync to 100
        // newMinKnown = 500 + 100 = 600
        // 80% of 600 = 480
        // Check: 400 >= 480? NO ✗ (should revert)

        vm.prank(owner);
        vm.expectRevert("New value too low vs valuer");
        adapter.syncExternalDeposits(100e18);
    }

    /**
     * @notice Test sync reverts when paused
     */
    function testSyncRevertsWhenPaused() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Pause adapter
        vm.prank(owner);
        adapter.setPaused(true);

        // Try to sync (should revert)
        vm.prank(owner);
        vm.expectRevert("Paused");
        adapter.syncExternalDeposits(0);
    }

    /**
     * @notice Test sync reverts when not owner
     */
    function testSyncRevertsWhenNotOwner() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Try to sync as attacker (should revert)
        vm.prank(attacker);
        vm.expectRevert(); // Will revert with NotAuthorized
        adapter.syncExternalDeposits(0);
    }

    /**
     * @notice Test sync works at boundary (20% below valuer)
     */
    function testSyncAtBoundary() public {
        // Setup with external deposits
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(500e18)
        );

        // State: balance=500, totalExternalDeposits=500, minKnown=1000
        // Valuer reports 1000
        valuer.setReturnValue(1000e18);

        // Sync to create newMinKnown exactly at 80% of valuer
        // 80% of 1000 = 800
        // newMinKnown = balance + newExternal = 500 + newExternal = 800
        // newExternal = 300

        vm.prank(owner);
        adapter.syncExternalDeposits(300e18); // Should succeed (exactly at boundary)

        assertEq(adapter.totalExternalDeposits(), 300e18, "Should accept value at 80% boundary");
    }

    /**
     * @notice Test multiple syncs to gradually reduce ghost
     */
    function testMultipleSyncs() public {
        // Setup with large ghost
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(800e18)
        );

        // Simulate 30% loss (800 → 560)
        // State: balance=200, totalExternalDeposits=800, real external value=560
        valuer.setReturnValue(760e18); // 200 + 560 = 760

        uint256 ghostBefore = adapter.getGhostAmount();
        assertEq(ghostBefore, 240e18, "Initial ghost should be 240e18");

        // First sync: reduce by half
        vm.prank(owner);
        adapter.syncExternalDeposits(680e18); // Reduce ghost partially

        uint256 ghostMiddle = adapter.getGhostAmount();
        assertEq(ghostMiddle, 120e18, "Ghost should be halved");

        // Second sync: remove completely
        vm.prank(owner);
        adapter.syncExternalDeposits(560e18); // Remove remaining ghost

        uint256 ghostAfter = adapter.getGhostAmount();
        assertEq(ghostAfter, 0, "Ghost should be completely removed");
    }

    /**
     * @notice Test sync to zero (complete removal)
     */
    function testSyncToZero() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Valuer reports accurate value (balance only, no external)
        valuer.setReturnValue(1000e18);

        // Sync to zero (all external deposits were actually losses)
        vm.prank(owner);
        adapter.syncExternalDeposits(0);

        assertEq(adapter.totalExternalDeposits(), 0, "totalExternalDeposits should be zero");
        assertEq(adapter.getGhostAmount(), 0, "No ghost should exist");
    }

    /**
     * @notice Fuzz test: syncExternalDeposits always reduces or maintains ghost
     */
    function testFuzzSyncAlwaysReducesGhost(uint256 initialExternal, uint256 newExternal) public {
        // Bound inputs
        initialExternal = bound(initialExternal, 100e18, 1000e18);
        newExternal = bound(newExternal, 0, initialExternal); // Can only reduce

        // Setup
        uint256 allocation = initialExternal + 200e18; // Allocate more than external
        asset.mint(address(adapter), allocation);

        bytes memory allocateData = abi.encode(strategyId, allocation, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, allocation, bytes4(0), address(0));

        // Manually set totalExternalDeposits for testing
        // (In reality this would be set by executeStrategy)
        vm.store(
            address(adapter),
            bytes32(uint256(6)), // totalExternalDeposits storage slot
            bytes32(initialExternal)
        );

        // Set valuer to report less than minimum (create ghost)
        uint256 balance = asset.balanceOf(address(adapter));
        uint256 minKnown = balance + initialExternal;
        valuer.setReturnValue((minKnown * 8) / 10); // 80% of minimum

        uint256 ghostBefore = adapter.getGhostAmount();

        // Sync
        vm.prank(owner);
        adapter.syncExternalDeposits(newExternal);

        uint256 ghostAfter = adapter.getGhostAmount();

        // Ghost should never increase after sync
        assertLe(ghostAfter, ghostBefore, "Ghost should not increase after sync");
    }

    /* ============ HELPER FUNCTIONS ============ */

    function _createDepositCall(uint256 amount) internal view returns (IUniversalAdapterEscrow.Call[] memory) {
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(valuer),
            data: abi.encodeWithSignature("deposit(uint256)", amount),
            value: 0
        });
        return calls;
    }
}

/**
 * @notice Mock valuer that can return arbitrary values and simulate deposits
 */
contract MockValuer {
    uint256 public returnValue;
    mapping(uint256 => uint256) public deposits;
    address public asset;

    function setAsset(address _asset) external {
        asset = _asset;
    }

    function setReturnValue(uint256 _value) external {
        returnValue = _value;
    }

    function getTotalValue(address) external view returns (uint256) {
        return returnValue;
    }

    function getValue(bytes32) external view returns (uint256) {
        return returnValue;
    }

    // Mock deposit function that transfers tokens to simulate external deposit
    function deposit(uint256 amount) external {
        deposits[amount] = amount;
        // Transfer tokens from caller to simulate external protocol receiving them
        if (asset != address(0)) {
            // This will cause the adapter's balance to decrease
            // which is what executeStrategy tracks
            MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        }
    }
}

/**
 * @notice Mock vault for testing
 */
contract MockVault {
    address public asset;
    address public owner;

    constructor(address _asset, address _owner) {
        asset = _asset;
        owner = _owner;
    }
}
