// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {UniversalTokenWrapper} from "../../src/wrapper/UniversalTokenWrapper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSenderChargedFeeToken} from "../mocks/MockSenderChargedFeeToken.sol";

/**
 * @title UniversalTokenWrapperWithdrawSecurity
 * @notice Tests for MEDIUM severity vulnerability: withdraw/redeem balance delta measurement
 * @dev Verifies that withdraw/redeem correctly measure actual balance delta to prevent
 *      exchange rate manipulation when using tokens with sender-charged fees
 */
contract UniversalTokenWrapperWithdrawSecurity is Test {
    UniversalTokenWrapper public wrapper;
    UniversalTokenWrapper public feeWrapper;
    MockERC20 public token;
    MockSenderChargedFeeToken public feeToken;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public carol = address(0x3);

    function setUp() public {
        // Setup standard token wrapper
        token = new MockERC20("Test Token", "TT", 18);
        wrapper = new UniversalTokenWrapper(address(token), "Wrapped TT", "wTT");

        // Setup sender-charged fee token wrapper (10% sender fee)
        feeToken = new MockSenderChargedFeeToken("Fee Token", "FT", 18);
        feeWrapper = new UniversalTokenWrapper(address(feeToken), "Wrapped FT", "wFT");

        // Mint tokens to test users
        token.mint(alice, 10000e18);
        token.mint(bob, 10000e18);
        token.mint(carol, 10000e18);

        feeToken.mint(alice, 10000e18);
        feeToken.mint(bob, 10000e18);
        feeToken.mint(carol, 10000e18);

        // Approve wrappers
        vm.prank(alice);
        token.approve(address(wrapper), type(uint256).max);
        vm.prank(bob);
        token.approve(address(wrapper), type(uint256).max);
        vm.prank(carol);
        token.approve(address(wrapper), type(uint256).max);

        vm.prank(alice);
        feeToken.approve(address(feeWrapper), type(uint256).max);
        vm.prank(bob);
        feeToken.approve(address(feeWrapper), type(uint256).max);
        vm.prank(carol);
        feeToken.approve(address(feeWrapper), type(uint256).max);
    }

    /* ============ STANDARD TOKEN TESTS (Baseline) ============ */

    function testStandardTokenWithdrawMaintainsExchangeRate() public {
        // Alice deposits 1000
        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        // Bob deposits 1000
        vm.prank(bob);
        wrapper.deposit(1000e18, bob);

        // Total: 2000 tokens, 2000 shares (1:1 rate)
        assertEq(wrapper.totalAssets(), 2000e18);
        assertEq(wrapper.totalSupply(), 2000e18);

        // Alice withdraws 500
        vm.prank(alice);
        wrapper.withdraw(500e18, alice, alice);

        // After withdraw: 1500 tokens, 1500 shares (still 1:1 rate)
        assertEq(wrapper.totalAssets(), 1500e18, "Total assets should be 1500");
        assertEq(wrapper.totalSupply(), 1500e18, "Total supply should be 1500");

        // Exchange rate should remain 1:1
        uint256 aliceValue = wrapper.convertToAssets(wrapper.balanceOf(alice));
        uint256 bobValue = wrapper.convertToAssets(wrapper.balanceOf(bob));

        assertEq(aliceValue, 500e18, "Alice should have 500 worth");
        assertEq(bobValue, 1000e18, "Bob should have 1000 worth");
    }

    function testStandardTokenRedeemMaintainsExchangeRate() public {
        // Alice deposits 1000
        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        // Bob deposits 1000
        vm.prank(bob);
        wrapper.deposit(1000e18, bob);

        // Alice redeems 500 shares
        vm.prank(alice);
        wrapper.redeem(500e18, alice, alice);

        // Exchange rate should remain 1:1
        assertEq(wrapper.totalAssets(), 1500e18);
        assertEq(wrapper.totalSupply(), 1500e18);
    }

    /* ============ SENDER-CHARGED FEE TOKEN TESTS (Vulnerability) ============ */

    function testSenderChargedFeeWithdrawPreventExchangeRateManipulation() public {
        // Alice deposits 1000 (pays 1100 due to 10% sender fee)
        vm.prank(alice);
        uint256 aliceShares = feeWrapper.deposit(1000e18, alice);

        // Bob deposits 1000 (pays 1100 due to 10% sender fee)
        vm.prank(bob);
        uint256 bobShares = feeWrapper.deposit(1000e18, bob);

        // Total: 2000 tokens in wrapper, shares minted based on received amounts
        uint256 totalAssetsBefore = feeWrapper.totalAssets();
        uint256 totalSupplyBefore = feeWrapper.totalSupply();

        console2.log("Before withdraw:");
        console2.log("  Total assets:", totalAssetsBefore);
        console2.log("  Total supply:", totalSupplyBefore);
        console2.log("  Exchange rate:", (totalAssetsBefore * 1e18) / totalSupplyBefore);

        // Alice attempts to withdraw 500
        // OLD BEHAVIOR: Would burn shares for 500, but balance would drop by 550 (500 + 50 fee)
        // NEW BEHAVIOR: Burns shares for 500, measures actual delta, ensures correctness
        vm.prank(alice);
        feeWrapper.withdraw(500e18, alice, alice);

        uint256 totalAssetsAfter = feeWrapper.totalAssets();
        uint256 totalSupplyAfter = feeWrapper.totalSupply();

        console2.log("After withdraw:");
        console2.log("  Total assets:", totalAssetsAfter);
        console2.log("  Total supply:", totalSupplyAfter);
        console2.log("  Exchange rate:", (totalAssetsAfter * 1e18) / totalSupplyAfter);

        // CRITICAL: Exchange rate should NOT deteriorate for remaining holders
        // The ratio totalAssets/totalSupply should remain roughly constant
        uint256 rateBefore = (totalAssetsBefore * 1e18) / totalSupplyBefore;
        uint256 rateAfter = (totalAssetsAfter * 1e18) / totalSupplyAfter;

        // Allow for small rounding differences (< 0.01%)
        uint256 rateDiff = rateAfter > rateBefore ? rateAfter - rateBefore : rateBefore - rateAfter;
        uint256 maxDiff = rateBefore / 10000; // 0.01%

        assertLe(rateDiff, maxDiff, "Exchange rate should not deteriorate");

        // Bob should still be able to redeem his proportional share
        uint256 bobBalanceBefore = feeToken.balanceOf(bob);
        vm.prank(bob);
        feeWrapper.redeem(bobShares, bob, bob);
        uint256 bobBalanceAfter = feeToken.balanceOf(bob);

        // Bob should receive approximately his original deposit worth
        uint256 bobReceived = bobBalanceAfter - bobBalanceBefore;
        console2.log("Bob received:", bobReceived);

        // Bob should not be unfairly penalized by Alice's withdrawal
        assertGt(bobReceived, 900e18, "Bob should receive most of his deposit back");
    }

    function testSenderChargedFeeRedeemBehavior() public {
        // CRITICAL FIX (4_xx.md): redeem() now burns additional shares when sender fees cause extra outflow
        // This prevents exchange rate dilution and protects remaining holders

        // Setup: Multiple depositors
        vm.prank(alice);
        uint256 aliceShares = feeWrapper.deposit(1000e18, alice);

        vm.prank(bob);
        feeWrapper.deposit(1000e18, bob);

        vm.prank(carol);
        feeWrapper.deposit(1000e18, carol);

        uint256 totalAssetsBefore = feeWrapper.totalAssets();
        uint256 totalSupplyBefore = feeWrapper.totalSupply();

        // Record Alice's initial share balance
        uint256 aliceSharesBefore = feeWrapper.balanceOf(alice);

        // Alice redeems half her shares
        vm.prank(alice);
        uint256 assetsReceived = feeWrapper.redeem(aliceShares / 2, alice, alice);

        uint256 totalAssetsAfter = feeWrapper.totalAssets();
        uint256 totalSupplyAfter = feeWrapper.totalSupply();

        // CRITICAL: With the fix, additional shares are burned to account for sender fees
        // So Alice may have fewer shares remaining than expected
        uint256 aliceSharesAfter = feeWrapper.balanceOf(alice);
        uint256 sharesBurned = aliceSharesBefore - aliceSharesAfter;

        console2.log("Shares requested to burn:", aliceShares / 2);
        console2.log("Shares actually burned:", sharesBurned);
        console2.log("Assets received:", assetsReceived);

        // With sender-charged fees, more shares should be burned than requested
        assertGe(sharesBurned, aliceShares / 2, "Should burn at least requested shares");

        // CRITICAL: Exchange rate should be preserved (or improve slightly due to rounding)
        uint256 rateBefore = (totalAssetsBefore * 1e18) / totalSupplyBefore;
        uint256 rateAfter = (totalAssetsAfter * 1e18) / totalSupplyAfter;

        console2.log("Exchange rate before:", rateBefore);
        console2.log("Exchange rate after:", rateAfter);

        // Rate should not deteriorate (it may improve slightly due to the fix)
        // Allow for 0.1% tolerance due to rounding
        uint256 maxDiff = rateBefore / 1000;
        assertGe(rateAfter + maxDiff, rateBefore, "Exchange rate should not deteriorate");

        // Alice still receives reasonable assets
        assertGt(assetsReceived, 400e18, "Alice should receive reasonable assets for her shares");
    }

    function testMultipleWithdrawalsPreserveExchangeRate() public {
        // Setup: All three users deposit
        vm.prank(alice);
        feeWrapper.deposit(1000e18, alice);

        vm.prank(bob);
        feeWrapper.deposit(1000e18, bob);

        vm.prank(carol);
        feeWrapper.deposit(1000e18, carol);

        uint256 initialRate = (feeWrapper.totalAssets() * 1e18) / feeWrapper.totalSupply();

        // Multiple withdrawals
        vm.prank(alice);
        feeWrapper.withdraw(100e18, alice, alice);

        vm.prank(bob);
        feeWrapper.withdraw(200e18, bob, bob);

        vm.prank(carol);
        feeWrapper.withdraw(300e18, carol, carol);

        uint256 finalRate = (feeWrapper.totalAssets() * 1e18) / feeWrapper.totalSupply();

        uint256 rateDiff = finalRate > initialRate ? finalRate - initialRate : initialRate - finalRate;
        uint256 maxDiff = initialRate / 1000; // 0.1% tolerance for multiple operations

        assertLe(rateDiff, maxDiff, "Exchange rate should remain stable across multiple withdrawals");
    }

    function testWithdrawEmitsCorrectActualAmount() public {
        vm.prank(alice);
        feeWrapper.deposit(1000e18, alice);

        uint256 wrapperBalanceBefore = feeToken.balanceOf(address(feeWrapper));

        // Withdraw 100 tokens
        vm.prank(alice);
        vm.expectEmit(true, true, true, false);
        // The event should emit the ACTUAL transferred amount (100 + 10 fee = 110)
        // But we can't easily test the exact amount in the emit check
        emit UniversalTokenWrapper.Withdraw(alice, alice, alice, 0, 0); // Partial match

        feeWrapper.withdraw(100e18, alice, alice);

        uint256 wrapperBalanceAfter = feeToken.balanceOf(address(feeWrapper));
        uint256 actualTransferred = wrapperBalanceBefore - wrapperBalanceAfter;

        // Actual transferred should be 110 (100 + 10% fee)
        assertEq(actualTransferred, 110e18, "Actual transferred should include sender fee");
    }

    function testRedeemEmitsCorrectActualAmount() public {
        vm.prank(alice);
        uint256 shares = feeWrapper.deposit(1000e18, alice);

        uint256 wrapperBalanceBefore = feeToken.balanceOf(address(feeWrapper));

        // Redeem shares
        vm.prank(alice);
        feeWrapper.redeem(shares / 2, alice, alice);

        uint256 wrapperBalanceAfter = feeToken.balanceOf(address(feeWrapper));
        uint256 actualTransferred = wrapperBalanceBefore - wrapperBalanceAfter;

        // Actual transferred should be > nominal due to sender fee
        uint256 nominalAmount = feeWrapper.previewRedeem(shares / 2);
        assertGt(actualTransferred, nominalAmount, "Actual transferred should exceed nominal");
    }

    function testHighSenderFeeScenario() public {
        // Create wrapper with 20% sender fee
        MockSenderChargedFeeToken highFeeToken = new MockSenderChargedFeeToken("High Fee", "HF", 18);
        highFeeToken.setSenderFeeBps(2000); // 20% fee
        UniversalTokenWrapper highFeeWrapper = new UniversalTokenWrapper(
            address(highFeeToken),
            "Wrapped HF",
            "wHF"
        );

        highFeeToken.mint(alice, 10000e18);
        highFeeToken.mint(bob, 10000e18);

        vm.prank(alice);
        highFeeToken.approve(address(highFeeWrapper), type(uint256).max);
        vm.prank(bob);
        highFeeToken.approve(address(highFeeWrapper), type(uint256).max);

        // Deposits
        vm.prank(alice);
        highFeeWrapper.deposit(1000e18, alice);

        vm.prank(bob);
        highFeeWrapper.deposit(1000e18, bob);

        uint256 rateBefore = (highFeeWrapper.totalAssets() * 1e18) / highFeeWrapper.totalSupply();

        // Withdraw with high fee
        vm.prank(alice);
        highFeeWrapper.withdraw(500e18, alice, alice);

        uint256 rateAfter = (highFeeWrapper.totalAssets() * 1e18) / highFeeWrapper.totalSupply();

        // Even with high fees, exchange rate should remain stable
        uint256 rateDiff = rateAfter > rateBefore ? rateAfter - rateBefore : rateBefore - rateAfter;
        uint256 maxDiff = rateBefore / 1000; // 0.1%

        assertLe(rateDiff, maxDiff, "Exchange rate stable even with high sender fee");
    }

    function testFuzzWithdrawPreservesExchangeRate(
        uint256 depositAmount,
        uint256 withdrawAmount,
        uint8 feeBps
    ) public {
        // Bound inputs
        depositAmount = bound(depositAmount, 100e18, 5000e18);
        withdrawAmount = bound(withdrawAmount, 10e18, depositAmount / 2);
        feeBps = uint8(bound(feeBps, 100, 2000)); // 1% to 20%

        // Create custom fee token
        MockSenderChargedFeeToken customFeeToken = new MockSenderChargedFeeToken("Custom", "CT", 18);
        customFeeToken.setSenderFeeBps(feeBps);
        UniversalTokenWrapper customWrapper = new UniversalTokenWrapper(
            address(customFeeToken),
            "Wrapped CT",
            "wCT"
        );

        customFeeToken.mint(alice, depositAmount * 3); // Extra for fees
        customFeeToken.mint(bob, depositAmount * 3);

        vm.prank(alice);
        customFeeToken.approve(address(customWrapper), type(uint256).max);
        vm.prank(bob);
        customFeeToken.approve(address(customWrapper), type(uint256).max);

        // Deposits
        vm.prank(alice);
        customWrapper.deposit(depositAmount, alice);

        vm.prank(bob);
        customWrapper.deposit(depositAmount, bob);

        uint256 rateBefore = (customWrapper.totalAssets() * 1e18) / customWrapper.totalSupply();

        // Withdraw
        vm.prank(alice);
        customWrapper.withdraw(withdrawAmount, alice, alice);

        uint256 rateAfter = (customWrapper.totalAssets() * 1e18) / customWrapper.totalSupply();

        // Exchange rate should remain stable (within 0.1% tolerance)
        uint256 rateDiff = rateAfter > rateBefore ? rateAfter - rateBefore : rateBefore - rateAfter;
        uint256 maxDiff = rateBefore / 1000; // 0.1%

        assertLe(rateDiff, maxDiff, "Fuzz: Exchange rate should remain stable");
    }

    /// @notice Test that redeem() attack from 4_xx.md is prevented
    /// @dev Verifies that additional shares are burned to prevent exchange rate dilution
    function testRedeemUnderBurnAttackPrevented() public {
        // Scenario from 4_xx.md: Partial exit with percentage sender fee
        // A=S=1000, 5% sender fee, attacker redeems 100 shares
        // Before fix: burns 100 shares, transfers 100 assets, wrapper loses 105 → ER degrades to ~0.9944
        // After fix: burns ~105 shares to maintain ER

        // Setup with 5% sender fee
        MockSenderChargedFeeToken attackToken = new MockSenderChargedFeeToken("Attack", "ATK", 18);
        attackToken.setSenderFeeBps(500); // 5%
        UniversalTokenWrapper attackWrapper = new UniversalTokenWrapper(
            address(attackToken),
            "Wrapped ATK",
            "wATK"
        );

        // Mint and setup
        attackToken.mint(alice, 2000e18);
        attackToken.mint(bob, 2000e18);

        vm.prank(alice);
        attackToken.approve(address(attackWrapper), type(uint256).max);
        vm.prank(bob);
        attackToken.approve(address(attackWrapper), type(uint256).max);

        // Both users deposit 1000 each
        vm.prank(alice);
        uint256 aliceShares = attackWrapper.deposit(1000e18, alice);

        vm.prank(bob);
        attackWrapper.deposit(1000e18, bob);

        // Verify initial state: A≈S≈1000 (minus virtual shares)
        uint256 totalAssetsBefore = attackWrapper.totalAssets();
        uint256 totalSupplyBefore = attackWrapper.totalSupply();
        uint256 exchangeRateBefore = (totalAssetsBefore * 1e18) / totalSupplyBefore;

        console2.log("Initial total assets:", totalAssetsBefore);
        console2.log("Initial total supply:", totalSupplyBefore);
        console2.log("Initial exchange rate:", exchangeRateBefore);

        // Alice redeems 100 shares
        uint256 sharesToRedeem = 100e18;
        uint256 aliceSharesBefore = attackWrapper.balanceOf(alice);

        vm.prank(alice);
        uint256 assetsReceived = attackWrapper.redeem(sharesToRedeem, alice, alice);

        uint256 aliceSharesAfter = attackWrapper.balanceOf(alice);
        uint256 sharesBurned = aliceSharesBefore - aliceSharesAfter;

        uint256 totalAssetsAfter = attackWrapper.totalAssets();
        uint256 totalSupplyAfter = attackWrapper.totalSupply();
        uint256 exchangeRateAfter = (totalAssetsAfter * 1e18) / totalSupplyAfter;

        console2.log("Shares requested to burn:", sharesToRedeem);
        console2.log("Shares actually burned:", sharesBurned);
        console2.log("Assets received by Alice:", assetsReceived);
        console2.log("Total assets after:", totalAssetsAfter);
        console2.log("Total supply after:", totalSupplyAfter);
        console2.log("Exchange rate after:", exchangeRateAfter);

        // CRITICAL: More shares should have been burned than requested (due to 5% fee)
        // Expected: ~105e18 shares burned (100e18 + 5%)
        assertGt(sharesBurned, sharesToRedeem, "Should burn more shares than requested");
        assertApproxEqRel(sharesBurned, 105e18, 0.01e18, "Should burn ~105 shares for 5% fee");

        // CRITICAL: Exchange rate should be preserved
        // Allow 0.1% tolerance for rounding
        uint256 rateDiff = exchangeRateAfter > exchangeRateBefore
            ? exchangeRateAfter - exchangeRateBefore
            : exchangeRateBefore - exchangeRateAfter;
        uint256 maxDiff = exchangeRateBefore / 1000; // 0.1%

        assertLe(rateDiff, maxDiff, "Exchange rate should not deteriorate");

        // Bob's shares should still be worth their original value
        uint256 bobShares = attackWrapper.balanceOf(bob);
        uint256 bobValue = attackWrapper.convertToAssets(bobShares);

        console2.log("Bob's remaining shares:", bobShares);
        console2.log("Bob's share value:", bobValue);

        // Bob should not lose value due to Alice's redeem
        // Allow small rounding error
        assertApproxEqRel(bobValue, 1000e18, 0.01e18, "Bob should not suffer principal loss");
    }

    /// @notice Test repeated small redeems with fixed sender fee
    /// @dev From 4_xx.md: Repeated minimal redeems should not erode exchange rate
    function testRepeatedSmallRedeemsWithFixedFee() public {
        // Setup with 1% fixed sender fee
        MockSenderChargedFeeToken feeToken2 = new MockSenderChargedFeeToken("Fee2", "FEE2", 18);
        feeToken2.setSenderFeeBps(100); // 1%
        UniversalTokenWrapper wrapper2 = new UniversalTokenWrapper(address(feeToken2), "wFEE2", "wFEE2");

        // Mint tokens
        feeToken2.mint(alice, 10000e18);
        feeToken2.mint(bob, 10000e18);

        vm.prank(alice);
        feeToken2.approve(address(wrapper2), type(uint256).max);
        vm.prank(bob);
        feeToken2.approve(address(wrapper2), type(uint256).max);

        // Both deposit
        vm.prank(alice);
        wrapper2.deposit(1000e18, alice);

        vm.prank(bob);
        wrapper2.deposit(1000e18, bob);

        uint256 initialRate = (wrapper2.totalAssets() * 1e18) / wrapper2.totalSupply();

        // Alice performs 10 small redeems
        for (uint256 i = 0; i < 10; i++) {
            vm.prank(alice);
            wrapper2.redeem(10e18, alice, alice);
        }

        uint256 finalRate = (wrapper2.totalAssets() * 1e18) / wrapper2.totalSupply();

        console2.log("Initial rate:", initialRate);
        console2.log("Final rate after 10 redeems:", finalRate);

        // Exchange rate should remain stable
        uint256 rateDiff = finalRate > initialRate ? finalRate - initialRate : initialRate - finalRate;
        uint256 maxDiff = initialRate / 1000; // 0.1%

        assertLe(rateDiff, maxDiff, "Exchange rate should not erode with repeated redeems");

        // Bob should not lose value
        uint256 bobValue = wrapper2.convertToAssets(wrapper2.balanceOf(bob));
        assertApproxEqRel(bobValue, 1000e18, 0.01e18, "Bob should not lose value");
    }
}
