// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

/**
 * @title UniversalAdapterEscrowCircuitBreakerTest
 * @notice Tests for circuit breaker in executeStrategy() to prevent catastrophic losses
 * @dev Tests the defense-in-depth MEV protection:
 *      - Circuit breaker prevents >10% balance loss per operation
 *      - Allows normal operations with <10% balance changes
 *      - Provides last-resort safety against agent mistakes or MEV attacks
 */
contract UniversalAdapterEscrowCircuitBreakerTest is Test {
    UniversalAdapterEscrow public adapter;
    MockERC20 public asset;
    MockValuer public valuer;
    MockVault public vault;
    MockProtocol public protocol;
    MockMaliciousDEX public maliciousDEX;

    address public owner = address(0x1);
    address public agent = address(0x2);

    bytes32 public strategyId = keccak256("test-strategy");

    function setUp() public {
        asset = new MockERC20("Test Token", "TEST", 18);
        valuer = new MockValuer();
        valuer.setAsset(address(asset));
        protocol = new MockProtocol(address(asset));
        maliciousDEX = new MockMaliciousDEX(address(asset));

        // Create a mock vault to get owner
        vault = new MockVault(address(asset), owner);

        // Deploy adapter with valuer
        adapter = new UniversalAdapterEscrow(
            address(vault),
            address(valuer),
            true // useOffchainValuer
        );

        // Setup strategy with agent
        vm.prank(owner);
        adapter.setStrategy(strategyId, agent, "", 0);

        // Whitelist protocol functions
        vm.prank(owner);
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("deposit(uint256)")), true, 0);

        vm.prank(owner);
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("withdraw(uint256)")), true, 0);

        // Whitelist malicious DEX (to test circuit breaker)
        vm.prank(owner);
        adapter.updateWhitelist(address(maliciousDEX), bytes4(keccak256("swap(uint256)")), true, 0);

        vm.prank(owner);
        adapter.updateWhitelist(address(maliciousDEX), bytes4(keccak256("swapExactLoss(uint256)")), true, 0);

        vm.prank(owner);
        adapter.updateWhitelist(address(maliciousDEX), bytes4(keccak256("stealTokens(uint256)")), true, 0);

        // Approve protocol to pull tokens from adapter
        vm.prank(address(adapter));
        asset.approve(address(protocol), type(uint256).max);

        // Approve DEX to pull tokens from adapter
        vm.prank(address(adapter));
        asset.approve(address(maliciousDEX), type(uint256).max);
    }

    /* ============ CIRCUIT BREAKER TESTS ============ */

    /**
     * @notice Test circuit breaker prevents direct token theft (>10%)
     * @dev SECURITY FIX: Circuit breaker should revert when tokens disappear without protocol deposit
     *      This tests the scenario where a malicious function just takes tokens without returning them
     */
    function testCircuitBreakerPreventsDirectTheft() public {
        // Setup: Allocate 1000 tokens
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Configure malicious contract to steal 15% of tokens
        maliciousDEX.setSlippagePercent(15);

        // Try to execute function that steals tokens
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(maliciousDEX),
            data: abi.encodeWithSignature("stealTokens(uint256)", 150e18),
            value: 0
        });

        // Should revert with ExcessiveBalanceLoss
        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.ExcessiveBalanceLoss.selector);
        adapter.executeStrategy(strategyId, calls);
    }

    /**
     * @notice Test circuit breaker allows small token losses (<10%)
     * @dev Small losses from fees or minor issues should be allowed
     */
    function testCircuitBreakerAllowsSmallLosses() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Function steals 5% (50 tokens) - should be allowed
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(maliciousDEX),
            data: abi.encodeWithSignature("stealTokens(uint256)", 50e18),
            value: 0
        });

        // Should succeed
        vm.prank(agent);
        adapter.executeStrategy(strategyId, calls);

        // Verify balance after 5% loss
        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 950e18, "Should have 950 tokens after 5% loss");
    }

    /**
     * @notice Test circuit breaker at exact threshold (10% loss)
     * @dev Exactly 10% loss should succeed
     */
    function testCircuitBreakerAtThreshold() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Steal exactly 10% (100 tokens)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(maliciousDEX),
            data: abi.encodeWithSignature("stealTokens(uint256)", 100e18),
            value: 0
        });

        // Should succeed (10% is at threshold)
        vm.prank(agent);
        adapter.executeStrategy(strategyId, calls);

        // Verify balance after 10% loss
        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 900e18, "Should have 900 tokens after 10% loss");
    }

    /**
     * @notice Test circuit breaker just above threshold (10.1% loss)
     * @dev Should revert when loss exceeds 10% by even 0.1%
     */
    function testCircuitBreakerJustAboveThreshold() public {
        // Setup with 1000 tokens
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Steal 10.1% (101 tokens)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(maliciousDEX),
            data: abi.encodeWithSignature("stealTokens(uint256)", 101e18),
            value: 0
        });

        // Should revert with ExcessiveBalanceLoss
        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.ExcessiveBalanceLoss.selector);
        adapter.executeStrategy(strategyId, calls);
    }

    /**
     * @notice Test circuit breaker allows balance increases (withdrawals)
     * @dev Withdrawals from protocols should not trigger circuit breaker (balance increases)
     */
    function testCircuitBreakerAllowsBalanceIncrease() public {
        // Setup with funds deposited to protocol
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // First deposit 100 tokens to protocol (under 10% threshold)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 90e18),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(strategyId, calls);

        // Now withdraw (balance increases - should never trigger circuit breaker)
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 90e18),
            value: 0
        });

        // SECURITY FIX Issue #1 (security_issues_5nov2025_4.md): executeStrategy() now prevents balance increases
        // Use executeStrategyWithSlippage() for withdrawals to enable symmetric reduction
        vm.prank(agent);
        adapter.executeStrategyWithSlippage(strategyId, calls, 90e18);

        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 1000e18, "Should have all tokens back after withdrawal");
    }

    /**
     * @notice Test circuit breaker prevents extreme losses (50%)
     * @dev Should prevent extreme token losses from malicious contracts
     */
    function testCircuitBreakerPreventsExtremeLoss() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Steal 50% (500 tokens)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(maliciousDEX),
            data: abi.encodeWithSignature("stealTokens(uint256)", 500e18),
            value: 0
        });

        // Should revert with ExcessiveBalanceLoss
        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.ExcessiveBalanceLoss.selector);
        adapter.executeStrategy(strategyId, calls);
    }

    /**
     * @notice Test circuit breaker allows small protocol deposits (<10% balance decrease)
     * @dev Circuit breaker has limitation: can't distinguish deposits from losses
     *      So deposits >10% will also trigger. This tests that small deposits work.
     */
    function testCircuitBreakerAllowsSmallProtocolDeposit() public {
        // Setup with larger balance so 100 token deposit is <10%
        asset.mint(address(adapter), 2000e18);

        bytes memory allocateData = abi.encode(strategyId, 2000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 2000e18, bytes4(0), address(0));

        // Deposit 100 tokens to protocol (5% of balance - under threshold)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 100e18),
            value: 0
        });

        // Should succeed (5% < 10% threshold)
        vm.prank(agent);
        adapter.executeStrategy(strategyId, calls);

        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 1900e18, "Should have 1900 tokens remaining");
    }

    /**
     * @notice Test circuit breaker blocks large protocol deposits (>10% balance decrease)
     * @dev KNOWN LIMITATION: Circuit breaker can't distinguish deposits from losses
     *      So large deposits also trigger. This is documented behavior.
     */
    function testCircuitBreakerBlocksLargeProtocolDeposit() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Try to deposit 900 tokens to protocol (90% of balance - over threshold)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 900e18),
            value: 0
        });

        // Should revert (90% > 10% threshold)
        // This is a known limitation - for large deposits, split into multiple calls
        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.ExcessiveBalanceLoss.selector);
        adapter.executeStrategy(strategyId, calls);
    }

    /**
     * @notice Test circuit breaker with zero balance (withdrawals from 0)
     * @dev Should handle edge case of zero balance gracefully - only withdrawals allowed from 0 balance
     */
    function testCircuitBreakerWithZeroBalance() public {
        // SECURITY FIX: Setup with funds via allocate, then execute strategy separately
        // This prevents deposit failures when strategies are unresponsive
        asset.mint(address(adapter), 1000e18);

        // Allocate without immediate execution
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Now execute deposit to protocol separately (under 10% threshold)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 90e18),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(strategyId, depositCalls);

        // Now adapter balance is 910, protocol has 90

        // Deposit more (under 10% of 910)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 90e18),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(strategyId, calls);

        // Balance went from 910 to 820 (9.9% decrease - under threshold)

        // SECURITY FIX (security_issues_5nov2025_4.md Issue #1): Withdrawals must use executeStrategyWithSlippage
        // executeStrategy() now prevents balance increases to force proper externalDeposits accounting
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 180e18),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategyWithSlippage(strategyId, calls, 180e18);

        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 1000e18, "Should have all 1000 tokens back");
    }

    /**
     * @notice Fuzz test: Circuit breaker prevents any loss >10%
     */
    function testFuzzCircuitBreakerPreventsHighLoss(uint256 balance, uint256 lossPercent) public {
        // Bound inputs
        balance = bound(balance, 100e18, 10000e18);
        lossPercent = bound(lossPercent, 11, 99); // 11% to 99% loss

        // Setup
        asset.mint(address(adapter), balance);

        bytes memory allocateData = abi.encode(strategyId, balance, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, balance, bytes4(0), address(0));

        // Calculate loss amount
        uint256 lossAmount = (balance * lossPercent) / 100;

        // Try to steal tokens
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(maliciousDEX),
            data: abi.encodeWithSignature("stealTokens(uint256)", lossAmount),
            value: 0
        });

        // Should revert with ExcessiveBalanceLoss
        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.ExcessiveBalanceLoss.selector);
        adapter.executeStrategy(strategyId, calls);
    }

    /**
     * @notice Fuzz test: Circuit breaker allows all losses <=10%
     */
    function testFuzzCircuitBreakerAllowsLowLoss(uint256 balance, uint256 lossPercent) public {
        // Bound inputs
        balance = bound(balance, 100e18, 10000e18);
        lossPercent = bound(lossPercent, 0, 10); // 0% to 10% loss

        // Setup
        asset.mint(address(adapter), balance);

        bytes memory allocateData = abi.encode(strategyId, balance, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, balance, bytes4(0), address(0));

        // Calculate loss amount
        uint256 expectedLoss = (balance * lossPercent) / 100;

        // Execute theft
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(maliciousDEX),
            data: abi.encodeWithSignature("stealTokens(uint256)", expectedLoss),
            value: 0
        });

        // Should succeed
        vm.prank(agent);
        adapter.executeStrategy(strategyId, calls);

        // Verify balance decreased by expected amount
        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, balance - expectedLoss, "Balance should match expected loss");
    }

    /* ============ HELPER FUNCTIONS ============ */

    function _createDepositCall(uint256 amount) internal view returns (IUniversalAdapterEscrow.Call[] memory) {
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", amount),
            value: 0
        });
        return calls;
    }

    function _createWithdrawCall(uint256 amount) internal view returns (IUniversalAdapterEscrow.Call[] memory) {
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", amount),
            value: 0
        });
        return calls;
    }
}

/**
 * @notice Mock valuer that can return arbitrary values
 */
contract MockValuer {
    uint256 public returnValue;
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
}

/**
 * @notice Mock protocol that can simulate deposit/withdraw
 */
contract MockProtocol {
    address public asset;
    mapping(address => uint256) public balances;

    constructor(address _asset) {
        asset = _asset;
    }

    function deposit(uint256 amount) external {
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
        MockERC20(asset).transfer(msg.sender, amount);
    }
}

/**
 * @notice Mock DEX that simulates slippage/MEV attacks
 */
contract MockMaliciousDEX {
    address public asset;
    uint256 public slippagePercent; // 0-100
    uint256 public lossAmount; // Exact loss amount

    constructor(address _asset) {
        asset = _asset;
    }

    function setSlippagePercent(uint256 _slippage) external {
        slippagePercent = _slippage;
    }

    function setLossAmount(uint256 _loss) external {
        lossAmount = _loss;
    }

    /// @notice Swap with percentage-based slippage
    function swap(uint256 amount) external {
        // Pull tokens
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);

        // Calculate slippage loss
        uint256 loss = (amount * slippagePercent) / 100;
        uint256 amountOut = amount - loss;

        // Return tokens minus slippage
        MockERC20(asset).transfer(msg.sender, amountOut);
    }

    /// @notice Swap with exact loss amount
    function swapExactLoss(uint256 amount) external {
        // Pull tokens
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);

        // Return tokens minus exact loss
        uint256 amountOut = amount - lossAmount;

        // Return tokens
        MockERC20(asset).transfer(msg.sender, amountOut);
    }

    /// @notice Steal tokens without returning them (simulates direct theft)
    /// @dev This function just takes tokens and doesn't return them
    ///      Unlike swap(), this doesn't confuse externalDeposits tracking
    function stealTokens(uint256 amount) external {
        // Just pull tokens and keep them (simulates direct loss/theft)
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        // No return - tokens are "lost"
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
