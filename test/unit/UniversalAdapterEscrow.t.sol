// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";
import {MockVaultV2} from "../mocks/MockVaultV2.sol";
import {MockValuer} from "../mocks/MockValuer.sol";
import {MockTarget} from "../mocks/MockTarget.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {MockAgent} from "../mocks/MockAgent.sol";

contract UniversalAdapterEscrowTest is Test {
    UniversalAdapterEscrow adapter;
    UniversalAdapterEscrowFactory factory;
    MockVaultV2 vault;
    MockERC20 asset;
    MockERC20 rewardToken;
    MockValuer valuer;
    MockTarget target;

    address owner = address(0x1);
    address agent;
    address attacker = address(0x3);
    address recipient = address(0x4);

    bytes32 constant STRATEGY_1 = keccak256("STRATEGY_1");
    bytes32 constant STRATEGY_2 = keccak256("STRATEGY_2");

    event StrategySet(bytes32 indexed strategyId, address indexed agent, uint256 dailyLimit);
    event StrategyExecuted(bytes32 indexed strategyId, address indexed executor);
    event WhitelistUpdated(address indexed target, bytes4 indexed selector, bool allowed, uint256 limit);
    event TokenSwept(address indexed token, address indexed recipient, uint256 amount);
    event PauseStatusChanged(bool paused);
    event AllocationUpdated(bytes32 indexed strategyId, uint256 newAmount, int256 change);
    event StrategyRemoved(bytes32 indexed strategyId);

    function setUp() public {
        // Deploy MockAgent for agent address
        agent = address(new MockAgent());

        // Deploy mocks
        asset = new MockERC20("USDC", "USDC", 6);
        rewardToken = new MockERC20("REWARD", "RWD", 18);
        valuer = new MockValuer();
        target = new MockTarget(address(asset)); // Pass asset address to MockTarget

        // Deploy vault mock
        vault = new MockVaultV2(address(asset), owner);

        // Deploy factory
        factory = new UniversalAdapterEscrowFactory();

        // Deploy adapter via factory (must be called by vault owner)
        vm.startPrank(owner);
        adapter = UniversalAdapterEscrow(
            payable(
                factory.deployAdapter(
                    address(vault),
                    keccak256("test-salt")
                )
            )
        );

        // Setup initial state
        vault.addAdapter(address(adapter));
        vm.stopPrank();

        // Mint assets to vault
        asset.mint(address(vault), 1000000e6);

        // Label addresses for better test output
        vm.label(address(adapter), "Adapter");
        vm.label(address(vault), "Vault");
        vm.label(address(asset), "Asset");
        vm.label(owner, "Owner");
        vm.label(agent, "Agent");
        vm.label(attacker, "Attacker");
    }

    /* DEPLOYMENT TESTS */

    function testDeployment() public view {
        assertEq(adapter.parentVault(), address(vault));
        assertEq(adapter.asset(), address(asset));
        assertEq(adapter.owner(), owner);
        assertEq(adapter.paused(), false);
    }

    function testFactoryTracking() public view {
        address[] memory vaultAdapters = factory.getVaultAdapters(address(vault));
        assertEq(vaultAdapters.length, 1);
        assertEq(vaultAdapters[0], address(adapter));
        assertTrue(factory.isAdapter(address(adapter)));
    }

    /* ACCESS CONTROL TESTS */

    function testOnlyOwnerCanSetStrategy() public {
        vm.expectRevert(IUniversalAdapterEscrow.NotAuthorized.selector);
        vm.prank(attacker);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
    }

    function testOnlyVaultCanAllocate() public {
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory data = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.expectRevert(IUniversalAdapterEscrow.NotAuthorized.selector);
        vm.prank(attacker);
        adapter.allocate(data, 100e6, bytes4(0), address(0));
    }

    function testOnlyStrategyAgentCanExecute() public {
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](0);

        vm.expectRevert(IUniversalAdapterEscrow.NotAuthorized.selector);
        vm.prank(attacker);
        adapter.executeStrategy(STRATEGY_1, calls);

        // Agent should succeed
        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls);

        // Owner can also execute
        vm.prank(owner);
        adapter.executeStrategy(STRATEGY_1, calls);
    }

    /* STRATEGY MANAGEMENT TESTS */

    function testSetStrategy() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit StrategySet(STRATEGY_1, agent, 1000e6);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        IUniversalAdapterEscrow.StrategyConfig memory config = adapter.getStrategy(STRATEGY_1);
        assertEq(config.agent, agent);
        assertEq(config.dailyLimit, 1000e6);
        assertTrue(config.active);
    }

    function testRemoveStrategy() public {
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        vm.expectEmit(true, false, false, false);
        emit StrategyRemoved(STRATEGY_1);
        adapter.removeStrategy(STRATEGY_1);
        vm.stopPrank();

        IUniversalAdapterEscrow.StrategyConfig memory config = adapter.getStrategy(STRATEGY_1);
        assertFalse(config.active);
    }

    function testCannotRemoveStrategyWithAllocation() public {
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        vm.stopPrank();

        // Allocate funds
        bytes memory data = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(data, 100e6, bytes4(0), address(0));

        // Try to remove - should fail
        vm.prank(owner);
        vm.expectRevert(IUniversalAdapterEscrow.InvalidStrategy.selector);
        adapter.removeStrategy(STRATEGY_1);
    }

    /* ALLOCATION TESTS */

    function testAllocate() public {
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory data = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        // Transfer assets first
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);

        vm.expectEmit(true, false, false, true);
        emit AllocationUpdated(STRATEGY_1, 100e6, int256(100e6));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.allocate(data, 100e6, bytes4(0), address(0));

        assertEq(ids.length, 1);
        assertEq(ids[0], STRATEGY_1);
        assertEq(change, int256(100e6));
        assertEq(adapter.getAllocation(STRATEGY_1), 100e6);

        bytes32[] memory active = adapter.getActiveStrategies();
        assertEq(active.length, 1);
        assertEq(active[0], STRATEGY_1);
    }

    function testAllocateInactiveStrategyReverts() public {
        bytes memory data = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.StrategyNotActive.selector);
        adapter.allocate(data, 100e6, bytes4(0), address(0));
    }

    function testAllocateRejectsUnknownAutomationFlags() public {
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory data = abi.encode(STRATEGY_1, uint256(4), new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);

        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidData.selector);
        adapter.allocate(data, 100e6, bytes4(0), address(0));
    }

    function testDeallocate() public {
        // Setup: allocate first
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Deallocate - use same payload format as allocate
        bytes memory deallocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.expectEmit(true, false, false, true);
        emit AllocationUpdated(STRATEGY_1, 50e6, -int256(50e6));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocData, 50e6, bytes4(0), address(0));

        assertEq(ids.length, 1);
        assertEq(ids[0], STRATEGY_1);
        assertEq(change, -int256(50e6));
        assertEq(adapter.getAllocation(STRATEGY_1), 50e6);
    }

    function testDeallocateRejectsUnknownAutomationFlags() public {
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        bytes memory deallocData = abi.encode(STRATEGY_1, uint256(4), new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidData.selector);
        adapter.deallocate(deallocData, 50e6, bytes4(0), address(0));
    }

    function testDeallocateAll() public {
        // Setup: allocate first
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Deallocate all - pass assets as max to deallocate all
        bytes memory deallocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocData, 100e6, bytes4(0), address(0));

        assertEq(change, -int256(100e6));
        assertEq(adapter.getAllocation(STRATEGY_1), 0);

        // Strategy should be removed from active list
        bytes32[] memory active = adapter.getActiveStrategies();
        assertEq(active.length, 0);
    }

    function testDeallocateWithYield() public {
        // SECURITY FIX: change is now capped at allocationDecrease to prevent cap bypass
        // VaultV2 can still transfer the full amount, but cap accounting stays accurate

        // Setup: allocate first
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Simulate yield by setting higher value in valuer (150e6 vs 100e6 allocated)
        valuer.setValue(STRATEGY_1, 150e6);

        // Transfer extra assets to adapter to cover yield withdrawal
        asset.mint(address(adapter), 50e6);

        // Deallocate with yield - request 120e6 but change capped at allocation (100e6)
        bytes memory deallocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocData, 120e6, bytes4(0), address(0));

        assertEq(ids[0], STRATEGY_1);
        // SECURITY FIX: change capped at allocation (100e6), not requested amount (120e6)
        assertEq(change, -int256(100e6), "Change capped at allocation to prevent cap bypass");
        assertEq(adapter.getAllocation(STRATEGY_1), 0, "Allocation should be 0 after deallocating");
    }

    function testFeeOnTransferTokensNotSupported() public {
        // DESIGN DECISION: Fee-on-transfer tokens are not supported
        // Reason: Underlying protocols (Morpho, Pendle, etc.) don't support them
        // This test documents that such tokens will cause accounting mismatches

        MockFeeOnTransferToken feeToken = new MockFeeOnTransferToken("FeeToken", "FEE", 18);
        feeToken.setTransferFeePercent(100); // 1% fee

        MockVaultV2 feeVault = new MockVaultV2(address(feeToken), owner);
        UniversalAdapterEscrow feeAdapter = new UniversalAdapterEscrow(address(feeVault));

        vm.prank(owner);
        feeVault.addAdapter(address(feeAdapter));

        vm.prank(owner);
        feeAdapter.setStrategy(STRATEGY_1, agent, "", 1000e18);

        // Demonstrate the problem with fee-on-transfer tokens
        uint256 intendedAmount = 100e18;
        feeToken.mint(address(feeVault), intendedAmount);

        // Vault transfers to adapter (fee is deducted)
        vm.prank(address(feeVault));
        feeToken.transfer(address(feeAdapter), intendedAmount);

        // Adapter received less due to fee
        uint256 actualReceived = feeToken.balanceOf(address(feeAdapter));
        assertEq(actualReceived, 99e18, "Adapter received 99 after 1% fee");

        // Allocation tracks intended amount, creating mismatch
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(feeVault));
        (bytes32[] memory ids, int256 change) = feeAdapter.allocate(allocData, intendedAmount, bytes4(0), address(0));

        // Demonstrates the accounting mismatch
        assertEq(feeAdapter.getAllocation(STRATEGY_1), intendedAmount, "Tracks intended amount");
        assertEq(actualReceived, 99e18, "But only has 99 tokens");

        // This mismatch would cause issues with underlying protocols
        assertTrue(feeAdapter.getAllocation(STRATEGY_1) > actualReceived, "Allocation > actual balance");

        console2.log("[WARNING] Fee-on-transfer tokens create accounting mismatches");
        console2.log("This adapter does not support such tokens by design");
    }

    function testMultipleFeeOnTransferTokenMismatches() public {
        // Demonstrates why fee-on-transfer tokens aren't supported:
        // Multiple allocations create compounding accounting mismatches

        MockFeeOnTransferToken feeToken = new MockFeeOnTransferToken("FeeToken", "FEE", 18);
        feeToken.setTransferFeePercent(200); // 2% fee

        MockVaultV2 feeVault = new MockVaultV2(address(feeToken), owner);
        UniversalAdapterEscrow feeAdapter = new UniversalAdapterEscrow(address(feeVault));

        vm.prank(owner);
        feeVault.addAdapter(address(feeAdapter));

        vm.startPrank(owner);
        feeAdapter.setStrategy(STRATEGY_1, agent, "", 1000e18);
        feeAdapter.setStrategy(STRATEGY_2, agent, "", 1000e18);
        vm.stopPrank();

        // First allocation: 100 intended, 98 received
        uint256 firstIntended = 100e18;
        feeToken.mint(address(feeVault), firstIntended);
        vm.prank(address(feeVault));
        feeToken.transfer(address(feeAdapter), firstIntended);

        vm.prank(address(feeVault));
        feeAdapter.allocate(
            abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), firstIntended, bytes4(0), address(0)
        );

        // Second allocation: 50 intended, 49 received
        uint256 secondIntended = 50e18;
        feeToken.mint(address(feeVault), secondIntended);
        vm.prank(address(feeVault));
        feeToken.transfer(address(feeAdapter), secondIntended);

        vm.prank(address(feeVault));
        feeAdapter.allocate(
            abi.encode(STRATEGY_2, 0, new IUniversalAdapterEscrow.Call[](0)), secondIntended, bytes4(0), address(0)
        );

        // Show the mismatch problem
        uint256 totalTracked = feeAdapter.getAllocation(STRATEGY_1) + feeAdapter.getAllocation(STRATEGY_2);
        uint256 totalBalance = feeToken.balanceOf(address(feeAdapter));

        assertEq(totalTracked, 150e18, "Adapter tracks 150 total");
        assertEq(totalBalance, 147e18, "But only has 147 tokens"); // 98 + 49 = 147

        console2.log("[ERROR] Accounting mismatch with multiple fee-on-transfer allocations:");
        console2.log("Tracked total:", totalTracked);
        console2.log("Actual balance:", totalBalance);
        console2.log("This would break protocol interactions");
    }

    /* WHITELIST TESTS */

    function testUpdateWhitelist() public {
        bytes4 selector = bytes4(keccak256("transfer(address,uint256)"));

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit WhitelistUpdated(address(target), selector, true, 100e6);
        adapter.updateWhitelist(address(target), selector, true, 100e6);

        IUniversalAdapterEscrow.WhitelistConfig memory config = adapter.getWhitelist(address(target), selector);
        assertTrue(config.allowed);
        assertEq(config.limit, 100e6);
    }

    /* MULTICALL EXECUTION TESTS */

    function testExecuteStrategyWithWhitelist() public {
        // Setup strategy and whitelist
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.updateWhitelist(address(target), bytes4(keccak256("doSomething()")), true, 0);
        vm.stopPrank();

        // Create call
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(target),
            data: abi.encodeWithSignature("doSomething()"),
            value: 0
        });

        // Execute
        vm.prank(agent);
        vm.expectEmit(true, true, false, false);
        emit StrategyExecuted(STRATEGY_1, agent);
        adapter.executeStrategy(STRATEGY_1, calls);
    }

    function testExecuteNotWhitelistedReverts() public {
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        vm.stopPrank();

        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(target),
            data: abi.encodeWithSignature("doSomething()"),
            value: 0
        });

        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.FunctionNotWhitelisted.selector);
        adapter.executeStrategy(STRATEGY_1, calls);
    }

    function testDailyLimitRemoved() public {
        // L-16 Fix: Daily limits have been removed per recommendation
        // Setup strategy (dailyLimit parameter is kept for interface compatibility but ignored)
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 10e6); // Daily limit parameter ignored
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 100e6);
        vm.stopPrank();

        // Fund adapter
        asset.mint(address(adapter), 100e6);

        // Multiple transfers that would have exceeded old daily limit should now succeed
        // NOTE: Circuit breaker prevents >10% balance loss per operation, so we use multiple smaller transfers
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 9e6), // 9% of 100e6
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed

        // Another transfer - should also succeed (no daily limit enforcement)
        // Total would be 17e6, exceeding old 10e6 daily limit
        calls[0].data = abi.encodeWithSignature("transfer(address,uint256)", recipient, 8e6); // <10% of 91e6

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed
    }

    function testLimitsCompletelyRemoved() public {
        // L-16 Fix: All limit checking removed - only whitelist-based access control remains
        // NOTE: Circuit breaker prevents >10% balance loss per operation
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6); // Daily limit value is ignored
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 5e6); // Per-call
            // limit value is ignored
        vm.stopPrank();

        asset.mint(address(adapter), 100e6);

        // Transfer 9e6 (9% of 100e6) - under circuit breaker threshold
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 9e6), // 9% of balance
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed - no limit checking

        // Another transfer: 8e6 (8.8% of 91e6) - should also succeed
        calls[0].data = abi.encodeWithSignature("transfer(address,uint256)", recipient, 8e6);

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed - only whitelist matters
    }

    /* PAUSE TESTS */

    function testPause() public {
        vm.prank(owner);
        vm.expectEmit(false, false, false, true);
        emit PauseStatusChanged(true);
        adapter.setPaused(true);

        assertTrue(adapter.paused());
    }

    function testPausedBlocksAllocate() public {
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.setPaused(true);
        vm.stopPrank();

        bytes memory data = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.ContractPaused.selector);
        adapter.allocate(data, 100e6, bytes4(0), address(0));
    }

    function testPausedBlocksExecute() public {
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.setPaused(true);
        vm.stopPrank();

        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](0);

        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.ContractPaused.selector);
        adapter.executeStrategy(STRATEGY_1, calls);
    }

    /* SWEEP TESTS */

    function testSweep() public {
        // Send reward tokens to adapter
        rewardToken.mint(address(adapter), 1000e18);

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit TokenSwept(address(rewardToken), recipient, 1000e18);
        adapter.sweep(address(rewardToken), recipient);

        assertEq(rewardToken.balanceOf(recipient), 1000e18);
        assertEq(rewardToken.balanceOf(address(adapter)), 0);
    }

    function testCannotSweepPrimaryAsset() public {
        asset.mint(address(adapter), 100e6);

        vm.prank(owner);
        vm.expectRevert(IUniversalAdapterEscrow.CannotSweepAsset.selector);
        adapter.sweep(address(asset), recipient);
    }

    /* PRE-CONFIGURED STRATEGY TESTS */

    function testExecutePreConfigured() public {
        // Setup pre-configured strategy
        vm.startPrank(owner);
        adapter.updateWhitelist(address(target), bytes4(keccak256("doSomething()")), true, 0);

        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(target),
            data: abi.encodeWithSignature("doSomething()"),
            value: 0
        });

        bytes memory preConfigData = abi.encode(calls);
        adapter.setStrategy(STRATEGY_1, agent, preConfigData, 1000e6);
        vm.stopPrank();

        // Execute pre-configured
        vm.prank(agent);
    }

    /* OWNERSHIP TESTS */

    function testTransferOwnership() public {
        address newOwner = address(0x5);

        vm.prank(owner);
        adapter.transferOwnership(newOwner);

        assertEq(adapter.owner(), newOwner);
    }

    function testTransferOwnershipZeroReverts() public {
        vm.prank(owner);
        vm.expectRevert("Invalid owner");
        adapter.transferOwnership(address(0));
    }

    /* REAL ASSETS TESTS */

    function testRealAssets() public {
        // Need an active strategy for valuation to work
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Agent reports 5000e6 via quoteCurrentAssets
        MockAgent(agent).setAssets(5000e6);
        assertEq(adapter.realAssets(), 5000e6);
    }

    /* L-14 FIX TESTS */

    function testForceDeallocateValidation() public {
        // Setup strategy and allocation
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Allocate some assets
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Whitelist asset for transfers (required for legitimate operations)
        vm.prank(owner);
        adapter.updateWhitelist(address(asset), bytes4(0xa9059cbb), true, 0); // transfer

        // Create legitimate transfer call
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSelector(0xa9059cbb, address(vault), 50e6), // transfer(vault, 50e6)
            value: 0
        });

        bytes memory data = abi.encode(STRATEGY_1, 0, calls);

        // Test that normal deallocate works (using regular deallocate selector)
        vm.prank(address(vault));
        bytes4 normalDeallocateSelector = 0x4b219d16; // deallocate(address,bytes,uint256)
        adapter.deallocate(data, 50e6, normalDeallocateSelector, address(this));

        // Re-allocate for next test
        bytes memory reallocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 50e6);
        asset.transfer(address(adapter), 50e6);
        vm.prank(address(vault));
        adapter.allocate(reallocData, 50e6, bytes4(0), address(0));

        // Test that forceDeallocate works with sufficient balance (no external calls executed)
        vm.prank(address(vault));
        bytes4 forceDeallocateSelector = 0xe4d38cd8; // forceDeallocate(address,bytes,uint256,address)
        adapter.deallocate(data, 50e6, forceDeallocateSelector, address(this));
    }

    function testForceDeallocateRejectsInsufficientBalance() public {
        // Setup strategy and allocation with 100e6
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Try to force deallocate more than adapter balance (100e6 available, requesting 150e6)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](0); // Empty calls array
        bytes memory data = abi.encode(STRATEGY_1, 0, calls);
        bytes4 forceDeallocateSelector = 0xe4d38cd8; // Correct selector

        // Should revert because requested amount exceeds adapter balance
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);
        adapter.deallocate(data, 150e6, forceDeallocateSelector, address(this));
    }

    function testForceDeallocateSucceedsWithSufficientBalance() public {
        // Setup strategy and allocation with 100e6
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Force deallocate with sufficient balance (no external calls should be executed)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSelector(0x12345678, address(vault), 50e6), // This call should be ignored
            value: 0
        });

        bytes memory data = abi.encode(STRATEGY_1, 0, calls);
        bytes4 forceDeallocateSelector = 0xe4d38cd8; // Correct selector

        // Should succeed because balance is sufficient and no external calls are executed
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(data, 50e6, forceDeallocateSelector, address(this));

        assertEq(ids[0], STRATEGY_1);
        assertEq(change, -50e6);
        assertEq(adapter.getAllocation(STRATEGY_1), 50e6); // Reduced from 100e6 to 50e6
    }

    /**
     * @notice Tests using vault.forceDeallocate() directly as requested by auditor
     */
    function testVaultForceDeallocateWithSufficientBalance() public {
        // Setup: Create vault and add adapter
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Allocate assets
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Force deallocate through vault (not direct adapter call)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](0); // Empty calls array
        bytes memory data = abi.encode(STRATEGY_1, 0, calls); // Same format as allocate

        // Mock vault balance for penalty calculation
        asset.mint(address(vault), 200e6);

        vm.prank(address(this)); // Caller of forceDeallocate
        uint256 penaltyShares = vault.forceDeallocate(address(adapter), data, 50e6, address(this));

        // Verify allocation was reduced
        assertEq(adapter.getAllocation(STRATEGY_1), 50e6);
        // Verify penalty was applied (penalty should be > 0)
        assertGt(penaltyShares, 0);
    }

    function testVaultForceDeallocateInsufficientBalance() public {
        // Setup: Create vault and add adapter with limited balance
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Allocate only 50e6 assets
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 50e6);
        asset.transfer(address(adapter), 50e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 50e6, bytes4(0), address(0));

        // Try to force deallocate more than available (should fail)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](0); // Empty calls array
        bytes memory data = abi.encode(STRATEGY_1, 0, calls); // Same format as allocate

        // Mock vault balance for penalty calculation
        asset.mint(address(vault), 200e6);

        vm.prank(address(this)); // Caller of forceDeallocate
        vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);
        vault.forceDeallocate(address(adapter), data, 100e6, address(this));
    }

    function testVaultForceDeallocateIgnoresMaliciousCallData() public {
        // Setup: Create vault and add adapter
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Allocate assets
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Create malicious call data that would transfer all funds
        IUniversalAdapterEscrow.Call[] memory maliciousCalls = new IUniversalAdapterEscrow.Call[](1);
        maliciousCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSelector(asset.transfer.selector, address(this), 100e6),
            value: 0
        });

        // Include malicious calls in data (they should be ignored)
        bytes memory data = abi.encode(STRATEGY_1, 0, maliciousCalls);
        uint256 balanceBefore = asset.balanceOf(address(this));

        // Mock vault balance for penalty calculation
        asset.mint(address(vault), 200e6);

        vm.prank(address(this)); // Caller of forceDeallocate
        uint256 penaltyShares = vault.forceDeallocate(address(adapter), data, 50e6, address(this));

        // Verify malicious calls were ignored (balance unchanged except for expected transfers)
        uint256 balanceAfter = asset.balanceOf(address(this));
        assertEq(balanceAfter, balanceBefore); // No unexpected transfers occurred

        // Verify normal deallocate behavior worked
        assertEq(adapter.getAllocation(STRATEGY_1), 50e6);
        assertGt(penaltyShares, 0);
    }

    /* L-16 FIX TESTS */

    function testL16DailyLimitLogicRemoved() public {
        // L-16 Fix: Verify that daily limit logic has been completely removed
        // Operations that would have been blocked by daily limits should now succeed
        // NOTE: Circuit breaker prevents >10% balance loss per operation

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 10e6); // Daily limit parameter ignored
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        adapter.updateWhitelist(address(rewardToken), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        vm.stopPrank();

        // Fund adapter
        asset.mint(address(adapter), 100e6);
        rewardToken.mint(address(adapter), 100e18);

        // Transfers under circuit breaker threshold demonstrate daily limits removed
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);

        // Transfer 9% of vault asset
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 9e6),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed

        // Transfer 8% of reward token (circuit breaker only applies to vault asset)
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(rewardToken),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 8e18),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed

        // Transfer more vault asset (8% of 91e6, total would be 17e6, exceeding old 10e6 daily limit)
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 7e6),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed - daily limits removed
    }

    function testL13FullAssetUtilization() public {
        // L-13 FIX: Test that all assets are fully tracked and utilized
        // This demonstrates how the current architecture prevents the L-13 issue

        // Set up strategy
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Simulate vault transferring assets to adapter
        uint256 assetAmount = 1000e6;
        asset.mint(address(adapter), assetAmount);

        // Initial state: assets are idle
        assertEq(adapter.getIdleAssets(), assetAmount, "Assets should be idle before allocation");

        // Allocate with full asset amount - this tracks the allocation internally
        bytes memory allocateData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.allocate(allocateData, assetAmount, bytes4(0), address(0));

        // L-13 FIX: All assets are tracked and available for strategy use
        assertEq(adapter.getAllocation(STRATEGY_1), assetAmount, "Full asset amount should be tracked");
        assertEq(int256(assetAmount), change, "Change should equal full asset amount");
        assertEq(ids[0], STRATEGY_1, "Strategy ID should be returned");

        // L-04 FIX: Assets are allocated, so getIdleAssets should return 0 (not idle anymore)
        assertEq(adapter.getIdleAssets(), 0, "Allocated assets are not idle");
        assertEq(adapter.totalAllocations(), assetAmount, "Total allocations should track allocated amount");

        // The key difference from old architecture: assets are tracked and available, not lost
        assertTrue(adapter.getAllocation(STRATEGY_1) > 0, "Assets are allocated and tracked for strategy use");
    }

    function testL13IdleAssetVisibility() public {
        // L-13 FIX: Test visibility into idle assets
        // SECURITY FIX: Test that donated assets are NOT counted in realAssets (prevents donation attack)

        // Initially no idle assets
        assertEq(adapter.getIdleAssets(), 0, "Should start with no idle assets");

        // Transfer some assets directly to adapter (simulating donation attack)
        uint256 donatedAmount = 100e6;
        asset.mint(address(adapter), donatedAmount);

        // Should be visible through getIdleAssets (visible but not counted in valuation)
        assertEq(adapter.getIdleAssets(), donatedAmount, "Idle assets should be visible");

        // SECURITY FIX: Should NOT be included in realAssets (prevents donation inflation attack)
        // With no allocations, realAssets should be 0 (ignores donations)
        uint256 totalAssets = adapter.realAssets();
        assertEq(totalAssets, 0, "Real assets should NOT include donated assets (security fix)");
    }

    /* L-04 FIX TESTS */

    function testL04GetIdleAssetsBeforeAllocation() public {
        // L-04 FIX: Test that getIdleAssets correctly returns assets before allocation

        // Transfer assets to adapter
        uint256 amount = 500e6;
        asset.mint(address(adapter), amount);

        // Before allocation, all assets are idle
        assertEq(adapter.getIdleAssets(), amount, "All assets should be idle before allocation");
        assertEq(adapter.totalAllocations(), 0, "No allocations should exist");
    }

    function testL04GetIdleAssetsAfterPartialAllocation() public {
        // L-04 FIX: Test getIdleAssets after partial allocation

        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Transfer 1000e6 to adapter
        uint256 totalAssets = 1000e6;
        asset.mint(address(adapter), totalAssets);

        // Initially all assets are idle
        assertEq(adapter.getIdleAssets(), totalAssets, "All assets should be idle initially");

        // Allocate 600e6 to strategy
        uint256 allocatedAmount = 600e6;
        bytes memory allocateData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, allocatedAmount, bytes4(0), address(0));

        // L-04 FIX: Only unallocated assets (1000 - 600 = 400) should be considered idle
        uint256 expectedIdle = totalAssets - allocatedAmount;
        assertEq(adapter.getIdleAssets(), expectedIdle, "Only unallocated assets should be idle");
        assertEq(adapter.totalAllocations(), allocatedAmount, "Total allocations should match allocated amount");
    }

    function testL04GetIdleAssetsAfterFullAllocation() public {
        // L-04 FIX: Test getIdleAssets after full allocation

        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Transfer assets to adapter
        uint256 amount = 800e6;
        asset.mint(address(adapter), amount);

        // Allocate all assets to strategy
        bytes memory allocateData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, amount, bytes4(0), address(0));

        // L-04 FIX: No idle assets remain after full allocation
        assertEq(adapter.getIdleAssets(), 0, "No assets should be idle after full allocation");
        assertEq(adapter.totalAllocations(), amount, "Total allocations should match allocated amount");
    }

    function testL04GetIdleAssetsWithMultipleStrategies() public {
        // L-04 FIX: Test getIdleAssets with allocations across multiple strategies

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.setStrategy(STRATEGY_2, agent, "", 1000e6);
        vm.stopPrank();

        // Transfer 1500e6 to adapter
        uint256 totalAssets = 1500e6;
        asset.mint(address(adapter), totalAssets);

        // Initially all assets are idle
        assertEq(adapter.getIdleAssets(), totalAssets, "All assets should be idle initially");

        // Allocate 500e6 to STRATEGY_1
        bytes memory allocData1 = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData1, 500e6, bytes4(0), address(0));

        // 1000e6 should still be idle
        assertEq(adapter.getIdleAssets(), 1000e6, "1000e6 should remain idle");

        // Allocate 700e6 to STRATEGY_2
        bytes memory allocData2 = abi.encode(STRATEGY_2, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData2, 700e6, bytes4(0), address(0));

        // L-04 FIX: Only 300e6 (1500 - 500 - 700) should be idle
        assertEq(adapter.getIdleAssets(), 300e6, "300e6 should remain idle");
        assertEq(adapter.totalAllocations(), 1200e6, "Total allocations should be 1200e6");
    }

    function testL04GetIdleAssetsAfterDeallocate() public {
        // L-04 FIX: Test getIdleAssets after deallocation

        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Transfer and allocate
        uint256 amount = 1000e6;
        asset.mint(address(adapter), amount);
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData, amount, bytes4(0), address(0));

        // All assets allocated, none idle
        assertEq(adapter.getIdleAssets(), 0, "No idle assets after full allocation");

        // Deallocate 400e6
        bytes memory deallocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.deallocate(deallocData, 400e6, bytes4(0), address(0));

        // L-04 FIX: After deallocation, 400e6 should be idle again
        assertEq(adapter.getIdleAssets(), 400e6, "400e6 should be idle after deallocation");
        assertEq(adapter.totalAllocations(), 600e6, "600e6 should remain allocated");
    }

    function testL04GetIdleAssetsWithProfits() public {
        // L-04 FIX: Test getIdleAssets when strategy generates profits

        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Transfer and allocate 500e6
        uint256 initialAmount = 500e6;
        asset.mint(address(adapter), initialAmount);
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData, initialAmount, bytes4(0), address(0));

        // All assets allocated, none idle
        assertEq(adapter.getIdleAssets(), 0, "No idle assets after allocation");

        // Simulate profits: mint additional 200e6 to adapter
        uint256 profits = 200e6;
        asset.mint(address(adapter), profits);

        // L-04 FIX: Profits are idle (not allocated to any strategy)
        assertEq(adapter.getIdleAssets(), profits, "Profits should be idle");
        assertEq(adapter.totalAllocations(), initialAmount, "Allocations unchanged by profits");

        // Total balance is initial + profits
        assertEq(asset.balanceOf(address(adapter)), initialAmount + profits, "Total balance includes profits");
    }

    function testL04GetIdleAssetsAccuracy() public {
        // L-04 FIX: Comprehensive test of getIdleAssets accuracy

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.setStrategy(STRATEGY_2, agent, "", 1000e6);
        vm.stopPrank();

        // Scenario: Complex series of allocations, deallocations, and external transfers

        // Step 1: Transfer 2000e6 to adapter
        asset.mint(address(adapter), 2000e6);
        assertEq(adapter.getIdleAssets(), 2000e6, "Step 1: All assets idle");

        // Step 2: Allocate 800e6 to STRATEGY_1
        bytes memory alloc1 = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(alloc1, 800e6, bytes4(0), address(0));
        assertEq(adapter.getIdleAssets(), 1200e6, "Step 2: 1200e6 idle after first allocation");

        // Step 3: Allocate 900e6 to STRATEGY_2
        bytes memory alloc2 = abi.encode(STRATEGY_2, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(alloc2, 900e6, bytes4(0), address(0));
        assertEq(adapter.getIdleAssets(), 300e6, "Step 3: 300e6 idle after second allocation");

        // Step 4: External transfer of 500e6 profits
        asset.mint(address(adapter), 500e6);
        assertEq(adapter.getIdleAssets(), 800e6, "Step 4: 800e6 idle after profits");

        // Step 5: Deallocate 300e6 from STRATEGY_1
        bytes memory dealloc1 = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.deallocate(dealloc1, 300e6, bytes4(0), address(0));
        assertEq(adapter.getIdleAssets(), 1100e6, "Step 5: 1100e6 idle after deallocation");

        // Step 6: Verify internal consistency
        uint256 balance = asset.balanceOf(address(adapter));
        uint256 totalAlloc = adapter.totalAllocations();
        uint256 idleAssets = adapter.getIdleAssets();
        assertEq(balance, totalAlloc + idleAssets, "Balance should equal allocations + idle");
    }

    /* EXTERNAL DEPOSIT TRACKING TESTS (CRITICAL FIX) */

    function testExternalDepositTrackingBasic() public {
        // CRITICAL FIX: Test that external deposits are tracked when executeStrategy moves tokens

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Create mock protocol and whitelist token transfer to it
        MockProtocol mockProtocol = new MockProtocol(address(asset));
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        vm.stopPrank();

        // Allocate 1000e6 to strategy
        uint256 allocAmount = 1000e6;
        asset.mint(address(adapter), allocAmount);
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Before execution: all allocated assets are in adapter, 0 idle
        assertEq(adapter.getIdleAssets(), 0, "No idle assets after allocation");
        assertEq(adapter.externalDeposits(STRATEGY_1), 0, "No external deposits yet");
        assertEq(asset.balanceOf(address(adapter)), allocAmount, "Full balance in adapter");

        // Execute strategy to transfer 90e6 to external protocol (9% under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", address(mockProtocol), 90e6),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls);

        // CRITICAL FIX: After execution, external deposits are tracked
        assertEq(adapter.externalDeposits(STRATEGY_1), 90e6, "Should track 90e6 external deposits");
        assertEq(adapter.totalExternalDeposits(), 90e6, "Total external deposits should be 90e6");
        assertEq(asset.balanceOf(address(adapter)), 910e6, "910e6 remains in adapter");
        assertEq(asset.balanceOf(address(mockProtocol)), 90e6, "90e6 moved to protocol");

        // CRITICAL: getIdleAssets should still return 0 (all assets are allocated, just moved externally)
        assertEq(adapter.getIdleAssets(), 0, "No idle assets - all still allocated");
    }

    function testExternalDepositTrackingWithProfit() public {
        // CRITICAL FIX: Test that profits from external protocols are correctly identified as idle

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        MockProtocol mockProtocol = new MockProtocol(address(asset));
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        adapter.updateWhitelist(address(mockProtocol), bytes4(keccak256("withdraw(uint256)")), true, 0);
        vm.stopPrank();

        // Allocate and execute deposit to protocol
        uint256 allocAmount = 1000e6;
        asset.mint(address(adapter), allocAmount);
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData, allocAmount, bytes4(0), address(0));

        // Execute deposit: transfer 80e6 to protocol (8% of 1000e6, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", address(mockProtocol), 80e6),
            value: 0
        });
        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, depositCalls);

        // Simulate protocol generating 200e6 profit
        asset.mint(address(mockProtocol), 200e6);

        // Withdraw 280e6 (80 principal + 200 profit) - adjusted for 8% deposit
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 280e6),
            value: 0
        });

        // SECURITY FIX Issue #1 (security_issues_5nov2025_4.md): executeStrategy() now prevents balance increases
        // Use executeStrategyWithSlippage() for withdrawals to enable symmetric reduction
        vm.prank(agent);
        adapter.executeStrategyWithSlippage(STRATEGY_1, withdrawCalls, 280e6);

        // SECURITY FIX Issue #1 (security_issues_5nov2025_4.md): Symmetric reduction in controlled withdrawal paths
        // executeStrategyWithSlippage() reduces externalDeposits by the measured balance increase
        // After withdrawal with profit:
        // - Balance increase: 280e6 (80 principal + 200 profit)
        // - externalDeposits reduced from 80e6 by min(280e6, 80e6, totalExternalDeposits) = 80e6
        // - externalDeposits: 80e6 - 80e6 = 0e6
        // - adapter balance: 920e6 (kept) + 280e6 (withdrawn) = 1200e6
        // - totalAllocations: 1000e6
        assertEq(adapter.externalDeposits(STRATEGY_1), 0, "External deposits reduced by symmetric reduction (80e6)");
        assertEq(adapter.totalExternalDeposits(), 0, "Total external deposits reduced to 0");
        assertEq(asset.balanceOf(address(adapter)), 1200e6, "Adapter has principal + profit");

        // getIdleAssets() should correctly report 200e6 profit as idle
        // Idle = balance - (totalAllocations - totalExternalDeposits) = 1200 - (1000 - 0) = 200
        assertEq(adapter.getIdleAssets(), 200e6, "200e6 profit correctly identified as idle");
    }

    function testExecuteStrategyWithSlippageTracksWithdrawalsWhenMinIncreaseIsZero() public {
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        MockProtocol mockProtocol = new MockProtocol(address(asset));
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        adapter.updateWhitelist(address(mockProtocol), bytes4(keccak256("withdraw(uint256)")), true, 0);
        vm.stopPrank();

        asset.mint(address(adapter), 1_000e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 1_000e6, bytes4(0), address(0)
        );

        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", address(mockProtocol), 80e6),
            value: 0
        });
        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, depositCalls);

        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 30e6),
            value: 0
        });
        vm.prank(agent);
        adapter.executeStrategyWithSlippage(STRATEGY_1, withdrawCalls, 0);

        assertEq(adapter.externalDeposits(STRATEGY_1), 50e6);
        assertEq(adapter.totalExternalDeposits(), 50e6);
        assertEq(asset.balanceOf(address(adapter)), 950e6);
    }

    function testExternalDepositTrackingMultipleStrategies() public {
        // CRITICAL FIX: Test tracking with multiple strategies depositing to different protocols

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.setStrategy(STRATEGY_2, agent, "", 1000e6);

        MockProtocol protocol1 = new MockProtocol(address(asset));
        MockProtocol protocol2 = new MockProtocol(address(asset));
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        vm.stopPrank();

        // Allocate to STRATEGY_1
        uint256 alloc1 = 500e6;
        asset.mint(address(adapter), alloc1);
        bytes memory allocData1 = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData1, alloc1, bytes4(0), address(0));

        // Execute STRATEGY_1: transfer 40e6 to protocol1 (8% of 500e6, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory calls1 = new IUniversalAdapterEscrow.Call[](1);
        calls1[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", address(protocol1), 40e6),
            value: 0
        });
        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls1);

        // Allocate to STRATEGY_2
        uint256 alloc2 = 700e6;
        asset.mint(address(adapter), alloc2);
        bytes memory allocData2 = abi.encode(STRATEGY_2, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData2, alloc2, bytes4(0), address(0));

        // Execute STRATEGY_2: transfer 50e6 to protocol2 (4.3% of 1160e6, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory calls2 = new IUniversalAdapterEscrow.Call[](1);
        calls2[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", address(protocol2), 50e6),
            value: 0
        });
        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_2, calls2);

        // CRITICAL FIX: Verify per-strategy and total external deposits
        assertEq(adapter.externalDeposits(STRATEGY_1), 40e6, "STRATEGY_1 has 40e6 external");
        assertEq(adapter.externalDeposits(STRATEGY_2), 50e6, "STRATEGY_2 has 50e6 external");
        assertEq(adapter.totalExternalDeposits(), 90e6, "Total 90e6 external deposits");

        // Balance in adapter: 500 - 40 + 700 - 50 = 1110e6
        assertEq(asset.balanceOf(address(adapter)), 1110e6, "1110e6 remains in adapter");

        // Idle assets: balance - (totalAllocations - totalExternalDeposits)
        // = 1110 - (1200 - 90) = 1110 - 1110 = 0
        assertEq(adapter.getIdleAssets(), 0, "No idle assets");
    }

    function testExternalDepositTrackingWithDeallocate() public {
        // CRITICAL FIX: Test that deallocation properly handles external deposits

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        MockProtocol mockProtocol = new MockProtocol(address(asset));
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        adapter.updateWhitelist(address(mockProtocol), bytes4(keccak256("withdraw(uint256)")), true, 0);
        vm.stopPrank();

        // Allocate 1000e6
        asset.mint(address(adapter), 1000e6);
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));

        // Execute: transfer 80e6 to protocol (8% of 1000e6, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", address(mockProtocol), 80e6),
            value: 0
        });
        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, depositCalls);

        // State: adapter has 920e6, protocol has 80e6, externalDeposits[STRATEGY_1] = 80e6

        // Deallocate 400e6 - has enough in adapter balance (no protocol withdrawal needed)
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](0); // Empty - use
            // adapter balance
        bytes memory deallocData = abi.encode(STRATEGY_1, 0, withdrawCalls);

        vm.prank(address(vault));
        adapter.deallocate(deallocData, 400e6, bytes4(0), address(0));

        // CRITICAL FIX: Deallocation reduces total allocations
        // External deposits unchanged (no withdrawal from protocol)
        assertEq(adapter.externalDeposits(STRATEGY_1), 80e6, "External deposits unchanged");
        assertEq(adapter.totalExternalDeposits(), 80e6, "Total external deposits unchanged");
        assertEq(adapter.totalAllocations(), 600e6, "Allocations reduced to 600e6");

        // Balance: 920e6 in adapter (vault hasn't pulled yet)
        assertEq(asset.balanceOf(address(adapter)), 920e6, "920e6 in adapter before vault pulls");
    }

    function testExternalDepositTrackingEdgeCasePartialWithdrawal() public {
        // CRITICAL FIX: Test edge case where withdrawal is less than deposit

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        MockProtocol mockProtocol = new MockProtocol(address(asset));
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        adapter.updateWhitelist(address(mockProtocol), bytes4(keccak256("withdraw(uint256)")), true, 0);
        vm.stopPrank();

        // Allocate and deposit to protocol
        asset.mint(address(adapter), 1000e6);
        bytes memory allocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));

        // Transfer 90e6 to protocol (9% of 1000e6, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", address(mockProtocol), 90e6),
            value: 0
        });
        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, depositCalls);

        // Partial withdrawal: 30e6 (3.3% of 910e6, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 30e6),
            value: 0
        });

        // SECURITY FIX Issue #1 (security_issues_5nov2025_4.md): executeStrategy() now prevents balance increases
        // Use executeStrategyWithSlippage() for withdrawals to enable symmetric reduction
        vm.prank(agent);
        adapter.executeStrategyWithSlippage(STRATEGY_1, withdrawCalls, 30e6);

        // SECURITY FIX Issue #1 (security_issues_5nov2025_4.md): Symmetric reduction in controlled withdrawal paths
        // executeStrategyWithSlippage() reduces externalDeposits by the measured balance increase
        // After partial withdrawal:
        // - Balance increase: 30e6
        // - externalDeposits reduced from 90e6 by min(30e6, 90e6, totalExternalDeposits) = 30e6
        // - externalDeposits: 90e6 - 30e6 = 60e6
        assertEq(adapter.externalDeposits(STRATEGY_1), 60e6, "External deposits reduced by symmetric reduction (30e6)");
        assertEq(adapter.totalExternalDeposits(), 60e6, "Total external deposits = 60e6");
        assertEq(asset.balanceOf(address(adapter)), 940e6, "940e6 in adapter");

        // getIdleAssets() should correctly report 0 (all assets still allocated)
        // Idle = balance - (totalAllocations - totalExternalDeposits) = 940 - (1000 - 60) = 0
        assertEq(adapter.getIdleAssets(), 0, "No idle assets - all still allocated");
    }

    function testExternalDepositTrackingComplexScenario() public {
        // CRITICAL FIX: Comprehensive test with multiple allocations, executions, and deallocations

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 2000e6);

        MockProtocol mockProtocol = new MockProtocol(address(asset));
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        adapter.updateWhitelist(address(mockProtocol), bytes4(keccak256("withdraw(uint256)")), true, 0);
        vm.stopPrank();

        // Step 1: Allocate 800e6
        asset.mint(address(adapter), 800e6);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 800e6, bytes4(0), address(0));
        assertEq(adapter.getIdleAssets(), 0, "Step 1: No idle after allocation");

        // Step 2: Transfer 70e6 to protocol (8.75% of 800e6, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](1);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", address(mockProtocol), 70e6),
            value: 0
        });
        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, depositCalls);
        assertEq(adapter.externalDeposits(STRATEGY_1), 70e6, "Step 2: 70e6 external");
        assertEq(asset.balanceOf(address(adapter)), 730e6, "Step 2: 730e6 in adapter");
        assertEq(adapter.getIdleAssets(), 0, "Step 2: No idle");

        // Step 3: Add more allocation (400e6)
        asset.mint(address(adapter), 400e6);
        vm.prank(address(vault));
        adapter.allocate(abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0)), 400e6, bytes4(0), address(0));
        // Now: totalAllocations = 1200, externalDeposits = 70, balance = 1130
        assertEq(adapter.totalAllocations(), 1200e6, "Step 3: 1200e6 total allocated");
        assertEq(adapter.getIdleAssets(), 0, "Step 3: No idle");

        // Step 4: Receive 300e6 profit directly
        asset.mint(address(adapter), 300e6);
        // Now: balance = 1430, totalAllocations = 1200, externalDeposits = 70
        // Idle = 1430 - (1200 - 70) = 1430 - 1130 = 300
        assertEq(adapter.getIdleAssets(), 300e6, "Step 4: 300e6 profit is idle");

        // Step 5: Withdraw 30e6 from protocol (2.1% of 1430e6, under circuit breaker threshold)
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 30e6),
            value: 0
        });

        // SECURITY FIX Issue #1 (security_issues_5nov2025_4.md): executeStrategy() now prevents balance increases
        // Use executeStrategyWithSlippage() for withdrawals to enable symmetric reduction
        vm.prank(agent);
        adapter.executeStrategyWithSlippage(STRATEGY_1, withdrawCalls, 30e6);

        // SECURITY FIX Issue #1 (security_issues_5nov2025_4.md): Symmetric reduction in controlled withdrawal paths
        // executeStrategyWithSlippage() reduces externalDeposits by the measured balance increase
        // After withdrawal:
        // - Balance increase: 30e6
        // - externalDeposits reduced from 70e6 by min(30e6, 70e6, totalExternalDeposits) = 30e6
        // - externalDeposits: 70e6 - 30e6 = 40e6
        assertEq(adapter.externalDeposits(STRATEGY_1), 40e6, "Step 5: 40e6 external (reduced by symmetric reduction)");
        assertEq(asset.balanceOf(address(adapter)), 1460e6, "Step 5: 1460e6 in adapter");

        // Step 6: Deallocate 500e6
        bytes memory deallocData = abi.encode(STRATEGY_1, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.deallocate(deallocData, 500e6, bytes4(0), address(0));
        assertEq(adapter.totalAllocations(), 700e6, "Step 6: 700e6 allocated");
        // With symmetric reduction: externalDeposits = 40e6
        // Idle = 1460 - (700 - 40) = 1460 - 660 = 800
        assertEq(adapter.getIdleAssets(), 800e6, "Step 6: 800e6 idle");
    }

    function testDeallocateSmartBalanceFirst() public {
        // SECURITY FIX: Test the new smart balance-first deallocate logic

        // Setup: Allocate to a strategy
        bytes32 strategyId = STRATEGY_1;
        address strategyAgent = address(new MockAgent());

        vm.prank(owner);
        adapter.setStrategy(strategyId, strategyAgent, "", 1000e6);

        uint256 initialAllocation = 500e6;
        asset.mint(address(this), initialAllocation);
        asset.transfer(address(adapter), initialAllocation);

        vm.prank(address(vault));
        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocateData, initialAllocation, 0, address(0));

        // Simulate profits by adding extra tokens to adapter
        uint256 profits = 200e6;
        asset.mint(address(adapter), profits);

        // Test: Deallocate with balance available in adapter (should NOT execute external calls)
        uint256 deallocateAmount = 300e6;
        bytes memory deallocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));

        // Record balance before
        uint256 balanceBefore = asset.balanceOf(address(adapter));
        assertEq(balanceBefore, 700e6, "Should have initial allocation + profits");

        // Should use adapter balance without external calls
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocateData, deallocateAmount, bytes4(0), address(0));

        assertEq(ids[0], strategyId, "Should return correct strategy ID");
        assertEq(change, -int256(deallocateAmount), "Should report correct change");

        // Verify allocation was reduced correctly
        uint256 remainingAllocation = adapter.getAllocation(strategyId);
        assertEq(remainingAllocation, 200e6, "Allocation should be reduced by deallocate amount");

        // Balance stays in adapter until vault pulls it - this is correct behavior
        uint256 remainingBalance = asset.balanceOf(address(adapter));
        assertEq(remainingBalance, balanceBefore, "Balance remains until vault pulls assets");
    }

    function testDeallocateWithProtocolWithdrawal() public {
        // SECURITY FIX: Test deallocate when adapter balance is insufficient

        // Setup: Allocate to a strategy
        bytes32 strategyId = STRATEGY_1;
        address strategyAgent = address(new MockAgent());

        vm.startPrank(owner);
        adapter.setStrategy(strategyId, strategyAgent, "", 1000e6);

        // Create and whitelist a mock protocol for testing
        MockProtocol mockProtocol = new MockProtocol(address(asset));
        adapter.updateWhitelist(address(mockProtocol), bytes4(0), true, 0);
        vm.stopPrank();

        uint256 initialAllocation = 500e6;
        asset.mint(address(this), initialAllocation);
        asset.transfer(address(adapter), initialAllocation);

        // Allocate funds
        vm.prank(address(vault));
        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocateData, initialAllocation, 0, address(0));

        // Simulate that funds were invested in protocol
        // Move most funds from adapter to protocol
        vm.prank(address(adapter));
        asset.transfer(address(mockProtocol), 450e6);

        // Adapter now has only 50e6, protocol has 450e6
        assertEq(asset.balanceOf(address(adapter)), 50e6, "Adapter should have limited balance");
        assertEq(asset.balanceOf(address(mockProtocol)), 450e6, "Protocol should hold most funds");

        // Test: Request more than adapter balance (200e6 when adapter only has 50e6)
        uint256 deallocateAmount = 200e6;

        // LAZY DEALLOCATION PATTERN: Agent withdraws from protocol BEFORE user deallocate
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 150e6),
            value: 0
        });

        vm.prank(strategyAgent);
        adapter.withdrawFromStrategy(strategyId, withdrawCalls, 150e6);

        // Verify funds were pulled from protocol by agent
        assertEq(asset.balanceOf(address(adapter)), 200e6, "Adapter should have received funds from agent withdrawal");
        assertEq(asset.balanceOf(address(mockProtocol)), 300e6, "Protocol should have 150e6 less");

        // Now user can deallocate (withdrawCalls ignored in new implementation)
        bytes memory deallocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocateData, deallocateAmount, bytes4(0), address(0));

        assertEq(ids[0], strategyId, "Should return correct strategy ID");
        assertEq(change, -int256(deallocateAmount), "Should report correct change");
    }

    function testDeallocateProfitsAccessible() public {
        // SECURITY FIX: change is capped at allocation to prevent cap bypass
        // VaultV2 can still transfer the full amount, but cap accounting stays accurate

        // Setup strategy
        bytes32 strategyId = STRATEGY_1;
        address strategyAgent = address(new MockAgent());

        vm.prank(owner);
        adapter.setStrategy(strategyId, strategyAgent, "", 1000e6);

        uint256 initialAllocation = 500e6;
        asset.mint(address(this), initialAllocation);
        asset.transfer(address(adapter), initialAllocation);

        // Allocate
        vm.prank(address(vault));
        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        adapter.allocate(allocateData, initialAllocation, 0, address(0));

        // Simulate 40% profit generated by strategy
        uint256 profits = 200e6;
        asset.mint(address(adapter), profits);

        // Balance should now be initial + profits
        assertEq(asset.balanceOf(address(adapter)), initialAllocation + profits, "Should have allocation + profits");

        // Request more than allocation (600e6 when allocation is 500e6)
        uint256 deallocateWithProfits = initialAllocation + 100e6; // Take initial + half of profits
        bytes memory deallocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocateData, deallocateWithProfits, bytes4(0), address(0));

        assertEq(ids[0], strategyId, "Should return correct strategy ID");
        // SECURITY FIX: change capped at allocation (500e6), not requested (600e6)
        assertEq(change, -int256(initialAllocation), "Change capped at allocation to prevent cap bypass");

        // Balance stays in adapter until vault pulls it
        uint256 remainingBalance = asset.balanceOf(address(adapter));
        assertEq(remainingBalance, 700e6, "Balance remains until vault pulls it");

        // Verify allocation was fully depleted
        uint256 remainingAllocation = adapter.getAllocation(strategyId);
        assertEq(remainingAllocation, 0, "Allocation should be zero");
    }

    /* SECURITY FIX: PERMISSIONLESS CREATE2 DEPLOYMENT PREVENTION */

    function testFactoryDeploymentOnlyByVaultOwner() public {
        // SECURITY FIX: Verify that only vault owner can deploy adapters
        // This prevents front-running attacks where an attacker could deploy
        // with known salt/params and capture adapter ownership

        UniversalAdapterEscrowFactory newFactory = new UniversalAdapterEscrowFactory();

        // Attacker tries to deploy adapter for the vault
        vm.prank(attacker);
        vm.expectRevert(UniversalAdapterEscrowFactory.OnlyVaultOwnerCanDeploy.selector);
        newFactory.deployAdapter(address(vault), keccak256("attacker-salt"));

        // Owner can successfully deploy
        vm.prank(owner);
        address deployed = newFactory.deployAdapter(address(vault), keccak256("owner-salt"));
        assertTrue(deployed != address(0), "Owner should be able to deploy");
    }

    function testSetStrategySucceedsWithNormalStrategyId() public {
        // Normal strategy IDs should work fine
        bytes32 normalStrategyId = keccak256("SOME_STRATEGY");

        // This should NOT equal the ESCROW_TOTAL ID
        bytes32 escrowTotalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));
        assertTrue(normalStrategyId != escrowTotalId, "Test setup: IDs should be different");

        // Setting strategy should succeed
        vm.prank(owner);
        adapter.setStrategy(normalStrategyId, agent, "", 1000e6);

        // Verify strategy was set
        IUniversalAdapterEscrow.StrategyConfig memory config = adapter.getStrategy(normalStrategyId);
        assertTrue(config.active, "Strategy should be active");
        assertEq(config.agent, agent, "Agent should be set correctly");
    }

    function testExecuteStrategyRejectsShortCalldata() public {
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);
        adapter.updateWhitelist(address(target), bytes4(0), true, type(uint256).max);
        vm.stopPrank();

        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({target: address(target), data: hex"01", value: 0});

        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.InvalidData.selector);
        adapter.executeStrategy(STRATEGY_1, calls);
    }

    function testAutoWithdrawRejectsOversizedQuotedCallArray() public {
        MockAutomationController automationController = new MockAutomationController(address(target), 65);

        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, address(automationController), "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, uint256(0), new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        vm.prank(address(adapter));
        asset.transfer(attacker, 100e6);

        bytes memory deallocData = abi.encode(STRATEGY_1, uint256(2), new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(IUniversalAdapterEscrow.InsufficientAdapterBalance.selector, 0, 100e6));
        adapter.deallocate(deallocData, 100e6, bytes4(keccak256("withdraw(uint256,address,address)")), address(0));
    }

    function testAutoAllocationRejectsOversizedQuotedCallArray() public {
        MockAutomationController automationController = new MockAutomationController(address(target), 65);

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, address(automationController), "", 1000e6);
        adapter.updateWhitelist(address(target), bytes4(keccak256("withdraw(uint256)")), true, 0);
        vm.stopPrank();

        asset.mint(address(adapter), 100e6);

        bytes memory allocData = abi.encode(STRATEGY_1, uint256(1), new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidData.selector);
        adapter.allocate(allocData, 100e6, bytes4(keccak256("allocate(address,bytes,uint256)")), address(0));
    }
}

// Mock protocol for testing withdrawals and deposits
contract MockProtocol {
    address public immutable asset;

    constructor(address _asset) {
        asset = _asset;
    }

    function deposit(uint256 amount) external {
        // Transfer tokens from sender (adapter) to this protocol
        IERC20(asset).transferFrom(msg.sender, address(this), amount);
    }

    function withdraw(uint256 amount) external {
        // Transfer tokens from protocol back to sender (adapter)
        IERC20(asset).transfer(msg.sender, amount);
    }
}

contract MockAutomationController {
    address public immutable target;
    uint256 public immutable callCount;

    constructor(address _target, uint256 _callCount) {
        target = _target;
        callCount = _callCount;
    }

    function quoteCurrentAssets() external pure returns (uint256 assets, bool healthy) {
        return (0, true);
    }

    function quoteAutomaticWithdrawal(uint256) external view returns (IUniversalAdapterEscrow.Call[] memory calls) {
        calls = new IUniversalAdapterEscrow.Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            calls[i] = IUniversalAdapterEscrow.Call({
                target: target,
                data: abi.encodeWithSignature("withdraw(uint256)", 0),
                value: 0
            });
        }
    }

    function quoteAutomaticAllocation(uint256) external view returns (IUniversalAdapterEscrow.Call[] memory calls) {
        calls = new IUniversalAdapterEscrow.Call[](callCount);
        for (uint256 i; i < callCount; i++) {
            calls[i] = IUniversalAdapterEscrow.Call({
                target: target,
                data: abi.encodeWithSignature("withdraw(uint256)", 0),
                value: 0
            });
        }
    }
}
