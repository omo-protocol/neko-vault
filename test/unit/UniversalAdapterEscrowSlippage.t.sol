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
     * @dev Backward compatible behavior - any amount returned is accepted
     */
    function testDeallocateWithNoSlippageCheck() public {
        // Setup: Allocate 1000 tokens and deposit ALL to DEX (no adapter balance left)
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit ALL to DEX - adapter balance will be ~0
        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(1000e18));

        // Set DEX to return less than requested (e.g., due to slippage)
        dex.setSlippagePercent(5); // 5% slippage

        // Deallocate with minAmountOut = 0 (no slippage check)
        // Request 500 but will only get 475 due to slippage
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(500e18, 0);
        bytes memory deallocateData = abi.encode(strategyId, 0, false, withdrawCalls); // minAmountOut = 0

        vm.prank(address(vault));
        (, int256 change) = adapter.deallocate(deallocateData, 500e18, bytes4(0x4b219d16), address(0));

        // Should succeed even with slippage because minAmountOut = 0
        uint256 returnedAmount = uint256(-change);
        assertEq(returnedAmount, 475e18, "Should return slipped amount (475 from 500 with 5% slippage)");
    }

    /**
     * @notice Test deallocate with slippage check that passes
     * @dev minAmountOut is set and actual return is above minimum
     */
    function testDeallocateWithSlippageCheckPasses() public {
        // Setup: Deposit ALL to DEX for clean slippage test
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(1000e18));

        // Set acceptable slippage (2%)
        dex.setSlippagePercent(2);

        // Deallocate with minAmountOut = 490e18 (2% slippage tolerance on 500e18)
        // Will get 490e18 with 2% slippage, which meets minimum
        uint256 requestedAmount = 500e18;
        uint256 minAcceptable = 490e18; // 98% of requested
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(requestedAmount, minAcceptable);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));

        // Should succeed - actual return (490) >= minAcceptable (490)
        uint256 returnedAmount = uint256(-change);
        assertEq(returnedAmount, 490e18, "Should return exactly 490 (2% slippage on 500)");
        assertGe(returnedAmount, minAcceptable, "Should meet minimum");
        assertEq(ids[0], strategyId, "Should return correct strategy ID");
    }

    /**
     * @notice Test deallocate with slippage check that fails
     * @dev minAmountOut is set but actual return is below minimum
     */
    function testDeallocateWithSlippageCheckFails() public {
        // Setup: Deposit ALL to DEX
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(1000e18));

        // Set high slippage (10%)
        dex.setSlippagePercent(10);

        // Deallocate with minAmountOut = 490e18 (2% slippage tolerance)
        // But DEX will only return 450 (10% slippage) - should revert
        uint256 requestedAmount = 500e18;
        uint256 minAcceptable = 490e18;
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(requestedAmount, minAcceptable);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        // Should revert with SlippageTooHigh
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);
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
        adapter.executeStrategy(strategyId, _createDepositCall(1000e18));

        // Simulate MEV sandwich attack:
        // 1. User initiates withdrawal of 500e18
        // 2. MEV bot frontruns and manipulates price
        // 3. Adapter's withdrawal gets worse price

        // MEV bot frontrun: manipulate DEX to cause 15% slippage
        vm.prank(mevBot);
        dex.setSlippagePercent(15); // Severe slippage from frontrun

        // User withdrawal with slippage protection (2% tolerance)
        uint256 requestedAmount = 500e18;
        uint256 minAcceptable = 490e18; // 2% tolerance
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(requestedAmount, minAcceptable);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        // Tx should revert, protecting user from MEV attack
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);
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
     * @notice Test exact amount returned meets minimum
     */
    function testExactMinimumAmount() public {
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(1000e18));

        // Set slippage to exactly hit the minimum
        dex.setSlippagePercent(2); // Returns 490 from 500

        uint256 requestedAmount = 500e18;
        uint256 minAcceptable = 490e18; // Exactly what DEX will return
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(requestedAmount, minAcceptable);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        vm.prank(address(vault));
        (, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));

        // Should succeed with exact minimum
        assertEq(uint256(-change), minAcceptable, "Should return exactly minimum");
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
        adapter.executeStrategy(strategyId, _createDepositCall(1000e18));

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
     * @notice Fuzz test: slippage check works across various amounts
     */
    function testFuzzSlippageProtection(uint256 amount, uint8 slippagePercent, uint8 tolerancePercent) public {
        amount = bound(amount, 100e18, 1000e18);
        slippagePercent = uint8(bound(slippagePercent, 0, 50)); // 0-50% slippage
        tolerancePercent = uint8(bound(tolerancePercent, 0, 50)); // 0-50% tolerance

        // Setup: Deposit ALL to DEX for clean slippage test
        asset.mint(address(adapter), amount);

        bytes memory allocateData = abi.encode(strategyId, amount, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, amount, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(amount));

        // Set DEX slippage
        dex.setSlippagePercent(slippagePercent);

        uint256 requestedAmount = amount / 2;
        uint256 minAcceptable = (requestedAmount * (100 - tolerancePercent)) / 100;
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(requestedAmount, minAcceptable);
        bytes memory deallocateData = abi.encode(strategyId, minAcceptable, false, withdrawCalls);

        vm.prank(address(vault));

        if (slippagePercent > tolerancePercent) {
            // Slippage exceeds tolerance - should revert
            vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);
            adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));
        } else {
            // Slippage within tolerance - should succeed
            (, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));
            assertGe(uint256(-change), minAcceptable, "Should meet minimum in fuzz test");
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
