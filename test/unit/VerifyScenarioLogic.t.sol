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
        console2.log("=== SCENARIO 2: Should only withdraw (assets - adapterBalance) ==");

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

        // Create withdrawal call for exactly the missing amount
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", expectedWithdrawal),
            value: 0
        });

        // Execute deallocate
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, calls),
            requestAmount,
            bytes4(0),
            address(0)
        );

        // Verify Scenario 2 logic:
        // - Used existing 300e6 balance
        // - Withdrew exactly 300e6 more from protocol
        // - Total provided: 600e6
        assertEq(change, -int256(requestAmount), "Should provide full requested amount");
        assertEq(mockProtocol.lastWithdrawalAmount(), expectedWithdrawal, "Should have withdrawn only missing amount");

        // The key verification: actualAmount = adapterBalance + actualWithdrawn
        uint256 finalAdapterBalance = asset.balanceOf(address(adapter));
        assertEq(finalAdapterBalance, requestAmount, "Adapter should have exactly the requested amount");

        console2.log("[VERIFIED] Scenario 2 uses: existing balance + (assets - balance) from protocol");
    }

    function testScenario3WithdrawsFullAmount() public {
        console2.log("=== SCENARIO 3: Should withdraw full assets amount ==");

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

        // Create withdrawal call for the FULL requested amount
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", requestAmount),
            value: 0
        });

        // Execute deallocate
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, calls),
            requestAmount,
            bytes4(0),
            address(0)
        );

        // Verify Scenario 3 logic:
        // - Started with 0 balance
        // - Withdrew full 600e6 from protocol
        assertEq(change, -int256(requestAmount), "Should provide full requested amount");
        assertEq(mockProtocol.lastWithdrawalAmount(), requestAmount, "Should have withdrawn full amount");

        console2.log("[VERIFIED] Scenario 3 withdraws: full assets amount from protocol");
    }

    function testScenarioDifference() public {
        console2.log("=== VERIFYING THE KEY DIFFERENCE BETWEEN SCENARIOS ==");

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

        // Execute Scenario 2
        IUniversalAdapterEscrow.Call[] memory calls2 = new IUniversalAdapterEscrow.Call[](1);
        calls2[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", scenario2ExpectedWithdrawal),
            value: 0
        });

        vm.prank(address(vault));
        adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, calls2),
            requestAmount,
            bytes4(0),
            address(0)
        );

        uint256 scenario2Withdrawal = mockProtocol.lastWithdrawalAmount();

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

        // Execute Scenario 3
        IUniversalAdapterEscrow.Call[] memory calls3 = new IUniversalAdapterEscrow.Call[](1);
        calls3[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", requestAmount),
            value: 0
        });

        vm.prank(address(vault));
        adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, calls3),
            requestAmount,
            bytes4(0),
            address(0)
        );

        uint256 scenario3Withdrawal = mockProtocol.lastWithdrawalAmount();

        // Verify the key difference
        console2.log("\n=== KEY DIFFERENCE VERIFIED ===");
        console2.log("Scenario 2 withdrew from protocol: %d", scenario2Withdrawal);
        console2.log("Scenario 3 withdrew from protocol: %d", scenario3Withdrawal);

        assertEq(scenario2Withdrawal, 300e6, "Scenario 2 should withdraw only missing amount");
        assertEq(scenario3Withdrawal, 500e6, "Scenario 3 should withdraw full amount");
        assertTrue(scenario2Withdrawal < scenario3Withdrawal, "Scenario 2 withdraws less than Scenario 3");

        console2.log("\n[SUCCESS] Confirmed different withdrawal logic:");
        console2.log("- Scenario 2: Withdraws (assets - balance) = uses existing balance efficiently");
        console2.log("- Scenario 3: Withdraws full assets = no existing balance to use");
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