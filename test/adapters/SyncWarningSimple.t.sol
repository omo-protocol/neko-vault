// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";
import "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import "../mocks/MockERC20.sol";
import "../mocks/MockValuer.sol";
import "../mocks/MockVaultV2.sol";
import "../mocks/MockProtocol.sol";

/// @title SyncWarningSimpleTest
/// @notice Simple test for Solution 3: Warning-only valuer check
contract SyncWarningSimpleTest is Test {
    UniversalAdapterEscrow adapter;
    MockVaultV2 vault;
    MockERC20 asset;
    MockValuer valuer;
    MockProtocol protocol;
    
    address owner = address(this);
    address agent = address(0x3);
    
    bytes32 strategyId = keccak256("TEST_STRATEGY");
    
    event SyncDeviationWarning(uint256 newMinKnown, uint256 valuerValue, uint256 deviation, uint256 deviationBps);
    
    function setUp() public {
        asset = new MockERC20("Test", "TEST", 6);
        valuer = new MockValuer();
        vault = new MockVaultV2(address(asset), owner);
        protocol = new MockProtocol(address(asset));
        
        adapter = new UniversalAdapterEscrow(address(vault), address(valuer), true);
        vault.addAdapter(address(adapter));
        adapter.setStrategy(strategyId, agent, "", 0);
        
        // Whitelist protocol
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("deposit(uint256)")), true, type(uint256).max);
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("withdraw(uint256)")), true, type(uint256).max);
        adapter.updateWhitelist(address(asset), bytes4(keccak256("approve(address,uint256)")), true, type(uint256).max);
    }
    
    /// @notice Test: Large deviation emits warning but doesn't block
    function test_LargeDeviation_WarningOnly() public {
        // Step 1: Create real external deposits by allocating and depositing to protocol
        asset.mint(address(adapter), 1000e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(strategyId, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            1000e6,
            bytes4(0),
            address(0)
        );
        
        // Deposit 900e6 to protocol (leaving 100e6 idle)
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](2);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("approve(address,uint256)", address(protocol), 900e6),
            value: 0
        });
        depositCalls[1] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 900e6),
            value: 0
        });
        
        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, depositCalls);
        
        // externalDeposits should be ~900e6 after deposit
        uint256 currentExternal = adapter.externalDeposits(strategyId);
        assertGt(currentExternal, 800e6, "Should have external deposits");
        
        // Step 2: Simulate market crash - want to sync down to 300e6
        // newMinKnown = balance(100e6) + newExternal(300e6) = 400e6
        // valuerValue = 200e6 (very stale/broken)
        // minExpected = 400e6 * 80% = 320e6
        // 200e6 < 320e6 ❌ Large deviation!
        
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));
        valuer.setValue(totalId, 200e6); // Broken/stale valuer
        
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = strategyId;
        uint256[] memory values = new uint256[](1);
        values[0] = 300e6; // Accurate value from manual queries
        
        // OLD BEHAVIOR: Would revert with "New value too low vs valuer"
        // NEW BEHAVIOR: Emits warning but succeeds
        
        vm.expectEmit(false, false, false, false); // Event will be emitted
        emit SyncDeviationWarning(0, 0, 0, 0);
        
        // Should NOT revert
        adapter.syncExternalDepositsPerStrategy(ids, values);
        
        // Verify sync succeeded
        assertEq(adapter.externalDeposits(strategyId), 300e6, "Sync should succeed despite large deviation");
    }
    
    /// @notice Test: Small deviation - no warning, succeeds
    function test_SmallDeviation_NoWarning() public {
        // Setup
        asset.mint(address(adapter), 1000e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(strategyId, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            1000e6,
            bytes4(0),
            address(0)
        );
        
        // Deposit to protocol
        IUniversalAdapterEscrow.Call[] memory depositCalls = new IUniversalAdapterEscrow.Call[](2);
        depositCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(asset),
            data: abi.encodeWithSignature("approve(address,uint256)", address(protocol), 900e6),
            value: 0
        });
        depositCalls[1] = IUniversalAdapterEscrow.Call({
            target: address(protocol),
            data: abi.encodeWithSignature("deposit(uint256)", 900e6),
            value: 0
        });
        
        vm.prank(agent);
        adapter.executeStrategyBypassCircuitBreaker(strategyId, depositCalls);
        
        // Sync with small deviation
        // newMinKnown = 100e6 + 800e6 = 900e6
        // valuerValue = 850e6
        // minExpected = 900e6 * 80% = 720e6
        // 850e6 >= 720e6 ✅ No warning
        
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(adapter)));
        valuer.setValue(totalId, 850e6);
        
        bytes32[] memory ids = new bytes32[](1);
        ids[0] = strategyId;
        uint256[] memory values = new uint256[](1);
        values[0] = 800e6;
        
        // Should succeed without warning
        vm.recordLogs();
        adapter.syncExternalDepositsPerStrategy(ids, values);
        
        // Check no warning was emitted
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool foundWarning = false;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("SyncDeviationWarning(uint256,uint256,uint256,uint256)")) {
                foundWarning = true;
            }
        }
        
        assertFalse(foundWarning, "Should not emit warning for small deviation");
        assertEq(adapter.externalDeposits(strategyId), 800e6, "Sync should succeed");
    }
}
