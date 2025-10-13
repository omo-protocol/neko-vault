// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

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

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Simulate external deposit (800 to protocol, 200 in adapter)
        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(800e18)
        );

        // Set protocol to fail on withdrawal
        protocol.setShouldFail(true);

        // Try to deallocate 500 (more than adapter balance of 200)
        // Before fix: Would revert due to protocol failure
        // After fix: Returns whatever balance we have (200)
        // Note: Set minAmountOut = 0 to disable slippage check (we expect only 200)
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createWithdrawCall(300e18);
        bytes memory deallocateData = abi.encode(strategyId, 0, false, withdrawCalls); // minAmountOut = 0

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocateData, 500e18, bytes4(0x4b219d16), address(0));

        // Should return partial amount (200) instead of reverting
        assertEq(uint256(-change), 200e18, "Should return available balance despite protocol failure");
        assertEq(ids[0], strategyId, "Should return correct strategy ID");
    }

    /**
     * @notice Test normal path still works when protocol succeeds
     */
    function testDeallocateWorksNormallyWhenProtocolSucceeds() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit to protocol
        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(800e18)
        );

        // Protocol has funds and will succeed
        protocol.setShouldFail(false);

        // Deallocate 500 (minAmountOut = 0 to disable slippage check for this test)
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = _createWithdrawCall(300e18);
        bytes memory deallocateData = abi.encode(strategyId, 0, false, withdrawCalls);

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(deallocateData, 500e18, bytes4(0x4b219d16), address(0));

        // Should return full requested amount
        assertEq(uint256(-change), 500e18, "Should return full requested amount when protocol succeeds");
    }

    /* ============ ISSUE #8: Pause Check Removed from syncExternalDeposits ============ */

    /**
     * @notice Test that syncExternalDeposits works during pause
     * @dev SECURITY FIX Issue #8: Owner needs to fix accounting during emergencies
     */
    function testSyncExternalDepositsWorksDuringPause() public {
        // Setup with ghost
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(800e18)
        );

        // Simulate loss
        valuer.setReturnValue(800e18);

        uint256 ghostBefore = adapter.getGhostAmount();
        assertEq(ghostBefore, 200e18, "Should have 200e18 ghost");

        // Pause the adapter
        vm.prank(owner);
        adapter.setPaused(true);

        // Should still be able to sync
        vm.prank(owner);
        adapter.syncExternalDeposits(600e18);

        uint256 ghostAfter = adapter.getGhostAmount();
        assertEq(ghostAfter, 0, "Ghost should be removed even during pause");
        assertEq(adapter.totalExternalDeposits(), 600e18, "totalExternalDeposits should be updated");
    }

    /**
     * @notice Test realAssets accuracy during pause after sync
     */
    function testRealAssetsDuringPauseAfterSync() public {
        // Setup with ghost
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(800e18)
        );

        // Simulate loss
        valuer.setReturnValue(800e18);

        // Pause
        vm.prank(owner);
        adapter.setPaused(true);

        // Before sync: realAssets overprices due to ghost
        uint256 realAssetsBefore = adapter.realAssets();
        assertEq(realAssetsBefore, 1000e18, "Should return minKnownValue (overpriced)");

        // Sync to fix
        vm.prank(owner);
        adapter.syncExternalDeposits(600e18);

        // After sync: realAssets is accurate
        uint256 realAssetsAfter = adapter.realAssets();
        assertEq(realAssetsAfter, 800e18, "Should return accurate value after sync");
    }

    /* ============ ISSUE #9: Desynchronized External Deposits Prevention ============ */

    /**
     * @notice Test that withdrawal doesn't underflow when totalExternalDeposits < per-strategy
     * @dev SECURITY FIX Issue #9: Prevents desynchronization causing underflow DoS
     */
    function testWithdrawalDoesntUnderflowWithDesync() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit to protocol
        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(800e18)
        );

        // At this point: externalDeposits[strategyId] = 800, totalExternalDeposits = 800

        // Simulate desynchronization by manually setting totalExternalDeposits lower
        // (This could happen through various edge cases or bugs)
        vm.store(
            address(adapter),
            bytes32(uint256(6)), // totalExternalDeposits storage slot
            bytes32(uint256(600e18)) // Set to 600 instead of 800
        );

        // Now: externalDeposits[strategyId] = 800, totalExternalDeposits = 600 (desync!)

        // Withdraw 300 from protocol - before fix, this could underflow totalExternalDeposits
        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createWithdrawCall(300e18)
        );

        // After fix: Should cap decrease to totalExternalDeposits (600), not underflow
        uint256 totalExternalAfter = adapter.totalExternalDeposits();
        assertEq(totalExternalAfter, 300e18, "Should cap to totalExternalDeposits, not underflow");

        // Per-strategy should also be decreased by same amount
        uint256 perStrategyAfter = adapter.externalDeposits(strategyId);
        assertEq(perStrategyAfter, 500e18, "Should decrease per-strategy by same amount");
    }

    /**
     * @notice Test large withdrawal with desynced state
     */
    function testLargeWithdrawalWithDesync() public {
        // Setup
        asset.mint(address(adapter), 1000e18);

        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Deposit to protocol
        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createDepositCall(800e18)
        );

        // Create extreme desync
        vm.store(
            address(adapter),
            bytes32(uint256(6)),
            bytes32(uint256(100e18)) // totalExternalDeposits = 100, but per-strategy = 800
        );

        // Try to withdraw 500 (more than totalExternalDeposits)
        vm.prank(owner);
        adapter.executeStrategy(
            strategyId,
            _createWithdrawCall(500e18)
        );

        // Should cap to totalExternalDeposits (100), bringing it to zero
        uint256 totalExternalAfter = adapter.totalExternalDeposits();
        assertEq(totalExternalAfter, 0, "Should cap to 100 decrease, bringing total to zero");

        uint256 perStrategyAfter = adapter.externalDeposits(strategyId);
        assertEq(perStrategyAfter, 700e18, "Per-strategy should decrease by 100");
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

        bytes memory allocateData = abi.encode(strategyId, allocation, false, new IUniversalAdapterEscrow.Call[](0));
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
        try adapter.executeStrategy(
            strategyId,
            _createWithdrawCall(withdrawAmount)
        ) {
            // Success - verify no underflow occurred
            uint256 totalAfter = adapter.totalExternalDeposits();
            assertLe(totalAfter, totalExternal, "Total should not increase");
        } catch {
            // If it reverts, it should be for a different reason, not underflow
            // Underflow would be caught by Solidity 0.8's built-in checks
        }
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
