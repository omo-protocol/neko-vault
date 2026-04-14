// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

/**
 * @title UniversalAdapterEscrowSlippageTest
 * @notice Tests for slippage protection in withdrawFromStrategy function
 * @dev LAZY DEALLOCATION UPDATE: Slippage protection now happens in withdrawFromStrategy(),
 *      not in deallocate(). This prevents MEV sandwich attacks during agent-triggered withdrawals.
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

        // Set adapter address in valuer for getValue(ESCROW_TOTAL_ID) pattern
        valuer.setAdapter(address(adapter));

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

    /* ============ LAZY DEALLOCATION PATTERN TESTS ============ */

    /**
     * @notice Test lazy deallocation with no slippage check
     * @dev LAZY DEALLOCATION: Agent withdraws first, then user deallocates
     */
    function testDeallocateWithNoSlippageCheck() public {
        // Setup: Allocate 1000 tokens and deposit to DEX
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit 90e18 to DEX (9% under circuit breaker threshold) - adapter balance will be 910e18
        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, _createDepositCall(90e18));

        // NO slippage - DEX returns exactly what's requested
        dex.setSlippagePercent(0);

        // LAZY DEALLOCATION: Agent withdraws from DEX first
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);
        vm.prank(owner); // owner is the agent
        adapter.withdrawFromStrategy(strategyId, withdrawCalls, 40e18); // minBalanceIncrease = 40e18

        // Verify adapter now has sufficient balance
        assertEq(asset.balanceOf(address(adapter)), 950e18, "Adapter should have 910 + 40 = 950");

        // User deallocates (calls ignored)
        bytes memory deallocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (, int256 change) = adapter.deallocate(deallocateData, 950e18, bytes4(0x4b219d16), address(0));

        uint256 returnedAmount = uint256(-change);
        assertEq(returnedAmount, 950e18, "Should return exact requested amount");
    }

    /**
     * @notice Test lazy deallocation with slippage protection that passes
     * @dev LAZY DEALLOCATION: Slippage check happens in withdrawFromStrategy()
     */
    function testDeallocateWithSlippageCheckPasses() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, _createDepositCall(90e18));

        // NO slippage so we get exact amount needed
        dex.setSlippagePercent(0);

        // LAZY DEALLOCATION: Agent withdraws with slippage protection
        uint256 minBalanceIncrease = 40e18;
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);

        vm.prank(owner);
        adapter.withdrawFromStrategy(strategyId, withdrawCalls, minBalanceIncrease);

        // Verify balance increased by at least minBalanceIncrease
        assertEq(asset.balanceOf(address(adapter)), 950e18, "Adapter should have 910 + 40 = 950");

        // User deallocates
        uint256 requestedAmount = 950e18;
        bytes memory deallocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));

        uint256 returnedAmount = uint256(-change);
        assertEq(returnedAmount, 950e18, "Should return exact requested amount");
        assertEq(ids[0], strategyId, "Should return correct strategy ID");
    }

    /**
     * @notice Test that withdrawFromStrategy reverts with high slippage
     * @dev LAZY DEALLOCATION: Slippage protection prevents agent from executing bad trades
     */
    function testDeallocateWithSlippageCheckFails() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, _createDepositCall(90e18));

        // Set high slippage (10%) so DEX returns less than needed
        dex.setSlippagePercent(10);

        // LAZY DEALLOCATION: Agent attempts withdrawal but slippage is too high
        // Need to withdraw 40e18, but DEX only returns 36e18 (10% slippage)
        uint256 minBalanceIncrease = 38e18; // Tolerate 5% slippage, but we get 10%
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);

        // Should revert with SlippageTooHigh
        vm.prank(owner);
        vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);
        adapter.withdrawFromStrategy(strategyId, withdrawCalls, minBalanceIncrease);
    }

    /* ============ MEV SANDWICH ATTACK PREVENTION ============ */

    /**
     * @notice Simulate MEV sandwich attack scenario with lazy deallocation
     * @dev LAZY DEALLOCATION: Agent detects bad price and refuses to execute
     */
    function testMEVSandwichAttackPrevention() public {
        // Setup: User has 1000 tokens allocated through adapter, all in DEX
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, _createDepositCall(90e18));

        // Simulate MEV sandwich attack:
        // MEV bot frontrun: manipulate DEX to cause 15% slippage
        vm.prank(mevBot);
        dex.setSlippagePercent(15); // Severe slippage from frontrun

        // LAZY DEALLOCATION: Agent attempts withdrawal but detects bad price
        uint256 minBalanceIncrease = 38e18; // Tolerate 5% slippage max
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);

        // Agent's withdrawal reverts due to excessive slippage (15% > 5% tolerance)
        vm.prank(owner);
        vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);
        adapter.withdrawFromStrategy(strategyId, withdrawCalls, minBalanceIncrease);

        // MEV bot's attack is prevented - agent waits for better price
        // User can retry withdrawal after price normalizes
    }

    /**
     * @notice Test exact amount returned with lazy deallocation
     * @dev When agent withdraws exact amount needed, user gets full withdrawal
     */
    function testExactMinimumAmount() public {
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, _createDepositCall(90e18));

        // NO slippage - must get exact amount
        dex.setSlippagePercent(0);

        // LAZY DEALLOCATION: Agent withdraws exactly 40e18
        uint256 minBalanceIncrease = 40e18;
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(40e18, 0);

        vm.prank(owner);
        adapter.withdrawFromStrategy(strategyId, withdrawCalls, minBalanceIncrease);

        // User deallocates
        uint256 requestedAmount = 950e18;
        bytes memory deallocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));

        // Should succeed with exact amount
        assertEq(uint256(-change), requestedAmount, "Should return exactly requested");
    }

    /**
     * @notice Test withdrawFromStrategy enforces minimum balance increase
     * @dev Agent withdrawal reverts if actual increase < minBalanceIncrease
     */
    function testMinAmountGreaterThanRequested() public {
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, _createDepositCall(90e18));

        // Set 3% slippage on DEX
        dex.setSlippagePercent(3);

        // LAZY DEALLOCATION: Agent attempts withdrawal with tight slippage tolerance
        // Withdraw 20e18, but with 3% slippage get only 19.4e18
        uint256 minBalanceIncrease = 19.5e18; // Require < 2.5% slippage, but we get 3%
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(20e18, 0);

        // Should revert because actualIncrease (19.4e18) < minBalanceIncrease (19.5e18)
        vm.prank(owner);
        vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);
        adapter.withdrawFromStrategy(strategyId, withdrawCalls, minBalanceIncrease);
    }

    /**
     * @notice Fuzz test: Lazy deallocation with various slippage scenarios
     * @dev Tests that slippage protection works correctly across different parameters
     */
    function testFuzzSlippageProtection(uint256 amount, uint8 slippagePercent, uint8 tolerancePercent) public {
        amount = bound(amount, 100e18, 1000e18);
        slippagePercent = uint8(bound(slippagePercent, 0, 20)); // 0-20% slippage
        tolerancePercent = uint8(bound(tolerancePercent, 0, 20)); // 0-20% tolerance

        // Setup: Deposit 9% to DEX (under circuit breaker threshold)
        asset.mint(address(adapter), amount);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, amount, bytes4(0), address(0));

        // Deposit 9% of balance to stay under circuit breaker
        uint256 depositAmount = (amount * 9) / 100;
        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, _createDepositCall(depositAmount));

        // Set DEX slippage
        dex.setSlippagePercent(slippagePercent);

        // Need to withdraw ~4% from DEX to get to 95% total
        uint256 requestedAmount = (amount * 95) / 100;
        uint256 adapterBalance = amount - depositAmount;
        uint256 dexWithdrawalNeeded = requestedAmount > adapterBalance ? requestedAmount - adapterBalance : 0;

        // Skip if no DEX interaction needed or amount too small
        if (dexWithdrawalNeeded == 0 || dexWithdrawalNeeded < amount / 100) {
            return;
        }

        // Calculate expected return with slippage
        uint256 dexActualReturn = (dexWithdrawalNeeded * (100 - slippagePercent)) / 100;
        uint256 minBalanceIncrease = (dexWithdrawalNeeded * (100 - tolerancePercent)) / 100;

        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createSwapWithdrawCall(dexWithdrawalNeeded, 0);

        // LAZY DEALLOCATION: Agent attempts withdrawal
        vm.prank(owner);

        if (dexActualReturn < minBalanceIncrease) {
            // Slippage exceeds tolerance - should revert
            vm.expectRevert(IUniversalAdapterEscrow.SlippageTooHigh.selector);
            adapter.withdrawFromStrategy(strategyId, withdrawCalls, minBalanceIncrease);
        } else {
            // Slippage within tolerance - should succeed
            adapter.withdrawFromStrategy(strategyId, withdrawCalls, minBalanceIncrease);

            // Verify balance increased
            uint256 newBalance = asset.balanceOf(address(adapter));
            assertGe(newBalance, adapterBalance + minBalanceIncrease, "Balance should increase by at least min");

            // User can now deallocate
            if (newBalance >= requestedAmount) {
                bytes memory deallocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
                vm.prank(address(vault));
                (, int256 change) = adapter.deallocate(deallocateData, requestedAmount, bytes4(0x4b219d16), address(0));
                assertEq(uint256(-change), requestedAmount, "Should return exact requested amount");
            }
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

    function _createSwapWithdrawCall(uint256 amount, uint256 minOut)
        internal
        view
        returns (IUniversalAdapterEscrow.Call[] memory)
    {
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
 * @notice Mock valuer that returns balance for getValue calls
 */
contract MockValuer {
    address public asset;
    address public adapter;

    function setAsset(address _asset) external {
        asset = _asset;
    }

    function setAdapter(address _adapter) external {
        adapter = _adapter;
    }

    function getValue(bytes32) external view returns (uint256) {
        // Return adapter balance for any getValue call (used for ESCROW_TOTAL_ID pattern)
        if (adapter != address(0)) {
            return MockERC20(asset).balanceOf(adapter);
        }
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
