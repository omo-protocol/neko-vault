// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {UniversalAdapterEscrow} from "../../src/adapters/UniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";

/**
 * @title UniversalAdapterEscrowValuerTrustTest
 * @notice Tests for valuer trust model in UniversalAdapterEscrow after HIGH SEVERITY FIX
 * @dev SECURITY FIX: Removed 10% tolerance threshold to prevent value extraction attacks
 *
 *      NEW SECURITY MODEL (After Fix):
 *      - Always trust the valuer's donation-adjusted value (even if indicates >10% loss)
 *      - Only fall back to principal if valuer returns 0 (no data)
 *      - Accurate loss reporting is CRITICAL to prevent value extraction
 *
 *      OLD VULNERABILITY (Before Fix):
 *      - 10% tolerance threshold caused realAssets() to return principal for >10% losses
 *      - VaultV2 overstated totalAssets, causing share overpricing
 *      - Early withdrawers extracted excess value at expense of late withdrawers
 *      - Created perverse "bank run" incentive during market crashes
 *
 *      WHY THE CHANGE:
 *      1. Overpricing enables value extraction (more harmful than underpricing)
 *      2. Real DeFi losses >10% are legitimate and must be reported accurately
 *      3. UniversalValuerOffchain has signature verification - it's trusted
 *      4. SecurityMonitor/EmergencyGate handle anomaly detection, not realAssets()
 *      5. Accurate pricing ensures fairness for all users
 *
 *      PROTECTION AGAINST MALICIOUS VALUERS:
 *      ✅ UniversalValuerOffchain: Multi-sig signature verification
 *      ✅ SecurityMonitor: Detects rapid withdrawals and price crashes
 *      ✅ EmergencyGate: Can pause operations
 *      ✅ Donation protection: excessIdle excluded from valuation
 *      ❌ NO LONGER: realAssets() rejecting values (this caused the vulnerability!)
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

    /* ============ NEW SECURITY MODEL TESTS ============ */

    /**
     * @notice Tests that valuer values are always trusted (no tolerance rejection)
     * @dev AFTER HIGH SEVERITY FIX: All valuer values > 0 are accepted, even large losses
     */
    function testValuerAlwaysTrusted() public {
        // Setup: Allocate 1000 tokens to strategy
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Test 1: 5% loss - ACCEPTED (typical slippage)
        maliciousValuer.setReturnValue(950e18);
        uint256 reported1 = adapter.realAssets();
        assertEq(reported1, 950e18, "5% loss should be accepted");

        // Test 2: 9% loss - ACCEPTED (edge case)
        maliciousValuer.setReturnValue(910e18);
        uint256 reported2 = adapter.realAssets();
        assertEq(reported2, 910e18, "9% loss should be accepted");

        // Test 3: Exactly 10% loss - ACCEPTED (no longer threshold)
        maliciousValuer.setReturnValue(900e18);
        uint256 reported3 = adapter.realAssets();
        assertEq(reported3, 900e18, "10% loss should be accepted");

        // Test 4: 11% loss - NOW ACCEPTED (was rejected before)
        maliciousValuer.setReturnValue(890e18);
        uint256 reported4 = adapter.realAssets();
        assertEq(reported4, 890e18, "11% loss should be accepted (no longer rejected!)");

        // Test 5: 50% loss - NOW ACCEPTED (accurate reporting critical)
        maliciousValuer.setReturnValue(500e18);
        uint256 reported5 = adapter.realAssets();
        assertEq(reported5, 500e18, "50% loss should be accepted (prevents value extraction!)");
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
        maliciousValuer.setReturnValue(996e18); // 99.6% of minimum

        uint256 reportedAssets = adapter.realAssets();

        // AFTER FIX: Accurate value reported
        assertEq(reportedAssets, 996e18, "Should accept 0.5% slippage loss");
    }

    /**
     * @notice Test that extreme losses are now accepted (for accurate pricing)
     * @dev CHANGE: Was "prevention" test, now "acceptance" test
     */
    function testExtremeUndervaluationAccepted() public {
        // Setup
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Real value: 1000e18
        // Valuer reports 100e18 (90% loss - could be legitimate black swan)
        maliciousValuer.setReturnValue(100e18);

        uint256 reportedAssets = adapter.realAssets();

        // AFTER FIX: Adapter accepts extreme loss for accurate pricing
        // This prevents early withdrawers from extracting value!
        assertEq(reportedAssets, 100e18, "Adapter now accepts extreme losses for fair pricing");
    }

    /**
     * @notice Test that minimal values are accepted if > 0
     * @dev CHANGE: Was "prevention" test, now "acceptance" test
     */
    function testValuerReturnsMinimalValueAccepted() public {
        // Setup
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // Valuer returns 1 wei (extreme undervaluation, but > 0)
        maliciousValuer.setReturnValue(1);

        uint256 reportedAssets = adapter.realAssets();

        // AFTER FIX: Adapter accepts any value > 0
        // Note: In practice, UniversalValuerOffchain has signature verification
        // so such extreme values wouldn't pass multi-sig validation
        assertEq(reportedAssets, 1, "Adapter accepts any value > 0");
    }

    /**
     * @notice Test that zero value triggers fallback and emergency mode invalidates cache
     * @dev TIME-BOUNDED FALLBACK FIX (FIXING.md): Uses cached value instead of principal
     * @dev SECURITY FIX (issues_27Nove2025.md): Emergency mode invalidates cached valuation
     *      to prevent attackers from pre-caching favorable values before emergency mode
     */
    function testZeroValueTriggersFallback() public {
        // Set valuer to return correct value BEFORE allocation
        maliciousValuer.setReturnValue(1000e18);

        // Setup - allocate funds
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        // SECURITY FIX: Keeper explicitly refreshes cache after allocation
        // This simulates the real keeper workflow: allocate → keeper updates valuer → keeper refreshes cache
        adapter.refreshCachedValuation();

        // Verify cache was populated correctly
        uint256 initialAssets = adapter.realAssets();
        assertEq(initialAssets, 1000e18, "Initial valuation should be 1000e18");

        // Now force valuer to return 0 (simulating valuation failure)
        maliciousValuer.setReturnValue(0);

        // UPDATED BEHAVIOR: In normal mode with fresh cache, uses cached valuation as fallback
        // instead of reverting. This allows vault to continue operating.
        uint256 cachedValue = adapter.realAssets();
        assertEq(cachedValue, 1000e18, "Should use cached valuation when valuer returns 0");

        // Enable emergency mode - SECURITY FIX (issues_27Nove2025.md):
        // This now invalidates the cached valuation (sets cachedValuationTimestamp = 0)
        // to prevent attackers from pre-caching favorable values before emergency mode
        vm.prank(owner);
        adapter.enableEmergencyMode();

        // Verify cache was invalidated by enabling emergency mode
        (, , bool isStale) = adapter.getCachedValuation();
        assertTrue(isStale, "Cache should be stale after emergency mode enabled");

        // Should now use totalExternalDeposits fallback with 5% haircut
        // Since no external deposits were made in this test, totalExternalDeposits = 0
        uint256 reportedAssets = adapter.realAssets();
        assertEq(reportedAssets, 0, "Should use totalExternalDeposits fallback (0) in emergency mode");
    }

    /**
     * @notice Test boundary: no tolerance threshold anymore
     * @dev CHANGE: Was testing 90% threshold, now tests that all values > 0 accepted
     */
    function testNoToleranceThreshold() public {
        // Setup
        bytes memory allocateData = abi.encode(strategyId, 1000e18, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, 1000e18, bytes4(0), address(0));

        uint256 minKnownValue = adapter.totalAllocations();

        // Test 1: Far below minimum (890e18) - NOW ACCEPTED
        maliciousValuer.setReturnValue(890e18);
        uint256 reportedAssets1 = adapter.realAssets();
        assertEq(reportedAssets1, 890e18, "Far below minimum is now accepted");

        // Test 2: At 90% of minimum (900e18) - ACCEPTED
        maliciousValuer.setReturnValue(900e18);
        uint256 reportedAssets2 = adapter.realAssets();
        assertEq(reportedAssets2, 900e18, "At old threshold is accepted");

        // Test 3: Just above old threshold - ACCEPTED
        maliciousValuer.setReturnValue(901e18);
        uint256 reportedAssets3 = adapter.realAssets();
        assertEq(reportedAssets3, 901e18, "Above old threshold is accepted");

        // Test 4: 1 wei below minimum - ACCEPTED
        maliciousValuer.setReturnValue(minKnownValue - 1);
        uint256 reportedAssets4 = adapter.realAssets();
        assertEq(reportedAssets4, minKnownValue - 1, "1 wei below minimum is accepted");

        // Test 5: Exactly at minimum - ACCEPTED
        maliciousValuer.setReturnValue(minKnownValue);
        uint256 reportedAssets5 = adapter.realAssets();
        assertEq(reportedAssets5, minKnownValue, "At minimum returns valuer value");

        // Test 6: Above minimum (profits) - ACCEPTED
        maliciousValuer.setReturnValue(minKnownValue + 100e18);
        uint256 reportedAssets6 = adapter.realAssets();
        assertEq(reportedAssets6, minKnownValue + 100e18, "Above minimum returns valuer value");
    }

    /**
     * @notice Fuzz test: Verify valuer values always accepted if > 0
     * @dev SECURITY FIX: Updated for new security model (no tolerance threshold)
     * @dev NOTE: This test validates realAssets() directly without cache refresh
     *            to test the semantic-agnostic adjustment logic independently
     */
    function testFuzzValuerAlwaysTrusted(uint256 realValue, uint256 valuerReturn) public {
        // Skip edge case where realValue is 0 (cold start - no allocations)
        if (realValue == 0) return;

        // Bound inputs - ensure realValue > 0 to avoid cold start edge case
        realValue = bound(realValue, 1000e18, 10000e18);

        // Bound valuerReturn - can be any positive value (semantic-agnostic)
        valuerReturn = bound(valuerReturn, 1, realValue * 10);

        // Set valuer to return correct value BEFORE allocation
        maliciousValuer.setReturnValue(realValue);

        // Setup
        asset.mint(address(adapter), realValue);
        bytes memory allocateData = abi.encode(strategyId, realValue, false, new IUniversalAdapterEscrow.Call[](0));
        vm.prank(address(vault));
        adapter.allocate(allocateData, realValue, bytes4(0), address(0));

        // NOTE: We don't call refreshCachedValuation() here because:
        // 1. This test validates realAssets() semantic-agnostic logic
        // 2. refreshCachedValuation() has sanity checks that would reject extreme fuzz values
        // 3. We want to test that realAssets() accepts any valuer value > 0

        // Calculate excessIdle (donations) that will be excluded
        uint256 balance = asset.balanceOf(address(adapter));
        uint256 allocatedInAdapter = adapter.totalAllocations() - adapter.totalExternalDeposits();
        uint256 excessIdle = balance > allocatedInAdapter ? balance - allocatedInAdapter : 0;

        // Ensure we actually allocated something
        vm.assume(adapter.totalAllocations() > 0);
        vm.assume(allocatedInAdapter > 0);

        // SECURITY FIX (security_issues_5nov2025_6.md Issue #2): Semantic-agnostic adjustment
        // Calculate expected adjusted value based on the semantic-agnostic logic:
        // - If valuerReturn >= excessIdle: subtract excessIdle
        // - If valuerReturn < excessIdle: add allocatedInAdapter
        uint256 expectedValueAdj;
        if (valuerReturn >= excessIdle) {
            expectedValueAdj = valuerReturn - excessIdle;
        } else {
            expectedValueAdj = valuerReturn + allocatedInAdapter;
        }

        // Skip cases where adjustment would result in 0 (triggers ValuationUnavailable)
        vm.assume(expectedValueAdj > 0);

        // Now set the fuzzed valuer return value
        maliciousValuer.setReturnValue(valuerReturn);

        uint256 reportedAssets = adapter.realAssets();

        // Semantic-agnostic adjustment always produces a value > 0 (when allocations > 0)
        // This prevents DoS from donations that would otherwise zero the adjusted value
        assertEq(reportedAssets, expectedValueAdj, "Should use semantic-agnostic adjusted value");
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
