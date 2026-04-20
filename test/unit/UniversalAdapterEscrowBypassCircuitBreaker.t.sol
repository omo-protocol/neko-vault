// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockAgent} from "../mocks/MockAgent.sol";

/**
 * @title UniversalAdapterEscrowBypassCircuitBreakerTest
 * @notice Tests for executeStrategyBypassCircuitBreaker() function
 * @dev Tests the ability to bypass the 10% circuit breaker for legitimate use cases:
 *      - LP minting where tokens are locked in NFT positions
 *      - Large protocol deposits that need atomic execution
 *      - Multi-step operations with temporary large balance decreases
 */
contract UniversalAdapterEscrowBypassCircuitBreakerTest is Test {
    UniversalAdapterEscrow public adapter;
    MockERC20 public asset;
    MockValuer public valuer;
    MockVault public vault;
    MockLPProtocol public lpProtocol;
    MockProtocol public protocol;

    address public owner = address(0x1);
    address public agent;

    bytes32 public strategyId = keccak256("lp-strategy");

    function setUp() public {
        agent = address(new MockAgent());

        asset = new MockERC20("Test Token", "TEST", 18);
        valuer = new MockValuer();
        valuer.setAsset(address(asset));
        protocol = new MockProtocol(address(asset));
        lpProtocol = new MockLPProtocol(address(asset));

        // Create a mock vault to get owner
        vault = new MockVault(address(asset), owner);

        // Deploy adapter
        adapter = new UniversalAdapterEscrow(address(vault));

        // Setup strategy with agent
        vm.prank(owner);
        adapter.setStrategy(strategyId, agent, "", 0);

        // Whitelist LP protocol functions
        vm.prank(owner);
        adapter.updateWhitelist(address(lpProtocol), bytes4(keccak256("mintLPPosition(uint256)")), true, 0);

        vm.prank(owner);
        adapter.updateWhitelist(address(lpProtocol), bytes4(keccak256("burnLPPosition(uint256)")), true, 0);

        // Whitelist regular protocol functions
        vm.prank(owner);
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("deposit(uint256)")), true, 0);

        vm.prank(owner);
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("withdraw(uint256)")), true, 0);

        // Approve protocols to pull tokens from adapter
        vm.prank(address(adapter));
        asset.approve(address(lpProtocol), type(uint256).max);

        vm.prank(address(adapter));
        asset.approve(address(protocol), type(uint256).max);
    }

    /* ============ BYPASS CIRCUIT BREAKER TESTS ============ */

    /**
     * @notice Test that regular executeStrategy() is blocked by circuit breaker on large deposits
     * @dev This confirms that normal function respects circuit breaker
     */
    function testRegularExecuteStrategyBlockedByCircuitBreaker() public {
        // Setup: Allocate 1000 tokens
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Try to deposit 90% using regular executeStrategy (should be blocked)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 900e18),
            value: 0
        });

        // Should revert with ExcessiveBalanceLoss
        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.ExcessiveBalanceLoss.selector);
        adapter.executeStrategy(strategyId, calls);
    }

    /**
     * @notice Test that bypass function allows large deposits (>10%)
     * @dev This is the primary use case: large protocol deposits that need atomic execution
     */
    function testBypassAllowsLargeProtocolDeposit() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit 90% using bypass function (should succeed)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 900e18),
            value: 0
        });

        // Should succeed
        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);

        // Verify balance after 90% deposit
        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 100e18, "Should have 100 tokens remaining");

        // Verify protocol received tokens
        assertEq(protocol.balances(address(adapter)), 900e18, "Protocol should have 900 tokens");
    }

    /**
     * @notice Test that bypass allows LP minting (tokens locked in NFT)
     * @dev This simulates Uniswap V3 LP position minting where tokens disappear from balance
     */
    function testBypassAllowsLPMinting() public {
        // Setup with 1000 tokens
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Mint LP position with 800 tokens (80% - would trigger circuit breaker)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(lpProtocol),
            data: abi.encodeWithSignature("mintLPPosition(uint256)", 800e18),
            value: 0
        });

        // Should succeed with bypass
        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);

        // Verify balance decreased by 80%
        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 200e18, "Should have 200 tokens remaining");

        // Verify LP protocol received tokens
        assertEq(lpProtocol.totalDeposited(), 800e18, "LP protocol should have 800 tokens");
    }

    /**
     * @notice Test that bypass allows extreme balance decreases (>50%)
     * @dev Confirms that bypass truly removes the circuit breaker
     */
    function testBypassAllowsExtremeDeposit() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit 99% (extreme case)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 990e18),
            value: 0
        });

        // Should succeed with bypass
        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);

        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 10e18, "Should have 10 tokens remaining");
    }

    /**
     * @notice Test that bypass still requires whitelisted functions
     * @dev IMPORTANT: Bypassing circuit breaker doesn't bypass whitelist security
     */
    function testBypassStillRequiresWhitelist() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Try to call non-whitelisted function
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("someNonWhitelistedFunction()"),
            value: 0
        });

        // Should revert with FunctionNotWhitelisted
        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.FunctionNotWhitelisted.selector);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);
    }

    /**
     * @notice Test that bypass function still requires proper authorization
     * @dev Only strategy agent or owner can call
     */
    function testBypassRequiresAuthorization() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 900e18),
            value: 0
        });

        // Try to call from unauthorized address
        address unauthorized = address(0x999);
        vm.prank(unauthorized);
        vm.expectRevert(IUniversalAdapterEscrow.NotAuthorized.selector);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);
    }

    /**
     * @notice Test that bypass respects pause state
     * @dev Bypass function should still respect contract pause
     */
    function testBypassRespectsContractPause() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Pause contract
        vm.prank(owner);
        adapter.setPaused(true);

        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 900e18),
            value: 0
        });

        // Should revert with ContractPaused
        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.ContractPaused.selector);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);
    }

    /**
     * @notice Test multi-step operation with temporary large balance decrease
     * @dev Simulates complex strategy where balance temporarily drops >10% but recovers
     */
    function testBypassAllowsMultiStepOperation() public {
        // Setup with funds already in protocol
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // First deposit some tokens to protocol (under 10% threshold)
        IUniversalAdapterEscrow.Call[] memory setupCalls = new IUniversalAdapterEscrow.Call[](1);
        setupCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 50e18),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(strategyId, setupCalls);

        // Now execute multi-step operation: deposit 90% then withdraw 50%
        // Net effect is -40%, but temporary drop is 90% (would trigger circuit breaker)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 850e18), // Now at 100 balance
            value: 0
        });
        calls[1] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 450e18), // Back to 550 balance
            value: 0
        });

        // Should succeed with bypass
        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);

        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 550e18, "Should have 550 tokens after multi-step op");
    }

    /**
     * @notice Fuzz test: Bypass allows any loss percentage
     */
    function testFuzzBypassAllowsAnyLoss(uint256 balance, uint256 lossPercent) public {
        // Bound inputs
        balance = bound(balance, 100e18, 10000e18);
        lossPercent = bound(lossPercent, 11, 99); // 11% to 99% loss

        // Setup
        asset.mint(address(adapter), balance);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, balance, bytes4(0), address(0));

        // Calculate deposit amount
        uint256 depositAmount = (balance * lossPercent) / 100;

        // Execute large deposit with bypass
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", depositAmount),
            value: 0
        });

        // Should succeed
        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);

        // Verify balance decreased by expected amount
        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, balance - depositAmount, "Balance should match expected deposit");
    }

    /**
     * @notice Test that owner can also use bypass function
     * @dev Owner should have same permissions as agent
     */
    function testOwnerCanUseBypass() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit 90% as owner
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 900e18),
            value: 0
        });

        // Should succeed as owner
        vm.prank(owner);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, calls);

        uint256 balanceAfter = asset.balanceOf(address(adapter));
        assertEq(balanceAfter, 100e18, "Should have 100 tokens remaining");
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
 * @notice Mock LP protocol that simulates Uniswap V3 LP minting
 * @dev Tokens "disappear" when locked in NFT position
 */
contract MockLPProtocol {
    address public asset;
    uint256 public totalDeposited;
    uint256 public nextTokenId = 1;
    mapping(address => uint256[]) public userPositions;

    constructor(address _asset) {
        asset = _asset;
    }

    /// @notice Mint LP position (tokens locked in NFT, not returned)
    function mintLPPosition(uint256 amount) external returns (uint256 tokenId) {
        // Pull tokens (they stay in protocol, representing NFT position)
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        totalDeposited += amount;

        // Simulate NFT minting
        tokenId = nextTokenId++;
        userPositions[msg.sender].push(tokenId);
    }

    /// @notice Burn LP position and return tokens
    function burnLPPosition(uint256 positionId) external {
        // Simple implementation - just return proportional amount
        require(userPositions[msg.sender].length > 0, "No positions");

        // For testing: return amount proportional to position ID
        uint256 amount = positionId * 100e18;
        require(totalDeposited >= amount, "Insufficient liquidity");

        totalDeposited -= amount;
        MockERC20(asset).transfer(msg.sender, amount);
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
