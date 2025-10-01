// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {UniversalTokenWrapper} from "../../src/wrapper/UniversalTokenWrapper.sol";
import {MockReentrantToken} from "../mocks/MockReentrantToken.sol";

/// @title UniversalTokenWrapperReentrancyTest
/// @notice Tests that reentrancy guard prevents all reentrancy attacks on UniversalTokenWrapper
/// @dev Tests scenarios from 3_xx.md and 3_xx2.md vulnerability reports
contract UniversalTokenWrapperReentrancyTest is Test {
    UniversalTokenWrapper public wrapper;
    MockReentrantToken public token;

    address public alice = address(0x10);
    address public bob = address(0x20);
    ReentrancyAttacker public attacker;

    function setUp() public {
        token = new MockReentrantToken("Test Token", "TT", 18);
        wrapper = new UniversalTokenWrapper(address(token), "Wrapped TT", "wTT");

        // Mint tokens to users
        token.mint(alice, 1000e18);
        token.mint(bob, 1000e18);

        // Deploy attacker contract
        attacker = new ReentrancyAttacker(address(wrapper), address(token));
        token.mint(address(attacker), 1000e18);

        // Approve wrapper
        vm.prank(alice);
        token.approve(address(wrapper), type(uint256).max);
        vm.prank(bob);
        token.approve(address(wrapper), type(uint256).max);
    }

    /// @notice Test that deposit reentrancy is prevented
    /// @dev From 3_xx.md: Nested deposit during outer deposit should revert
    function testDepositReentrancyPrevented() public {
        // Alice makes initial deposit to set up state
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        // Setup reentrancy: when token is transferred, it will try to call deposit again
        bytes memory reentrantCall = abi.encodeWithSelector(
            UniversalTokenWrapper.deposit.selector,
            50e18,
            address(attacker)
        );
        token.setReentrancy(address(wrapper), reentrantCall, true);

        // Attacker tries to deposit with reentrancy
        // The reentrancy guard causes the transfer to fail, which is caught by SafeERC20Lib
        vm.expectRevert(); // Will revert with TransferFromReverted or WRP: reentrant call
        attacker.attackDeposit(100e18);
    }

    /// @notice Test that mint reentrancy is prevented
    /// @dev From 3_xx.md: Nested mint during outer mint should revert
    function testMintReentrancyPrevented() public {
        // Alice makes initial deposit to set up state
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        // Setup reentrancy: when token is transferred, it will try to call mint
        bytes memory reentrantCall = abi.encodeWithSelector(
            UniversalTokenWrapper.mint.selector,
            50e18,
            address(attacker)
        );
        token.setReentrancy(address(wrapper), reentrantCall, true);

        // Attacker tries to mint with reentrancy
        vm.expectRevert(); // Will revert due to reentrancy guard
        attacker.attackMint(100e18);
    }

    /// @notice Test that withdraw reentrancy is prevented (3_xx2.md scenario)
    /// @dev External transfer-before-burn reentrancy should be blocked
    function testWithdrawReentrancyPrevented() public {
        // Setup: Alice and Bob deposit
        vm.prank(alice);
        wrapper.deposit(100e18, alice);
        vm.prank(bob);
        wrapper.deposit(100e18, bob);

        // Attacker deposits
        attacker.initialDeposit(100e18);

        // Setup reentrancy: during withdraw transfer, try to deposit back
        // This would cause under-burning in vulnerable implementation
        bytes memory reentrantCall = abi.encodeWithSelector(
            UniversalTokenWrapper.deposit.selector,
            50e18,
            address(attacker)
        );
        token.setReentrancy(address(wrapper), reentrantCall, true);

        // Attacker tries withdraw with reentrancy
        vm.expectRevert(); // Will revert due to reentrancy guard
        attacker.attackWithdraw(50e18);
    }

    /// @notice Test that redeem reentrancy is prevented
    /// @dev Even though redeem burns first, still test reentrancy protection
    function testRedeemReentrancyPrevented() public {
        // Setup: Alice deposits
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        // Attacker deposits
        attacker.initialDeposit(100e18);

        // Setup reentrancy: during redeem transfer, try to deposit
        bytes memory reentrantCall = abi.encodeWithSelector(
            UniversalTokenWrapper.deposit.selector,
            50e18,
            address(attacker)
        );
        token.setReentrancy(address(wrapper), reentrantCall, true);

        // Attacker tries redeem with reentrancy
        vm.expectRevert(); // Will revert due to reentrancy guard
        attacker.attackRedeem(50e18);
    }

    /// @notice Test first-deposit virtual shares corruption prevention
    /// @dev From 3_xx.md: Prevent multiple virtual shares minting via reentrancy
    function testFirstDepositVirtualSharesCorruptionPrevented() public {
        // Setup reentrancy: during first deposit, try to deposit again
        // This would mint VIRTUAL_SHARES twice in vulnerable implementation
        bytes memory reentrantCall = abi.encodeWithSelector(
            UniversalTokenWrapper.deposit.selector,
            50e18,
            address(attacker)
        );
        token.setReentrancy(address(wrapper), reentrantCall, true);

        // Attacker tries first deposit with reentrancy
        vm.expectRevert(); // Will revert due to reentrancy guard
        attacker.attackDeposit(100e18);
    }

    /// @notice Test iterative small-amount exploitation is prevented (3_xx2.md)
    /// @dev Repeated withdraw with re-deposit should all revert
    function testIterativeExploitationPrevented() public {
        // Setup: Alice and Bob deposit
        vm.prank(alice);
        wrapper.deposit(200e18, alice);
        vm.prank(bob);
        wrapper.deposit(200e18, bob);

        // Attacker deposits
        attacker.initialDeposit(200e18);

        uint256 initialAttackerShares = wrapper.balanceOf(address(attacker));

        // Setup reentrancy
        bytes memory reentrantCall = abi.encodeWithSelector(
            UniversalTokenWrapper.deposit.selector,
            9e18, // Re-deposit slightly less
            address(attacker)
        );
        token.setReentrancy(address(wrapper), reentrantCall, true);

        // Try multiple iterations - all should fail
        for (uint256 i = 0; i < 5; i++) {
            vm.expectRevert(); // Will revert due to reentrancy guard
            attacker.attackWithdraw(10e18);
        }

        // Attacker shares should remain unchanged
        assertEq(wrapper.balanceOf(address(attacker)), initialAttackerShares, "Attacker shares should not increase");
    }

    /// @notice Test that normal operations work without reentrancy
    function testNormalOperationsWithoutReentrancy() public {
        // Disable reentrancy
        token.setReentrancy(address(0), "", false);

        // Normal deposit should work
        vm.prank(alice);
        uint256 shares = wrapper.deposit(100e18, alice);
        assertGt(shares, 0, "Deposit should succeed");

        // Normal withdraw should work
        vm.prank(alice);
        uint256 withdrawn = wrapper.withdraw(50e18, alice, alice);
        assertGt(withdrawn, 0, "Withdraw should succeed");

        // Normal mint should work
        vm.prank(bob);
        uint256 assets = wrapper.mint(50e18, bob);
        assertGt(assets, 0, "Mint should succeed");

        // Normal redeem should work
        vm.prank(bob);
        uint256 redeemed = wrapper.redeem(25e18, bob, bob);
        assertGt(redeemed, 0, "Redeem should succeed");
    }

    /// @notice Fuzz test: Verify reentrancy protection with random amounts
    function testFuzzReentrancyProtection(uint256 depositAmount, uint256 reentrantAmount) public {
        uint256 VIRTUAL_SHARES = 1000;
        depositAmount = bound(depositAmount, VIRTUAL_SHARES + 1e6, 500e18);
        reentrantAmount = bound(reentrantAmount, 1e6, 500e18);

        // Alice makes initial deposit
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        // Setup reentrancy with random amount
        bytes memory reentrantCall = abi.encodeWithSelector(
            UniversalTokenWrapper.deposit.selector,
            reentrantAmount,
            address(attacker)
        );
        token.setReentrancy(address(wrapper), reentrantCall, true);

        // Any deposit should revert due to reentrancy
        vm.expectRevert(); // Will revert due to reentrancy guard
        attacker.attackDeposit(depositAmount);
    }
}

/// @notice Attacker contract that attempts reentrancy attacks
contract ReentrancyAttacker {
    UniversalTokenWrapper public wrapper;
    MockReentrantToken public token;

    constructor(address _wrapper, address _token) {
        wrapper = UniversalTokenWrapper(_wrapper);
        token = MockReentrantToken(_token);
        token.approve(_wrapper, type(uint256).max);
    }

    function initialDeposit(uint256 amount) external {
        wrapper.deposit(amount, address(this));
    }

    function attackDeposit(uint256 amount) external {
        wrapper.deposit(amount, address(this));
    }

    function attackMint(uint256 shares) external {
        wrapper.mint(shares, address(this));
    }

    function attackWithdraw(uint256 assets) external {
        wrapper.withdraw(assets, address(this), address(this));
    }

    function attackRedeem(uint256 shares) external {
        wrapper.redeem(shares, address(this), address(this));
    }
}
