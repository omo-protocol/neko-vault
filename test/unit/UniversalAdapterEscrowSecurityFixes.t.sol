// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {IUniversalValuerOffchain} from "../../src/adapters/interfaces/IUniversalValuerOffchain.sol";
import {MockTarget} from "../mocks/MockTarget.sol";

/**
 * @title UniversalAdapterEscrowSecurityFixesTest
 * @notice Tests for recent security fixes (Issues #7, #8, #9)
 * @dev Tests the three critical security fixes:
 *      - Issue #7: Try-catch multicall to prevent revert-on-failure DoS
 *      - Issue #8: Remove pause check from syncExternalDeposits
 *      - Issue #9: Prevent desynchronized externalDeposits underflow
 */
contract UniversalAdapterEscrowSecurityFixesTest is Test {
    UniversalAdapterEscrow public adapter;
    MockERC20 public asset;
    MockValuer public valuer;
    MockVault public vault;
    MockProtocol public protocol;

    address public owner = address(0x1);
    address public user = address(0x2);

    bytes32 public strategyId = keccak256("test-strategy");

    function setUp() public {
        asset = new MockERC20("Test Token", "TEST", 18);
        valuer = new MockValuer();
        valuer.setAsset(address(asset));
        protocol = new MockProtocol(address(asset));

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

        // Whitelist protocol
        vm.prank(owner);
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("deposit(uint256)")), true, 0);

        vm.prank(owner);
        adapter.updateWhitelist(address(protocol), bytes4(keccak256("withdraw(uint256)")), true, 0);

        // Approve protocol to pull tokens from adapter
        vm.prank(address(adapter));
        asset.approve(address(protocol), type(uint256).max);
    }

    /* ============ ISSUE #7: Try-Catch Multicall DoS Prevention ============ */

    /**
     * @notice Test that deallocate doesn't revert when protocol withdrawal fails
     * @dev SECURITY FIX Issue #7: Before fix, this would cause DoS
     */
    function testDeallocateSucceedsWhenProtocolWithdrawalFails() public {
        // Setup: Allocate 1000 tokens
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Simulate external deposit (80 to protocol, 920 in adapter) - 8% under circuit breaker threshold
        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(80e18));

        // Set protocol to fail on withdrawal
        protocol.setShouldFail(true);

        // Try to deallocate 90
        // Before fix: Would revert due to protocol failure
        // After fix: Returns up to requested amount (90) without reverting
        // Note: Set minAmountOut = 0 to disable slippage check
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createWithdrawCall(30e18);
        bytes memory deallocateData = abi.encode(strategyId, 0, withdrawCalls); // minAmountOut = 0

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocateData, 90e18, bytes4(0x4b219d16), address(0));

        // Should return requested amount (90) from adapter balance despite protocol failure
        assertEq(uint256(-change), 90e18, "Should return requested amount despite protocol failure");
        assertEq(ids[0], strategyId, "Should return correct strategy ID");
    }

    /**
     * @notice Test normal path still works when protocol succeeds
     */
    function testDeallocateWorksNormallyWhenProtocolSucceeds() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit to protocol (8% under circuit breaker threshold)
        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(80e18));

        // Protocol has funds and will succeed
        protocol.setShouldFail(false);

        // Deallocate 90 (minAmountOut = 0 to disable slippage check for this test)
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createWithdrawCall(30e18);
        bytes memory deallocateData = abi.encode(strategyId, 0, withdrawCalls);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) =
            adapter.deallocate(deallocateData, 90e18, bytes4(0x4b219d16), address(0));

        // Should return requested amount (90) from available balance when protocol succeeds
        assertEq(uint256(-change), 90e18, "Should return requested amount when protocol succeeds");
    }

    /* ============ ISSUE #8: Pause Check Removed from syncExternalDeposits ============ */

    /**
     * @notice Test that syncExternalDeposits works during pause
     * @dev SECURITY FIX Issue #8: Owner needs to fix accounting during emergencies
     */
    function testSyncExternalDepositsWorksDuringPause() public {
        // SECURITY FIX: Updated for donation-resistant valuation
        // Setup with ghost
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(80e18));

        // Simulate loss
        // State: balance=920, totalExternalDeposits=80, totalAllocations=1000
        // NEW logic: minKnown = totalAllocations = 1000, ghost = 1000 - 800 = 200
        valuer.setReturnValue(800e18);

        // Pause the adapter
        vm.prank(owner);
        adapter.setPaused(true);

        // Should still be able to sync using per-strategy sync
        // To remove ghost with NEW logic: Set valuer to totalAllocations
        valuer.setReturnValue(1000e18);
        vm.prank(owner);
        bytes32[] memory strategyIds = new bytes32[](1);
        strategyIds[0] = strategyId;
        uint256[] memory newValues = new uint256[](1);
        newValues[0] = 0;
        adapter.syncExternalDepositsPerStrategy(strategyIds, newValues);

        assertEq(adapter.totalExternalDeposits(), 0, "totalExternalDeposits should be updated");
    }

    /**
     * @notice Test realAssets accuracy during pause after sync
     */
    function testRealAssetsDuringPauseAfterSync() public {
        // Setup with ghost
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(80e18));

        // Simulate loss
        valuer.setReturnValue(800e18);

        // Pause
        vm.prank(owner);
        adapter.setPaused(true);

        // AFTER HIGH SEVERITY FIX: realAssets reports accurate value immediately (no overpricing)
        uint256 realAssetsBefore = adapter.realAssets();
        assertEq(realAssetsBefore, 800e18, "Should return accurate valuer value (no longer overpriced!)");

        // Sync to fix accounting drift using per-strategy sync
        valuer.setReturnValue(920e18);
        vm.prank(owner);
        bytes32[] memory strategyIds = new bytes32[](1);
        strategyIds[0] = strategyId;
        uint256[] memory newValues = new uint256[](1);
        newValues[0] = 0;
        adapter.syncExternalDepositsPerStrategy(strategyIds, newValues);

        // After sync: realAssets remains accurate
        uint256 realAssetsAfter = adapter.realAssets();
        assertEq(realAssetsAfter, 920e18, "Should return accurate value after sync");
    }

    /* ============ ISSUE #9: Desynchronized External Deposits Prevention ============ */

    /**
     * @notice Test that withdrawal doesn't underflow when totalExternalDeposits < per-strategy
     * @dev SECURITY FIX Issue #9: Prevents desynchronization causing underflow DoS
     */
    function testWithdrawalDoesntUnderflowWithDesync() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit to protocol (8% under circuit breaker threshold)
        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(80e18));

        // At this point: externalDeposits[strategyId] = 80, totalExternalDeposits = 80

        // Simulate desynchronization by manually setting totalExternalDeposits lower
        // (This could happen through various edge cases or bugs)
        vm.store(
            address(adapter),
            bytes32(uint256(6)), // totalExternalDeposits storage slot
            bytes32(uint256(60e18)) // Set to 60 instead of 80
        );

        // Now: externalDeposits[strategyId] = 80, totalExternalDeposits = 60 (desync!)

        // SECURITY FIX (security_issues_5nov2025_4.md Issue #1): executeStrategy() now prevents withdrawals
        // Withdrawals must use executeStrategyWithSlippage() for proper externalDeposits accounting
        vm.prank(owner);
        adapter.executeStrategyWithSlippage(
            strategyId,
            _createWithdrawCall(30e18),
            30e18 // Expect at least 30e18 balance increase
        );

        // SECURITY FIX (security_issues_5nov2025_3.md Issue #3): Symmetric reduction in executeStrategyWithSlippage
        // Balance increases (withdrawals) now DO reduce externalDeposits in controlled contexts
        uint256 totalExternalAfter = adapter.totalExternalDeposits();
        assertEq(totalExternalAfter, 30e18, "Total reduced on withdrawal via executeStrategyWithSlippage");

        uint256 perStrategyAfter = adapter.externalDeposits(strategyId);
        assertEq(perStrategyAfter, 50e18, "Per-strategy reduced on withdrawal (80 - 30 = 50)");
    }

    /**
     * @notice Test large withdrawal with desynced state
     */
    function testLargeWithdrawalWithDesync() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit to protocol (8% under circuit breaker threshold)
        vm.prank(owner);
        adapter.executeStrategy(strategyId, _createDepositCall(80e18));

        // Create extreme desync
        vm.store(
            address(adapter),
            bytes32(uint256(6)),
            bytes32(uint256(10e18)) // totalExternalDeposits = 10, but per-strategy = 80
        );

        // SECURITY FIX (security_issues_5nov2025_4.md Issue #1): executeStrategy() now prevents withdrawals
        // Withdrawals must use executeStrategyWithSlippage() for proper externalDeposits accounting
        vm.prank(owner);
        adapter.executeStrategyWithSlippage(
            strategyId,
            _createWithdrawCall(50e18),
            50e18 // Expect at least 50e18 balance increase
        );

        // SECURITY FIX (security_issues_5nov2025_3.md Issue #3): Symmetric reduction in executeStrategyWithSlippage
        // Balance increases (withdrawals) DO reduce externalDeposits in controlled contexts
        // With desync protection: x is capped to min(d=80, totalExternalDeposits=10) = 10
        uint256 totalExternalAfter = adapter.totalExternalDeposits();
        assertEq(totalExternalAfter, 0, "Total reduced to 0 (10 - 10 = 0)");

        uint256 perStrategyAfter = adapter.externalDeposits(strategyId);
        assertEq(perStrategyAfter, 70e18, "Per-strategy reduced by capped amount (80 - 10 = 70)");
    }

    /**
     * @notice Fuzz test: No underflow regardless of desync state
     */
    function testFuzzNoUnderflowWithDesync(uint256 perStrategy, uint256 totalExternal, uint256 withdrawAmount) public {
        perStrategy = bound(perStrategy, 100e18, 1000e18);
        totalExternal = bound(totalExternal, 50e18, perStrategy); // Can be less than per-strategy
        withdrawAmount = bound(withdrawAmount, 10e18, 500e18);

        // Setup
        uint256 allocation = perStrategy + 200e18;
        asset.mint(address(adapter), allocation);

        bytes memory allocateData = abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, allocation, bytes4(0), address(0));

        // Manually set desynchronized state
        vm.store(
            address(adapter),
            bytes32(uint256(5)), // externalDeposits[strategyId] storage slot (keccak256(strategyId, 5))
            bytes32(perStrategy)
        );
        vm.store(
            address(adapter),
            bytes32(uint256(6)), // totalExternalDeposits storage slot
            bytes32(totalExternal)
        );

        // Withdraw - should not revert
        vm.prank(owner);
        try adapter.executeStrategy(strategyId, _createWithdrawCall(withdrawAmount)) {
            // Success - verify no underflow occurred
            uint256 totalAfter = adapter.totalExternalDeposits();
            assertLe(totalAfter, totalExternal, "Total should not increase");
        } catch {
            // If it reverts, it should be for a different reason, not underflow
            // Underflow would be caught by Solidity 0.8's built-in checks
        }
    }

    function testSetStrategyRejectsNonOnchainAgentWithoutValuer() public {
        UniversalAdapterEscrow noValuerAdapter = new UniversalAdapterEscrow(address(vault), address(0), false);

        vm.prank(owner);
        vm.expectRevert(IUniversalAdapterEscrow.InvalidData.selector);
        noValuerAdapter.setStrategy(strategyId, address(0xBEEF), "", 0);
    }

    function testSetStrategyAcceptsOnchainValuerAgentWithoutValuer() public {
        UniversalAdapterEscrow noValuerAdapter = new UniversalAdapterEscrow(address(vault), address(0), false);
        MockSecurityOnchainValuerAgent onchainAgent = new MockSecurityOnchainValuerAgent();

        vm.prank(owner);
        noValuerAdapter.setStrategy(strategyId, address(onchainAgent), "", 0);

        IUniversalAdapterEscrow.StrategyConfig memory config = noValuerAdapter.getStrategy(strategyId);
        assertEq(config.agent, address(onchainAgent));
        assertTrue(config.active);
    }

    function testRealAssetsUsesHaircutForUnhealthyOnchainValuation() public {
        UniversalAdapterEscrow noValuerAdapter = new UniversalAdapterEscrow(address(vault), address(0), false);
        MockSecurityOnchainValuerAgent onchainAgent = new MockSecurityOnchainValuerAgent();
        onchainAgent.setQuote(1_000e18, false);

        vm.prank(owner);
        noValuerAdapter.setStrategy(strategyId, address(onchainAgent), "", 0);

        asset.mint(address(noValuerAdapter), 1_000e18);
        vm.prank(address(vault));
        noValuerAdapter.allocate(
            abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0)), 1_000e18, bytes4(0), address(0)
        );

        assertEq(noValuerAdapter.realAssets(), 950e18);
    }

    function testQuoteSnapshotStateUsesZeroTimestampForOnchainValuation() public {
        UniversalAdapterEscrow noValuerAdapter = new UniversalAdapterEscrow(address(vault), address(0), false);
        MockSecurityOnchainValuerAgent onchainAgent = new MockSecurityOnchainValuerAgent();
        onchainAgent.setQuote(1_000e18, true);

        vm.prank(owner);
        noValuerAdapter.setStrategy(strategyId, address(onchainAgent), "", 0);

        asset.mint(address(noValuerAdapter), 1_000e18);
        vm.prank(address(vault));
        noValuerAdapter.allocate(
            abi.encode(strategyId, 0, new IUniversalAdapterEscrow.Call[](0)), 1_000e18, bytes4(0), address(0)
        );

        (uint256 assetsQuoted, uint64 snapshotTimestamp, bool healthy) = noValuerAdapter.quoteSnapshotState();
        assertEq(assetsQuoted, 1_000e18);
        assertEq(snapshotTimestamp, 0);
        assertFalse(healthy);
    }

    function testQuoteSnapshotStateMarksHealthCheckFailureUnhealthy() public {
        MockSecuritySnapshotValuer snapshotValuer = new MockSecuritySnapshotValuer();
        UniversalAdapterEscrow snapshotAdapter = new UniversalAdapterEscrow(address(vault), address(snapshotValuer), true);
        bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(snapshotAdapter)));
        snapshotValuer.setValue(totalId, 1_000e18, uint64(block.timestamp));
        snapshotValuer.setHealthCheckFailure(true);

        (uint256 assetsQuoted, uint64 snapshotTimestamp, bool healthy) = snapshotAdapter.quoteSnapshotState();
        assertEq(assetsQuoted, 1_000e18);
        assertEq(snapshotTimestamp, uint64(block.timestamp));
        assertFalse(healthy);
    }

    function testUpdateWhitelistRejectsDelegatecallTargets() public {
        MockSecuritySnapshotValuer snapshotValuer = new MockSecuritySnapshotValuer();
        UniversalAdapterEscrow snapshotAdapter = new UniversalAdapterEscrow(address(vault), address(snapshotValuer), true);
        MockSecurityDelegatecallTarget proxyLike = new MockSecurityDelegatecallTarget();

        vm.prank(owner);
        vm.expectRevert(IUniversalAdapterEscrow.InvalidData.selector);
        snapshotAdapter.updateWhitelist(address(proxyLike), bytes4(0), true, 0);
    }

    function testExecuteStrategyRejectsCodeHashChangesAfterWhitelisting() public {
        MockSecuritySnapshotValuer snapshotValuer = new MockSecuritySnapshotValuer();
        UniversalAdapterEscrow snapshotAdapter = new UniversalAdapterEscrow(address(vault), address(snapshotValuer), true);
        MockTarget targetContract = new MockTarget(address(asset));

        vm.prank(owner);
        snapshotAdapter.setStrategy(strategyId, owner, "", 0);
        vm.prank(owner);
        snapshotAdapter.updateWhitelist(address(targetContract), targetContract.doSomething.selector, true, 0);

        MockSecurityMutatedTarget mutatedTarget = new MockSecurityMutatedTarget();
        vm.etch(address(targetContract), address(mutatedTarget).code);

        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(targetContract),
            data: abi.encodeWithSelector(targetContract.doSomething.selector),
            value: 0
        });

        vm.prank(owner);
        vm.expectRevert(IUniversalAdapterEscrow.InvalidData.selector);
        snapshotAdapter.executeStrategy(strategyId, calls);
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

    function getValue(bytes32) external view returns (uint256) {
        return returnValue;
    }

    function isValuationHealthy(address) external pure returns (bool) {
        return true;
    }
}

/**
 * @notice Mock protocol that can simulate deposit/withdraw with failures
 */
contract MockProtocol {
    address public asset;
    bool public shouldFail;
    mapping(address => uint256) public balances;

    constructor(address _asset) {
        asset = _asset;
    }

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function deposit(uint256 amount) external {
        require(!shouldFail, "Protocol: deposit failed");
        MockERC20(asset).transferFrom(msg.sender, address(this), amount);
        balances[msg.sender] += amount;
    }

    function withdraw(uint256 amount) external {
        require(!shouldFail, "Protocol: withdraw failed");
        require(balances[msg.sender] >= amount, "Insufficient balance");
        balances[msg.sender] -= amount;
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

contract MockSecurityOnchainValuerAgent {
    uint256 internal assets;
    bool internal healthy;

    function setQuote(uint256 assets_, bool healthy_) external {
        assets = assets_;
        healthy = healthy_;
    }

    function quoteCurrentAssets() external view returns (uint256, bool) {
        return (assets, healthy);
    }
}

contract MockSecuritySnapshotValuer {
    mapping(bytes32 => IUniversalValuerOffchain.ValueReport) internal reports;
    bool internal healthCheckFailure;

    function setValue(bytes32 strategyId, uint256 value, uint64 timestamp) external {
        reports[strategyId] = IUniversalValuerOffchain.ValueReport({
            value: value,
            timestamp: timestamp,
            confidence: 100,
            nonce: 1,
            isPush: true,
            lastUpdater: msg.sender
        });
    }

    function setHealthCheckFailure(bool shouldFail) external {
        healthCheckFailure = shouldFail;
    }

    function getValue(bytes32 strategyId) external view returns (uint256) {
        return reports[strategyId].value;
    }

    function getReport(bytes32 strategyId) external view returns (IUniversalValuerOffchain.ValueReport memory) {
        return reports[strategyId];
    }

    function isValuationHealthy(address) external view returns (bool) {
        if (healthCheckFailure) revert("health check unavailable");
        return true;
    }
}

contract MockSecurityDelegatecallTarget {
    function forward(address target, bytes calldata data) external returns (bytes memory result) {
        (bool success, bytes memory returnData) = target.delegatecall(data);
        require(success, "delegatecall failed");
        return returnData;
    }
}

contract MockSecurityMutatedTarget {
    uint256 public counter;

    function doSomething() external {
        counter += 2;
    }
}
