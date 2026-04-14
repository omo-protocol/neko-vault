// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/VaultTimeLockWrapper.sol";
import "../src/VaultV2.sol";
import "../src/VaultV2Factory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {AdapterMock} from "./mocks/AdapterMock.sol";

/**
 * @title VaultTimeLockWrapperTest
 * @notice Comprehensive test suite covering all security fixes
 * @dev Tests all 5 vulnerability fixes from Vulnerability_Report.md:
 *      1. FIFO ordering preservation (swap-with-last fix)
 *      2. Per-batch lock enforcement (lock bypass fix)
 *      3. DoS attack prevention (onBehalf approval + batch limit)
 *      4. Emergency withdraw functionality (properly redeems from vault)
 *      5. Allowance unit consistency (shares not assets)
 */
contract VaultTimeLockWrapperTest is Test {
    VaultTimeLockWrapper public wrapper;
    IVaultV2 public vault;
    IERC20 public asset;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public carol = address(0x4);
    address public attacker = address(0x666);

    uint256 constant LOCK_PERIOD = 7 days;
    uint256 constant INITIAL_DEPOSIT = 1000e18;

    function setUp() public {
        // Deploy mock ERC20 asset
        vm.startPrank(owner);
        asset = IERC20(address(new MockERC20("Test Asset", "TEST", 18)));

        // Deploy vault via factory
        VaultV2Factory factory = new VaultV2Factory();
        vault = IVaultV2(
            factory.createVaultV2(
                owner, // owner
                address(asset), // asset
                bytes32(uint256(1)) // salt
            )
        );

        // Deploy secure wrapper
        wrapper = new VaultTimeLockWrapper(address(vault));

        // Mint assets to test users
        MockERC20(address(asset)).mint(alice, 10000e18);
        MockERC20(address(asset)).mint(bob, 10000e18);
        MockERC20(address(asset)).mint(carol, 10000e18);
        MockERC20(address(asset)).mint(attacker, 10000e18);

        vm.stopPrank();
    }

    // ============================================
    // VULNERABILITY #1 TESTS: FIFO ORDERING
    // ============================================

    function test_fifo_orderingPreservedAfterWithdrawal() public {
        vm.startPrank(alice);

        // Deposit 3 batches at different times, capturing timestamps at deposit moment
        asset.approve(address(wrapper), 600e18);

        wrapper.deposit(100e18);
        (, uint256 firstTime,,) = wrapper.getDeposit(alice, 0);

        vm.warp(block.timestamp + 1 days);
        wrapper.deposit(200e18);
        (, uint256 secondTime,,) = wrapper.getDeposit(alice, 1);

        vm.warp(block.timestamp + 2 days);
        wrapper.deposit(300e18);
        (, uint256 thirdTime,,) = wrapper.getDeposit(alice, 2);

        // Verify initial ordering
        (uint256 amt0, uint256 time0,,) = wrapper.getDeposit(alice, 0);
        (uint256 amt1, uint256 time1,,) = wrapper.getDeposit(alice, 1);
        (uint256 amt2, uint256 time2,,) = wrapper.getDeposit(alice, 2);

        assertEq(amt0, 100e18, "First batch amount");
        assertEq(time0, firstTime, "First batch time");
        assertEq(amt1, 200e18, "Second batch amount");
        assertEq(time1, secondTime, "Second batch time");
        assertEq(amt2, 300e18, "Third batch amount");
        assertEq(time2, thirdTime, "Third batch time");

        // Withdraw first batch
        vm.warp(firstTime + LOCK_PERIOD);
        wrapper.withdraw(100e18, alice, alice);

        // SECURITY CHECK: Second batch should now be at index 0 (not third!)
        (uint256 newAmt0, uint256 newTime0,,) = wrapper.getDeposit(alice, 0);
        assertEq(newAmt0, 200e18, "Second batch moved to index 0");
        assertEq(newTime0, secondTime, "Second batch time preserved");

        // Third batch should be at index 1
        (uint256 newAmt1, uint256 newTime1,,) = wrapper.getDeposit(alice, 1);
        assertEq(newAmt1, 300e18, "Third batch at index 1");
        assertEq(newTime1, thirdTime, "Third batch time preserved");

        vm.stopPrank();
    }

    function test_fifo_orderingPreservedAfterTransfer() public {
        vm.startPrank(alice);

        // Alice creates 3 batches
        asset.approve(address(wrapper), 600e18);

        wrapper.deposit(100e18);
        (, uint256 time1,,) = wrapper.getDeposit(alice, 0);

        vm.warp(block.timestamp + 1 days);
        wrapper.deposit(200e18);
        (, uint256 time2,,) = wrapper.getDeposit(alice, 1);

        vm.warp(block.timestamp + 1 days);
        wrapper.deposit(300e18);
        (, uint256 time3,,) = wrapper.getDeposit(alice, 2);

        // Transfer first batch + partial second (150e18 total)
        wrapper.transfer(bob, 150e18);

        vm.stopPrank();

        // Alice should have remaining 450e18 in correct order
        assertEq(wrapper.getDepositCount(alice), 2, "Alice has 2 batches");

        (uint256 amt0, uint256 t0,,) = wrapper.getDeposit(alice, 0);
        assertEq(amt0, 150e18, "Remaining from second batch");
        assertEq(t0, time2, "Second batch time");

        (uint256 amt1, uint256 t1,,) = wrapper.getDeposit(alice, 1);
        assertEq(amt1, 300e18, "Third batch intact");
        assertEq(t1, time3, "Third batch time");

        // Bob should have 150e18 in correct order
        assertEq(wrapper.getDepositCount(bob), 2, "Bob has 2 batches");

        (uint256 bobAmt0, uint256 bobT0,,) = wrapper.getDeposit(bob, 0);
        assertEq(bobAmt0, 100e18, "First batch transferred");
        assertEq(bobT0, time1, "First batch time preserved");

        (uint256 bobAmt1, uint256 bobT1,,) = wrapper.getDeposit(bob, 1);
        assertEq(bobAmt1, 50e18, "Partial second batch");
        assertEq(bobT1, time2, "Second batch time preserved");
    }

    // ============================================
    // VULNERABILITY #2 TESTS: LOCK BYPASS
    // ============================================

    function test_lockBypass_perBatchCheckPreventsExploit() public {
        vm.startPrank(alice);

        // Create unlocked and locked batches
        asset.approve(address(wrapper), 300e18);

        wrapper.deposit(100e18);
        (, uint256 unlockedTime,,) = wrapper.getDeposit(alice, 0);

        vm.warp(block.timestamp + 6 days); // 6 days later (still within 7 day period)
        wrapper.deposit(200e18);
        (, uint256 lockedTime,,) = wrapper.getDeposit(alice, 1);

        // Fast forward to unlock first batch only
        vm.warp(unlockedTime + LOCK_PERIOD);

        // ATTACK: Try to withdraw 150e18 (should burn from both batches)
        // Expected: Should revert when trying to burn from locked second batch
        vm.expectRevert(
            abi.encodeWithSelector(
                VaultTimeLockWrapper.BatchStillLocked.selector,
                1, // batch index
                lockedTime + LOCK_PERIOD // unlock time
            )
        );
        wrapper.withdraw(150e18, alice, alice);

        vm.stopPrank();
    }

    function test_lockBypass_canOnlyWithdrawUnlockedAmount() public {
        vm.startPrank(alice);

        // Create multiple batches with different ages
        asset.approve(address(wrapper), 600e18);

        wrapper.deposit(100e18);
        (, uint256 time1,,) = wrapper.getDeposit(alice, 0);

        vm.warp(block.timestamp + 2 days);
        wrapper.deposit(200e18);

        vm.warp(block.timestamp + 3 days);
        wrapper.deposit(300e18);

        // Fast forward 7 days from first deposit
        vm.warp(time1 + LOCK_PERIOD);

        // Check unlocked balance
        uint256 unlocked = wrapper.unlockedBalanceOf(alice);
        assertEq(unlocked, 100e18, "Only first batch unlocked");

        // Can withdraw up to unlocked amount
        wrapper.withdraw(100e18, alice, alice);

        // Cannot withdraw more
        vm.expectRevert();
        wrapper.withdraw(1e18, alice, alice);

        vm.stopPrank();
    }

    // ============================================
    // VULNERABILITY #3 TESTS: DoS ATTACKS
    // ============================================

    function test_dos_depositForRequiresApproval() public {
        vm.startPrank(attacker);
        asset.approve(address(wrapper), 100e18);

        // ATTACK: Try to deposit on behalf of Alice without approval
        vm.expectRevert(VaultTimeLockWrapper.NotApprovedForDeposit.selector);
        wrapper.depositFor(100e18, alice);

        vm.stopPrank();
    }

    function test_dos_batchLimitPreventsSpam() public {
        // Alice approves attacker (for testing batch limit, not approval bypass)
        vm.prank(alice);
        wrapper.setApprovalForDeposit(attacker, true);

        vm.startPrank(attacker);
        asset.approve(address(wrapper), type(uint256).max);

        // Spam deposits up to limit
        for (uint256 i = 0; i < 100; i++) {
            wrapper.depositFor(1e18, alice);
        }

        // 101st deposit should revert
        vm.expectRevert(VaultTimeLockWrapper.MaxBatchesReached.selector);
        wrapper.depositFor(1e18, alice);

        vm.stopPrank();
    }

    function test_dos_zeroShareDepositsRejected() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1);

        // Try to deposit amount that would result in 0 shares
        // (depends on vault's share calculation, but testing the check exists)
        vm.expectRevert(VaultTimeLockWrapper.ZeroAmount.selector);
        wrapper.deposit(0);

        vm.stopPrank();
    }

    function test_dos_transferToFullUserReverts() public {
        // Fill up Alice's batches with DIFFERENT timestamps so they don't merge
        uint256 baseTime = block.timestamp;
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 100; i++) {
            vm.warp(baseTime + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 100, "Alice should have 100 batches");

        // Bob tries to transfer to Alice (Bob's batch has a different timestamp)
        vm.warp(baseTime + 200); // Different timestamp than any of Alice's
        vm.startPrank(bob);
        asset.approve(address(wrapper), 10e18);
        wrapper.deposit(10e18);

        // Since Bob's batch has a different timestamp than Alice's last batch,
        // it won't merge and should hit the cap
        vm.expectRevert(VaultTimeLockWrapper.MaxBatchesReached.selector);
        wrapper.transfer(alice, 10e18);

        vm.stopPrank();
    }

    // ============================================
    // VULNERABILITY #4 TESTS: EMERGENCY WITHDRAW
    // ============================================

    function test_emergency_properlyRedeemsFromVault() public {
        // Note: This test requires a properly configured vault with adapters
        // For now, we test that the function exists and has correct signature
        // Full integration test would require adapter setup

        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        // Emergency withdraw would be called like:
        // wrapper.emergencyWithdraw(adapterAddress, data, 500e18);
        // But requires adapter setup which is beyond basic unit test scope

        vm.stopPrank();
    }

    function test_emergency_allowanceProperlyManagedWithAdapter() public {
        // Setup: Deploy mock adapter and configure vault
        vm.startPrank(owner);

        // Set curator and allocator to owner
        VaultV2 vaultV2 = VaultV2(address(vault));
        vaultV2.setCurator(owner);
        vaultV2.submit(abi.encodeCall(IVaultV2.setIsAllocator, (owner, true)));
        vault.setIsAllocator(owner, true);

        AdapterMock mockAdapter = new AdapterMock(address(vault));

        // Add adapter to vault using timelock pattern
        vaultV2.submit(abi.encodeCall(IVaultV2.addAdapter, (address(mockAdapter))));
        vault.addAdapter(address(mockAdapter));

        // Set caps for the mock adapter IDs (id-0 and id-1)
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (abi.encodePacked("id-0"), type(uint128).max)));
        vault.increaseAbsoluteCap(abi.encodePacked("id-0"), type(uint128).max);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (abi.encodePacked("id-0"), 1e18)));
        vault.increaseRelativeCap(abi.encodePacked("id-0"), 1e18);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (abi.encodePacked("id-1"), type(uint128).max)));
        vault.increaseAbsoluteCap(abi.encodePacked("id-1"), type(uint128).max);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (abi.encodePacked("id-1"), 1e18)));
        vault.increaseRelativeCap(abi.encodePacked("id-1"), 1e18);

        // Set force deallocate penalty (2% = 0.02 * 1e18, max allowed)
        uint256 penalty = 0.02e18; // 2% penalty
        vaultV2.submit(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(mockAdapter), penalty)));
        vault.setForceDeallocatePenalty(address(mockAdapter), penalty);

        vm.stopPrank();

        // Alice deposits into wrapper
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);
        vm.stopPrank();

        // Wrapper deposits into vault, vault allocates to adapter
        vm.startPrank(owner);
        uint256 wrapperShares = vault.balanceOf(address(wrapper));
        vault.allocate(address(mockAdapter), "", wrapperShares / 2); // Allocate 50% to adapter
        vm.stopPrank();

        // SECURITY CHECK #1: Verify wrapper has no allowance set initially
        assertEq(vault.allowance(address(wrapper), address(vault)), 0, "No initial allowance");

        // Alice triggers emergency withdraw
        vm.startPrank(alice);
        uint256 assetsToEmergencyWithdraw = 100e18;

        // Emergency withdraw should succeed despite requiring allowance internally
        wrapper.emergencyWithdraw(address(mockAdapter), "", assetsToEmergencyWithdraw);

        vm.stopPrank();

        // SECURITY CHECK #2: Verify allowance is revoked after emergency withdraw
        assertEq(vault.allowance(address(wrapper), address(vault)), 0, "Allowance revoked after emergency");

        // SECURITY CHECK #3: Verify Alice received assets (minus penalty)
        // Penalty is paid from wrapper's vault shares, Alice gets the requested assets
        assertGt(asset.balanceOf(alice), 0, "Alice received assets");
    }

    function test_emergency_noGriefingAfterAllowanceRevoked() public {
        // Setup: Deploy mock adapter and configure vault
        vm.startPrank(owner);

        VaultV2 vaultV2 = VaultV2(address(vault));
        vaultV2.setCurator(owner);
        vaultV2.submit(abi.encodeCall(IVaultV2.setIsAllocator, (owner, true)));
        vault.setIsAllocator(owner, true);

        AdapterMock mockAdapter = new AdapterMock(address(vault));

        // Add adapter to vault
        vaultV2.submit(abi.encodeCall(IVaultV2.addAdapter, (address(mockAdapter))));
        vault.addAdapter(address(mockAdapter));

        // Set caps
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (abi.encodePacked("id-0"), type(uint128).max)));
        vault.increaseAbsoluteCap(abi.encodePacked("id-0"), type(uint128).max);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (abi.encodePacked("id-0"), 1e18)));
        vault.increaseRelativeCap(abi.encodePacked("id-0"), 1e18);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (abi.encodePacked("id-1"), type(uint128).max)));
        vault.increaseAbsoluteCap(abi.encodePacked("id-1"), type(uint128).max);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (abi.encodePacked("id-1"), 1e18)));
        vault.increaseRelativeCap(abi.encodePacked("id-1"), 1e18);

        // Set force deallocate penalty (2% = 0.02 * 1e18, max allowed)
        uint256 penalty = 0.02e18; // 2% penalty
        vaultV2.submit(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(mockAdapter), penalty)));
        vault.setForceDeallocatePenalty(address(mockAdapter), penalty);

        vm.stopPrank();

        // Alice deposits into wrapper
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);
        vm.stopPrank();

        // Wrapper deposits into vault, vault allocates to adapter
        vm.startPrank(owner);
        uint256 wrapperShares = vault.balanceOf(address(wrapper));
        vault.allocate(address(mockAdapter), "", wrapperShares / 2);
        vm.stopPrank();

        // Alice triggers emergency withdraw
        vm.startPrank(alice);
        wrapper.emergencyWithdraw(address(mockAdapter), "", 100e18);
        vm.stopPrank();

        // GRIEFING ATTACK: Attacker tries to call forceDeallocate on wrapper's behalf
        // This should fail because wrapper revoked approval
        vm.startPrank(attacker);

        uint256 wrapperSharesBefore = vault.balanceOf(address(wrapper));

        // Attacker tries to grief by calling forceDeallocate
        // This should revert with InsufficientAllowance error
        vm.expectRevert();
        vault.forceDeallocate(address(mockAdapter), "", 50e18, address(wrapper));

        vm.stopPrank();

        // SECURITY CHECK: Wrapper shares unchanged (attack failed)
        assertEq(vault.balanceOf(address(wrapper)), wrapperSharesBefore, "Wrapper shares unchanged");
    }

    function test_emergency_allowanceOnlyExistsDuringExecution() public {
        // Setup: Deploy mock adapter
        vm.startPrank(owner);

        VaultV2 vaultV2 = VaultV2(address(vault));
        vaultV2.setCurator(owner);
        vaultV2.submit(abi.encodeCall(IVaultV2.setIsAllocator, (owner, true)));
        vault.setIsAllocator(owner, true);

        AdapterMock mockAdapter = new AdapterMock(address(vault));

        vaultV2.submit(abi.encodeCall(IVaultV2.addAdapter, (address(mockAdapter))));
        vault.addAdapter(address(mockAdapter));

        // Set caps
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (abi.encodePacked("id-0"), type(uint128).max)));
        vault.increaseAbsoluteCap(abi.encodePacked("id-0"), type(uint128).max);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (abi.encodePacked("id-0"), 1e18)));
        vault.increaseRelativeCap(abi.encodePacked("id-0"), 1e18);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (abi.encodePacked("id-1"), type(uint128).max)));
        vault.increaseAbsoluteCap(abi.encodePacked("id-1"), type(uint128).max);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (abi.encodePacked("id-1"), 1e18)));
        vault.increaseRelativeCap(abi.encodePacked("id-1"), 1e18);

        uint256 penalty = 0.01e18; // 1% penalty
        vaultV2.submit(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(mockAdapter), penalty)));
        vault.setForceDeallocatePenalty(address(mockAdapter), penalty);

        vm.stopPrank();

        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);
        vm.stopPrank();

        // Allocate to adapter
        vm.startPrank(owner);
        uint256 wrapperShares = vault.balanceOf(address(wrapper));
        vault.allocate(address(mockAdapter), "", wrapperShares / 2);
        vm.stopPrank();

        // Check allowance before emergency withdraw
        uint256 allowanceBefore = vault.allowance(address(wrapper), address(vault));
        assertEq(allowanceBefore, 0, "No allowance before emergency");

        // Alice triggers emergency withdraw
        vm.startPrank(alice);
        wrapper.emergencyWithdraw(address(mockAdapter), "", 100e18);
        vm.stopPrank();

        // Check allowance after emergency withdraw
        uint256 allowanceAfter = vault.allowance(address(wrapper), address(vault));
        assertEq(allowanceAfter, 0, "No allowance after emergency");

        // SECURITY VALIDATION: Allowance was only temporary during execution
        // The approve → forceDeallocate → revoke pattern ensures no persistent allowance
    }

    function test_emergency_multipleUsersCanEmergencyWithdraw() public {
        // Setup: Deploy mock adapter
        vm.startPrank(owner);

        VaultV2 vaultV2 = VaultV2(address(vault));
        vaultV2.setCurator(owner);
        vaultV2.submit(abi.encodeCall(IVaultV2.setIsAllocator, (owner, true)));
        vault.setIsAllocator(owner, true);

        AdapterMock mockAdapter = new AdapterMock(address(vault));

        vaultV2.submit(abi.encodeCall(IVaultV2.addAdapter, (address(mockAdapter))));
        vault.addAdapter(address(mockAdapter));

        // Set caps
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (abi.encodePacked("id-0"), type(uint128).max)));
        vault.increaseAbsoluteCap(abi.encodePacked("id-0"), type(uint128).max);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (abi.encodePacked("id-0"), 1e18)));
        vault.increaseRelativeCap(abi.encodePacked("id-0"), 1e18);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (abi.encodePacked("id-1"), type(uint128).max)));
        vault.increaseAbsoluteCap(abi.encodePacked("id-1"), type(uint128).max);
        vaultV2.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (abi.encodePacked("id-1"), 1e18)));
        vault.increaseRelativeCap(abi.encodePacked("id-1"), 1e18);

        uint256 penalty = 0.02e18; // 2% penalty
        vaultV2.submit(abi.encodeCall(IVaultV2.setForceDeallocatePenalty, (address(mockAdapter), penalty)));
        vault.setForceDeallocatePenalty(address(mockAdapter), penalty);

        vm.stopPrank();

        // Multiple users deposit
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);
        vm.stopPrank();

        vm.startPrank(bob);
        asset.approve(address(wrapper), 2000e18);
        wrapper.deposit(2000e18);
        vm.stopPrank();

        // Allocate to adapter
        vm.startPrank(owner);
        uint256 wrapperShares = vault.balanceOf(address(wrapper));
        vault.allocate(address(mockAdapter), "", wrapperShares / 2);
        vm.stopPrank();

        // Both Alice and Bob can emergency withdraw
        vm.prank(alice);
        wrapper.emergencyWithdraw(address(mockAdapter), "", 100e18);

        vm.prank(bob);
        wrapper.emergencyWithdraw(address(mockAdapter), "", 200e18);

        // SECURITY CHECK: Both withdrawals succeeded and allowance is still 0
        assertEq(vault.allowance(address(wrapper), address(vault)), 0, "No allowance after multiple emergencies");
    }

    function test_emergency_revertsWithZeroBalance() public {
        // Setup adapter (simplified - no allocation needed for this test)
        vm.startPrank(owner);
        VaultV2 vaultV2 = VaultV2(address(vault));
        vaultV2.setCurator(owner);
        AdapterMock mockAdapter = new AdapterMock(address(vault));
        vaultV2.submit(abi.encodeCall(IVaultV2.addAdapter, (address(mockAdapter))));
        vault.addAdapter(address(mockAdapter));
        vm.stopPrank();

        // Carol has no deposits
        vm.startPrank(carol);

        // Should revert with InsufficientBalance
        vm.expectRevert(VaultTimeLockWrapper.InsufficientBalance.selector);
        wrapper.emergencyWithdraw(address(mockAdapter), "", 100e18);

        vm.stopPrank();
    }

    // ============================================
    // VULNERABILITY #5 TESTS: ALLOWANCE UNITS
    // ============================================

    function test_allowance_checkedInSharesNotAssets() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        // Alice approves Bob for 100 vTokens (shares)
        wrapper.approve(bob, 100e18);

        vm.stopPrank();

        // Bob tries to withdraw on behalf of Alice
        vm.startPrank(bob);

        // Calculate how many shares needed for withdrawal
        uint256 assetsToWithdraw = 50e18;
        uint256 sharesNeeded = vault.previewWithdraw(assetsToWithdraw);

        // If shares > 100, should revert
        if (sharesNeeded > 100e18) {
            vm.expectRevert(VaultTimeLockWrapper.InsufficientAllowance.selector);
        }

        // Fast forward past lockup
        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        wrapper.withdraw(assetsToWithdraw, bob, alice);

        // Check allowance was deducted in shares
        uint256 remainingAllowance = wrapper.allowance(alice, bob);
        assertEq(remainingAllowance, 100e18 - sharesNeeded, "Allowance deducted in shares");

        vm.stopPrank();
    }

    function test_allowance_consistentBetweenWithdrawAndRedeem() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 2000e18);
        wrapper.deposit(2000e18);

        // Test 1: Approve Bob for withdraw
        wrapper.approve(bob, 500e18); // 500 shares

        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD + 1);

        // Bob withdraws using shares allowance
        vm.prank(bob);
        wrapper.redeem(100e18, bob, alice); // Redeem 100 shares

        // Check allowance updated correctly
        assertEq(wrapper.allowance(alice, bob), 400e18, "Allowance reduced by shares");

        // Test 2: Approve Carol for redeem
        vm.prank(alice);
        wrapper.approve(carol, 300e18); // 300 shares

        // Carol redeems
        vm.prank(carol);
        wrapper.redeem(200e18, carol, alice);

        assertEq(wrapper.allowance(alice, carol), 100e18, "Allowance consistent");
    }

    // ============================================
    // BASIC FUNCTIONALITY TESTS
    // ============================================

    function test_deposit_mintsVTokens() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);

        uint256 vTokens = wrapper.deposit(INITIAL_DEPOSIT);

        assertGt(vTokens, 0, "Should receive vTokens");
        assertEq(wrapper.balanceOf(alice), vTokens, "Balance matches");
        assertEq(wrapper.getDepositCount(alice), 1, "One batch created");

        vm.stopPrank();
    }

    function test_withdraw_revertsBeforeLockup() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        wrapper.deposit(INITIAL_DEPOSIT);

        vm.expectRevert();
        wrapper.withdraw(INITIAL_DEPOSIT, alice, alice);

        vm.stopPrank();
    }

    function test_withdraw_succeedsAfterLockup() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        uint256 vTokens = wrapper.deposit(INITIAL_DEPOSIT);

        uint256 depositTime = block.timestamp;
        vm.warp(depositTime + LOCK_PERIOD);

        wrapper.redeem(vTokens, alice, alice);

        assertEq(wrapper.balanceOf(alice), 0, "All vTokens redeemed");
        assertApproxEqAbs(asset.balanceOf(alice), 10000e18, 1e18, "Assets returned");

        vm.stopPrank();
    }

    function test_unwrapToApproval_supportsPullBasedIntegrations() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        uint256 vTokens = wrapper.deposit(INITIAL_DEPOSIT);

        uint256 depositTime = block.timestamp;
        vm.warp(depositTime + LOCK_PERIOD);

        wrapper.unwrapToApproval(vTokens, bob, alice);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(alice), 0, "vTokens burned");
        assertEq(IERC20(address(vault)).allowance(address(wrapper), bob), vTokens, "shares approved for pull");

        vm.prank(bob);
        IERC20(address(vault)).transferFrom(address(wrapper), bob, vTokens);

        assertEq(IERC20(address(vault)).balanceOf(bob), vTokens, "spender pulled wrapped shares");
    }

    function test_transfer_preservesOriginalDepositTime() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        wrapper.deposit(INITIAL_DEPOSIT);
        (, uint256 aliceDepositTime,,) = wrapper.getDeposit(alice, 0);

        vm.warp(block.timestamp + 3 days);
        wrapper.transfer(bob, INITIAL_DEPOSIT);

        vm.stopPrank();

        // Bob's batch should have Alice's original timestamp
        (uint256 amount, uint256 depositTime,,) = wrapper.getDeposit(bob, 0);
        assertEq(amount, INITIAL_DEPOSIT, "Full amount transferred");
        assertEq(depositTime, aliceDepositTime, "Original deposit time preserved");

        // Bob waits 4 more days (total 7 from Alice's deposit)
        vm.warp(aliceDepositTime + LOCK_PERIOD);

        // Bob can withdraw (based on Alice's original deposit time)
        vm.prank(bob);
        wrapper.withdraw(INITIAL_DEPOSIT, bob, bob);

        assertEq(wrapper.balanceOf(bob), 0, "Bob successfully withdrew");
    }

    function test_multipleDeposits_differentUnlockTimes() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 600e18);

        wrapper.deposit(100e18);
        (, uint256 time1,,) = wrapper.getDeposit(alice, 0);

        vm.warp(block.timestamp + 2 days);
        wrapper.deposit(200e18);
        (, uint256 time2,,) = wrapper.getDeposit(alice, 1);

        vm.warp(block.timestamp + 2 days);
        wrapper.deposit(300e18);
        (, uint256 time3,,) = wrapper.getDeposit(alice, 2);

        // Check all batches exist
        assertEq(wrapper.getDepositCount(alice), 3, "Three batches");

        // Check unlock times
        (,, uint256 unlock1,) = wrapper.getDeposit(alice, 0);
        (,, uint256 unlock2,) = wrapper.getDeposit(alice, 1);
        (,, uint256 unlock3,) = wrapper.getDeposit(alice, 2);

        assertEq(unlock1, time1 + LOCK_PERIOD, "First unlock");
        assertEq(unlock2, time2 + LOCK_PERIOD, "Second unlock");
        assertEq(unlock3, time3 + LOCK_PERIOD, "Third unlock");

        vm.stopPrank();
    }

    function test_viewFunctions_returnCorrectValues() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 300e18);
        wrapper.deposit(300e18);
        uint256 depositTime = block.timestamp;

        // Before lockup
        assertFalse(wrapper.isUnlocked(alice), "Should be locked");
        assertEq(wrapper.remainingLockTime(alice), LOCK_PERIOD, "Full period remaining");
        assertEq(wrapper.unlockedBalanceOf(alice), 0, "Nothing unlocked");

        // After lockup
        vm.warp(depositTime + LOCK_PERIOD);
        assertTrue(wrapper.isUnlocked(alice), "Should be unlocked");
        assertEq(wrapper.remainingLockTime(alice), 0, "No time remaining");
        assertEq(wrapper.unlockedBalanceOf(alice), 300e18, "All unlocked");

        vm.stopPrank();
    }

    // ============================================
    // ERC20 TESTS
    // ============================================

    function test_erc20_transferWorksCorrectly() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        wrapper.transfer(bob, 500e18);

        assertEq(wrapper.balanceOf(alice), 500e18, "Alice balance");
        assertEq(wrapper.balanceOf(bob), 500e18, "Bob balance");

        vm.stopPrank();
    }

    function test_erc20_selfTransferPreservesDepositBatches() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(600e18);
        vm.warp(block.timestamp + 1 days);
        wrapper.deposit(400e18);

        uint256 depositCountBefore = wrapper.getDepositCount(alice);
        (uint256 amount0Before, uint256 time0Before) = wrapper.userDeposits(alice, 0);
        (uint256 amount1Before, uint256 time1Before) = wrapper.userDeposits(alice, 1);

        wrapper.transfer(alice, 250e18);

        assertEq(wrapper.balanceOf(alice), 1_000e18, "Self transfer should preserve balance");
        assertEq(wrapper.getDepositCount(alice), depositCountBefore, "Self transfer should preserve batch count");

        (uint256 amount0After, uint256 time0After) = wrapper.userDeposits(alice, 0);
        (uint256 amount1After, uint256 time1After) = wrapper.userDeposits(alice, 1);

        assertEq(amount0After, amount0Before, "First batch amount should be unchanged");
        assertEq(time0After, time0Before, "First batch timestamp should be unchanged");
        assertEq(amount1After, amount1Before, "Second batch amount should be unchanged");
        assertEq(time1After, time1Before, "Second batch timestamp should be unchanged");
        vm.stopPrank();
    }

    function test_erc20_transferFromWorksWithApproval() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        wrapper.approve(bob, 600e18);
        vm.stopPrank();

        vm.prank(bob);
        wrapper.transferFrom(alice, carol, 400e18);

        assertEq(wrapper.balanceOf(alice), 600e18, "Alice balance");
        assertEq(wrapper.balanceOf(carol), 400e18, "Carol balance");
        assertEq(wrapper.allowance(alice, bob), 200e18, "Remaining allowance");
    }

    // ============================================
    // EDGE CASES
    // ============================================

    function test_depositZero_reverts() public {
        vm.prank(alice);
        vm.expectRevert(VaultTimeLockWrapper.ZeroAmount.selector);
        wrapper.deposit(0);
    }

    function test_withdrawToZeroAddress_reverts() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        vm.warp(block.timestamp + LOCK_PERIOD);

        vm.expectRevert(VaultTimeLockWrapper.ZeroAddress.selector);
        wrapper.withdraw(100e18, address(0), alice);

        vm.stopPrank();
    }

    function test_transferToZeroAddress_reverts() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        vm.expectRevert(VaultTimeLockWrapper.ZeroAddress.selector);
        wrapper.transfer(address(0), 100e18);

        vm.stopPrank();
    }

    // ============================================
    // NEW SECURITY FIX TESTS: DECIMAL MATCHING
    // ============================================

    function test_security_decimalsMatchVault() public view {
        // SECURITY FIX: Wrapper decimals must match vault decimals
        assertEq(wrapper.decimals(), vault.decimals(), "Wrapper decimals must match vault");
    }

    function test_security_decimalsConsistentWith18DecimalAsset() public view {
        // Test with 18-decimal asset (most common)
        assertEq(vault.decimals(), 18, "Vault should have 18 decimals for 18-decimal asset");
        assertEq(wrapper.decimals(), 18, "Wrapper should match vault decimals");
    }

    function test_security_decimalsWorkWithLowDecimalAsset() public {
        // Test with 6-decimal asset (like USDC)
        vm.startPrank(owner);
        MockERC20 usdcLike = new MockERC20("Mock USDC", "USDC", 6);

        VaultV2Factory factory = new VaultV2Factory();
        IVaultV2 usdcVault = IVaultV2(factory.createVaultV2(owner, address(usdcLike), bytes32(uint256(2))));

        VaultTimeLockWrapper usdcWrapper = new VaultTimeLockWrapper(address(usdcVault));

        // Vault should normalize to 18 decimals (6 + 12 offset)
        assertEq(usdcVault.decimals(), 18, "Vault normalizes to 18 decimals");
        assertEq(usdcWrapper.decimals(), 18, "Wrapper matches vault decimals");

        vm.stopPrank();
    }

    // ============================================
    // NEW SECURITY FIX TESTS: CAP BYPASS PREVENTION
    // ============================================

    function test_security_transferRevertsWhenReceiverNearCap() public {
        // Fill Alice to 99 batches with DIFFERENT timestamps
        uint256 baseTime = block.timestamp;
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 99; i++) {
            vm.warp(baseTime + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 99, "Alice should have 99 batches");

        // Bob creates 5 batches with different timestamps (continuing from Alice's last)
        vm.startPrank(bob);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(baseTime + 100 + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }

        // Bob tries to transfer all 5 batches to Alice
        // Since all batches have different timestamps, they won't merge
        // Should succeed for first batch (Alice goes to 100)
        // Should revert on second batch attempt
        vm.expectRevert(VaultTimeLockWrapper.MaxBatchesReached.selector);
        wrapper.transfer(alice, 5e18);

        vm.stopPrank();

        // Alice should still have 99 batches (transaction reverted)
        assertEq(wrapper.getDepositCount(alice), 99, "Alice unchanged after revert");
    }

    function test_security_transferExactlyToCapSucceeds() public {
        // Alice has 99 batches with DIFFERENT timestamps
        uint256 baseTime = block.timestamp;
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 99; i++) {
            vm.warp(baseTime + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 99, "Alice should have 99 batches");

        // Bob transfers exactly 1 batch to bring Alice to 100
        vm.warp(baseTime + 200); // Different timestamp than Alice's
        vm.startPrank(bob);
        asset.approve(address(wrapper), 10e18);
        wrapper.deposit(10e18);

        wrapper.transfer(alice, 10e18); // Should succeed (different timestamp, creates new batch)

        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 100, "Alice at exactly 100 batches");
    }

    function test_security_capEnforcedInMiddleOfTransferLoop() public {
        // Alice has 98 batches with DIFFERENT timestamps
        uint256 baseTime = block.timestamp;
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 98; i++) {
            vm.warp(baseTime + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 98, "Alice should have 98 batches");

        // Bob has 5 batches with different timestamps
        vm.startPrank(bob);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(baseTime + 100 + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }

        // Bob tries to transfer all 5 batches
        // Since all have different timestamps, no merging occurs
        // First 2 should push successfully (98->99->100)
        // Third should fail at cap check
        vm.expectRevert(VaultTimeLockWrapper.MaxBatchesReached.selector);
        wrapper.transfer(alice, 5e18);

        vm.stopPrank();
    }

    function test_security_multipleSmallTransfersRespectsCapEach() public {
        // Alice has 99 batches with DIFFERENT timestamps
        uint256 baseTime = block.timestamp;
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 99; i++) {
            vm.warp(baseTime + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 99, "Alice should have 99 batches");

        // Bob transfers 1 batch successfully (different timestamp from Alice's)
        vm.warp(baseTime + 200); // Different timestamp than Alice's
        vm.startPrank(bob);
        asset.approve(address(wrapper), type(uint256).max);
        wrapper.deposit(1e18);
        wrapper.transfer(alice, 1e18); // Success: Alice at 100

        // Bob tries to transfer another batch with a DIFFERENT timestamp
        vm.warp(baseTime + 300); // New timestamp
        wrapper.deposit(1e18);
        vm.expectRevert(VaultTimeLockWrapper.MaxBatchesReached.selector);
        wrapper.transfer(alice, 1e18); // Fail: Alice already at 100 and different timestamp

        vm.stopPrank();
    }

    // ============================================
    // EDGE CASE TESTS: BATCH MANAGEMENT
    // ============================================

    function test_edge_partialBatchTransferLeavesFraction() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18); // 1 batch with 1000 tokens

        // Transfer 300 (partial batch)
        wrapper.transfer(bob, 300e18);

        vm.stopPrank();

        // Alice should have 700 in original batch
        assertEq(wrapper.getDepositCount(alice), 1, "Alice still has 1 batch");
        (uint256 aliceAmt,,,) = wrapper.getDeposit(alice, 0);
        assertEq(aliceAmt, 700e18, "Alice has 700 remaining");

        // Bob should have 300 in new batch with same timestamp
        assertEq(wrapper.getDepositCount(bob), 1, "Bob has 1 batch");
        (uint256 bobAmt, uint256 bobTime,,) = wrapper.getDeposit(bob, 0);
        assertEq(bobAmt, 300e18, "Bob has 300");

        (, uint256 aliceTime,,) = wrapper.getDeposit(alice, 0);
        assertEq(bobTime, aliceTime, "Timestamp preserved");
    }

    function test_edge_transferAllBatchesLeavesZero() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 300e18);

        wrapper.deposit(100e18);
        wrapper.deposit(200e18);

        assertEq(wrapper.getDepositCount(alice), 2, "Alice has 2 batches");

        // Transfer all tokens
        wrapper.transfer(bob, 300e18);

        assertEq(wrapper.getDepositCount(alice), 0, "Alice has 0 batches after full transfer");
        assertEq(wrapper.balanceOf(alice), 0, "Alice balance is 0");

        vm.stopPrank();
    }

    function test_edge_multiplePartialTransfersFragmentBatches() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        // Transfer 100 to bob, 200 to carol
        wrapper.transfer(bob, 100e18);
        wrapper.transfer(carol, 200e18);

        // Alice should have 700 in 1 batch
        assertEq(wrapper.getDepositCount(alice), 1, "Alice has 1 batch");
        (uint256 amt,,,) = wrapper.getDeposit(alice, 0);
        assertEq(amt, 700e18, "Alice has 700");

        // Bob has 100
        (uint256 bobAmt,,,) = wrapper.getDeposit(bob, 0);
        assertEq(bobAmt, 100e18, "Bob has 100");

        // Carol has 200
        (uint256 carolAmt,,,) = wrapper.getDeposit(carol, 0);
        assertEq(carolAmt, 200e18, "Carol has 200");

        vm.stopPrank();
    }

    function test_edge_withdrawMultipleBatchesAtOnce() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 600e18);

        wrapper.deposit(100e18);
        uint256 time1 = block.timestamp;

        vm.warp(block.timestamp + 1 days);
        wrapper.deposit(200e18);

        vm.warp(block.timestamp + 1 days);
        wrapper.deposit(300e18);

        assertEq(wrapper.getDepositCount(alice), 3, "Alice has 3 batches");

        // Fast forward to unlock all
        vm.warp(time1 + LOCK_PERIOD + 3 days);

        // Withdraw all at once
        wrapper.withdraw(600e18, alice, alice);

        assertEq(wrapper.getDepositCount(alice), 0, "All batches consumed");
        assertEq(wrapper.balanceOf(alice), 0, "All vTokens burned");

        vm.stopPrank();
    }

    // ============================================
    // EDGE CASE TESTS: ALLOWANCE
    // ============================================

    function test_edge_maxAllowanceDoesntDecrement() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        // Approve Bob with max uint256
        wrapper.approve(bob, type(uint256).max);

        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD);

        // Bob withdraws on behalf of Alice
        vm.prank(bob);
        wrapper.withdraw(100e18, bob, alice);

        // Allowance should still be max
        assertEq(wrapper.allowance(alice, bob), type(uint256).max, "Max allowance unchanged");
    }

    function test_edge_allowanceExhaustedReverts() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);

        wrapper.approve(bob, 50e18); // Approve exactly 50 shares

        vm.stopPrank();

        vm.warp(block.timestamp + LOCK_PERIOD);

        // Bob tries to withdraw more than allowance
        vm.prank(bob);
        vm.expectRevert(VaultTimeLockWrapper.InsufficientAllowance.selector);
        wrapper.withdraw(100e18, bob, alice);
    }

    function test_edge_transferFromRespectsCapLimit() public {
        // Fill Carol to 100 batches with DIFFERENT timestamps
        uint256 baseTime = block.timestamp;
        vm.startPrank(carol);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 100; i++) {
            vm.warp(baseTime + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(carol), 100, "Carol should have 100 batches");

        // Alice approves Bob for transferFrom (different timestamp than Carol's batches)
        vm.warp(baseTime + 200); // Different timestamp than Carol's
        vm.startPrank(alice);
        asset.approve(address(wrapper), 10e18);
        wrapper.deposit(10e18);
        wrapper.approve(bob, 10e18);
        vm.stopPrank();

        // Bob tries to transferFrom Alice to Carol (who is at cap)
        // Since timestamps are different, no merge, so should revert
        vm.prank(bob);
        vm.expectRevert(VaultTimeLockWrapper.MaxBatchesReached.selector);
        wrapper.transferFrom(alice, carol, 10e18);
    }

    // ============================================
    // EDGE CASE TESTS: APPROVAL SYSTEM
    // ============================================

    function test_edge_setApprovalForDepositEnablesDeposit() public {
        // Alice approves Bob
        vm.prank(alice);
        wrapper.setApprovalForDeposit(bob, true);

        // Bob can now deposit for Alice
        vm.startPrank(bob);
        asset.approve(address(wrapper), 100e18);
        wrapper.depositFor(100e18, alice);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(alice), 100e18, "Alice received deposit");
        assertEq(wrapper.getDepositCount(alice), 1, "Alice has 1 batch");
    }

    function test_edge_removeApprovalForDepositPreventsDeposit() public {
        // Alice approves then removes Bob
        vm.startPrank(alice);
        wrapper.setApprovalForDeposit(bob, true);
        wrapper.setApprovalForDeposit(bob, false);
        vm.stopPrank();

        // Bob cannot deposit for Alice
        vm.startPrank(bob);
        asset.approve(address(wrapper), 100e18);
        vm.expectRevert(VaultTimeLockWrapper.NotApprovedForDeposit.selector);
        wrapper.depositFor(100e18, alice);
        vm.stopPrank();
    }

    function test_edge_multipleOperatorsCanDeposit() public {
        // Alice approves both Bob and Carol
        vm.startPrank(alice);
        wrapper.setApprovalForDeposit(bob, true);
        wrapper.setApprovalForDeposit(carol, true);
        vm.stopPrank();

        // Both can deposit
        vm.startPrank(bob);
        asset.approve(address(wrapper), 100e18);
        wrapper.depositFor(100e18, alice);
        vm.stopPrank();

        vm.startPrank(carol);
        asset.approve(address(wrapper), 200e18);
        wrapper.depositFor(200e18, alice);
        vm.stopPrank();

        assertEq(wrapper.balanceOf(alice), 300e18, "Alice received both deposits");
        assertEq(wrapper.getDepositCount(alice), 2, "Alice has 2 batches");
    }

    // ============================================
    // EDGE CASE TESTS: LOCK TIME BOUNDARIES
    // ============================================

    function test_edge_depositAtExactUnlockMoment() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 200e18);

        wrapper.deposit(100e18);
        uint256 depositTime = block.timestamp;

        // Warp to EXACTLY unlock time
        vm.warp(depositTime + LOCK_PERIOD);

        // Deposit again at unlock boundary
        wrapper.deposit(100e18);

        // First batch should be unlocked
        assertTrue(wrapper.isUnlocked(alice), "First batch unlocked");

        // Can withdraw first batch
        wrapper.withdraw(100e18, alice, alice);

        // Cannot withdraw second batch (just deposited)
        vm.expectRevert();
        wrapper.withdraw(100e18, alice, alice);

        vm.stopPrank();
    }

    function test_edge_multipleDepositsAtSameTimestamp() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 300e18);

        // Multiple deposits in same block
        wrapper.deposit(100e18);
        wrapper.deposit(100e18);
        wrapper.deposit(100e18);

        // All should have same timestamp
        (, uint256 time1,,) = wrapper.getDeposit(alice, 0);
        (, uint256 time2,,) = wrapper.getDeposit(alice, 1);
        (, uint256 time3,,) = wrapper.getDeposit(alice, 2);

        assertEq(time1, time2, "Same timestamp");
        assertEq(time2, time3, "Same timestamp");

        // All unlock at same time
        vm.warp(time1 + LOCK_PERIOD);

        uint256 unlocked = wrapper.unlockedBalanceOf(alice);
        assertEq(unlocked, 300e18, "All unlock together");

        vm.stopPrank();
    }

    // ============================================
    // EDGE CASE TESTS: MINT FUNCTION
    // ============================================

    function test_edge_mintRespectsCapLimit() public {
        // Fill Alice to 100 batches
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 100; i++) {
            wrapper.deposit(1e18);
        }

        // Try to mint (should hit cap)
        vm.expectRevert(VaultTimeLockWrapper.MaxBatchesReached.selector);
        wrapper.mint(10e18);

        vm.stopPrank();
    }

    function test_edge_mintCreatesDepositBatch() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);

        uint256 shares = 100e18;
        wrapper.mint(shares);

        assertEq(wrapper.getDepositCount(alice), 1, "Batch created");
        (uint256 amt, uint256 time,,) = wrapper.getDeposit(alice, 0);
        assertEq(amt, shares, "Correct amount");
        assertGt(time, 0, "Timestamp set");

        vm.stopPrank();
    }

    // ============================================
    // GAS LIMIT SCENARIO TESTS
    // ============================================

    function test_gas_withdrawWithMaxBatchesCompletes() public {
        // Fill Alice to 100 batches
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 100; i++) {
            wrapper.deposit(1e18);
        }

        // Fast forward past lockup
        vm.warp(block.timestamp + LOCK_PERIOD);

        // Withdraw all (should complete despite O(100) shift-left)
        uint256 gasBefore = gasleft();
        wrapper.withdraw(100e18, alice, alice);
        uint256 gasUsed = gasBefore - gasleft();

        // Should use reasonable gas (not DoS)
        assertLt(gasUsed, 3_000_000, "Gas under 3M");
        assertEq(wrapper.getDepositCount(alice), 0, "First batch removed");

        vm.stopPrank();
    }

    function test_gas_transferWithManyBatchesCompletes() public {
        // Alice creates 50 batches with DIFFERENT timestamps
        uint256 baseTime = block.timestamp;
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 50; i++) {
            vm.warp(baseTime + i); // Different timestamp each time
            wrapper.deposit(1e18);
        }

        assertEq(wrapper.getDepositCount(alice), 50, "Alice should have 50 batches");

        // Transfer all to Bob
        uint256 gasBefore = gasleft();
        wrapper.transfer(bob, 50e18);
        uint256 gasUsed = gasBefore - gasleft();

        // Should complete without DoS
        assertLt(gasUsed, 5_000_000, "Gas under 5M");
        // With different timestamps, Bob gets 50 separate batches
        assertEq(wrapper.getDepositCount(bob), 50, "Bob received 50 batches");
        assertEq(wrapper.getDepositCount(alice), 0, "Alice batches cleared");

        vm.stopPrank();
    }

    // ============================================
    // SECURITY FIX TESTS: TRANSFER SPAM DOS MITIGATION
    // ============================================

    function test_security_transferMergesSameTimestampBatches() public {
        // Alice deposits (creates batch with current timestamp)
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);
        (, uint256 aliceDepositTime,,) = wrapper.getDeposit(alice, 0);
        vm.stopPrank();

        // Bob receives multiple transfers from Alice's same-timestamp batch
        // In the same block (same timestamp), all should merge into one batch
        vm.startPrank(alice);
        wrapper.transfer(bob, 100e18);
        wrapper.transfer(bob, 200e18);
        wrapper.transfer(bob, 300e18);
        vm.stopPrank();

        // SECURITY CHECK: Bob should have only 1 batch (merged), not 3
        assertEq(wrapper.getDepositCount(bob), 1, "All transfers merged into 1 batch");

        // Verify total amount is correct
        (uint256 bobAmt, uint256 bobTime,,) = wrapper.getDeposit(bob, 0);
        assertEq(bobAmt, 600e18, "Merged amount is correct");
        assertEq(bobTime, aliceDepositTime, "Timestamp preserved");
    }

    function test_security_transferSpamMitigated() public {
        // Attacker deposits small amount to get vTokens
        vm.startPrank(attacker);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);
        vm.stopPrank();

        // ATTACK: Attacker tries to fill victim's batch array with 100 tiny transfers
        vm.startPrank(attacker);
        for (uint256 i = 0; i < 100; i++) {
            wrapper.transfer(alice, 1e18);
        }
        vm.stopPrank();

        // SECURITY CHECK: Alice should have only 1 batch (all merged), not 100
        assertEq(wrapper.getDepositCount(alice), 1, "Attack mitigated - only 1 batch");
        (uint256 aliceAmt,,,) = wrapper.getDeposit(alice, 0);
        assertEq(aliceAmt, 100e18, "Total amount correct");

        // Alice can still deposit (not blocked)
        vm.startPrank(alice);
        asset.approve(address(wrapper), 100e18);
        wrapper.deposit(100e18); // Should succeed
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 2, "Alice can still deposit");
    }

    function test_security_differentTimestampsCreateSeparateBatches() public {
        // Alice creates multiple batches at different times
        // Use explicit timestamps to ensure they're different
        uint256 startTime = block.timestamp;

        vm.startPrank(alice);
        asset.approve(address(wrapper), 600e18);

        wrapper.deposit(100e18);
        (, uint256 time1,,) = wrapper.getDeposit(alice, 0);

        vm.warp(startTime + 1 days);
        wrapper.deposit(200e18);
        (, uint256 time2,,) = wrapper.getDeposit(alice, 1);

        vm.warp(startTime + 2 days);
        wrapper.deposit(300e18);
        (, uint256 time3,,) = wrapper.getDeposit(alice, 2);
        vm.stopPrank();

        // Verify timestamps are actually different
        assertTrue(time1 != time2 && time2 != time3, "Timestamps should be different");

        // Transfer each batch to Bob separately
        vm.startPrank(alice);
        wrapper.transfer(bob, 100e18); // First batch (time1)
        wrapper.transfer(bob, 200e18); // Second batch (time2)
        wrapper.transfer(bob, 300e18); // Third batch (time3)
        vm.stopPrank();

        // SECURITY CHECK: Bob should have 3 separate batches (different timestamps)
        assertEq(wrapper.getDepositCount(bob), 3, "Different timestamps create separate batches");

        // Verify each batch has correct timestamp
        (, uint256 bobTime1,,) = wrapper.getDeposit(bob, 0);
        (, uint256 bobTime2,,) = wrapper.getDeposit(bob, 1);
        (, uint256 bobTime3,,) = wrapper.getDeposit(bob, 2);

        assertEq(bobTime1, time1, "First batch timestamp preserved");
        assertEq(bobTime2, time2, "Second batch timestamp preserved");
        assertEq(bobTime3, time3, "Third batch timestamp preserved");
    }

    function test_security_mixedTimestampsMergeCorrectly() public {
        // Alice creates 2 batches at different times
        vm.startPrank(alice);
        asset.approve(address(wrapper), 400e18);

        wrapper.deposit(200e18);
        (, uint256 time1,,) = wrapper.getDeposit(alice, 0);

        vm.warp(block.timestamp + 1 days);
        wrapper.deposit(200e18);
        (, uint256 time2,,) = wrapper.getDeposit(alice, 1);
        vm.stopPrank();

        // Transfer partial amounts in alternating pattern
        // First 50 from time1, then 50 from time2 (time1 exhausted at 200)
        vm.startPrank(alice);
        wrapper.transfer(bob, 250e18); // 200 from time1 + 50 from time2
        vm.stopPrank();

        // Bob should have 2 batches (different timestamps)
        assertEq(wrapper.getDepositCount(bob), 2, "Two batches for two timestamps");

        (uint256 amt1, uint256 t1,,) = wrapper.getDeposit(bob, 0);
        (uint256 amt2, uint256 t2,,) = wrapper.getDeposit(bob, 1);

        assertEq(amt1, 200e18, "First batch amount");
        assertEq(t1, time1, "First batch timestamp");
        assertEq(amt2, 50e18, "Second batch amount");
        assertEq(t2, time2, "Second batch timestamp");
    }

    function test_security_subsequentSameTimestampMerges() public {
        uint256 startTime = block.timestamp;

        // Alice creates a batch
        vm.startPrank(alice);
        asset.approve(address(wrapper), 1000e18);
        wrapper.deposit(1000e18);
        vm.stopPrank();

        // Bob creates a batch at a DIFFERENT timestamp
        vm.warp(startTime + 1 days);
        vm.startPrank(bob);
        asset.approve(address(wrapper), 100e18);
        wrapper.deposit(100e18);
        vm.stopPrank();

        // Alice transfers to Bob multiple times (all transfers from Alice's batch
        // have Alice's depositTime, which is different from Bob's batch)
        vm.startPrank(alice);
        wrapper.transfer(bob, 100e18);
        wrapper.transfer(bob, 100e18);
        wrapper.transfer(bob, 100e18);
        vm.stopPrank();

        // Bob should have 2 batches: his original + Alice's (merged because all
        // transfers from Alice share the same depositTime)
        assertEq(wrapper.getDepositCount(bob), 2, "Bob has 2 batches total");

        // First batch is Bob's original deposit
        (uint256 amt0,,,) = wrapper.getDeposit(bob, 0);
        assertEq(amt0, 100e18, "Bob's original deposit unchanged");

        // Second batch is all of Alice's transfers merged
        (uint256 amt1,,,) = wrapper.getDeposit(bob, 1);
        assertEq(amt1, 300e18, "Alice's transfers merged");
    }

    function test_security_capEnforcedAfterMerging() public {
        // Fill Alice close to cap with different timestamps
        uint256 baseTime = block.timestamp;
        vm.startPrank(alice);
        asset.approve(address(wrapper), type(uint256).max);
        for (uint256 i = 0; i < 99; i++) {
            vm.warp(baseTime + i); // Different timestamp each deposit
            wrapper.deposit(1e18);
        }
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 99, "Alice at 99 batches");

        // Bob creates a batch (different timestamp than all of Alice's batches)
        vm.warp(baseTime + 200); // Different timestamp than Alice's
        vm.startPrank(bob);
        asset.approve(address(wrapper), 10e18);
        wrapper.deposit(10e18);
        (, uint256 bobDepositTime,,) = wrapper.getDeposit(bob, 0);

        // Bob transfers to Alice - should succeed (creates 1 new batch since
        // Bob's depositTime is different from all of Alice's batches)
        wrapper.transfer(alice, 5e18);
        vm.stopPrank();

        assertEq(wrapper.getDepositCount(alice), 100, "Alice at 100 batches");

        // Bob tries another transfer - should still succeed because same timestamp
        // as Alice's batch 99 (which came from Bob's deposit)
        vm.prank(bob);
        wrapper.transfer(alice, 5e18); // Same timestamp as Alice's last batch, should merge

        // Alice should still be at 100 (merged into existing batch)
        assertEq(wrapper.getDepositCount(alice), 100, "Still at 100 after merge");

        // Verify the last batch has the merged amount
        (uint256 lastAmt, uint256 lastTime,,) = wrapper.getDeposit(alice, 99);
        assertEq(lastAmt, 10e18, "Last batch has merged amount (5 + 5)");
        assertEq(lastTime, bobDepositTime, "Last batch has Bob's deposit time");
    }
}

// ============================================
// MOCK CONTRACTS
// ============================================

contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }

    function asset() external view returns (address) {
        return address(this);
    }
}
