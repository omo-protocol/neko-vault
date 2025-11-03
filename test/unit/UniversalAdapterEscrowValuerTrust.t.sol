// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

/**
 * @title UniversalAdapterEscrowValuerTrustTest
 * @notice Tests for critical valuer trust vulnerability in UniversalAdapterEscrow
 * @dev CRITICAL SECURITY ISSUE: Blind trust in positive valuer returns causes underpriced minting
 *
 *      Vulnerability: In realAssets(), the code does:
 *        if (success && data.length >= 32) {
 *            uint256 totalValue = abi.decode(data, (uint256));
 *            if (totalValue > 0) {
 *                return totalValue;  // ❌ BLINDLY TRUSTS THIS VALUE
 *            }
 *        }
 *
 *      The adapter has NO validation that the valuer's returned value is reasonable!
 *      Missing checks:
 *      - Is returned value >= known minimum (balance + totalExternalDeposits)?
 *      - Is returned value within reasonable bounds?
 *      - Has value changed unrealistically?
 *
 *      Attack scenario:
 *      1. Real assets: 1000 (200 balance + 800 external)
 *      2. Malicious valuer returns: 500 (undervalued)
 *      3. Adapter blindly trusts 500
 *      4. Attacker mints shares at 50% discount
 *      5. Existing holders diluted by 25%!
 *
 *      This affects:
 *      - Compromised valuer contracts
 *      - Buggy valuer implementations
 *      - Stale/incorrect valuer data
 *      - Oracle manipulation attacks
 */
contract UniversalAdapterEscrowValuerTrustTest is Test {
    UniversalAdapterEscrow public adapter;
    MockERC20 public asset;
    MockMaliciousValuer public maliciousValuer;
    MockVault public vault;

    address public owner = address(0x1);
    address public attacker = address(0x2);

    bytes32 public strategyId = keccak256("test-strategy");

    function setUp() public {
        asset = new MockERC20("Test Token", "TEST", 18);
        maliciousValuer = new MockMaliciousValuer();

        // Create a mock vault to get owner
        vault = new MockVault(address(asset), owner);

        // Deploy adapter with malicious valuer
        adapter = new UniversalAdapterEscrow(
            address(vault),
            address(maliciousValuer),
            true // useOffchainValuer
        );

        // Setup strategy
        vm.prank(owner);
        adapter.setStrategy(strategyId, owner, "", 0);

        // Whitelist a mock protocol for deposits
        vm.prank(owner);
        adapter.updateWhitelist(address(maliciousValuer), bytes4(keccak256("deposit(uint256)")), true, 0);

        // Mint tokens to adapter
        asset.mint(address(adapter), 1000e18);
    }

    /* ============ VULNERABILITY DEMONSTRATION ============ */

    /**
     * @notice Tests tolerance-based validation - allows 5% loss, rejects 50% underpricing
     * @dev AFTER FIX: Adapter uses 10% tolerance to balance legitimate losses vs attacks
     */
    function testToleranceBasedValidation() public {
        // Setup: Simulate real scenario
        // 1. Allocate 1000 tokens to strategy
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // State after allocation:
        // - Adapter balance: 1000e18
        // - External deposits: 0
        // - Minimum known value: 1000e18
        // - 90% threshold: 900e18

        uint256 minKnownValue = asset.balanceOf(address(adapter)) + adapter.totalExternalDeposits();
        assertEq(minKnownValue, 1000e18, "Min known value should be 1000");

        // Test 1: 5% loss (typical slippage) - SHOULD BE ACCEPTED
        maliciousValuer.setReturnValue(950e18); // 95% of minimum
        uint256 reported1 = adapter.realAssets();
        assertEq(reported1, 950e18, "5% loss should be accepted (within 10% tolerance)");

        // Test 2: 9% loss (edge case) - SHOULD BE ACCEPTED
        maliciousValuer.setReturnValue(910e18); // 91% of minimum
        uint256 reported2 = adapter.realAssets();
        assertEq(reported2, 910e18, "9% loss should be accepted (within 10% tolerance)");

        // Test 3: Exactly 10% loss (boundary) - SHOULD BE ACCEPTED
        maliciousValuer.setReturnValue(900e18); // 90% of minimum
        uint256 reported3 = adapter.realAssets();
        assertEq(reported3, 900e18, "10% loss should be accepted (at threshold)");

        // Test 4: 11% loss - SHOULD BE REJECTED
        maliciousValuer.setReturnValue(890e18); // 89% of minimum
        uint256 reported4 = adapter.realAssets();
        assertEq(reported4, 1000e18, "11% loss should be rejected (returns minimum)");

        // Test 5: 50% malicious underpricing - SHOULD BE REJECTED
        maliciousValuer.setReturnValue(500e18); // 50% of minimum
        uint256 reported5 = adapter.realAssets();
        assertEq(reported5, 1000e18, "50% underpricing should be rejected (returns minimum)");
    }

    /**
     * @notice Test realistic PT-KHYPE scenario with slippage
     */
    function testRealisticSlippageScenario() public {
        // Setup: Allocate 1000 KHYPE
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Realistic scenario: 0.5% slippage on swap to PT-KHYPE
        // Deposited 800 KHYPE, received PT worth 796 KHYPE (0.5% loss)
        // minKnownValue = 200 balance + 800 externalDeposits = 1000
        // Real value = 200 balance + 796 PT value = 996
        // Loss = 4 KHYPE (0.4%)

        maliciousValuer.setReturnValue(996e18); // 99.6% of minimum

        uint256 reportedAssets = adapter.realAssets();

        // AFTER TOLERANCE FIX: 0.5% loss is accepted (within 10% tolerance)
        // No persistent overpricing!
        assertEq(reportedAssets, 996e18, "Should accept 0.5% slippage loss");

        // Verify this prevents persistent overpricing
        uint256 minKnownValue = asset.balanceOf(address(adapter)) + adapter.totalExternalDeposits();
        assertLt(reportedAssets, minKnownValue, "Reported is less than minimum (ghost not added)");
    }

    /**
     * @notice Test that fix prevents extreme undervaluation (90% underpriced)
     */
    function testExtremeUndervaluationPrevented() public {
        // Setup
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Real value: 1000e18
        // Malicious valuer returns only 100 (90% undervalued!)
        maliciousValuer.setReturnValue(100e18);

        uint256 reportedAssets = adapter.realAssets();
        uint256 minKnownValue = asset.balanceOf(address(adapter)) + adapter.totalExternalDeposits();

        // AFTER FIX: Adapter rejects extreme undervaluation
        assertEq(reportedAssets, 1000e18, "Adapter returns minimum known value");
        assertGe(reportedAssets, minKnownValue, "Reported >= minimum");
        assertEq(minKnownValue, 1000e18, "Minimum known value is 1000");

        // Fix prevents 10x dilution attack!
    }

    /**
     * @notice Test that fix prevents valuer returning 1 wei (extreme case)
     */
    function testValuerReturnsMinimalValuePrevented() public {
        // Setup
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Valuer returns 1 wei (extreme undervaluation)
        maliciousValuer.setReturnValue(1);

        uint256 reportedAssets = adapter.realAssets();

        // AFTER FIX: Adapter rejects 1 wei and returns minimum known value
        assertEq(reportedAssets, 1000e18, "Adapter returns 1000e18, not 1 wei");
        assertGe(reportedAssets, 1000e18, "Reported >= minimum");

        // Fix prevents essentially infinite dilution!
    }

    /**
     * @notice Test that zero value correctly triggers fallback
     */
    function testZeroValueTriggersFallback() public {
        // Setup
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Valuer returns 0 (should trigger fallback)
        maliciousValuer.setReturnValue(0);

        uint256 reportedAssets = adapter.realAssets();

        // Fallback should return balance + totalExternalDeposits
        uint256 expectedFallback = asset.balanceOf(address(adapter)) + adapter.totalExternalDeposits();
        assertEq(reportedAssets, expectedFallback, "Zero value should trigger fallback");
    }

    /**
     * @notice Test boundary: tolerance threshold at 90% of minimum
     */
    function testBoundaryToleranceThreshold() public {
        // Setup
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        uint256 minKnownValue = asset.balanceOf(address(adapter)) + adapter.totalExternalDeposits();
        uint256 threshold = (minKnownValue * 9000) / 10000; // 900e18

        // Test 1: 1 wei below threshold (should be rejected)
        maliciousValuer.setReturnValue(threshold - 1);
        uint256 reportedAssets1 = adapter.realAssets();
        assertEq(reportedAssets1, minKnownValue, "Below threshold returns minimum");

        // Test 2: Exactly at threshold (should be accepted)
        maliciousValuer.setReturnValue(threshold);
        uint256 reportedAssets2 = adapter.realAssets();
        assertEq(reportedAssets2, threshold, "At threshold returns valuer value");

        // Test 3: 1 wei above threshold (should be accepted)
        maliciousValuer.setReturnValue(threshold + 1);
        uint256 reportedAssets3 = adapter.realAssets();
        assertEq(reportedAssets3, threshold + 1, "Above threshold returns valuer value");

        // Test 4: 1 wei below minimum (but above threshold - should be accepted)
        maliciousValuer.setReturnValue(minKnownValue - 1);
        uint256 reportedAssets4 = adapter.realAssets();
        assertEq(reportedAssets4, minKnownValue - 1, "1 wei below minimum but above threshold is accepted");

        // Test 5: Exactly at minimum (should be accepted)
        maliciousValuer.setReturnValue(minKnownValue);
        uint256 reportedAssets5 = adapter.realAssets();
        assertEq(reportedAssets5, minKnownValue, "At minimum returns valuer value");

        // Test 6: Above minimum (should be accepted)
        maliciousValuer.setReturnValue(minKnownValue + 100e18);
        uint256 reportedAssets6 = adapter.realAssets();
        assertEq(reportedAssets6, minKnownValue + 100e18, "Above minimum returns valuer value");
    }

    /**
     * @notice Fuzz test: Verify tolerance-based validation across all scenarios
     * SECURITY FIX: Updated for donation-resistant valuation logic
     */
    function testFuzzToleranceValidation(uint256 realValue, uint256 valuerReturn) public {
        // Bound inputs
        realValue = bound(realValue, 1000e18, 10000e18);
        valuerReturn = bound(valuerReturn, 1, realValue * 2); // Can be under or over

        // Setup
        asset.mint(address(adapter), realValue);
        bytes memory allocateData = abi.encode(strategyId, realValue, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, realValue, bytes4(0), address(0));

        // NEW LOGIC: minKnownValue = totalAllocations (not balance + totalExternalDeposits)
        uint256 minKnownValue = adapter.totalAllocations();
        uint256 threshold90Percent = (minKnownValue * 9000) / 10000;

        // Calculate excessIdle (donations) that will be excluded
        uint256 balance = asset.balanceOf(address(adapter));
        uint256 allocatedInAdapter = adapter.totalAllocations() - adapter.totalExternalDeposits();
        uint256 excessIdle = balance > allocatedInAdapter ? balance - allocatedInAdapter : 0;

        // Valuer returns some amount (could be under, at, or above minimum)
        maliciousValuer.setReturnValue(valuerReturn);

        uint256 reportedAssets = adapter.realAssets();

        // Adjust valuerReturn for excessIdle to get valuerValueAdj
        uint256 valuerValueAdj = valuerReturn > excessIdle ? valuerReturn - excessIdle : 0;

        // AFTER TOLERANCE FIX: Use tolerance-based validation with adjusted value
        if (valuerValueAdj >= threshold90Percent) {
            // Within tolerance (>= 90% of minimum) - accept valuer's adjusted value
            assertEq(reportedAssets, valuerValueAdj, "Should use valuer's adjusted value when >= 90% threshold");
        } else {
            // Below tolerance (< 90% of minimum) - use minimum for protection
            assertEq(reportedAssets, minKnownValue, "Should use minimum when valuer < 90% threshold");
        }

        // Safety check: never return less than 90% of minimum
        assertGe(reportedAssets, threshold90Percent, "Reported should never be < 90% of minimum");
    }
}

/**
 * @notice Mock malicious valuer that can return arbitrary values
 */
contract MockMaliciousValuer {
    uint256 public returnValue;
    mapping(uint256 => uint256) public deposits;

    function setReturnValue(uint256 _value) external {
        returnValue = _value;
    }

    function getTotalValue(address) external view returns (uint256) {
        return returnValue;
    }

    function getValue(bytes32) external view returns (uint256) {
        return returnValue;
    }

    // Mock deposit function for testing
    function deposit(uint256 amount) external {
        deposits[amount] = amount;
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
