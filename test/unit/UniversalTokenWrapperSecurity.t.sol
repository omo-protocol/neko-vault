// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {UniversalTokenWrapper} from "../../src/wrapper/UniversalTokenWrapper.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract UniversalTokenWrapperSecurityTest is Test {
    UniversalTokenWrapper public wrapper;
    MockERC20 public token;

    address public alice = address(0x10);  // Changed from 0x1 to avoid collision with DEAD_ADDRESS
    address public bob = address(0x20);    // Changed from 0x2 for consistency

    function setUp() public {
        token = new MockERC20("Test Token", "TT", 18);
        wrapper = new UniversalTokenWrapper(address(token), "Wrapped TT", "wTT");

        // Mint tokens to test users
        token.mint(alice, 1000e18);
        token.mint(bob, 1000e18);

        vm.prank(alice);
        token.approve(address(wrapper), type(uint256).max);
        vm.prank(bob);
        token.approve(address(wrapper), type(uint256).max);
    }

    function testDepositCalculatesSharesCorrectly() public {
        // Alice deposits first
        uint256 aliceDeposit = 100e18;
        vm.prank(alice);
        uint256 aliceShares = wrapper.deposit(aliceDeposit, alice);

        // First depositor gets deposit minus virtual shares (1000 shares locked in dead address)
        uint256 VIRTUAL_SHARES = 1000;
        assertEq(aliceShares, aliceDeposit - VIRTUAL_SHARES, "First deposit should mint deposit-virtualShares");
        assertEq(wrapper.balanceOf(alice), aliceDeposit - VIRTUAL_SHARES, "Alice should have correct shares");

        // Bob deposits after Alice
        uint256 bobDeposit = 50e18;
        uint256 expectedBobShares = (bobDeposit * wrapper.totalSupply()) / wrapper.totalAssets();

        vm.prank(bob);
        uint256 bobShares = wrapper.deposit(bobDeposit, bob);

        // Bob should get correct proportion of shares based on pre-deposit state
        assertEq(bobShares, expectedBobShares, "Bob should get correct shares");
        assertEq(wrapper.balanceOf(bob), expectedBobShares, "Bob balance should match");

        // Verify exchange rate hasn't been inflated by incorrect calculation
        uint256 aliceAssets = wrapper.convertToAssets(aliceShares);
        uint256 bobAssets = wrapper.convertToAssets(bobShares);

        // Alice gets slightly less due to virtual shares cost (security trade-off)
        // The VIRTUAL_SHARES are permanently locked as donation attack protection
        assertApproxEqAbs(aliceAssets, aliceDeposit - VIRTUAL_SHARES, 1, "Alice redeems deposit minus virtual shares");
        assertApproxEqAbs(bobAssets, bobDeposit, 1, "Bob should be able to redeem full deposit");
    }

    function testNoZeroShareMinting() public {
        // Alice makes initial deposit
        vm.prank(alice);
        wrapper.deposit(1000e18, alice);

        // Bob tries small deposit that would previously mint 0 shares
        uint256 smallDeposit = 10; // 10 wei
        vm.prank(bob);
        uint256 bobShares = wrapper.deposit(smallDeposit, bob);

        // Bob should receive non-zero shares
        assertGt(bobShares, 0, "Small deposits should still mint non-zero shares");
    }

    function testMintFunctionWorksAfterFirstDeposit() public {
        // Alice deposits first
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        // Bob uses mint function (this would previously revert)
        uint256 sharesToMint = 50e18;
        uint256 assetsNeeded = wrapper.previewMint(sharesToMint);

        vm.prank(bob);
        uint256 assetsSpent = wrapper.mint(sharesToMint, bob);

        assertEq(wrapper.balanceOf(bob), sharesToMint, "Bob should receive requested shares");
        assertEq(assetsSpent, assetsNeeded, "Assets spent should match preview");
    }

    function testPreviewFunctionsMatchActualOperations() public {
        // Initial deposit
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        // Test deposit preview
        uint256 depositAmount = 50e18;
        uint256 previewedShares = wrapper.previewDeposit(depositAmount);

        vm.prank(bob);
        uint256 actualShares = wrapper.deposit(depositAmount, bob);

        assertEq(actualShares, previewedShares, "Deposit preview should match actual");

        // Test mint preview
        uint256 sharesToMint = 25e18;
        uint256 previewedAssets = wrapper.previewMint(sharesToMint);

        vm.prank(alice);
        uint256 actualAssets = wrapper.mint(sharesToMint, alice);

        assertEq(actualAssets, previewedAssets, "Mint preview should match actual");

        // Test withdraw preview
        uint256 assetsToWithdraw = 10e18;
        uint256 previewedSharesBurn = wrapper.previewWithdraw(assetsToWithdraw);

        vm.prank(alice);
        uint256 actualSharesBurned = wrapper.withdraw(assetsToWithdraw, alice, alice);

        assertEq(actualSharesBurned, previewedSharesBurn, "Withdraw preview should match actual");
    }

    function testShareCalculationWithRebase() public {
        // Alice deposits
        vm.prank(alice);
        wrapper.deposit(100e18, alice);

        // Simulate positive rebase by minting tokens directly to wrapper
        token.mint(address(wrapper), 20e18); // 20% rebase

        // Bob deposits after rebase
        uint256 bobDeposit = 60e18;
        uint256 totalAssetsBefore = wrapper.totalAssets(); // 120e18
        uint256 totalSupplyBefore = wrapper.totalSupply(); // 100e18
        uint256 expectedBobShares = (bobDeposit * totalSupplyBefore) / totalAssetsBefore; // 60*100/120 = 50

        vm.prank(bob);
        uint256 bobShares = wrapper.deposit(bobDeposit, bob);

        assertEq(bobShares, expectedBobShares, "Bob should get correct shares after rebase");

        // Verify both can withdraw proportionally
        uint256 aliceValue = wrapper.convertToAssets(wrapper.balanceOf(alice));
        uint256 bobValue = wrapper.convertToAssets(wrapper.balanceOf(bob));

        // Alice should have her original 100 + rebase gains, minus her proportional share of virtual shares cost
        // Virtual shares (1000) locked in dead address also get proportional rebase value (1200 wei worth)
        // Alice has (100e18 - 1000) shares out of 100e18 total, so gets (120e18 - 1200) = 119999999999999998800
        assertApproxEqAbs(aliceValue, 120e18 - 1200, 2, "Alice should have original + rebase gains minus virtual shares cost");
        // Bob should have his 60
        assertApproxEqAbs(bobValue, 60e18, 1, "Bob should have his deposit value");
    }

    function testFuzzDepositShareCalculation(uint256 initialDeposit, uint256 secondDeposit) public {
        uint256 VIRTUAL_SHARES = 1000;
        initialDeposit = bound(initialDeposit, VIRTUAL_SHARES + 1e6, 1000e18); // Must be > VIRTUAL_SHARES
        secondDeposit = bound(secondDeposit, 1e6, 1000e18);

        // First deposit
        vm.prank(alice);
        uint256 aliceShares = wrapper.deposit(initialDeposit, alice);

        assertEq(aliceShares, initialDeposit - VIRTUAL_SHARES, "First deposit should be deposit-virtualShares");

        // Second deposit - verify shares are calculated correctly
        uint256 expectedBobShares = (secondDeposit * wrapper.totalSupply()) / wrapper.totalAssets();

        vm.prank(bob);
        uint256 bobShares = wrapper.deposit(secondDeposit, bob);

        assertEq(bobShares, expectedBobShares, "Second deposit shares should be calculated correctly");

        // Verify total value is preserved
        uint256 totalAssetsAfter = wrapper.totalAssets();
        assertEq(totalAssetsAfter, initialDeposit + secondDeposit, "Total assets should equal sum of deposits");
    }
}
