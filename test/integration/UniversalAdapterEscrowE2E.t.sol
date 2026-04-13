// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {UniversalAdapterEscrowFactory} from "../../src/adapters/UniversalAdapterEscrowFactory.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockVaultV2} from "../mocks/MockVaultV2.sol";
import {MockValuer} from "../mocks/MockValuer.sol";
import {MockTarget} from "../mocks/MockTarget.sol";

/// @title UniversalAdapterEscrowE2E
/// @notice End-to-end integration tests for the UniversalAdapterEscrow
/// @dev Tests complete flows from VaultV2 → UniversalAdapterEscrow → Protocol
contract UniversalAdapterEscrowE2E is Test {
    UniversalAdapterEscrow adapter;
    UniversalAdapterEscrowFactory factory;
    MockVaultV2 vault;
    MockERC20 asset;
    MockERC20 rewardToken;
    MockValuer valuer;
    MockTarget defiProtocol;

    address owner = address(0x1);
    address agent = address(0x2);
    address user = address(0x3);

    bytes32 constant LENDING_STRATEGY = keccak256("LENDING_STRATEGY");
    bytes32 constant YIELD_STRATEGY = keccak256("YIELD_STRATEGY");

    function setUp() public {
        // Deploy infrastructure
        asset = new MockERC20("USDC", "USDC", 6);
        rewardToken = new MockERC20("REWARD", "RWD", 18);
        valuer = new MockValuer();
        defiProtocol = new MockTarget(address(asset)); // Pass asset address to MockTarget

        // Deploy vault
        vault = new MockVaultV2(address(asset), owner);

        // Deploy factory and adapter (must be called by vault owner)
        factory = new UniversalAdapterEscrowFactory();
        vm.startPrank(owner);
        adapter = UniversalAdapterEscrow(
            payable(factory.deployAdapter(address(vault), address(valuer), false, keccak256("production")))
        );

        // Setup vault
        vault.addAdapter(address(adapter));
        vm.stopPrank();

        // Fund users
        asset.mint(user, 10000e6);
        asset.mint(address(vault), 100000e6);

        // Labels
        vm.label(address(adapter), "UniversalAdapterEscrow");
        vm.label(address(vault), "VaultV2");
        vm.label(address(defiProtocol), "DeFiProtocol");
        vm.label(owner, "Owner");
        vm.label(agent, "Agent");
        vm.label(user, "User");
    }

    function testCompleteAllocationFlow() public {
        // Debug: Check parentVault
        assertEq(adapter.parentVault(), address(vault), "Parent vault mismatch");

        // 1. Setup strategy
        vm.startPrank(owner);
        adapter.setStrategy(LENDING_STRATEGY, agent, "", 10000e6);

        // Whitelist protocol functions
        adapter.updateWhitelist(address(defiProtocol), bytes4(keccak256("deposit(uint256)")), true, 5000e6);
        adapter.updateWhitelist(address(asset), bytes4(keccak256("approve(address,uint256)")), true, 10000e6);
        vm.stopPrank();

        // 2. Vault allocates to adapter
        bytes memory allocData = abi.encode(LENDING_STRATEGY, 0, new IUniversalAdapterEscrow.Call[](0));

        asset.mint(address(vault), 1000e6);
        vm.startPrank(address(vault));
        asset.transfer(address(adapter), 1000e6);
        (bytes32[] memory ids, int256 change) = adapter.allocate(allocData, 1000e6, bytes4(0), address(0));
        vm.stopPrank();

        assertEq(ids[0], LENDING_STRATEGY);
        assertEq(change, int256(1000e6));
        assertEq(adapter.getAllocation(LENDING_STRATEGY), 1000e6);

        // 3. Agent deposits into protocol
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("approve(address,uint256)", address(defiProtocol), 1000e6),
            value: 0
        });
        calls[1] = IUniversalAdapterEscrow.Call({
            target: address(defiProtocol),
            data: abi.encodeWithSignature("deposit(uint256)", 1000e6),
            value: 0
        });

        // Simulate asset transfer for deposit
        asset.mint(address(adapter), 1000e6);

        vm.prank(agent);
        // Use bypassCircuitBreaker for deposits >10% of balance (expected behavior)
        adapter.executeStrategyBypassCircuitBreaker(LENDING_STRATEGY, calls);

        // Verify deposit
        assertEq(defiProtocol.balances(address(adapter)), 1000e6);
    }

    function testCompleteDeallocationFlow() public {
        // Setup and allocate first
        testCompleteAllocationFlow();

        // Add withdraw whitelist
        vm.prank(owner);
        adapter.updateWhitelist(address(defiProtocol), bytes4(keccak256("withdraw(uint256)")), true, 10000e6);

        // Create withdrawal calls
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(defiProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 1000e6),
            value: 0
        });

        // Simulate protocol returning funds to test balance-first logic
        asset.mint(address(adapter), 1000e6);

        // Deallocate - should use adapter balance first without protocol withdrawal
        bytes memory deallocData = abi.encode(LENDING_STRATEGY, 0, withdrawCalls);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocData, 1000e6, bytes4(0), address(0));

        assertEq(ids[0], LENDING_STRATEGY);
        assertEq(change, -int256(1000e6));
        assertEq(adapter.getAllocation(LENDING_STRATEGY), 0);

        // Protocol balance should remain unchanged since we used adapter balance first
        // This demonstrates the new smart balance-first deallocation working correctly
        assertEq(defiProtocol.balances(address(adapter)), 1000e6);
    }

    function testDeallocationWithProtocolWithdrawal() public {
        // Setup and allocate first
        testCompleteAllocationFlow();

        // Add withdraw whitelist
        vm.prank(owner);
        adapter.updateWhitelist(address(defiProtocol), bytes4(keccak256("withdraw(uint256)")), true, 10000e6);

        // Check current adapter balance after testCompleteAllocationFlow
        uint256 currentBalance = asset.balanceOf(address(adapter));

        // Remove most adapter balance to force protocol withdrawal, leaving just 100e6
        if (currentBalance > 100e6) {
            vm.prank(address(adapter));
            asset.transfer(address(0x123), currentBalance - 100e6);
        }

        // Verify limited adapter balance
        assertEq(asset.balanceOf(address(adapter)), 100e6);

        // LAZY DEALLOCATION: Agent withdraws from protocol FIRST
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(defiProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 900e6), // Withdraw what's needed (1000 - 100)
            value: 0
        });

        vm.prank(agent);
        adapter.withdrawFromStrategy(LENDING_STRATEGY, withdrawCalls, 900e6);

        // Verify agent withdrawal succeeded
        assertEq(
            asset.balanceOf(address(adapter)), 1000e6, "Adapter should have 100 + 900 = 1000 after agent withdrawal"
        );
        assertEq(defiProtocol.balances(address(adapter)), 100e6, "Protocol should have 1000 - 900 = 100 remaining");

        // User deallocates (calls ignored in lazy deallocation)
        bytes memory deallocData = abi.encode(LENDING_STRATEGY, 0, new IUniversalAdapterEscrow.Call[](0));

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocData, 1000e6, bytes4(0), address(0));

        assertEq(ids[0], LENDING_STRATEGY);
        assertEq(change, -int256(1000e6), "Should deallocate full 1000e6");
        assertEq(adapter.getAllocation(LENDING_STRATEGY), 0, "Allocation should be 0 after full deallocation");

        // Protocol balance should remain at 100e6 (unchanged by user deallocate)
        assertEq(defiProtocol.balances(address(adapter)), 100e6, "Protocol balance unchanged by user deallocate");
    }

    function testMultiStrategyManagement() public {
        // Setup multiple strategies
        vm.startPrank(owner);
        adapter.setStrategy(LENDING_STRATEGY, agent, "", 5000e6);
        adapter.setStrategy(YIELD_STRATEGY, agent, "", 5000e6);

        // Whitelist for both strategies
        adapter.updateWhitelist(address(defiProtocol), bytes4(0), true, 10000e6); // Allow all functions
        adapter.updateWhitelist(address(asset), bytes4(0), true, 10000e6);
        vm.stopPrank();

        // Allocate to first strategy
        bytes memory allocData1 = abi.encode(LENDING_STRATEGY, 0, new IUniversalAdapterEscrow.Call[](0));

        asset.mint(address(vault), 3000e6);
        vm.startPrank(address(vault));
        asset.transfer(address(adapter), 3000e6);
        adapter.allocate(allocData1, 3000e6, bytes4(0), address(0));
        vm.stopPrank();

        // Allocate to second strategy
        bytes memory allocData2 = abi.encode(YIELD_STRATEGY, 0, new IUniversalAdapterEscrow.Call[](0));

        asset.mint(address(vault), 2000e6);
        vm.startPrank(address(vault));
        asset.transfer(address(adapter), 2000e6);
        adapter.allocate(allocData2, 2000e6, bytes4(0), address(0));
        vm.stopPrank();

        // Verify allocations
        assertEq(adapter.getAllocation(LENDING_STRATEGY), 3000e6);
        assertEq(adapter.getAllocation(YIELD_STRATEGY), 2000e6);

        bytes32[] memory active = adapter.getActiveStrategies();
        assertEq(active.length, 2);
    }

    function testAllocateWithImmediateExecution() public {
        // Setup
        vm.startPrank(owner);
        adapter.setStrategy(LENDING_STRATEGY, agent, "", 10000e6);
        adapter.updateWhitelist(address(asset), bytes4(0), true, 10000e6);
        adapter.updateWhitelist(address(defiProtocol), bytes4(0), true, 10000e6);
        vm.stopPrank();

        // Allocate first without automation
        bytes memory allocData = abi.encode(LENDING_STRATEGY, 0, new IUniversalAdapterEscrow.Call[](0));

        // Fund adapter
        asset.mint(address(adapter), 1000e6);
        asset.mint(address(vault), 1000e6);

        vm.startPrank(address(vault));
        asset.transfer(address(adapter), 1000e6);
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));
        vm.stopPrank();

        // Verify allocation
        assertEq(adapter.getAllocation(LENDING_STRATEGY), 1000e6);

        // Now execute strategy calls separately with circuit breaker bypass (for deposits >10%)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("approve(address,uint256)", address(defiProtocol), 1000e6),
            value: 0
        });
        calls[1] = IUniversalAdapterEscrow.Call({
            target: address(defiProtocol),
            data: abi.encodeWithSignature("deposit(uint256)", 1000e6),
            value: 0
        });

        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(LENDING_STRATEGY, calls);

        // Verify deposit happened
        assertEq(defiProtocol.balances(address(adapter)), 1000e6);
    }

    function testSweepRewards() public {
        // Simulate rewards accumulation
        rewardToken.mint(address(adapter), 1000e18);

        // Sweep rewards to user
        vm.prank(owner);
        adapter.sweep(address(rewardToken), user);

        assertEq(rewardToken.balanceOf(user), 1000e18);
        assertEq(rewardToken.balanceOf(address(adapter)), 0);
    }

    function testEmergencyPauseScenario() public {
        // Setup strategy
        vm.startPrank(owner);
        adapter.setStrategy(LENDING_STRATEGY, agent, "", 10000e6);
        vm.stopPrank();

        // Normal allocation
        bytes memory allocData = abi.encode(LENDING_STRATEGY, 0, new IUniversalAdapterEscrow.Call[](0));

        asset.mint(address(vault), 1000e6);
        vm.startPrank(address(vault));
        asset.transfer(address(adapter), 1000e6);
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));
        vm.stopPrank();

        // Emergency pause
        vm.prank(owner);
        adapter.setPaused(true);

        // Try to allocate more - should fail
        asset.mint(address(vault), 1000e6);
        vm.startPrank(address(vault));
        asset.transfer(address(adapter), 1000e6);
        vm.expectRevert(IUniversalAdapterEscrow.ContractPaused.selector);
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));
        vm.stopPrank();

        // Unpause
        vm.prank(owner);
        adapter.setPaused(false);

        // Should work again
        vm.prank(address(vault));
        adapter.allocate(allocData, 1000e6, bytes4(0), address(0));
    }

    function testRealAssetsValuation() public {
        // Set valuation
        valuer.setValue(address(adapter), 10000e6);

        // Check real assets
        uint256 realAssets = adapter.realAssets();
        assertEq(realAssets, 10000e6);
    }

    function testFactoryAddressComputation() public {
        // Compute expected address
        address computed = factory.computeAddress(address(vault), address(valuer), false, keccak256("test-deployment"));

        // Deploy with same parameters (must be called by vault owner)
        vm.prank(owner);
        address deployed = factory.deployAdapter(address(vault), address(valuer), false, keccak256("test-deployment"));

        // Should match
        assertEq(computed, deployed);
    }
}
