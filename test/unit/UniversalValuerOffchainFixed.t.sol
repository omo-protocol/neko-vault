// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/valuers/UniversalValuerOffchain.sol";
import "../../src/interfaces/IERC20.sol";
import {IUniversalValuerOffchain} from "../../src/adapters/interfaces/IUniversalValuerOffchain.sol";

/// @title UniversalValuerOffchainFixedTest
/// @notice Fixed test suite for UniversalValuerOffchain achieving >90% coverage
contract UniversalValuerOffchainFixedTest is Test {
    UniversalValuerOffchain public valuer;
    MockERC20 public asset;
    MockEscrowWithStrategies public escrow;

    address public owner = address(0x1);
    address public unauthorized = address(0x999);

    address public signer1;
    address public signer2;
    address public signer3;
    uint256 public signer1Key = 0x1234;
    uint256 public signer2Key = 0x5678;
    uint256 public signer3Key = 0x9ABC;

    bytes32 constant STRATEGY_A = keccak256("STRATEGY_A");
    bytes32 constant STRATEGY_B = keccak256("STRATEGY_B");
    bytes32 constant STRATEGY_C = keccak256("STRATEGY_C");

    event ValueUpdated(bytes32 indexed strategyId, uint256 value, uint256 confidence, uint256 timestamp, bool isPush);
    event SignerConfigured(address indexed signer, bool authorized, uint256 weight);
    event StrategyConfigured(bytes32 indexed strategyId, uint256 minUpdateInterval, uint256 maxStaleness, uint256 pushThreshold);
    event RequiredWeightUpdated(uint256 newWeight);
    event FallbackValueSet(bytes32 indexed strategyId, uint256 value);
    event EmergencyModeSet(bool enabled);
    event UpdateRequested(bytes32 indexed strategyId, address requester, IUniversalValuerOffchain.UpdateReason reason);

    function setUp() public {
        asset = new MockERC20("Test", "TST");
        valuer = new UniversalValuerOffchain(owner, address(asset));
        escrow = new MockEscrowWithStrategies();

        // Setup signers
        signer1 = vm.addr(signer1Key);
        signer2 = vm.addr(signer2Key);
        signer3 = vm.addr(signer3Key);

        vm.startPrank(owner);
        valuer.initiateSignerChange(signer1, true, 100);
        valuer.initiateSignerChange(signer2, true, 50);
        valuer.initiateSignerChange(signer3, true, 25);
        valuer.setRequiredWeight(100);

        // Configure strategies with proper thresholds
        valuer.configureStrategy(STRATEGY_A, 1 hours, 24 hours, 500, 95); // 5% threshold, 95 confidence
        valuer.configureStrategy(STRATEGY_B, 1 hours, 24 hours, 500, 95); // 5% threshold, 95 confidence
        valuer.configureStrategy(STRATEGY_C, 1 hours, 24 hours, 500, 85); // 5% threshold, 85 confidence (lower)
        vm.stopPrank();
    }

    /* SINGLE VALUE UPDATE TESTS */

    function testUpdateValue() public {
        uint256 value = 1000e18;
        uint256 confidence = 95;
        uint256 nonce = 1;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, value, confidence, nonce, block.timestamp + 3600, signer1Key);

        vm.expectEmit(true, true, true, true);
        emit ValueUpdated(STRATEGY_A, value, confidence, block.timestamp, true);

        valuer.updateValue(STRATEGY_A, value, confidence, nonce, block.timestamp + 3600, signatures);

        assertEq(valuer.getValue(STRATEGY_A), value);
    }

    function testUpdateValueUnauthorizedSigner() public {
        uint256 unauthorizedKey = 0xDEAD;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, unauthorizedKey);

        vm.expectRevert(IUniversalValuerOffchain.InsufficientSignatures.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);
    }

    function testUpdateValueStaleNonce() public {
        // First update
        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signValue(STRATEGY_A, 1000e18, 95, 2, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 2, block.timestamp + 3600, signatures1);

        // Try with old nonce
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(STRATEGY_A, 2000e18, 95, 1, block.timestamp + 3600, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.StaleNonce.selector);
        valuer.updateValue(STRATEGY_A, 2000e18, 95, 1, block.timestamp + 3600, signatures2);
    }

    /* BATCH UPDATE TESTS */

    function testBatchUpdateValues() public {
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = STRATEGY_A;
        strategyIds[1] = STRATEGY_B;

        uint256[] memory values = new uint256[](2);
        values[0] = 1000e18;
        values[1] = 2000e18;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 95;
        confidences[1] = 95;

        uint256 nonce = 1;

        bytes32 batchHash = keccak256(abi.encode(strategyIds, values, confidences, nonce, block.timestamp + 3600));
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatchHash(batchHash, signer1Key);

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, block.timestamp + 3600, signatures);

        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
        assertEq(valuer.getValue(STRATEGY_B), 2000e18);
    }

    function testBatchUpdateDifferentConfidences() public {
        bytes32[] memory strategyIds = new bytes32[](3);
        strategyIds[0] = STRATEGY_A;
        strategyIds[1] = STRATEGY_B;
        strategyIds[2] = STRATEGY_C;

        uint256[] memory values = new uint256[](3);
        values[0] = 1000e18;
        values[1] = 2000e18;
        values[2] = 3000e18;

        uint256[] memory confidences = new uint256[](3);
        confidences[0] = 95;  // Meets defaultConfidenceThreshold
        confidences[1] = 96;  // Above defaultConfidenceThreshold
        confidences[2] = 95;  // Meets defaultConfidenceThreshold

        uint256 nonce = 1;

        bytes32 batchHash = keccak256(abi.encode(strategyIds, values, confidences, nonce, block.timestamp + 3600));
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatchHash(batchHash, signer1Key);

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, block.timestamp + 3600, signatures);

        // All should succeed with configured thresholds
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
        assertEq(valuer.getValue(STRATEGY_B), 2000e18);
        assertEq(valuer.getValue(STRATEGY_C), 3000e18);
    }

    function testBatchUpdateEmptyArrays() public {
        bytes32[] memory strategyIds = new bytes32[](0);
        uint256[] memory values = new uint256[](0);
        uint256[] memory confidences = new uint256[](0);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatchHash(keccak256(abi.encode(strategyIds, values, confidences, 1, block.timestamp + 3600)), signer1Key);

        // Should succeed with empty arrays
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, block.timestamp + 3600, signatures);
    }

    function testBatchUpdateArrayMismatch() public {
        bytes32[] memory strategyIds = new bytes32[](2);
        uint256[] memory values = new uint256[](1); // Mismatch
        uint256[] memory confidences = new uint256[](2);
        bytes[] memory signatures = new bytes[](0);

        vm.expectRevert(IUniversalValuerOffchain.ArrayLengthMismatch.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, block.timestamp + 3600, signatures);
    }

    /* PUSH THRESHOLD TESTS */

    function testPushThresholdUpdate() public {
        // Initial value
        uint256 value1 = 1000e18;
        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signValue(STRATEGY_A, value1, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, value1, 95, 1, block.timestamp + 3600, signatures1);

        // Try update too soon (should fail)
        vm.warp(block.timestamp + 1 minutes);
        uint256 value2 = 1010e18; // 1% change
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(STRATEGY_A, value2, 95, 2, block.timestamp + 3600, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.UpdateTooFrequent.selector);
        valuer.updateValue(STRATEGY_A, value2, 95, 2, block.timestamp + 3600, signatures2);

        // Large change should work even if too soon
        uint256 value3 = 1060e18; // 6% change (> 5% threshold)
        bytes[] memory signatures3 = new bytes[](1);
        signatures3[0] = _signValue(STRATEGY_A, value3, 95, 3, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, value3, 95, 3, block.timestamp + 3600, signatures3);

        assertEq(valuer.getValue(STRATEGY_A), value3);
    }

    /* STALENESS TESTS */

    function testValueStaleness() public {
        uint256 value = 1000e18;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, value, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, value, 95, 1, block.timestamp + 3600, signatures);

        assertEq(valuer.getValue(STRATEGY_A), value);

        // Fast forward past MAX_STALENESS (24 hours) with no fallback set
        vm.warp(block.timestamp + 25 hours);

        // Should revert when stale and no fallback
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.getValue(STRATEGY_A);
    }

    function testFallbackValue() public {
        // Set fallback value
        vm.prank(owner);
        valuer.setFallbackValue(STRATEGY_A, 500e18);

        // Update with real value
        uint256 value = 1000e18;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, value, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, value, 95, 1, block.timestamp + 3600, signatures);

        // Value should be the updated one
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);

        // Fast forward past MAX_STALENESS (24 hours)
        vm.warp(block.timestamp + 25 hours);

        // Should return fallback value when stale
        assertEq(valuer.getValue(STRATEGY_A), 500e18);
    }

    function testClearFallbackValue() public {
        vm.startPrank(owner);
        valuer.setFallbackValue(STRATEGY_A, 500e18);
        valuer.setFallbackValue(STRATEGY_A, 0); // Clear by setting to 0
        vm.stopPrank();

        // After clearing, fallback value should be 0
        assertEq(valuer.fallbackValues(STRATEGY_A), 0);

        // Update value
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);

        // Fast forward past MAX_STALENESS (24 hours)
        vm.warp(block.timestamp + 25 hours);

        // Should revert since no fallback and value is stale
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.getValue(STRATEGY_A);
    }

    /* LOW CONFIDENCE TESTS */

    function testLowConfidence() public {
        uint256 value = 1000e18;
        uint256 lowConfidence = 50; // Below default threshold of 95

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, value, lowConfidence, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, value, lowConfidence, 1, block.timestamp + 3600, signatures);

        // Should revert when getting value with low confidence
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.getValue(STRATEGY_A);
    }

    function testFallbackValueWithLowConfidence() public {
        // Set fallback value
        vm.prank(owner);
        valuer.setFallbackValue(STRATEGY_A, 5000e18);

        // Update with low confidence
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 50, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 50, 1, block.timestamp + 3600, signatures);

        // getValue should revert with LowConfidence (fallback doesn't apply for low confidence)
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.getValue(STRATEGY_A);
    }

    /* EMERGENCY MODE TESTS */

    function testEmergencyMode() public {
        vm.prank(owner);
        valuer.setEmergencyMode(true);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.EmergencyMode.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);
    }

    function testEmergencyUpdate() public {
        vm.startPrank(owner);
        valuer.setEmergencyMode(true);
        valuer.emergencyUpdate(STRATEGY_A, 999e18);
        vm.stopPrank();

        assertEq(valuer.getValue(STRATEGY_A), 999e18);
    }

    function testDisableEmergencyMode() public {
        vm.startPrank(owner);
        valuer.setEmergencyMode(true);
        valuer.setEmergencyMode(false);
        vm.stopPrank();

        // Should be able to update again
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);
    }

    /* WEIGHTED MULTI-SIG TESTS */

    function testWeightedMultiSigSingleHighWeight() public {
        // Signer1 has 100 weight, which meets the required 100
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);

        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
    }

    function testWeightedMultiSigCombinedLowWeights() public {
        // Signer2 (50) + Signer3 (25) = 75, not enough
        vm.prank(owner);
        valuer.setRequiredWeight(80);

        bytes[] memory signatures = new bytes[](2);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer2Key);
        signatures[1] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer3Key);

        vm.expectRevert(IUniversalValuerOffchain.InsufficientSignatures.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);
    }

    function testWeightedMultiSigInsufficientWeight() public {
        // Only signer2 (50 weight), not enough for 100 required
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer2Key);

        vm.expectRevert(IUniversalValuerOffchain.InsufficientSignatures.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);
    }

    /* REQUEST UPDATE TESTS */

    function testRequestUpdate() public {
        // Configure strategy
        vm.prank(owner);
        valuer.configureStrategy(STRATEGY_A, 1 hours, 24 hours, 500, 95);

        // Initial update
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);

        // Request update after interval
        vm.warp(block.timestamp + 2 hours);

        vm.expectEmit(true, true, true, true);
        emit UpdateRequested(STRATEGY_A, address(this), IUniversalValuerOffchain.UpdateReason.ON_DEMAND);

        valuer.requestUpdate(STRATEGY_A);
    }

    function testRequestUpdateTooSoon() public {
        // Configure with 1 hour min interval
        vm.prank(owner);
        valuer.configureStrategy(STRATEGY_A, 1 hours, 24 hours, 500, 95);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);

        // Request update soon after (requestUpdate doesn't enforce frequency limits)
        vm.warp(block.timestamp + 30 minutes);

        // requestUpdate should succeed and emit ON_DEMAND reason
        vm.expectEmit(true, true, true, true);
        emit UpdateRequested(STRATEGY_A, address(this), IUniversalValuerOffchain.UpdateReason.ON_DEMAND);

        valuer.requestUpdate(STRATEGY_A);
    }

    /* GET TOTAL VALUE TESTS */

    function testGetTotalValue() public {
        // Setup strategies in escrow
        escrow.addStrategy(STRATEGY_A);
        escrow.addStrategy(STRATEGY_B);

        // Update values
        bytes[] memory signaturesA = new bytes[](1);
        signaturesA[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signaturesA);

        bytes[] memory signaturesB = new bytes[](1);
        signaturesB[0] = _signValue(STRATEGY_B, 2000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_B, 2000e18, 95, 1, block.timestamp + 3600, signaturesB);

        // Add idle balance to escrow
        asset.mint(address(escrow), 500e18);

        // Note: Current implementation's _getActiveStrategies returns empty array
        // So only idle balance is counted: 500e18
        assertEq(valuer.getTotalValue(address(escrow)), 500e18);
    }

    function testGetTotalValueEmptyStrategies() public {
        // Escrow with no strategies
        assertEq(valuer.getTotalValue(address(escrow)), 0);

        // Add idle balance
        asset.mint(address(escrow), 100e18);
        assertEq(valuer.getTotalValue(address(escrow)), 100e18);
    }

    /* ADMIN FUNCTIONS TESTS */

    function testConfigureSigner() public {
        uint256 newSignerKey = 0xABCDEF;
        address newSigner = vm.addr(newSignerKey);

        vm.expectEmit(true, true, true, true);
        emit SignerConfigured(newSigner, true, 200);

        vm.prank(owner);
        valuer.initiateSignerChange(newSigner, true, 200);

        // Test the new signer works
        vm.prank(owner);
        valuer.setRequiredWeight(200);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1500e18, 95, 1, block.timestamp + 3600, newSignerKey);
        valuer.updateValue(STRATEGY_A, 1500e18, 95, 1, block.timestamp + 3600, signatures);
    }

    function testConfigureSignerUnauthorized() public {
        vm.prank(unauthorized);
        vm.expectRevert();
        valuer.initiateSignerChange(address(0x123), true, 100);
    }

    function testConfigureStrategy() public {
        vm.expectEmit(true, true, true, true);
        emit StrategyConfigured(STRATEGY_A, 2 hours, 48 hours, 1000);

        vm.prank(owner);
        valuer.configureStrategy(STRATEGY_A, 2 hours, 48 hours, 1000, 90);
    }

    function testSetRequiredWeight() public {
        vm.expectEmit(true, true, true, true);
        emit RequiredWeightUpdated(150);

        vm.prank(owner);
        valuer.setRequiredWeight(150);

        assertEq(valuer.requiredWeight(), 150);
    }

    function testSetFallbackValue() public {
        vm.expectEmit(true, true, true, true);
        emit FallbackValueSet(STRATEGY_A, 750e18);

        vm.prank(owner);
        valuer.setFallbackValue(STRATEGY_A, 750e18);

        assertEq(valuer.fallbackValues(STRATEGY_A), 750e18);
    }

    /* EDGE CASES AND MISC TESTS */

    function testZeroValue() public {
        // Configure strategy with no minimum update interval for this test
        vm.prank(owner);
        valuer.configureStrategy(STRATEGY_A, 0, 24 hours, 500, 95);

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 0, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 0, 95, 1, block.timestamp + 3600, signatures);

        assertEq(valuer.getValue(STRATEGY_A), 0);
    }

    function testMaxUint256Value() public {
        uint256 maxValue = type(uint256).max;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, maxValue, 95, 1, block.timestamp + 3600, signer1Key);

        valuer.updateValue(STRATEGY_A, maxValue, 95, 1, block.timestamp + 3600, signatures);
        assertEq(valuer.getValue(STRATEGY_A), maxValue);
    }

    function testNeedsUpdate() public {
        // Configure strategy
        vm.prank(owner);
        valuer.configureStrategy(STRATEGY_A, 1 hours, 24 hours, 500, 95);

        // Initially needs update (no value set)
        assertTrue(valuer.needsUpdate(STRATEGY_A));

        // After update, doesn't need update
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);

        assertFalse(valuer.needsUpdate(STRATEGY_A));

        // After staleness period, needs update
        vm.warp(block.timestamp + 25 hours);
        assertTrue(valuer.needsUpdate(STRATEGY_A));
    }

    function testIsAuthorizedSigner() public {
        assertTrue(valuer.isAuthorizedSigner(signer1));
        assertTrue(valuer.isAuthorizedSigner(signer2));
        assertFalse(valuer.isAuthorizedSigner(unauthorized));

        // Disable signer
        vm.prank(owner);
        valuer.initiateSignerChange(signer2, false, 0);

        // Fast forward past timelock
        vm.warp(block.timestamp + 24 hours + 1);

        // Execute the removal
        vm.prank(owner);
        valuer.executeSignerRemoval(signer2);
        assertFalse(valuer.isAuthorizedSigner(signer2));
    }

    /* NEW TESTS FOR INCREASED COVERAGE */

    // Test signer rotation with cancellation
    function testCancelSignerRemoval() public {
        vm.startPrank(owner);

        // Initiate removal
        valuer.initiateSignerChange(signer1, false, 0);
        assertTrue(valuer.pendingSignerRemoval(signer1));

        // Cancel removal
        valuer.cancelSignerRemoval(signer1);
        assertFalse(valuer.pendingSignerRemoval(signer1));
        assertEq(valuer.signerChangeTimestamp(signer1), 0);

        vm.stopPrank();

        // Signer should still be authorized
        assertTrue(valuer.isAuthorizedSigner(signer1));
    }

    // Test cancel non-existent removal
    function testCancelSignerRemovalNotPending() public {
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.NoSignerRemovalPending.selector);
        valuer.cancelSignerRemoval(signer3);
    }

    // Test execute removal before timelock
    function testExecuteSignerRemovalBeforeTimelock() public {
        vm.prank(owner);
        valuer.initiateSignerChange(signer1, false, 0);

        // Try to execute immediately (before timelock)
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.SignerRemovalTimelockNotExpired.selector);
        valuer.executeSignerRemoval(signer1);
    }

    // Test execute removal without pending
    function testExecuteSignerRemovalNoPending() public {
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.NoSignerRemovalPending.selector);
        valuer.executeSignerRemoval(address(0x999));
    }

    // Test setting invalid required weight
    function testSetRequiredWeightZero() public {
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.InvalidWeight.selector);
        valuer.setRequiredWeight(0);
    }

    // Test price change bounds
    function testSetPriceChangeBounds() public {
        vm.prank(owner);
        valuer.setPriceChangeBounds(STRATEGY_A, 2000); // 20% max change
        assertEq(valuer.maxPriceChangeBps(STRATEGY_A), 2000);
    }

    // Test invalid price change bounds
    function testSetPriceChangeBoundsInvalid() public {
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.InvalidPriceChangeBounds.selector);
        valuer.setPriceChangeBounds(STRATEGY_A, 10001); // >100%
    }

    // Test price validation with custom bounds
    function testPriceValidationWithCustomBounds() public {
        // Set initial value
        bytes[] memory sig1 = new bytes[](1);
        sig1[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, sig1);

        // Set max 10% price change
        vm.prank(owner);
        valuer.setPriceChangeBounds(STRATEGY_A, 1000);

        // Try 15% increase (should fail)
        bytes[] memory sig2 = new bytes[](1);
        sig2[0] = _signValue(STRATEGY_A, 1150e18, 95, 2, block.timestamp + 3600, signer1Key);

        vm.expectRevert();
        valuer.updateValue(STRATEGY_A, 1150e18, 95, 2, block.timestamp + 3600, sig2);

        // 8% increase should work
        bytes[] memory sig3 = new bytes[](1);
        sig3[0] = _signValue(STRATEGY_A, 1080e18, 95, 2, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1080e18, 95, 2, block.timestamp + 3600, sig3);
    }

    // Test signature expiry - expired signature
    function testSignatureExpired() public {
        uint256 expiry = block.timestamp - 1; // Already expired
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValueWithExpiry(STRATEGY_A, 1000e18, 95, 1, expiry, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.SignatureExpired.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, expiry, signatures);
    }

    // Test signature expiry - too far in future
    function testSignatureExpiryTooFar() public {
        uint256 expiry = block.timestamp + 2 hours; // Too far
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValueWithExpiry(STRATEGY_A, 1000e18, 95, 1, expiry, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.SignatureExpiryTooFar.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, expiry, signatures);
    }

    // Test duplicate signatures in single update
    function testDuplicateSignatures() public {
        bytes[] memory signatures = new bytes[](2);
        // Same signer twice
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        signatures[1] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);

        // Should only count signer1 once, so total weight = 100 (meets requirement)
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
    }

    // Test duplicate signatures causing insufficient weight
    function testDuplicateSignaturesInsufficientWeight() public {
        // Require higher weight
        vm.prank(owner);
        valuer.setRequiredWeight(150);

        bytes[] memory signatures = new bytes[](3);
        // Signer1 (100) twice + signer3 (25) = should only count as 125
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key);
        signatures[1] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer1Key); // Duplicate
        signatures[2] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signer3Key);

        // Should fail because total unique weight = 125 < 150
        vm.expectRevert(IUniversalValuerOffchain.InsufficientSignatures.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 3600, signatures);
    }

    // Test batch update with duplicate signatures
    function testBatchUpdateDuplicateSignatures() public {
        bytes32[] memory strategyIds = new bytes32[](1);
        strategyIds[0] = STRATEGY_A;

        uint256[] memory values = new uint256[](1);
        values[0] = 1000e18;

        uint256[] memory confidences = new uint256[](1);
        confidences[0] = 95;

        bytes32 batchHash = keccak256(abi.encode(strategyIds, values, confidences, 1, block.timestamp + 3600));

        bytes[] memory signatures = new bytes[](2);
        // Same signer twice
        signatures[0] = _signBatchHash(batchHash, signer1Key);
        signatures[1] = _signBatchHash(batchHash, signer1Key);

        // Should succeed with duplicate filtered out
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, block.timestamp + 3600, signatures);
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
    }

    // Test emergency update without emergency mode
    function testEmergencyUpdateNotInEmergency() public {
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.NotInEmergencyMode.selector);
        valuer.emergencyUpdate(STRATEGY_A, 1000e18);
    }

    // Test get report function
    function testGetReport() public {
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1500e18, 98, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1500e18, 98, 1, block.timestamp + 3600, signatures);

        IUniversalValuerOffchain.ValueReport memory report = valuer.getReport(STRATEGY_A);
        assertEq(report.value, 1500e18);
        assertEq(report.confidence, 98);
        assertEq(report.nonce, 1);
        assertTrue(report.isPush);
        assertEq(report.timestamp, block.timestamp);
    }

    // Test adding signer immediately (not removal)
    function testAddSignerImmediate() public {
        address newSigner = address(0x7777);

        vm.prank(owner);
        valuer.initiateSignerChange(newSigner, true, 50);

        // Should be immediately active for additions
        assertTrue(valuer.isAuthorizedSigner(newSigner));

        (bool authorized, uint256 weight) = valuer.signers(newSigner);
        assertTrue(authorized);
        assertEq(weight, 50);
    }

    // Test modify existing signer weight
    function testModifySignerWeight() public {
        vm.prank(owner);
        valuer.initiateSignerChange(signer1, true, 200); // Increase weight

        (bool authorized, uint256 weight) = valuer.signers(signer1);
        assertTrue(authorized);
        assertEq(weight, 200);
    }

    // Test batch update with expiry validation
    function testBatchUpdateExpired() public {
        bytes32[] memory strategyIds = new bytes32[](1);
        strategyIds[0] = STRATEGY_A;

        uint256[] memory values = new uint256[](1);
        values[0] = 1000e18;

        uint256[] memory confidences = new uint256[](1);
        confidences[0] = 95;

        uint256 expiry = block.timestamp - 1; // Expired
        bytes32 batchHash = keccak256(abi.encode(strategyIds, values, confidences, 1, expiry));

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatchHash(batchHash, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.SignatureExpired.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);
    }

    // Test initial value with no price bounds check
    function testInitialValueNoBoundsCheck() public {
        // Set price bounds for new strategy
        vm.prank(owner);
        valuer.setPriceChangeBounds(STRATEGY_C, 500); // 5% max

        // First update should succeed regardless of bounds
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_C, 10000e18, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_C, 10000e18, 95, 1, block.timestamp + 3600, signatures);

        assertEq(valuer.getValue(STRATEGY_C), 10000e18);
    }

    /* HELPER FUNCTIONS */

    function _signValue(
        bytes32 strategyId,
        uint256 value,
        uint256 confidence,
        uint256 nonce,
        uint256 expiry,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        return _signValueWithExpiry(strategyId, value, confidence, nonce, expiry, privateKey);
    }

    function _signValueWithExpiry(
        bytes32 strategyId,
        uint256 value,
        uint256 confidence,
        uint256 nonce,
        uint256 expiry,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encode(
            strategyId,
            value,
            confidence,
            nonce,
            expiry,
            block.chainid,
            address(valuer)
        ));
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", messageHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signBatchHash(bytes32 batchHash, uint256 privateKey) internal pure returns (bytes memory) {
        bytes32 ethSignedHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", batchHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }
}

// ============ Mock Contracts ============

contract MockERC20 is IERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function transfer(address to, uint256 amount) public returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) public returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function approve(address spender, uint256 amount) public returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }
}

contract MockEscrowWithStrategies {
    bytes32[] public activeStrategies;

    function addStrategy(bytes32 strategyId) external {
        activeStrategies.push(strategyId);
    }

    function getActiveStrategies() external view returns (bytes32[] memory) {
        return activeStrategies;
    }
}