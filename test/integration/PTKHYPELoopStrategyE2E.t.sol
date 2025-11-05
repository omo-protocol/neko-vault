// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/VaultV2.sol";
import "../../src/VaultV2Factory.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";
import "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import "../../src/valuers/UniversalValuerOffchain.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IAdapter} from "../../src/interfaces/IAdapter.sol";
import {IVaultV2} from "../../src/interfaces/IVaultV2.sol";

/**
 * @title PTKHYPELoopStrategyE2ETest
 * @notice Comprehensive end-to-end test for PT-KHYPE loop strategy using UniversalAdapterEscrow
 * @dev Tests all aspects of the strategy lifecycle with detailed assertions
 */
contract PTKHYPELoopStrategyE2ETest is Test {
    // ============ Events ============

    event AllocationUpdated(bytes32 indexed strategyId, uint256 totalAllocation, int256 change);
    event StrategyExecuted(bytes32 indexed strategyId, address executor);
    event TokenSwept(address indexed token, address indexed recipient, uint256 amount);

    // ============ Errors ============

    error NotAuthorized();
    error InvalidStrategy();
    error ContractPaused();
    error CannotSweepAsset();

    // ============ Constants ============

    // Mock addresses for testing
    address constant KHYPE = address(0x1111);
    address constant PT_KHYPE = address(0x2222);
    address constant YT_KHYPE = address(0x3333);
    address constant PENDLE_ROUTER = address(0x4444);
    address constant KHYPE_MARKET = address(0x5555);

    // Strategy configuration
    bytes32 constant PT_KHYPE_LOOP_ID = keccak256("pt-khype-loop");
    uint256 constant INITIAL_DEPOSIT = 1000e18;
    uint256 constant ALLOCATION_AMOUNT = 500e18;
    uint256 constant DAILY_LIMIT = 10000e18;

    // ============ State Variables ============

    VaultV2Factory vaultFactory;
    UniversalAdapterEscrowFactory adapterFactory;
    VaultV2 vault;
    UniversalAdapterEscrow adapter;
    UniversalValuerOffchain valuer;
    MockERC20 khype;
    MockERC20 ptKhype;
    MockERC20 ytKhype;
    MockPendleRouter pendleRouter;

    address owner = address(0x1);
    address user = address(0x2);
    address strategyAgent = address(0x3);
    address curator = address(0x4);
    address allocator = address(0x5);

    // ============ Setup ============

    function setUp() public {
        // Deploy mock tokens
        khype = new MockERC20("KHYPE", "KHYPE", 18);
        ptKhype = new MockERC20("PT-KHYPE", "PT-KHYPE", 18);
        ytKhype = new MockERC20("YT-KHYPE", "YT-KHYPE", 18);

        // Deploy mock Pendle router
        pendleRouter = new MockPendleRouter(address(khype), address(ptKhype));

        // Override constants with mock addresses
        vm.etch(KHYPE, address(khype).code);
        vm.etch(PT_KHYPE, address(ptKhype).code);
        vm.etch(YT_KHYPE, address(ytKhype).code);
        vm.etch(PENDLE_ROUTER, address(pendleRouter).code);

        // Deploy infrastructure
        deployInfrastructure();

        // Setup initial state
        setupInitialState();
    }

    function deployInfrastructure() internal {
        vm.startPrank(owner);

        // Deploy factories
        vaultFactory = new VaultV2Factory();
        adapterFactory = new UniversalAdapterEscrowFactory();

        // Deploy valuer
        valuer = new UniversalValuerOffchain(owner, address(khype));

        // Adding signers is immediate (no timelock required)
        valuer.initiateSignerChange(owner, true, 100);
        valuer.setRequiredWeight(100);

        // Deploy vault
        bytes32 salt = keccak256("test-vault");
        address vaultAddress = vaultFactory.createVaultV2(
            owner,
            address(khype),
            salt
        );
        vault = VaultV2(vaultAddress);

        // Deploy adapter
        address adapterAddress = adapterFactory.deployAdapter(
            address(vault),
            address(valuer),
            false,
            salt
        );
        adapter = UniversalAdapterEscrow(payable(adapterAddress));

        // Configure vault - set curator
        vault.setCurator(curator);

        // Add adapter and set allocator using timelock pattern
        vm.startPrank(curator);
        vault.submit(abi.encodeCall(IVaultV2.addAdapter, (address(adapter))));
        vault.addAdapter(address(adapter));

        vault.submit(abi.encodeCall(IVaultV2.setIsAllocator, (allocator, true)));
        vault.setIsAllocator(allocator, true);

        // Set caps for the PT-KHYPE strategy
        bytes memory idData = abi.encodePacked("pt-khype-loop");
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);

        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();

        vm.stopPrank();
    }

    function setupInitialState() internal {
        vm.startPrank(owner);

        // Configure strategy
        adapter.setStrategy(
            PT_KHYPE_LOOP_ID,
            strategyAgent,
            "",  // No pre-configured data
            DAILY_LIMIT
        );

        // Whitelist functions
        adapter.updateWhitelist(
            address(khype),
            khype.approve.selector,
            true,
            type(uint256).max
        );

        adapter.updateWhitelist(
            address(pendleRouter),
            bytes4(keccak256("swapExactTokenForPt(address,uint256)")),
            true,
            type(uint256).max
        );

        adapter.updateWhitelist(
            address(ptKhype),
            ptKhype.transfer.selector,
            true,
            type(uint256).max
        );

        // SECURITY FIX (security_issues_5nov2025_3.md Issue #1): Set fallback value for ESCROW_TOTAL
        // The adapter now uses getValue(ESCROW_TOTAL_ID) instead of getTotalValue(address)
        // to prevent DoS from unbounded strategy enumeration. Set a reasonable fallback value.
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));
        valuer.setFallbackValue(escrowTotalId, INITIAL_DEPOSIT); // Use initial deposit as max possible

        vm.stopPrank();
    }

    // ============ Test Cases ============

    function testFullE2EFlow() public {
        // Step 1: User deposits
        userDeposit();

        // Step 2: Allocate to strategy
        allocateToStrategy();

        // Step 3: Execute strategy
        executeStrategy();

        // Step 4: Verify position
        verifyPosition();

        // Step 5: Deallocate
        deallocateFromStrategy();

        // Step 6: User withdraws
        userWithdraw();
    }

    function testStrategyConfiguration() public {
        IUniversalAdapterEscrow.StrategyConfig memory config = adapter.getStrategy(PT_KHYPE_LOOP_ID);

        assertEq(config.agent, strategyAgent);
        assertEq(config.dailyLimit, DAILY_LIMIT);
        assertTrue(config.active);
        assertEq(config.dailyUsed, 0);
    }

    function testWhitelistConfiguration() public {
        IUniversalAdapterEscrow.WhitelistConfig memory approveConfig =
            adapter.getWhitelist(address(khype), khype.approve.selector);

        assertTrue(approveConfig.allowed);
        assertEq(approveConfig.limit, type(uint256).max);
    }

    function testAllocationWithoutDeposit() public {
        bytes memory allocData = abi.encode(
            PT_KHYPE_LOOP_ID,
            ALLOCATION_AMOUNT,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );

        vm.prank(allocator);
        vm.expectRevert();
        vault.allocate(address(adapter), allocData, ALLOCATION_AMOUNT);
    }

    function testExecuteStrategyUnauthorized() public {
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](0);

        vm.prank(user);
        vm.expectRevert(NotAuthorized.selector);
        adapter.executeStrategy(PT_KHYPE_LOOP_ID, calls);
    }

    function testPauseStrategy() public {
        vm.prank(owner);
        adapter.setPaused(true);

        bytes memory allocData = abi.encode(
            PT_KHYPE_LOOP_ID,
            ALLOCATION_AMOUNT,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );

        khype.mint(address(vault), ALLOCATION_AMOUNT);

        vm.prank(allocator);
        vm.expectRevert(ContractPaused.selector);
        vault.allocate(address(adapter), allocData, ALLOCATION_AMOUNT);
    }

    function testSweepRewards() public {
        // Create a reward token
        MockERC20 rewardToken = new MockERC20("REWARD", "RWD", 18);
        uint256 rewardAmount = 100e18;
        rewardToken.mint(address(adapter), rewardAmount);

        vm.prank(owner);
        adapter.sweep(address(rewardToken), owner);

        assertEq(rewardToken.balanceOf(owner), rewardAmount);
        assertEq(rewardToken.balanceOf(address(adapter)), 0);
    }

    function testCannotSweepPrimaryAsset() public {
        khype.mint(address(adapter), 100e18);

        vm.prank(owner);
        vm.expectRevert(CannotSweepAsset.selector);
        adapter.sweep(address(khype), owner);
    }

    function testDailyLimitRemoved() public {
        // L-16 Fix: Test that daily limits have been removed per recommendation
        // Previously this test verified daily limit enforcement, now it verifies removal
        bytes32 limitedStrategyId = keccak256("limited-strategy");
        uint256 dailyLimitParameter = 100e18; // This parameter is now ignored

        vm.prank(owner);
        adapter.setStrategy(
            limitedStrategyId,
            strategyAgent,
            "",
            dailyLimitParameter // Daily limit parameter kept for interface compatibility but ignored
        );

        // Set caps for the strategy
        vm.startPrank(curator);
        bytes memory idData = abi.encodePacked("limited-strategy");
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);
        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();

        // Deposit and allocate funds
        khype.mint(address(vault), 1000e18);
        bytes memory allocData = abi.encode(
            limitedStrategyId,
            200e18,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );

        vm.prank(allocator);
        vault.allocate(address(adapter), allocData, 200e18);

        // Update whitelist for transfer
        vm.prank(owner);
        adapter.updateWhitelist(
            address(khype),
            khype.transfer.selector,
            true,
            type(uint256).max
        );

        // Execute a transfer (18e18, 9% of 200e18, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory calls1 = new IUniversalAdapterEscrow.Call[](1);
        calls1[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            value: 0,
            data: abi.encodeWithSelector(khype.transfer.selector, user, 18e18)
        });

        vm.prank(strategyAgent);
        adapter.executeStrategy(limitedStrategyId, calls1); // Should succeed

        // Execute another transfer that brings total to >50e18
        IUniversalAdapterEscrow.Call[] memory calls2 = new IUniversalAdapterEscrow.Call[](1);
        calls2[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            value: 0,
            data: abi.encodeWithSelector(khype.transfer.selector, user, 16e18)
        });

        vm.prank(strategyAgent);
        adapter.executeStrategy(limitedStrategyId, calls2); // Should succeed

        // Execute third transfer to exceed old daily limit
        IUniversalAdapterEscrow.Call[] memory calls3 = new IUniversalAdapterEscrow.Call[](1);
        calls3[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            value: 0,
            data: abi.encodeWithSelector(khype.transfer.selector, user, 15e18)
        });

        vm.prank(strategyAgent);
        adapter.executeStrategy(limitedStrategyId, calls3); // Should succeed

        // Execute fourth transfer
        IUniversalAdapterEscrow.Call[] memory calls4 = new IUniversalAdapterEscrow.Call[](1);
        calls4[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            value: 0,
            data: abi.encodeWithSelector(khype.transfer.selector, user, 14e18)
        });

        vm.prank(strategyAgent);
        adapter.executeStrategy(limitedStrategyId, calls4); // Should succeed

        // Execute fifth transfer
        IUniversalAdapterEscrow.Call[] memory calls5 = new IUniversalAdapterEscrow.Call[](1);
        calls5[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            value: 0,
            data: abi.encodeWithSelector(khype.transfer.selector, user, 13e18)
        });

        vm.prank(strategyAgent);
        adapter.executeStrategy(limitedStrategyId, calls5); // Should succeed

        // Execute sixth transfer
        IUniversalAdapterEscrow.Call[] memory calls6 = new IUniversalAdapterEscrow.Call[](1);
        calls6[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            value: 0,
            data: abi.encodeWithSelector(khype.transfer.selector, user, 12e18)
        });

        vm.prank(strategyAgent);
        adapter.executeStrategy(limitedStrategyId, calls6); // Should succeed

        // Total transferred: 88e18, which would have been close to old daily limit of 100e18
        // Multiple small transfers prove daily limits have been removed per L-16 recommendation
        // Each transfer stays under 10% circuit breaker threshold
    }

    function testMultipleStrategies() public {
        bytes32 secondStrategyId = keccak256("second-strategy");

        // Add second strategy
        vm.prank(owner);
        adapter.setStrategy(
            secondStrategyId,
            strategyAgent,
            "",
            DAILY_LIMIT / 2
        );

        // Set caps for second strategy
        vm.startPrank(curator);
        bytes memory idData = abi.encodePacked("second-strategy");
        vault.submit(abi.encodeCall(IVaultV2.increaseAbsoluteCap, (idData, type(uint128).max)));
        vault.increaseAbsoluteCap(idData, type(uint128).max);
        vault.submit(abi.encodeCall(IVaultV2.increaseRelativeCap, (idData, 1e18)));
        vault.increaseRelativeCap(idData, 1e18);
        vm.stopPrank();

        // Deposit funds
        khype.mint(address(vault), INITIAL_DEPOSIT);

        // Allocate to first strategy
        bytes memory allocData1 = abi.encode(
            PT_KHYPE_LOOP_ID,
            300e18,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );
        vm.prank(allocator);
        vault.allocate(address(adapter), allocData1, 300e18);

        // Update fallback value after first allocation to reflect current state
        // SECURITY FIX: Ensure valuer reflects current allocation total
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));
        vm.prank(owner);
        valuer.setFallbackValue(escrowTotalId, 300e18);

        // Allocate to second strategy
        bytes memory allocData2 = abi.encode(
            secondStrategyId,
            200e18,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );
        vm.prank(allocator);
        vault.allocate(address(adapter), allocData2, 200e18);

        // Update fallback value after second allocation
        vm.prank(owner);
        valuer.setFallbackValue(escrowTotalId, 500e18);

        // Verify allocations
        assertEq(adapter.getAllocation(PT_KHYPE_LOOP_ID), 300e18);
        assertEq(adapter.getAllocation(secondStrategyId), 200e18);

        // Verify active strategies
        bytes32[] memory activeStrategies = adapter.getActiveStrategies();
        assertEq(activeStrategies.length, 2);
    }

    function testAllocateWithImmediateExecution() public {
        userDeposit();

        // Prepare strategy calls - swap only 45e18 (9% of 500e18) to stay under circuit breaker
        uint256 swapAmount = 45e18;
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(khype),
            value: 0,
            data: abi.encodeWithSelector(khype.approve.selector, address(pendleRouter), swapAmount)
        });
        calls[1] = IUniversalAdapterEscrow.Call({
            target: address(pendleRouter),
            value: 0,
            data: abi.encodeWithSelector(pendleRouter.swapExactTokenForPt.selector, address(adapter), swapAmount)
        });

        // Allocate with immediate execution
        bytes memory allocData = abi.encode(
            PT_KHYPE_LOOP_ID,
            ALLOCATION_AMOUNT,
            true,  // executeNow
            calls
        );

        vm.prank(allocator);
        // vm.expectEmit(true, true, false, true);
        // emit AllocationUpdated(PT_KHYPE_LOOP_ID, ALLOCATION_AMOUNT, int256(ALLOCATION_AMOUNT));
        vault.allocate(address(adapter), allocData, ALLOCATION_AMOUNT);

        // Verify PT tokens received (should have swapped 45e18)
        assertGt(ptKhype.balanceOf(address(adapter)), 0);
        // Verify remaining KHYPE balance (should be 500 - 45 = 455e18)
        assertEq(khype.balanceOf(address(adapter)), 455e18);
    }

    // ============ Helper Functions ============

    function userDeposit() internal {
        khype.mint(user, INITIAL_DEPOSIT);

        vm.startPrank(user);
        khype.approve(address(vault), INITIAL_DEPOSIT);
        uint256 shares = vault.deposit(INITIAL_DEPOSIT, user);
        vm.stopPrank();

        assertEq(shares, INITIAL_DEPOSIT); // 1:1 initial exchange rate
        assertEq(vault.totalAssets(), INITIAL_DEPOSIT);
    }

    function allocateToStrategy() internal {
        bytes memory allocData = abi.encode(
            PT_KHYPE_LOOP_ID,
            ALLOCATION_AMOUNT,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );

        vm.prank(allocator);
        vault.allocate(address(adapter), allocData, ALLOCATION_AMOUNT);

        assertEq(adapter.getAllocation(PT_KHYPE_LOOP_ID), ALLOCATION_AMOUNT);
        assertEq(khype.balanceOf(address(adapter)), ALLOCATION_AMOUNT);
    }

    function executeStrategy() internal {
        // Split swap into multiple calls to stay under 10% circuit breaker threshold
        // Swap 8% of current balance each iteration
        uint256 minSwapThreshold = 1e18; // Stop when balance is very small

        while (khype.balanceOf(address(adapter)) > minSwapThreshold) {
            // Calculate 8% of ACTUAL current balance
            uint256 currentBalance = khype.balanceOf(address(adapter));
            uint256 swapAmount = (currentBalance * 8) / 100;

            if (swapAmount < minSwapThreshold) {
                // If remaining balance is very small, skip it to avoid dust
                break;
            }

            IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);
            calls[0] = IUniversalAdapterEscrow.Call({
                target: address(khype),
                value: 0,
                data: abi.encodeWithSelector(khype.approve.selector, address(pendleRouter), swapAmount)
            });
            calls[1] = IUniversalAdapterEscrow.Call({
                target: address(pendleRouter),
                value: 0,
                data: abi.encodeWithSelector(pendleRouter.swapExactTokenForPt.selector, address(adapter), swapAmount)
            });

            vm.prank(strategyAgent);
            adapter.executeStrategy(PT_KHYPE_LOOP_ID, calls);
        }
    }

    function verifyPosition() internal view {
        uint256 khypeBalance = khype.balanceOf(address(adapter));
        uint256 ptBalance = ptKhype.balanceOf(address(adapter));

        assertLt(khypeBalance, 15e18); // Most KHYPE swapped (small amount remaining due to circuit breaker constraints)
        assertGt(ptBalance, 0); // Received PT tokens
        assertEq(adapter.getAllocation(PT_KHYPE_LOOP_ID), ALLOCATION_AMOUNT);
    }

    function deallocateFromStrategy() internal {
        // Simulate swapping PT back to KHYPE
        uint256 ptBalance = ptKhype.balanceOf(address(adapter));
        ptKhype.burn(address(adapter), ptBalance);
        khype.mint(address(adapter), ALLOCATION_AMOUNT);

        bytes memory deallocData = abi.encode(
            PT_KHYPE_LOOP_ID,
            0,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );

        vm.prank(allocator);
        vault.deallocate(address(adapter), deallocData, ALLOCATION_AMOUNT);

        assertEq(adapter.getAllocation(PT_KHYPE_LOOP_ID), 0);
        // SECURITY FIX Issue #3: Strategy remains active if externalDeposits > 0
        // After deallocating, the PT tokens from loop swaps are tracked as externalDeposits
        // Strategy only removed when BOTH allocations AND externalDeposits are zero
        assertEq(adapter.getActiveStrategies().length, 1, "Strategy should remain active with external deposits");
    }

    function userWithdraw() internal {
        uint256 userShares = vault.balanceOf(user);

        vm.prank(user);
        uint256 assetsReceived = vault.redeem(userShares, user, user);

        assertEq(assetsReceived, INITIAL_DEPOSIT);
        assertEq(khype.balanceOf(user), INITIAL_DEPOSIT);
        assertEq(vault.balanceOf(user), 0);
    }
}

// ============ Mock Contracts ============

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name;
    string public symbol;
    uint8 public decimals;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function burn(address from, uint256 amount) external {
        balanceOf[from] -= amount;
        totalSupply -= amount;
    }
}

contract MockPendleRouter {
    IERC20 public khype;
    IERC20 public ptKhype;

    constructor(address _khype, address _ptKhype) {
        khype = IERC20(_khype);
        ptKhype = IERC20(_ptKhype);
    }

    function swapExactTokenForPt(address receiver, uint256 amount) external returns (uint256) {
        // Simple mock: 1:0.95 swap ratio
        uint256 ptAmount = (amount * 95) / 100;

        khype.transferFrom(msg.sender, address(this), amount);
        MockERC20(address(ptKhype)).mint(receiver, ptAmount);

        return ptAmount;
    }
}

contract MockValuer {
    function getValue(address) external pure returns (uint256) {
        return 1000e18; // Mock value
    }
}