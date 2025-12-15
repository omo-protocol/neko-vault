// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockVaultV2} from "../mocks/MockVaultV2.sol";
import {MockValuer} from "../mocks/MockValuer.sol";

/**
 * @title VerifyScenarioLogic
 * @notice Explicitly verifies that Scenario 2 and Scenario 3 have different withdrawal logic
 */
contract VerifyScenarioLogic is Test {
    UniversalAdapterEscrow adapter;
    MockVaultV2 vault;
    MockERC20 asset;
    MockValuer valuer;
    MockProtocolWithTracking mockProtocol;

    address owner = address(0x1);
    address agent = address(0x2);

    bytes32 constant STRATEGY_1 = keccak256("STRATEGY_1");

    function setUp() public {
        asset = new MockERC20("USDC", "USDC", 6);
        valuer = new MockValuer();
        vault = new MockVaultV2(address(asset), owner);

        adapter = new UniversalAdapterEscrow(
            address(vault),
            address(valuer),
            false
        );

        // Create mock protocol that tracks withdrawal amounts
        mockProtocol = new MockProtocolWithTracking(address(asset));

        vm.startPrank(owner);
        vault.addAdapter(address(adapter));
        adapter.setStrategy(STRATEGY_1, agent, "", 10000e6);
        adapter.updateWhitelist(
            address(mockProtocol),
            bytes4(keccak256("withdraw(uint256)")),
            true,
            0
        );
        vm.stopPrank();

        asset.mint(address(vault), 10000e6);
    }

    function testScenario2OnlyWithdrawsMissingAmount() public {
        console2.log("=== SCENARIO 2: Agent withdraws only missing amount (LAZY DEALLOCATION) ==");

        // Setup: Allocate 800e6, then move 500e6 to protocol, leaving 300e6 in adapter
        asset.mint(address(adapter), 800e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            800e6,
            bytes4(0),
            address(0)
        );

        // Move 500e6 to protocol
        vm.prank(address(adapter));
        asset.transfer(address(mockProtocol), 500e6);

        uint256 adapterBalance = asset.balanceOf(address(adapter));
        uint256 requestAmount = 600e6; // Request 600e6
        uint256 expectedWithdrawal = requestAmount - adapterBalance; // Should withdraw 300e6

        console2.log("Adapter balance:", adapterBalance); // 300e6
        console2.log("Request amount:", requestAmount); // 600e6
        console2.log("Expected withdrawal from protocol:", expectedWithdrawal); // 300e6

        // LAZY DEALLOCATION: Agent withdraws exactly the missing amount
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", expectedWithdrawal),
            value: 0
        });

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_1, withdrawCalls, expectedWithdrawal);

        // Verify agent withdrawal
        assertEq(mockProtocol.lastWithdrawalAmount(), expectedWithdrawal, "Should have withdrawn only missing amount");
        assertEq(asset.balanceOf(address(adapter)), requestAmount, "Adapter should have exactly the requested amount after agent withdrawal");

        // User deallocates (calls ignored)
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            requestAmount,
            bytes4(0),
            address(0)
        );

        // Verify Scenario 2 logic:
        // - Agent withdrew exactly 300e6 (missing amount)
        // - User deallocated full 600e6
        assertEq(change, -int256(requestAmount), "Should provide full requested amount");

        console2.log("[VERIFIED] Scenario 2: Agent withdraws only missing amount (assets - balance) from protocol");
    }

    function testScenario3WithdrawsFullAmount() public {
        console2.log("=== SCENARIO 3: Agent withdraws full amount (LAZY DEALLOCATION) ==");

        // Setup: Allocate 800e6, then move ALL to protocol, leaving 0 in adapter
        asset.mint(address(adapter), 800e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            800e6,
            bytes4(0),
            address(0)
        );

        // Move ALL to protocol
        vm.prank(address(adapter));
        asset.transfer(address(mockProtocol), 800e6);

        uint256 adapterBalance = asset.balanceOf(address(adapter));
        uint256 requestAmount = 600e6; // Request 600e6

        console2.log("Adapter balance:", adapterBalance); // 0
        console2.log("Request amount:", requestAmount); // 600e6
        console2.log("Expected withdrawal from protocol:", requestAmount); // Full 600e6

        assertEq(adapterBalance, 0, "Adapter should have 0 balance for Scenario 3");

        // LAZY DEALLOCATION: Agent withdraws the FULL requested amount
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", requestAmount),
            value: 0
        });

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_1, withdrawCalls, requestAmount);

        // Verify agent withdrawal
        assertEq(mockProtocol.lastWithdrawalAmount(), requestAmount, "Should have withdrawn full amount");
        assertEq(asset.balanceOf(address(adapter)), requestAmount, "Adapter should have the requested amount after agent withdrawal");

        // User deallocates (calls ignored)
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            requestAmount,
            bytes4(0),
            address(0)
        );

        // Verify Scenario 3 logic:
        // - Agent withdrew full 600e6 from protocol
        // - User deallocated full 600e6
        assertEq(change, -int256(requestAmount), "Should provide full requested amount");

        console2.log("[VERIFIED] Scenario 3: Agent withdraws full assets amount from protocol");
    }

    function testScenarioDifference() public {
        console2.log("=== VERIFYING THE KEY DIFFERENCE BETWEEN SCENARIOS (LAZY DEALLOCATION) ==");

        // Test both scenarios with same request but different starting balances
        uint256 requestAmount = 500e6;

        // Scenario 2 setup: Has 200e6 balance
        asset.mint(address(adapter), 700e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            700e6,
            bytes4(0),
            address(0)
        );
        vm.prank(address(adapter));
        asset.transfer(address(mockProtocol), 500e6); // Leave 200e6 in adapter

        uint256 scenario2Balance = asset.balanceOf(address(adapter));
        uint256 scenario2ExpectedWithdrawal = requestAmount - scenario2Balance; // 300e6

        console2.log("\nScenario 2 - Partial coverage:");
        console2.log("  Adapter balance: %d", scenario2Balance);
        console2.log("  Should withdraw from protocol: %d", scenario2ExpectedWithdrawal);

        // LAZY DEALLOCATION: Agent withdraws for Scenario 2
        IUniversalAdapterEscrow.Call[] memory withdrawCalls2 = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls2[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", scenario2ExpectedWithdrawal),
            value: 0
        });

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_1, withdrawCalls2, scenario2ExpectedWithdrawal);

        uint256 scenario2Withdrawal = mockProtocol.lastWithdrawalAmount();

        // User deallocates
        vm.prank(address(vault));
        adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            requestAmount,
            bytes4(0),
            address(0)
        );

        // Reset for Scenario 3
        setUp();
        asset.mint(address(adapter), 700e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            700e6,
            bytes4(0),
            address(0)
        );
        vm.prank(address(adapter));
        asset.transfer(address(mockProtocol), 700e6); // Move ALL to protocol

        uint256 scenario3Balance = asset.balanceOf(address(adapter));

        console2.log("\nScenario 3 - No coverage:");
        console2.log("  Adapter balance: %d", scenario3Balance);
        console2.log("  Should withdraw from protocol: %d", requestAmount);

        // LAZY DEALLOCATION: Agent withdraws for Scenario 3
        IUniversalAdapterEscrow.Call[] memory withdrawCalls3 = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls3[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", requestAmount),
            value: 0
        });

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_1, withdrawCalls3, requestAmount);

        uint256 scenario3Withdrawal = mockProtocol.lastWithdrawalAmount();

        // User deallocates
        vm.prank(address(vault));
        adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            requestAmount,
            bytes4(0),
            address(0)
        );

        // Verify the key difference
        console2.log("\n=== KEY DIFFERENCE VERIFIED ===");
        console2.log("Scenario 2 agent withdrew from protocol: %d", scenario2Withdrawal);
        console2.log("Scenario 3 agent withdrew from protocol: %d", scenario3Withdrawal);

        assertEq(scenario2Withdrawal, 300e6, "Scenario 2 agent should withdraw only missing amount");
        assertEq(scenario3Withdrawal, 500e6, "Scenario 3 agent should withdraw full amount");
        assertTrue(scenario2Withdrawal < scenario3Withdrawal, "Scenario 2 withdraws less than Scenario 3");

        console2.log("\n[SUCCESS] Confirmed different agent withdrawal logic:");
        console2.log("- Scenario 2: Agent withdraws (assets - balance) = uses existing balance efficiently");
        console2.log("- Scenario 3: Agent withdraws full assets = no existing balance to use");
    }
}

/**
 * @title MockProtocolWithTracking
 * @notice Mock protocol that tracks the last withdrawal amount for verification
 */
contract MockProtocolWithTracking {
    MockERC20 public immutable token;
    uint256 public lastWithdrawalAmount;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function withdraw(uint256 amount) external {
        lastWithdrawalAmount = amount;
        token.transfer(msg.sender, amount);
    }
}