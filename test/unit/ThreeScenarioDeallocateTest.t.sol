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
 * @title ThreeScenarioDeallocateTest
 * @notice Tests the three distinct balance scenarios in deallocate function
 * @dev Verifies proper handling of: full coverage, partial coverage, and no coverage scenarios
 */
contract ThreeScenarioDeallocateTest is Test {
    UniversalAdapterEscrow adapter;
    MockVaultV2 vault;
    MockERC20 asset;
    MockValuer valuer;

    address owner = address(0x1);
    address agent = address(0x2);

    bytes32 constant STRATEGY_1 = keccak256("STRATEGY_1");

    // Mock protocol for testing withdrawals
    MockProtocol mockProtocol;

    function setUp() public {
        asset = new MockERC20("USDC", "USDC", 6);
        valuer = new MockValuer();
        vault = new MockVaultV2(address(asset), owner);

        adapter = new UniversalAdapterEscrow(
            address(vault),
            address(valuer),
            false
        );

        // Create mock protocol
        mockProtocol = new MockProtocol(address(asset));

        vm.startPrank(owner);
        vault.addAdapter(address(adapter));
        adapter.setStrategy(STRATEGY_1, agent, "", 10000e6);

        // Whitelist protocol withdraw function
        adapter.updateWhitelist(
            address(mockProtocol),
            bytes4(keccak256("withdraw(uint256)")),
            true,
            0
        );
        vm.stopPrank();

        asset.mint(address(vault), 10000e6);
    }

    function testScenario1_FullCoverage() public {
        console2.log("=== SCENARIO 1: Adapter balance covers entire withdrawal ===");

        // Setup: First allocate 800e6 to strategy, then add 200e6 idle assets
        asset.mint(address(adapter), 800e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            800e6,
            bytes4(0),
            address(0)
        );

        // Add idle assets (profits/yield)
        asset.mint(address(adapter), 200e6);
        uint256 requestAmount = 500e6;

        uint256 adapterBalanceBefore = asset.balanceOf(address(adapter));
        uint256 protocolBalanceBefore = asset.balanceOf(address(mockProtocol));

        console2.log("Adapter balance before:", adapterBalanceBefore);
        console2.log("Request amount:", requestAmount);
        console2.log("Protocol balance before:", protocolBalanceBefore);

        // Verify: adapterBalance >= assets (Scenario 1 condition)
        assertTrue(adapterBalanceBefore >= requestAmount, "Should be Scenario 1");

        // Create withdrawal calls (should NOT be executed in Scenario 1)
        IUniversalAdapterEscrow.Call[] memory calls = new IUniversalAdapterEscrow.Call[](1);
        calls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 200e6),
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

        // Verify results
        assertEq(change, -int256(requestAmount), "Should withdraw exact requested amount");
        assertEq(asset.balanceOf(address(adapter)), adapterBalanceBefore, "Adapter balance unchanged");
        assertEq(asset.balanceOf(address(mockProtocol)), protocolBalanceBefore, "Protocol NOT touched");

        console2.log("[PASS] Scenario 1: Used adapter balance only, no protocol withdrawal");
    }

    function testScenario2_PartialCoverage() public {
        console2.log("=== SCENARIO 2: Adapter balance covers partially (LAZY DEALLOCATION) ===");

        // Setup: First allocate 600e6 to strategy (this is the strategy value)
        asset.mint(address(adapter), 600e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            600e6,
            bytes4(0),
            address(0)
        );

        // Simulate that 300e6 was moved to external protocol, leaving 300e6 in adapter
        vm.prank(address(adapter));
        asset.transfer(address(mockProtocol), 300e6);

        // Now adapter has 300e6, protocol has 300e6, strategy allocation is 600e6
        uint256 requestAmount = 500e6;

        uint256 adapterBalanceBefore = asset.balanceOf(address(adapter));
        uint256 protocolBalanceBefore = asset.balanceOf(address(mockProtocol));

        console2.log("Adapter balance before:", adapterBalanceBefore);
        console2.log("Protocol balance before:", protocolBalanceBefore);
        console2.log("Request amount:", requestAmount);
        console2.log("Needed from protocol:", requestAmount - adapterBalanceBefore);

        // Verify: 0 < adapterBalance < assets (Scenario 2 condition)
        assertTrue(adapterBalanceBefore > 0 && adapterBalanceBefore < requestAmount, "Should be Scenario 2");

        // LAZY DEALLOCATION: Agent withdraws from protocol FIRST
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", 200e6), // Exactly what we need
            value: 0
        });

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_1, withdrawCalls, 200e6);

        // Verify agent withdrawal succeeded
        assertEq(asset.balanceOf(address(adapter)), 500e6, "Adapter should have 300 + 200 = 500 after agent withdrawal");

        // User deallocates (calls ignored)
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            requestAmount,
            bytes4(0),
            address(0)
        );

        // Verify results
        assertEq(change, -int256(requestAmount), "Should withdraw exact requested amount");
        assertEq(asset.balanceOf(address(mockProtocol)), 100e6, "Protocol should have 300 - 200 = 100");

        console2.log("[PASS] Scenario 2: Agent withdrew from protocol, then user deallocated");
    }

    function testScenario3_NoCoverage() public {
        console2.log("=== SCENARIO 3: No adapter balance available (LAZY DEALLOCATION) ===");

        // Setup: First allocate 500e6 to strategy, then move all to protocol
        asset.mint(address(adapter), 500e6);
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            500e6,
            bytes4(0),
            address(0)
        );

        // Move all assets to external protocol, leaving adapter with 0 balance
        vm.prank(address(adapter));
        asset.transfer(address(mockProtocol), 500e6);

        // Now adapter has 0e6, protocol has 500e6, strategy allocation is 500e6
        uint256 requestAmount = 400e6;

        uint256 adapterBalanceBefore = asset.balanceOf(address(adapter));
        uint256 protocolBalanceBefore = asset.balanceOf(address(mockProtocol));

        console2.log("Adapter balance before:", adapterBalanceBefore);
        console2.log("Protocol balance before:", protocolBalanceBefore);
        console2.log("Request amount:", requestAmount);

        // Verify: adapterBalance = 0 (Scenario 3 condition)
        assertEq(adapterBalanceBefore, 0, "Should be Scenario 3");

        // LAZY DEALLOCATION: Agent withdraws from protocol FIRST
        IUniversalAdapterEscrow.Call[] memory withdrawCalls = new IUniversalAdapterEscrow.Call[](1);
        withdrawCalls[0] = IUniversalAdapterEscrow.Call({
            target: address(mockProtocol),
            data: abi.encodeWithSignature("withdraw(uint256)", requestAmount), // Full amount needed
            value: 0
        });

        vm.prank(agent);
        adapter.withdrawFromStrategy(STRATEGY_1, withdrawCalls, requestAmount);

        // Verify agent withdrawal succeeded
        assertEq(asset.balanceOf(address(adapter)), requestAmount, "Adapter should have 400e6 after agent withdrawal");
        assertEq(asset.balanceOf(address(mockProtocol)), 100e6, "Protocol should have 500 - 400 = 100");

        // User deallocates (calls ignored)
        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            requestAmount,
            bytes4(0),
            address(0)
        );

        // Verify results
        assertEq(change, -int256(requestAmount), "Should withdraw exact requested amount");
        assertEq(asset.balanceOf(address(mockProtocol)), 100e6, "Protocol balance unchanged after deallocate");

        console2.log("[PASS] Scenario 3: Agent withdrew full amount from protocol, then user deallocated");
    }


    function testEdgeCases() public {
        console2.log("=== TESTING EDGE CASES ===");

        // Edge case: Exactly equal balance and request
        asset.mint(address(adapter), 100e6);

        // First allocate to have strategy value
        vm.prank(address(vault));
        adapter.allocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            100e6,
            bytes4(0),
            address(0)
        );

        vm.prank(address(vault));
        (bytes32[] memory ids, int256 change) = adapter.deallocate(
            abi.encode(STRATEGY_1, 0, false, new IUniversalAdapterEscrow.Call[](0)),
            100e6,
            bytes4(0),
            address(0)
        );

        assertEq(change, -100e6, "Should handle exact balance match");
        console2.log("[PASS] Edge case: exact balance match");
    }
}

/**
 * @title MockProtocol
 * @notice Mock external protocol for testing withdrawals
 */
contract MockProtocol {
    MockERC20 public immutable token;

    constructor(address _token) {
        token = MockERC20(_token);
    }

    function withdraw(uint256 amount) external {
        // Transfer tokens from protocol to caller (adapter)
        token.transfer(msg.sender, amount);
    }

    function deposit(uint256 amount) external {
        // Accept tokens from caller
        token.transferFrom(msg.sender, address(this), amount);
    }
}