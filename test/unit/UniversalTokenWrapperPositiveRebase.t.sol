// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {UniversalTokenWrapper} from "../../src/wrapper/UniversalTokenWrapper.sol";
import {MockPositiveRebaseToken} from "../mocks/MockPositiveRebaseToken.sol";

/**
 * @title UniversalTokenWrapperPositiveRebaseTest
 * @notice Tests for positive rebase token handling in UniversalTokenWrapper
 * @dev SECURITY ISSUE: Unchecked balance-delta subtraction causes DoS when positive rebases occur
 *
 *      Vulnerability: In withdraw() and redeem(), the code does:
 *        uint256 actualTransferred = beforeBal - afterBal;
 *
 *      If a positive rebase occurs during the transfer (afterBal > beforeBal),
 *      this subtraction will underflow and revert, causing DoS.
 *
 *      This affects:
 *      - Positive rebasing tokens (e.g., stETH during rebases, aTokens)
 *      - Tokens that mint on transfer (reward tokens)
 *      - Tokens with on-transfer credits
 */
contract UniversalTokenWrapperPositiveRebaseTest is Test {
    UniversalTokenWrapper public wrapper;
    MockPositiveRebaseToken public rebaseToken;

    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        // Create token that rebases positively on transfer (1% rebase)
        rebaseToken = new MockPositiveRebaseToken("Rebase Token", "RBASE", 18);
        wrapper = new UniversalTokenWrapper(address(rebaseToken), "Wrapped Rebase", "wRBASE");

        // Mint tokens
        rebaseToken.mint(alice, 10000e18);
        rebaseToken.mint(bob, 10000e18);

        // Approve
        vm.prank(alice);
        rebaseToken.approve(address(wrapper), type(uint256).max);
        vm.prank(bob);
        rebaseToken.approve(address(wrapper), type(uint256).max);
    }

    /* ============ VULNERABILITY DEMONSTRATION ============ */

    /**
     * @notice Demonstrates the DoS vulnerability with withdraw()
     * @dev BEFORE FIX: This test will revert due to underflow
     *      AFTER FIX: This test should pass
     */
    function testWithdrawDoSWithPositiveRebase() public {
        // Alice deposits normally
        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        console2.log("Wrapper balance after deposit:", rebaseToken.balanceOf(address(wrapper)));

        // Enable AGGRESSIVE positive rebase (60% of original balance)
        // This will cause: balance after transfer (500) + rebase (600) = 1100 > 1000 (before)
        rebaseToken.setPositiveRebaseOnTransfer(6000); // 60%
        rebaseToken.setAggressiveRebase(true); // Rebase based on balance BEFORE transfer

        console2.log("Before withdraw - wrapper balance:", rebaseToken.balanceOf(address(wrapper)));

        // Alice tries to withdraw 500 (50% of balance)
        // Expected: beforeBal=1000, transfer=500, afterBal=500, rebase=600, final=1100
        // VULNERABILITY: afterBal (1100) > beforeBal (1000) → subtraction will UNDERFLOW
        vm.prank(alice);

        // BEFORE FIX: This will revert with arithmetic underflow
        // AFTER FIX: This should succeed
        wrapper.withdraw(500e18, alice, alice);

        console2.log("After withdraw - wrapper balance:", rebaseToken.balanceOf(address(wrapper)));

        // If we get here, the fix is working
        assertGt(rebaseToken.balanceOf(alice), 500e18, "Alice should receive at least 500e18");
    }

    /**
     * @notice Demonstrates the DoS vulnerability with redeem()
     * @dev BEFORE FIX: This test will revert due to underflow
     *      AFTER FIX: This test should pass
     */
    function testRedeemDoSWithPositiveRebase() public {
        // Alice deposits normally
        vm.prank(alice);
        uint256 shares = wrapper.deposit(1000e18, alice);

        // Enable positive rebase (1% rebase on transfer)
        rebaseToken.setPositiveRebaseOnTransfer(100); // 1%

        // Alice tries to redeem
        // VULNERABILITY: If afterBal > beforeBal due to rebase, subtraction will underflow
        vm.prank(alice);

        // BEFORE FIX: This will revert with arithmetic underflow
        // AFTER FIX: This should succeed
        wrapper.redeem(shares / 2, alice, alice);

        // If we get here, the fix is working
        assertGt(rebaseToken.balanceOf(alice), 0, "Alice should receive tokens");
    }

    /**
     * @notice Test that positive rebase doesn't break exchange rate
     * @dev After fix, positive rebases should be treated as profits for the wrapper
     */
    function testPositiveRebaseMaintainsExchangeRate() public {
        // Both users deposit
        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        vm.prank(bob);
        wrapper.deposit(1000e18, bob);

        uint256 rateBefore = (wrapper.totalAssets() * 1e18) / wrapper.totalSupply();

        // Enable AGGRESSIVE positive rebase to trigger the fix
        // This ensures afterBal > beforeBal during withdrawals
        rebaseToken.setPositiveRebaseOnTransfer(6000); // 60%
        rebaseToken.setAggressiveRebase(true);

        // Alice withdraws - this triggers positive rebase
        vm.prank(alice);
        wrapper.withdraw(500e18, alice, alice);

        uint256 rateAfter = (wrapper.totalAssets() * 1e18) / wrapper.totalSupply();

        // Exchange rate should improve significantly due to positive rebase
        assertGt(rateAfter, rateBefore, "Exchange rate should improve from positive rebase");

        // Bob can still withdraw normally (no need to test redeem here)
        vm.prank(bob);
        wrapper.withdraw(100e18, bob, bob);

        assertGt(rebaseToken.balanceOf(bob), 100e18, "Bob should receive at least 100e18");
    }

    /**
     * @notice Test high positive rebase scenario
     * @dev Even with large rebases, withdraw/redeem should work
     */
    function testHighPositiveRebase() public {
        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        // Enable 10% positive rebase (very high)
        rebaseToken.setPositiveRebaseOnTransfer(1000); // 10%

        // Should still be able to withdraw
        vm.prank(alice);
        wrapper.withdraw(500e18, alice, alice);

        // Alice should receive the requested amount + rebase bonus
        assertGe(rebaseToken.balanceOf(alice), 500e18, "Should receive at least requested amount");
    }

    /**
     * @notice Test multiple operations with positive rebase
     * @dev Ensures the system remains functional across multiple txs
     */
    function testMultipleOperationsWithPositiveRebase() public {
        // Enable rebase from the start
        rebaseToken.setPositiveRebaseOnTransfer(100); // 1%

        // Multiple users deposit and withdraw
        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        vm.prank(bob);
        wrapper.deposit(1000e18, bob);

        vm.prank(alice);
        wrapper.withdraw(200e18, alice, alice);

        vm.prank(bob);
        wrapper.redeem(100e18, bob, bob);

        vm.prank(alice);
        wrapper.redeem(50e18, alice, alice);

        // All operations should succeed
        assertTrue(true, "All operations completed successfully");
    }

    /**
     * @notice Test that the wrapper benefits from positive rebases
     * @dev Positive rebases should increase totalAssets without increasing supply
     */
    function testWrapperBenefitsFromPositiveRebase() public {
        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        uint256 assetsBefore = wrapper.totalAssets();
        uint256 supplyBefore = wrapper.totalSupply();

        // Enable rebase
        rebaseToken.setPositiveRebaseOnTransfer(100); // 1%

        // Perform a withdraw (which triggers the rebase)
        vm.prank(alice);
        wrapper.withdraw(100e18, alice, alice);

        uint256 assetsAfter = wrapper.totalAssets();
        uint256 supplyAfter = wrapper.totalSupply();

        // The wrapper should have gained value from the rebase
        // Even after withdrawing 100e18, the wrapper might have more assets due to rebase
        console2.log("Assets before:", assetsBefore);
        console2.log("Assets after:", assetsAfter);
        console2.log("Supply before:", supplyBefore);
        console2.log("Supply after:", supplyAfter);

        // Exchange rate should improve
        uint256 rateBefore = (assetsBefore * 1e18) / supplyBefore;
        uint256 rateAfter = (assetsAfter * 1e18) / supplyAfter;

        assertGe(rateAfter, rateBefore, "Exchange rate should improve from positive rebase");
    }

    /**
     * @notice Fuzz test to ensure no DoS across various rebase percentages
     */
    function testFuzzPositiveRebaseNoDoS(uint256 rebasePercentage, uint256 withdrawAmount) public {
        // Bound inputs
        rebasePercentage = bound(rebasePercentage, 1, 5000); // 0.01% to 50%
        withdrawAmount = bound(withdrawAmount, 1e18, 500e18);

        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        rebaseToken.setPositiveRebaseOnTransfer(rebasePercentage);

        // Should not revert regardless of rebase percentage
        vm.prank(alice);
        wrapper.withdraw(withdrawAmount, alice, alice);

        assertTrue(true, "Withdraw succeeded despite positive rebase");
    }
}
