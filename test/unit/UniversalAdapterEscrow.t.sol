// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockFeeOnTransferToken} from "../mocks/MockFeeOnTransferToken.sol";
import {MockVaultV2} from "../mocks/MockVaultV2.sol";
import {MockValuer} from "../mocks/MockValuer.sol";
import {MockTarget} from "../mocks/MockTarget.sol";

contract UniversalAdapterEscrowTest is Test {
    UniversalAdapterEscrow adapter;
    UniversalAdapterEscrowFactory factory;
    MockVaultV2 vault;
    MockERC20 asset;
    MockERC20 rewardToken;
    MockValuer valuer;
    MockTarget target;

    address owner = address(0x1);
    address agent = address(0x2);
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
        // Deploy mocks
        asset = new MockERC20("USDC", "USDC", 6);
        rewardToken = new MockERC20("REWARD", "RWD", 18);
        valuer = new MockValuer();
        target = new MockTarget();

        // Deploy vault mock
        vault = new MockVaultV2(address(asset), owner);

        // Deploy factory
        factory = new UniversalAdapterEscrowFactory();

        // Deploy adapter via factory
        adapter = UniversalAdapterEscrow(
            payable(factory.deployAdapter(
                address(vault),
                address(valuer),
                false, // use onchain valuer
                keccak256("test-salt")
            ))
        );

        // Setup initial state
        vm.startPrank(owner);
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
        assertEq(adapter.valuer(), address(valuer));
        assertEq(adapter.useOffchainValuer(), false);
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

        bytes memory data = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));

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
        bytes memory data = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));
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

        bytes memory data = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));

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
        bytes memory data = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.StrategyNotActive.selector);
        adapter.allocate(data, 100e6, bytes4(0), address(0));
    }

    function testDeallocate() public {
        // Setup: allocate first
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Deallocate - no longer includes amount parameter
        bytes memory deallocData = abi.encode(STRATEGY_1, new IUniversalAdapterEscrow.Call[](0));

        vm.expectEmit(true, false, false, true);
        emit AllocationUpdated(STRATEGY_1, 50e6, -int256(50e6));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocData, 50e6, bytes4(0), address(0));

        assertEq(ids.length, 1);
        assertEq(ids[0], STRATEGY_1);
        assertEq(change, -int256(50e6));
        assertEq(adapter.getAllocation(STRATEGY_1), 50e6);
    }

    function testDeallocateAll() public {
        // Setup: allocate first
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Deallocate all - pass assets as max to deallocate all
        bytes memory deallocData = abi.encode(STRATEGY_1, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocData, 100e6, bytes4(0), address(0));

        assertEq(change, -int256(100e6));
        assertEq(adapter.getAllocation(STRATEGY_1), 0);

        // Strategy should be removed from active list
        bytes32[] memory active = adapter.getActiveStrategies();
        assertEq(active.length, 0);
    }

    function testDeallocateWithYield() public {
        // Setup: allocate first
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Simulate yield by setting higher value in valuer (150e6 vs 100e6 allocated)
        valuer.setValue(STRATEGY_1, 150e6);

        // Transfer extra assets to adapter to cover yield withdrawal
        asset.mint(address(adapter), 50e6);

        // Deallocate with yield - should be able to withdraw 120e6 even though only 100e6 was allocated
        bytes memory deallocData = abi.encode(STRATEGY_1, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocData, 120e6, bytes4(0), address(0));

        assertEq(ids[0], STRATEGY_1);
        assertEq(change, -int256(120e6), "Should be able to withdraw yield");
        assertEq(adapter.getAllocation(STRATEGY_1), 0, "Allocation should be 0 after withdrawing more than allocated");
    }

    function testAllocateWithFeeOnTransferToken() public {
        // Create a fee-on-transfer adapter for testing
        MockFeeOnTransferToken feeToken = new MockFeeOnTransferToken("FeeToken", "FEE", 18);
        feeToken.setTransferFeePercent(100); // 1% fee

        // Create a new adapter with the fee token
        UniversalAdapterEscrow feeAdapter = new UniversalAdapterEscrow(
            address(vault),
            address(valuer),
            false
        );

        // Mock the asset function to return our fee token
        vm.mockCall(
            address(vault),
            abi.encodeWithSignature("asset()"),
            abi.encode(address(feeToken))
        );

        vm.prank(owner);
        vault.addAdapter(address(feeAdapter));

        vm.prank(owner);
        feeAdapter.setStrategy(STRATEGY_1, agent, "", 1000e18);

        // Mint tokens and simulate vault transfer with fee
        uint256 requestedAmount = 100e18;
        feeToken.mint(address(vault), requestedAmount);

        // Simulate vault transferring to adapter (with fee deducted)
        vm.prank(address(vault));
        feeToken.transfer(address(feeAdapter), requestedAmount);

        // Check actual received amount (should be less due to fee)
        uint256 actualReceived = feeToken.balanceOf(address(feeAdapter));
        uint256 expectedReceived = requestedAmount - (requestedAmount * 100) / 10000; // 1% fee
        assertEq(actualReceived, expectedReceived, "Should receive amount minus fee");

        // Allocate using actual received amount (this is what vault passes as assets parameter)
        bytes memory allocData = abi.encode(STRATEGY_1, requestedAmount, false, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = feeAdapter.allocate(allocData, actualReceived, bytes4(0), address(0));

        // Verify allocation is tracked with actual received amount, not requested amount
        assertEq(feeAdapter.getAllocation(STRATEGY_1), actualReceived, "Should track actual received amount");
        assertEq(change, int256(actualReceived), "Should return actual received amount as change");
        assertEq(ids[0], STRATEGY_1);
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

        // Multiple large transfers that would have exceeded old daily limit should now succeed
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 15e6),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed

        // Another large transfer - should also succeed (no daily limit enforcement)
        calls[0].data = abi.encodeWithSignature("transfer(address,uint256)", recipient, 20e6);

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed
    }

    function testPerCallLimitStillEnforced() public {
        // L-16 Fix: Daily limits removed, but per-call limits still work
        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 10e6); // Daily limit ignored
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 5e6); // Per-call limit of 5 USDC
        vm.stopPrank();

        asset.mint(address(adapter), 100e6);

        // Transfer within per-call limit - should succeed
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 5e6),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed

        // Transfer exceeding per-call limit - should fail
        calls[0].data = abi.encodeWithSignature("transfer(address,uint256)", recipient, 6e6);

        vm.prank(agent);
        vm.expectRevert(IUniversalAdapterEscrow.CallLimitExceeded.selector);
        adapter.executeStrategy(STRATEGY_1, calls);

        // Another transfer within per-call limit - should succeed (no daily limit blocking)
        calls[0].data = abi.encodeWithSignature("transfer(address,uint256)", recipient, 4e6);

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed
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

        bytes memory data = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));

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
        adapter.executePreConfigured(STRATEGY_1);
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
        valuer.setValue(address(adapter), 5000e6);
        assertEq(adapter.realAssets(), 5000e6);
    }

    /* RECEIVE ETH TEST */

    function testReceiveETH() public {
        vm.deal(address(this), 1 ether);
        (bool success,) = address(adapter).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(adapter).balance, 1 ether);
    }

    /* L-14 FIX TESTS */

    function testForceDeallocateValidation() public {
        // Setup strategy and allocation
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        // Allocate some assets
        bytes memory allocData = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));
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

        bytes memory data = abi.encode(STRATEGY_1, calls);

        // Test that normal deallocate works (using regular deallocate selector)
        vm.prank(address(vault));
        bytes4 normalDeallocateSelector = 0xda3485c6; // deallocate(address,bytes,uint256)
        adapter.deallocate(data, 50e6, normalDeallocateSelector, address(this));

        // Re-allocate for next test
        bytes memory reallocData = abi.encode(STRATEGY_1, 50e6, false, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 50e6);
        asset.transfer(address(adapter), 50e6);
        vm.prank(address(vault));
        adapter.allocate(reallocData, 50e6, bytes4(0), address(0));

        // Test that forceDeallocate with whitelisted operations works
        vm.prank(address(vault));
        bytes4 forceDeallocateSelector = 0x47def04c; // forceDeallocate(address,bytes,uint256,address)
        adapter.deallocate(data, 50e6, forceDeallocateSelector, address(this));
    }

    function testForceDeallocateRejectsETHTransfers() public {
        // Setup strategy and allocation
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Whitelist the transfer function first so we reach the ETH transfer check
        vm.prank(owner);
        adapter.updateWhitelist(address(asset), bytes4(0xa9059cbb), true, 0); // transfer

        // Create call with ETH transfer (should be rejected for forceDeallocate)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSelector(0xa9059cbb, address(vault), 50e6),
            value: 1 ether // ETH transfer
        });

        bytes memory data = abi.encode(STRATEGY_1, calls);
        bytes4 forceDeallocateSelector = 0x47def04c;

        // Should revert because ETH transfers are not allowed in forceDeallocate
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.InvalidAmount.selector);
        adapter.deallocate(data, 50e6, forceDeallocateSelector, address(this));
    }

    function testForceDeallocateRejectsNonWhitelistedFunctions() public {
        // Setup strategy and allocation
        vm.prank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 1000e6);

        bytes memory allocData = abi.encode(STRATEGY_1, 100e6, false, new IUniversalAdapterEscrow.Call[](0));
        asset.mint(address(this), 100e6);
        asset.transfer(address(adapter), 100e6);
        vm.prank(address(vault));
        adapter.allocate(allocData, 100e6, bytes4(0), address(0));

        // Create call with non-whitelisted function
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSelector(0x12345678, address(vault), 50e6), // random non-whitelisted function
            value: 0
        });

        bytes memory data = abi.encode(STRATEGY_1, calls);
        bytes4 forceDeallocateSelector = 0x47def04c;

        // Should revert because function is not whitelisted
        vm.prank(address(vault));
        vm.expectRevert(IUniversalAdapterEscrow.FunctionNotWhitelisted.selector);
        adapter.deallocate(data, 50e6, forceDeallocateSelector, address(this));
    }

    /* L-16 FIX TESTS */

    function testL16DailyLimitLogicRemoved() public {
        // L-16 Fix: Verify that daily limit logic has been completely removed
        // Operations that would have been blocked by daily limits should now succeed

        vm.startPrank(owner);
        adapter.setStrategy(STRATEGY_1, agent, "", 10e6); // Daily limit parameter ignored
        adapter.updateWhitelist(address(asset), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        adapter.updateWhitelist(address(rewardToken), bytes4(keccak256("transfer(address,uint256)")), true, 0);
        vm.stopPrank();

        // Fund adapter
        asset.mint(address(adapter), 100e6);
        rewardToken.mint(address(adapter), 100e18);

        // Large transfers that would have exceeded daily limits should all succeed
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);

        // Transfer large amount of vault asset
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 50e6),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed

        // Transfer large amount of reward token
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(rewardToken),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 80e18),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategy(STRATEGY_1, calls); // Should succeed

        // Transfer more vault asset (total would be 60e6, far exceeding old 10e6 daily limit)
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("transfer(address,uint256)", recipient, 30e6),
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
        bytes memory allocateData = abi.encode(STRATEGY_1, assetAmount, false, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.allocate(allocateData, assetAmount, bytes4(0), address(0));

        // L-13 FIX: All assets are tracked and available for strategy use
        assertEq(adapter.getAllocation(STRATEGY_1), assetAmount, "Full asset amount should be tracked");
        assertEq(int256(assetAmount), change, "Change should equal full asset amount");
        assertEq(ids[0], STRATEGY_1, "Strategy ID should be returned");

        // Assets remain in adapter but are allocated to strategy (available for use)
        assertEq(adapter.getIdleAssets(), assetAmount, "Assets remain available for strategy execution");

        // The key difference from old architecture: assets are tracked and available, not lost
        assertTrue(adapter.getAllocation(STRATEGY_1) > 0, "Assets are allocated and tracked for strategy use");
    }

    function testL13IdleAssetVisibility() public {
        // L-13 FIX: Test visibility into idle assets

        // Initially no idle assets
        assertEq(adapter.getIdleAssets(), 0, "Should start with no idle assets");

        // Transfer some assets directly to adapter (simulating edge case)
        uint256 idleAmount = 100e6;
        asset.mint(address(adapter), idleAmount);

        // Should be visible through getIdleAssets
        assertEq(adapter.getIdleAssets(), idleAmount, "Idle assets should be visible");

        // Should be included in realAssets
        uint256 totalAssets = adapter.realAssets();
        assertGe(totalAssets, idleAmount, "Real assets should include idle assets");
    }
}