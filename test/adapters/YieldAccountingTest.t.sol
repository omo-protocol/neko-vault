// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";
import "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockValuer.sol";
import "../mocks/MockVaultV2.sol";
import "../mocks/MockProtocol.sol";

/// @title YieldAccountingTest
/// @notice Tests for yield accounting fix (valuer-based synchronization)
contract YieldAccountingTest is Test {
    UniversalAdapterEscrow adapter;
    MockVaultV2 vault;
    MockERC20 asset;
    MockValuer valuer;
    MockProtocol protocol;
    
    address owner = address(this);
    address agent = address(0x3);
    
    bytes32 strategyId = keccak256("TEST_STRATEGY");
    
    event ExternalDepositsValuerSynced(bytes32 indexed strategyId, uint256 oldValue, uint256 newValue, int256 delta);
    event UnexpectedValueChange(bytes32 indexed strategyId, uint256 expected, uint256 actual, uint256 withdrawn, string reason);
    
    function setUp() public {
        asset = new MockERC20("Test", "TEST", 18);
        valuer = new MockValuer();
        vault = new MockVaultV2(address(asset), owner);
        protocol = new MockProtocol(address(asset));
        
        adapter = new UniversalAdapterEscrow(address(vault), address(valuer), true);
        vault.addAdapter(address(adapter));
        adapter.setStrategy(strategyId, agent, "", 0);
        
        // Whitelist protocol functions
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("deposit(uint256)")), true, type(uint256).max);
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("withdraw(uint256)")), true, type(uint256).max);
        adapter.updateWhitelist(address(asset), bytes4(keccak256("approve(address,uint256)")), true, type(uint256).max);
        
        // Give adapter large balance - we'll burn before deallocate to force protocol withdrawal
        // This avoids circuit breaker issues during setup
        asset.mint(address(adapter), 20000e18);
    }
    
    /// @notice Helper: Allocate and deposit to protocol
    function _allocateAndDeposit(bytes32 _strategyId, uint256 amount) internal {
        // Allocate
        vm.prank(address(vault));
        adapter.allocate(abi.encode(_strategyId, amount, false, new IUniversalAdapterEscrow.Call[](0)), amount, bytes4(0), address(0));
        
        // Execute deposit to protocol
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](2);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("approve(address,uint256)", address(protocol), amount),
            value: 0
        });
        calls[1] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", amount),
            value: 0
        });
        
        vm.prank(agent);
        adapter.executeStrategy(_strategyId, calls);
    }
    
    /// @notice Test 1: Ghost funds prevented
    function testGhostFundsPrevention() public {
        _allocateAndDeposit(strategyId, 1000e18);
        assertEq(adapter.externalDeposits(strategyId), 1000e18);
        
        // Yield accrues to 1200 (protocol now has 1200 worth of assets)
        valuer.setValue(strategyId, 1200e18);
        
        // Simulate protocol having extra yield by minting to it
        asset.mint(address(protocol), 200e18);
        
        // Burn most idle balance to force protocol withdrawal
        // Keep small amount to avoid triggering circuit breaker (10% of total)
        uint256 adapterBalance = asset.balanceOf(address(adapter));
        asset.burn(address(adapter), adapterBalance - 50e18);
        
        // Withdraw 500 - must come from protocol
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 450e18),
            value: 0
        });
        
        // After withdrawal, protocol has 1200 - 450 = 750 remaining
        valuer.setValue(strategyId, 750e18);
        
        vm.prank(address(vault));
        adapter.deallocate(abi.encode(strategyId, 0, false, withdrawCalls), 500e18, bytes4(0), address(0));
        
        // With fix: syncs to 750 (actual remaining)
        // Without fix: would be 550 (1000 - 450), creating 200 ghost tokens
        assertEq(adapter.externalDeposits(strategyId), 750e18, "Should sync to actual value");
    }
    
    /// @notice Test 2: Yield tracking
    function testYieldTracking() public {
        _allocateAndDeposit(strategyId, 1000e18);
        
        // Yield accrues to 1200
        valuer.setValue(strategyId, 1200e18);
        asset.mint(address(protocol), 200e18);
        
        // Burn idle to force protocol withdrawal
        uint256 adapterBalance = asset.balanceOf(address(adapter));
        asset.burn(address(adapter), adapterBalance - 10e18);
        
        // Withdraw 100 - must come from protocol
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 90e18),
            value: 0
        });
        
        valuer.setValue(strategyId, 1110e18); // 1200 - 90
        
        vm.prank(address(vault));
        adapter.deallocate(abi.encode(strategyId, 0, false, calls), 100e18, bytes4(0), address(0));
        
        assertEq(adapter.externalDeposits(strategyId), 1110e18, "Should include yield");
    }
    
    /// @notice Test 3: Conservative fallback without valuer
    function testConservativeFallback() public {
        // Deploy adapter without valuer
        UniversalAdapterEscrow noValuerAdapter = new UniversalAdapterEscrow(address(vault), address(0), false);
        vault.addAdapter(address(noValuerAdapter));
        bytes32 sid = keccak256("NO_VALUER");
        noValuerAdapter.setStrategy(sid, agent, "", 0);
        noValuerAdapter.updateWhitelist(address(protocol), bytes4(keccak256("deposit(uint256)")), true, type(uint256).max);
        noValuerAdapter.updateWhitelist(address(protocol), bytes4(keccak256("withdraw(uint256)")), true, type(uint256).max);
        noValuerAdapter.updateWhitelist(address(asset), bytes4(keccak256("approve(address,uint256)")), true, type(uint256).max);
        
        // Large initial balance
        asset.mint(address(noValuerAdapter), 2000e18);
        
        // Allocate and deposit
        vm.prank(address(vault));
        noValuerAdapter.allocate(abi.encode(sid, 0, false, new IUniversalAdapterEscrow.Call[](0)), 1000e18, bytes4(0), address(0));
        
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](2);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("approve(address,uint256)", address(protocol), 1000e18),
            value: 0
        });
        depositCalls[1] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 1000e18),
            value: 0
        });
        
        vm.prank(agent);
        noValuerAdapter.executeStrategyBypassCircuitBreaker(sid, depositCalls);
        
        // Burn idle to force protocol withdrawal
        uint256 adapterBalance = asset.balanceOf(address(noValuerAdapter));
        asset.burn(address(noValuerAdapter), adapterBalance - 50e18);
        
        // Withdraw 500 - forces protocol withdrawal
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 450e18),
            value: 0
        });
        
        vm.prank(address(vault));
        noValuerAdapter.deallocate(abi.encode(sid, 0, false, withdrawCalls), 500e18, bytes4(0), address(0));
        
        // Uses conservative fallback: 1000 - 450 = 550
        assertEq(noValuerAdapter.externalDeposits(sid), 550e18, "Conservative fallback");
    }
    
    /// @notice Test 4: Sync event emission
    function testSyncEvent() public {
        _allocateAndDeposit(strategyId, 1000e18);
        
        // Set valuer to 800 (loss scenario)
        valuer.setValue(strategyId, 800e18);
        
        // Burn idle to force protocol withdrawal
        uint256 adapterBalance = asset.balanceOf(address(adapter));
        asset.burn(address(adapter), adapterBalance - 10e18);
        
        // Withdraw from protocol
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 90e18),
            value: 0
        });
        
        // Expect sync event: 1000 -> 800, delta = -200e18
        vm.expectEmit(true, false, false, true);
        emit ExternalDepositsValuerSynced(strategyId, 1000e18, 800e18, -200e18);
        
        vm.prank(address(vault));
        adapter.deallocate(abi.encode(strategyId, 0, false, calls), 100e18, bytes4(0), address(0));
        
        assertEq(adapter.externalDeposits(strategyId), 800e18);
    }
    
    /// @notice Test 5: Complete withdrawal with yield
    function testCompleteWithdrawal() public {
        _allocateAndDeposit(strategyId, 1000e18);
        
        // Yield accrues to 1500 (50% gain)
        // Simulate yield by minting to protocol and crediting adapter's balance
        valuer.setValue(strategyId, 1500e18);
        asset.mint(address(protocol), 500e18);
        // Manually credit adapter's protocol balance to simulate yield
        // In real protocols, this happens automatically
        vm.store(
            address(protocol),
            keccak256(abi.encode(address(adapter), 1)), // balances mapping slot
            bytes32(uint256(1500e18))
        );
        
        // Burn idle to force protocol withdrawal
        uint256 adapterBalance = asset.balanceOf(address(adapter));
        asset.burn(address(adapter), adapterBalance - 100e18);
        
        // Withdraw everything from protocol
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 1400e18),
            value: 0
        });
        
        valuer.setValue(strategyId, 0);
        
        vm.prank(address(vault));
        adapter.deallocate(abi.encode(strategyId, 0, false, calls), 1500e18, bytes4(0), address(0));
        
        // Should be completely withdrawn
        assertEq(adapter.externalDeposits(strategyId), 0, "Complete withdrawal");
        assertEq(adapter.totalExternalDeposits(), 0, "Total also zero");
    }
}
