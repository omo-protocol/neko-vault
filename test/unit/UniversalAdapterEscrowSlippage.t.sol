// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

/**
 * @title UniversalAdapterEscrowSlippageTest
 * @notice Tests for slippage protection in deallocate function
 * @dev SECURITY FIX: Tests the minAmountOut parameter that prevents MEV sandwich attacks
 *      during liquidity adapter withdrawals involving DEX swaps
 */
contract UniversalAdapterEscrowSlippageTest is Test {
    UniversalAdapterEscrow public adapter;
    MockERC20 public asset;
    MockValuer public valuer;
    MockVault public vault;
    MockDEX public dex;

    address public owner = address(0x1);
    address public user = address(0x2);
    address public mevBot = address(0x3);

    bytes32 public strategyId = keccak256("test-strategy");

    function setUp() public {
        asset = new MockERC20("Test Token", "TEST", 18);
        valuer = new MockValuer();
        valuer.setAsset(address(asset));
        dex = new MockDEX(address(asset));

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

        // Whitelist DEX functions
        vm.prank(owner);
        adapter.updateWhitelist(address(dex), bytes4(keccak256("deposit(uint256)")), true, 0);

        vm.prank(owner);
        adapter.updateWhitelist(address(dex), bytes4(keccak256("swapAndWithdraw(uint256,uint256)")), true, 0);

        // Approve DEX to pull tokens from adapter
        vm.prank(address(adapter));
        asset.approve(address(dex), type(uint256).max);
    }

    /* ============ BASIC SLIPPAGE PROTECTION TESTS ============ */

    /**
     * @notice Test deallocate with minAmountOut = 0 (no slippage check)
     * @dev UPDATED: With Issue #2 fix (all-or-nothing), insufficient balance causes revert
     */
    function testDeallocateWithNoSlippageCheck() public {
        // Setup: Allocate 1000 tokens and deposit to DEX
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit 90e18 to DEX (9% under circuit breaker threshold) - adapter balance will be 910e18
        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(90e18));

        // NO slippage - DEX returns exactly what's requested
        dex.setSlippagePercent(0);

        // Deallocate with minAmountOut = 0 (no slippage check)
        // Adapter has 910e18, request 950e18 so it must withdraw 40e18 from DEX
        // DEX returns exactly 40e18 (no slippage), total = 910 + 40 = 950e18 ✓
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);
        bytes memory deallocateData = abi.encode(strategyId, 0, false, withdrawCalls); // minAmountOut = 0

        vm.prank(address(vault));
        (, int256 change) = adapter.deallocate(deallocateData, 950e18, bytes4(0x4b219d16), address(0));

        // SECURITY FIX Issue #2: All-or-nothing - must return exact amount
        uint256 returnedAmount = uint256(-change);
        assertEq(returnedAmount, 950e18, "Should return exact requested amount");
    }

    /**
     * @notice Test deallocate with slippage check that passes
     * @dev UPDATED: With Issue #2 fix, DEX must return enough to meet full request
     */
    function testDeallocateWithSlippageCheckPasses() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(90e18));

        // NO slippage so we get exact amount needed
        dex.setSlippagePercent(0);

        // Deallocate with slippage check: adapter has 910e18, request 950e18
        // Must withdraw 40e18 from DEX, which returns exactly 40e18
        // Total return = 910 + 40 = 950e18 ✓
        uint256 requestedAmount = 950e18;
        uint256 minAcceptable = 950e18; // Expect exact amount with Issue #2 fix
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));

        // SECURITY FIX Issue #2: Must return exact requested amount
        uint256 returnedAmount = uint256(-change);
        assertEq(returnedAmount, 950e18, "Should return exact requested amount");
        assertGe(returnedAmount, minAcceptable, "Should meet minimum");
        assertEq(ids[0], strategyId, "Should return correct strategy ID");
    }

    /**
     * @notice Test deallocate with insufficient balance reverts
     * @dev UPDATED: With Issue #2 fix, insufficient balance causes InvalidAmount() revert
     */
    function testDeallocateWithSlippageCheckFails() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(90e18));

        // Set high slippage (10%) so DEX returns less than needed
        dex.setSlippagePercent(10);

        // Deallocate: adapter has 910e18, request 950e18
        // Need to withdraw 40e18 from DEX, but DEX returns only 36e18 (10% slippage)
        // Total = 910 + 36 = 946e18 < 950e18 requested
        uint256 requestedAmount = 950e18;
        uint256 minAcceptable = 948e18;
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        // SECURITY FIX Issue #2: Should revert with InvalidAmount (all-or-nothing)
        // The slippage check never runs because insufficient balance check happens first
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);
        adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));
    }

    /* ============ MEV SANDWICH ATTACK PREVENTION ============ */

    /**
     * @notice Simulate MEV sandwich attack scenario
     * @dev Without slippage protection, MEV bot profits. With protection, tx reverts.
     */
    function testMEVSandwichAttackPrevention() public {
        // Setup: User has 1000 tokens allocated through adapter, all in DEX
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(90e18));

        // Simulate MEV sandwich attack:
        // 1. User initiates withdrawal
        // 2. MEV bot frontruns and manipulates price
        // 3. Adapter's withdrawal gets worse price

        // MEV bot frontrun: manipulate DEX to cause 15% slippage
        vm.prank(mevBot);
        dex.setSlippagePercent(15); // Severe slippage from frontrun

        // User withdrawal with slippage protection
        // Adapter has 910e18, request 950e18, must withdraw 40e18 from DEX
        // With 15% MEV slippage, DEX returns 34e18, total = 910 + 34 = 944e18 < 950e18
        uint256 requestedAmount = 950e18;
        uint256 minAcceptable = 948e18; // 2% tolerance
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        // SECURITY FIX Issue #2: Tx reverts with InvalidAmount (insufficient balance after slippage)
        // The insufficient balance check (944 < 950) happens before slippage check
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);
        adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));

        // MEV bot's attack is prevented - user doesn't lose funds
    }

    /**
     * @notice Test that slippage check doesn't affect normal balance-only withdrawals
     * @dev When adapter has sufficient balance, no DEX interaction needed
     */
    function testSlippageCheckWithSufficientBalance() public {
        // Setup: All tokens stay in adapter (no external protocol deposit)
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // No external deposit - all funds stay in adapter

        // Deallocate with slippage check, but no calls needed
        uint256 requestedAmount = 500e18;
        uint256 minAcceptable = 490e18;
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));

        // Should succeed with exact amount (no slippage when no swap)
        assertEq(uint256(-change), requestedAmount, "Should return exact amount from balance");
        assertGe(uint256(-change), minAcceptable, "Should meet minimum");
    }

    /* ============ FORCE DEALLOCATE WITH SLIPPAGE ============ */

    /**
     * @notice Test that force deallocate ignores slippage check
     * @dev Force deallocate doesn't execute calls, so minAmountOut is not validated
     */
    function testForceDeallocateIgnoresSlippage() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Set high minAmountOut that would normally revert
        uint256 requestedAmount = 200e18; // Only have 200 in adapter
        uint256 minAcceptable = 500e18; // Impossibly high minimum
        IUniversalAdapterEscrow.Call[] memory calls = _createSwapWithdrawCall(1000e18, minAcceptable);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, calls);

        // Force deallocate ignores calls and minAmountOut check
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            deallocateData,
            requestedAmount,
            bytes4(0xe4d38cd8), // FORCE_DEALLOCATE_SELECTOR
            address(0)
        );

        // Should succeed even though 200 < minAcceptable (500)
        // Because force deallocate bypasses call execution and slippage check
        assertEq(uint256(-change), requestedAmount, "Force deallocate ignores minAmountOut");
    }

    /* ============ EDGE CASES ============ */

    /**
     * @notice Test exact amount returned - UPDATED for Issue #2 fix
     */
    function testExactMinimumAmount() public {
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(90e18));

        // NO slippage - must get exact amount
        dex.setSlippagePercent(0);

        // Adapter has 910e18, request 950e18 so it withdraws 40e18 from DEX
        // Total return = 910 + 40 = 950e18 (exact)
        uint256 requestedAmount = 950e18;
        uint256 minAcceptable = 950e18; // Must be exact with Issue #2 fix
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        vm.prank(address(vault));
        (, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));

        // Should succeed with exact amount
        assertEq(uint256(-change), requestedAmount, "Should return exactly requested");
    }

    /**
     * @notice Test minAmountOut greater than requested amount
     * @dev Edge case where caller sets minAmountOut > assets (expecting profit/yield)
     */
    function testMinAmountGreaterThanRequested() public {
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(90e18));

        // Request 500, but set minAmountOut = 600 (expecting yield)
        // Note: actualAmount is capped to requested assets (500), so this will always fail
        uint256 requestedAmount = 500e18;
        uint256 minAcceptable = 600e18;
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(requestedAmount, minAcceptable);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        // Should revert because actual (500 or less) < minAcceptable (600)
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);
        adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));
    }

    /**
     * @notice Fuzz test: UPDATED for Issue #2 fix (all-or-nothing)
     */
    function testFuzzSlippageProtection(uint256 amount, uint8 slippagePercent, uint8 tolerancePercent) public {
        amount = bound(amount, 100e18, 1000e18);
        slippagePercent = uint8(bound(slippagePercent, 0, 20)); // 0-20% slippage
        tolerancePercent = uint8(bound(tolerancePercent, 0, 20)); // 0-20% tolerance

        // Setup: Deposit 9% to DEX (under circuit breaker threshold)
        asset.mint(address(adapter), amount);

        bytes memory allocateData = abi.encode(strategyId, amount, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, amount, bytes4(0), address(0));

        // Deposit 9% of balance to stay under circuit breaker
        uint256 depositAmount = (amount * 9) / 100;
        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(depositAmount));

        // Set DEX slippage
        dex.setSlippagePercent(slippagePercent);

        // Request 95% of total (adapter has ~91%, so need ~4% from DEX)
        uint256 requestedAmount = (amount * 95) / 100;
        uint256 adapterBalance = amount - depositAmount;
        uint256 dexWithdrawalNeeded = requestedAmount > adapterBalance ? requestedAmount - adapterBalance : 0;

        // Skip if no DEX interaction needed or if slippage would cause underflow
        if (dexWithdrawalNeeded == 0 || dexWithdrawalNeeded < amount / 100) {
            return;
        }

        // Calculate expected return with slippage
        uint256 dexActualReturn = (dexWithdrawalNeeded * (100 - slippagePercent)) / 100;
        uint256 totalExpectedReturn = adapterBalance + dexActualReturn;

        // Set minAcceptable based on tolerance
        uint256 minAcceptable = (requestedAmount * (100 - tolerancePercent)) / 100;

        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(dexWithdrawalNeeded, 0);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        vm.prank(address(vault));

        // SECURITY FIX Issue #2: All-or-nothing enforcement
        // If totalExpectedReturn < requestedAmount, revert with InvalidAmount
        if (totalExpectedReturn < requestedAmount) {
            // Insufficient balance after DEX withdrawal - should revert with InvalidAmount
            vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);
            adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));
        } else {
            // Has sufficient balance - should succeed with exact requested amount
            (, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));
            assertEq(uint256(-change), requestedAmount, "Should return exact requested amount");
        }
    }

    /* ============ HELPER FUNCTIONS ============ */

    function _createDepositCall(uint256 amount) internal view returns (IUniversalAdapterEscrow.Call[] memory) {
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(dex),
            data: abi.encodeWithSignature("deposit(uint256)", amount),
            value: 0
        });
        return calls;
    }

    function _createSwapWithdrawCall(uint256 amount, uint256 minOut) internal view returns (IUniversalAdapterEscrow.Call[] memory) {
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(dex),
            data: abi.encodeWithSignature("swapAndWithdraw(uint256,uint256)", amount, minOut),
            value: 0
        });
        return calls;
    }
}

/**
 * @notice Mock valuer that returns balance + external deposits
 */
contract MockValuer {
    address public asset;

    function setAsset(address _asset) external {
        asset = _asset;
    }

    function getTotalValue(address adapter) external view returns (uint256) {
        return MockERC20(asset).balanceOf(adapter);
    }

    function getValue(bytes32) external view returns (uint256) {
        return 0;
    }
}

/**
 * @notice Mock DEX that simulates swaps with configurable slippage
 */
contract MockDEX {
    address public asset;
    uint256 public slippagePercent; // 0-100
    mapping(address => uint256) public balances;

    constructor(address _asset) {
        asset = _asset;
    }

    function setSlippagePercent(uint256 _percent) external {
        require(_percent <= 100, "Invalid slippage");
        slippagePercent = _percent;
    }

    function deposit(uint256 amount) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    function swapAndWithdraw(uint256 amount, uint256) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;

        // Apply slippage
        uint256 returnAmount = (amount * (100 - slippagePercent)) / 100;
        MockERC20(asset).transfer(msg.sender, returnAmount);
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
