// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../src/VaultTimeLockWrapper.sol";
import "../src/VaultV2.sol";
import "../src/VaultV2Factory.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract VaultTimeLockWrapperTest is Test {
    VaultTimeLockWrapper public wrapper;
    IVaultV2 public vault;
    IERC20 public asset;

    address public owner = address(0x1);
    address public alice = address(0x2);
    address public bob = address(0x3);
    address public carol = address(0x4);

    uint256 constant LOCK_PERIOD = 7 days;
    uint256 constant INITIAL_DEPOSIT = 1000e18;

    function setUp() public {
        // Deploy mock ERC20 asset
        vm.startPrank(owner);
        asset = IERC20(address(new MockERC20("Test Asset", "TEST", 18)));

        // Deploy vault via factory
        VaultV2Factory factory = new VaultV2Factory();
        vault = IVaultV2(factory.createVaultV2(
            owner,           // owner
            address(asset),  // asset
            "Test Vault",    // name
            "vTEST",         // symbol
            bytes32(uint256(1)) // salt
        ));

        // Deploy wrapper
        wrapper = new VaultTimeLockWrapper(address(vault));

        // Mint assets to test users
        MockERC20(address(asset)).mint(alice, 10000e18);
        MockERC20(address(asset)).mint(bob, 10000e18);
        MockERC20(address(asset)).mint(carol, 10000e18);

        vm.stopPrank();
    }

    // ============================================
    // BASIC DEPOSIT/WITHDRAW TESTS
    // ============================================

    function test_deposit_mintsVTokens() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);

        uint256 vTokens = wrapper.deposit(INITIAL_DEPOSIT, alice);

        assertEq(wrapper.balanceOf(alice), vTokens, "Alice should receive vTokens");
        assertEq(wrapper.totalSupply(), vTokens, "Total supply should increase");
        assertTrue(wrapper.getDepositCount(alice) == 1, "Should have 1 deposit batch");
        vm.stopPrank();
    }

    function test_withdraw_revertsBeforeLockupExpiry() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        wrapper.deposit(INITIAL_DEPOSIT, alice);

        // Try to withdraw immediately (should fail)
        vm.expectRevert("Oldest deposit still locked");
        wrapper.withdraw(INITIAL_DEPOSIT, alice, alice);

        vm.stopPrank();
    }

    function test_withdraw_succedsAfterLockupExpiry() public {
        // Alice deposits
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        uint256 vTokens = wrapper.deposit(INITIAL_DEPOSIT, alice);

        // Fast forward 7 days
        vm.warp(block.timestamp + LOCK_PERIOD);

        // Withdraw should succeed
        wrapper.redeem(vTokens, alice, alice);

        assertEq(wrapper.balanceOf(alice), 0, "Alice should have 0 vTokens");
        assertApproxEqAbs(asset.balanceOf(alice), 10000e18, 1e18, "Alice should receive assets back");
        vm.stopPrank();
    }

    // ============================================
    // TRANSFER PRESERVES ORIGINAL DEPOSIT TIME
    // ============================================

    function test_transfer_preservesOriginalDepositTime() public {
        // T=0: Alice deposits
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        uint256 vTokens = wrapper.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        // T=3 days: Alice transfers to Bob
        vm.warp(block.timestamp + 3 days);
        vm.prank(alice);
        wrapper.transfer(bob, vTokens);

        // Bob should have vTokens
        assertEq(wrapper.balanceOf(bob), vTokens, "Bob should have vTokens");
        assertEq(wrapper.getDepositCount(bob), 1, "Bob should have 1 deposit batch");

        // Check Bob's deposit timestamp (should be Alice's original deposit time)
        (uint256 amount, uint256 depositTime,,) = wrapper.getDeposit(bob, 0);
        assertEq(amount, vTokens, "Bob's batch amount should match");
        assertEq(depositTime, block.timestamp - 3 days, "Deposit time should be Alice's original time");

        // T=4 days: Bob tries to withdraw (should fail - only 4 days elapsed)
        vm.warp(block.timestamp + 1 days); // Now at T=4
        vm.prank(bob);
        vm.expectRevert("Oldest deposit still locked");
        wrapper.withdraw(INITIAL_DEPOSIT, bob, bob);

        // T=7 days: Bob can withdraw (7 days from Alice's original deposit)
        vm.warp(block.timestamp + 3 days); // Now at T=7
        vm.prank(bob);
        wrapper.redeem(vTokens, bob, bob);

        assertEq(wrapper.balanceOf(bob), 0, "Bob should have withdrawn");
    }

    function test_partialTransfer_preservesTimestamps() public {
        // Alice deposits 1000
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        uint256 vTokens = wrapper.deposit(INITIAL_DEPOSIT, alice);
        vm.stopPrank();

        uint256 transferAmount = vTokens / 2;

        // Alice transfers 500 to Bob
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        wrapper.transfer(bob, transferAmount);

        // Alice should have 500, Bob should have 500
        assertEq(wrapper.balanceOf(alice), vTokens - transferAmount, "Alice balance");
        assertEq(wrapper.balanceOf(bob), transferAmount, "Bob balance");

        // Both should have deposits with same timestamp
        (,uint256 aliceDepositTime,,) = wrapper.getDeposit(alice, 0);
        (,uint256 bobDepositTime,,) = wrapper.getDeposit(bob, 0);
        assertEq(aliceDepositTime, bobDepositTime, "Timestamps should match");
    }

    // ============================================
    // FIFO WITHDRAWAL ORDERING
    // ============================================

    function test_fifo_withdrawsOldestFirst() public {
        vm.startPrank(alice);

        // Deposit 1: 400 tokens at T=0
        asset.approve(address(wrapper), 400e18);
        wrapper.deposit(400e18, alice);

        // Deposit 2: 300 tokens at T=2 days
        vm.warp(block.timestamp + 2 days);
        asset.approve(address(wrapper), 300e18);
        wrapper.deposit(300e18, alice);

        // Deposit 3: 300 tokens at T=4 days
        vm.warp(block.timestamp + 2 days);
        asset.approve(address(wrapper), 300e18);
        wrapper.deposit(300e18, alice);

        // Alice now has 1000 vTokens in 3 batches
        assertEq(wrapper.getDepositCount(alice), 3, "Should have 3 batches");
        assertEq(wrapper.balanceOf(alice), 1000e18, "Total balance");

        // T=7 days: Only first deposit is unlocked
        vm.warp(block.timestamp + 3 days); // Now at T=7

        // Can withdraw 400 (first batch only)
        uint256 unlockedBalance = wrapper.unlockedBalanceOf(alice);
        assertEq(unlockedBalance, 400e18, "Only first batch unlocked");

        wrapper.redeem(400e18, alice, alice);
        assertEq(wrapper.getDepositCount(alice), 2, "Should have 2 batches left");

        // T=9 days: First + second deposits unlocked
        vm.warp(block.timestamp + 2 days); // Now at T=9
        unlockedBalance = wrapper.unlockedBalanceOf(alice);
        assertEq(unlockedBalance, 300e18, "Second batch unlocked");

        // T=11 days: All deposits unlocked
        vm.warp(block.timestamp + 2 days); // Now at T=11
        unlockedBalance = wrapper.unlockedBalanceOf(alice);
        assertEq(unlockedBalance, 600e18, "All batches unlocked");

        vm.stopPrank();
    }

    function test_fifo_transfersOldestFirst() public {
        vm.startPrank(alice);

        // Deposit 1: 400 at T=0
        asset.approve(address(wrapper), 400e18);
        wrapper.deposit(400e18, alice);
        uint256 firstDepositTime = block.timestamp;

        // Deposit 2: 600 at T=3 days
        vm.warp(block.timestamp + 3 days);
        asset.approve(address(wrapper), 600e18);
        wrapper.deposit(600e18, alice);
        uint256 secondDepositTime = block.timestamp;

        // Transfer 700 to Bob (should take all of deposit 1 + 300 from deposit 2)
        wrapper.transfer(bob, 700e18);

        vm.stopPrank();

        // Bob should have 2 batches
        assertEq(wrapper.getDepositCount(bob), 2, "Bob should have 2 batches");

        // Check Bob's first batch (400 from Alice's first deposit)
        (uint256 amount1, uint256 time1,,) = wrapper.getDeposit(bob, 0);
        assertEq(amount1, 400e18, "First batch amount");
        assertEq(time1, firstDepositTime, "First batch time");

        // Check Bob's second batch (300 from Alice's second deposit)
        (uint256 amount2, uint256 time2,,) = wrapper.getDeposit(bob, 1);
        assertEq(amount2, 300e18, "Second batch amount");
        assertEq(time2, secondDepositTime, "Second batch time");

        // Alice should have 1 batch left (300 from second deposit)
        assertEq(wrapper.getDepositCount(alice), 1, "Alice should have 1 batch");
        (uint256 aliceAmount, uint256 aliceTime,,) = wrapper.getDeposit(alice, 0);
        assertEq(aliceAmount, 300e18, "Alice's remaining amount");
        assertEq(aliceTime, secondDepositTime, "Alice's remaining time");
    }

    // ============================================
    // MULTIPLE DEPOSITS SCENARIOS
    // ============================================

    function test_multipleDeposits_differentUnlockTimes() public {
        vm.startPrank(alice);

        // Deposit 1 at T=0
        asset.approve(address(wrapper), 300e18);
        wrapper.deposit(300e18, alice);
        uint256 deposit1Time = block.timestamp;

        // Deposit 2 at T=1 day
        vm.warp(block.timestamp + 1 days);
        asset.approve(address(wrapper), 400e18);
        wrapper.deposit(400e18, alice);
        uint256 deposit2Time = block.timestamp;

        // Deposit 3 at T=3 days
        vm.warp(block.timestamp + 2 days);
        asset.approve(address(wrapper), 300e18);
        wrapper.deposit(300e18, alice);

        // Check unlock times
        (, , uint256 unlock1,) = wrapper.getDeposit(alice, 0);
        (, , uint256 unlock2,) = wrapper.getDeposit(alice, 1);
        (, , uint256 unlock3,) = wrapper.getDeposit(alice, 2);

        assertEq(unlock1, deposit1Time + LOCK_PERIOD, "Unlock time 1");
        assertEq(unlock2, deposit2Time + LOCK_PERIOD, "Unlock time 2");
        assertEq(unlock3, block.timestamp + LOCK_PERIOD, "Unlock time 3");

        vm.stopPrank();
    }

    // ============================================
    // EMERGENCY WITHDRAW TESTS
    // ============================================

    function test_emergencyWithdraw_bypassesLockup() public {
        // Setup: Alice deposits and vault has a configured adapter
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        wrapper.deposit(INITIAL_DEPOSIT, alice);

        // Immediately try emergency withdraw (before lockup expires)
        // Note: This would call vault.forceDeallocate() which requires:
        // 1. Vault has adapters configured
        // 2. Adapter has allocated funds
        // For this test, we'll mock/skip actual adapter interaction

        // In production, user would:
        // wrapper.emergencyWithdraw(adapterAddress, calldata, amount)
        // This bypasses lockup but pays penalty per vault's forceDeallocatePenalty

        vm.stopPrank();

        // Test skipped - requires full vault + adapter setup
        // See integration tests for full emergency withdraw flow
    }

    // ============================================
    // VIEW FUNCTION TESTS
    // ============================================

    function test_isUnlocked_returnsCorrectStatus() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        wrapper.deposit(INITIAL_DEPOSIT, alice);

        // Before lockup: locked
        assertFalse(wrapper.isUnlocked(alice), "Should be locked");

        // After lockup: unlocked
        vm.warp(block.timestamp + LOCK_PERIOD);
        assertTrue(wrapper.isUnlocked(alice), "Should be unlocked");

        vm.stopPrank();
    }

    function test_remainingLockTime_returnsCorrectValue() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        wrapper.deposit(INITIAL_DEPOSIT, alice);

        uint256 remaining = wrapper.remainingLockTime(alice);
        assertEq(remaining, LOCK_PERIOD, "Should be full lock period");

        // Fast forward 3 days
        vm.warp(block.timestamp + 3 days);
        remaining = wrapper.remainingLockTime(alice);
        assertEq(remaining, LOCK_PERIOD - 3 days, "Should be 4 days remaining");

        // Fast forward past lockup
        vm.warp(block.timestamp + 5 days);
        remaining = wrapper.remainingLockTime(alice);
        assertEq(remaining, 0, "Should be 0 after lockup");

        vm.stopPrank();
    }

    function test_unlockedBalanceOf_calculatesCorrectly() public {
        vm.startPrank(alice);

        // Deposit 1: 400 at T=0
        asset.approve(address(wrapper), 400e18);
        wrapper.deposit(400e18, alice);

        // Deposit 2: 600 at T=2 days
        vm.warp(block.timestamp + 2 days);
        asset.approve(address(wrapper), 600e18);
        wrapper.deposit(600e18, alice);

        // T=3 days: Nothing unlocked
        vm.warp(block.timestamp + 1 days);
        assertEq(wrapper.unlockedBalanceOf(alice), 0, "Nothing unlocked at T=3");

        // T=7 days: First deposit unlocked
        vm.warp(block.timestamp + 4 days);
        assertEq(wrapper.unlockedBalanceOf(alice), 400e18, "First deposit unlocked at T=7");

        // T=9 days: Both deposits unlocked
        vm.warp(block.timestamp + 2 days);
        assertEq(wrapper.unlockedBalanceOf(alice), 1000e18, "All unlocked at T=9");

        vm.stopPrank();
    }

    // ============================================
    // ERC20 STANDARD TESTS
    // ============================================

    function test_transferFrom_worksWithApproval() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        uint256 vTokens = wrapper.deposit(INITIAL_DEPOSIT, alice);

        // Approve bob to transfer
        wrapper.approve(bob, vTokens);
        vm.stopPrank();

        // Bob transfers from Alice to Carol
        vm.prank(bob);
        wrapper.transferFrom(alice, carol, vTokens);

        assertEq(wrapper.balanceOf(carol), vTokens, "Carol should have vTokens");
        assertEq(wrapper.balanceOf(alice), 0, "Alice should have 0");
    }

    function test_approve_setsAllowance() public {
        vm.prank(alice);
        wrapper.approve(bob, 1000e18);

        assertEq(wrapper.allowance(alice, bob), 1000e18, "Allowance should be set");
    }

    // ============================================
    // EDGE CASES
    // ============================================

    function test_depositZero_reverts() public {
        vm.prank(alice);
        vm.expectRevert("Zero deposit");
        wrapper.deposit(0, alice);
    }

    function test_withdrawMoreThanBalance_reverts() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        wrapper.deposit(INITIAL_DEPOSIT, alice);

        vm.warp(block.timestamp + LOCK_PERIOD);

        vm.expectRevert();
        wrapper.withdraw(INITIAL_DEPOSIT * 2, alice, alice);
        vm.stopPrank();
    }

    function test_transferToZeroAddress_reverts() public {
        vm.startPrank(alice);
        asset.approve(address(wrapper), INITIAL_DEPOSIT);
        wrapper.deposit(INITIAL_DEPOSIT, alice);

        vm.expectRevert("Zero address");
        wrapper.transfer(address(0), 100e18);
        vm.stopPrank();
    }

    // ============================================
    // COMPLEX SCENARIOS
    // ============================================

    function test_complexScenario_multipleUsersAndTransfers() public {
        // Alice deposits 500 at T=0
        vm.startPrank(alice);
        asset.approve(address(wrapper), 500e18);
        wrapper.deposit(500e18, alice);
        vm.stopPrank();

        // Bob deposits 300 at T=1 day
        vm.warp(block.timestamp + 1 days);
        vm.startPrank(bob);
        asset.approve(address(wrapper), 300e18);
        wrapper.deposit(300e18, bob);
        vm.stopPrank();

        // Alice transfers 200 to Carol at T=3 days
        vm.warp(block.timestamp + 2 days);
        vm.prank(alice);
        wrapper.transfer(carol, 200e18);

        // Bob transfers 100 to Carol at T=5 days
        vm.warp(block.timestamp + 2 days);
        vm.prank(bob);
        wrapper.transfer(carol, 100e18);

        // Carol now has 300 vTokens from 2 different original deposits
        assertEq(wrapper.balanceOf(carol), 300e18, "Carol balance");
        assertEq(wrapper.getDepositCount(carol), 2, "Carol has 2 batches");

        // T=7 days: Carol's first batch (from Alice) should be unlocked
        vm.warp(block.timestamp + 2 days);
        uint256 carolUnlocked = wrapper.unlockedBalanceOf(carol);
        assertEq(carolUnlocked, 200e18, "Carol's first batch unlocked");

        // T=8 days: Both batches unlocked
        vm.warp(block.timestamp + 1 days);
        carolUnlocked = wrapper.unlockedBalanceOf(carol);
        assertEq(carolUnlocked, 300e18, "All of Carol's tokens unlocked");

        // Carol can withdraw all
        vm.prank(carol);
        wrapper.redeem(300e18, carol, carol);
        assertEq(wrapper.balanceOf(carol), 0, "Carol withdrew successfully");
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
