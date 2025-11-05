// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../src/valuers/UniversalValuerOffchain.sol";
import "../../src/adapters/UniversalAdapterEscrow.sol";
import "../../src/VaultV2.sol";
import {IUniversalValuerOffchain} from "../../src/adapters/interfaces/IUniversalValuerOffchain.sol";
import {IUniversalAdapterEscrow} from "../../src/adapters/interfaces/IUniversalAdapterEscrow.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/**
 * @title UniversalValuerOffchainComprehensive
 * @notice Comprehensive test suite for UniversalValuerOffchain to achieve >90% coverage
 */
contract UniversalValuerOffchainComprehensive is Test {
    UniversalValuerOffchain public valuer;
    UniversalAdapterEscrow public adapter;
    VaultV2 public vault;
    MockERC20 public asset;

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

    uint256 constant MAX_STALENESS = 24 hours;
    uint256 constant MIN_UPDATE_INTERVAL = 5 minutes;
    uint256 constant SIGNER_TIMELOCK = 24 hours;

    event ValueUpdated(bytes32 indexed strategyId, uint256 value, uint256 confidence, uint256 timestamp, bool isPush);
    event SignerConfigured(address indexed signer, bool authorized, uint256 weight);
    event StrategyConfigured(bytes32 indexed strategyId, uint256 minUpdateInterval, uint256 maxStaleness, uint256 pushThreshold);
    event RequiredWeightUpdated(uint256 newWeight);
    event FallbackValueSet(bytes32 indexed strategyId, uint256 value);
    event EmergencyModeToggled(bool enabled);
    event UpdateRequested(bytes32 indexed strategyId, address requester, IUniversalValuerOffchain.UpdateReason reason);
    event SignerRemovalInitiated(address indexed signer, uint256 executeTimestamp);
    event SignerRemovalCancelled(address indexed signer);
    event PriceChangeBoundsSet(bytes32 indexed strategyId, uint256 maxChangeBps);
    event EmergencyValueUpdate(bytes32 indexed strategyId, uint256 value);

    function setUp() public {
        asset = new MockERC20("Test", "TST", 18);

        vm.startPrank(owner);
        vault = new VaultV2(owner, address(asset));
        valuer = new UniversalValuerOffchain(owner, address(asset));
        vm.stopPrank();

        adapter = new UniversalAdapterEscrow(address(vault), address(valuer), false);

        // Setup signers
        signer1 = vm.addr(signer1Key);
        signer2 = vm.addr(signer2Key);
        signer3 = vm.addr(signer3Key);

        vm.startPrank(owner);
        // Initialize signers - adding signers is immediate when authorized=true
        valuer.initiateSignerChange(signer1, true, 100);
        valuer.initiateSignerChange(signer2, true, 50);
        valuer.initiateSignerChange(signer3, true, 25);

        valuer.setRequiredWeight(100);

        // Configure strategies (L-05 FIX: Use parameters that meet validation requirements)
        valuer.configureStrategy(STRATEGY_A, MIN_UPDATE_INTERVAL, MAX_STALENESS, 500, 95);
        valuer.configureStrategy(STRATEGY_B, MIN_UPDATE_INTERVAL, MAX_STALENESS, 500, 95);
        valuer.configureStrategy(STRATEGY_C, MIN_UPDATE_INTERVAL, MAX_STALENESS, 500, 95);
        vm.stopPrank();
    }

    /* SINGLE VALUE UPDATE TESTS */

    function testUpdateValue() public {
        uint256 value = 1000e18;
        uint256 confidence = 95;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, value, confidence, nonce, expiry, signer1Key);

        vm.expectEmit(true, true, true, true);
        emit ValueUpdated(STRATEGY_A, value, confidence, block.timestamp, true);

        valuer.updateValue(STRATEGY_A, value, confidence, nonce, expiry, signatures);

        assertEq(valuer.getValue(STRATEGY_A), value);

        IUniversalValuerOffchain.ValueReport memory report = valuer.getReport(STRATEGY_A);
        assertEq(report.value, value);
        assertEq(report.confidence, confidence);
        assertEq(report.timestamp, block.timestamp);
        assertEq(report.nonce, nonce);
    }

    function testUpdateValueMultipleSigners() public {
        // Need signer1 (weight 100) or signer2+signer3 (weight 50+25=75, insufficient)
        uint256 value = 2000e18;
        uint256 confidence = 98;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        // Test with signer2 + signer3 (insufficient weight)
        bytes[] memory insufficientSigs = new bytes[](2);
        insufficientSigs[0] = _signValue(STRATEGY_B, value, confidence, nonce, expiry, signer2Key);
        insufficientSigs[1] = _signValue(STRATEGY_B, value, confidence, nonce, expiry, signer3Key);

        vm.expectRevert(IUniversalValuerOffchain.InsufficientSignatures.selector);
        valuer.updateValue(STRATEGY_B, value, confidence, nonce, expiry, insufficientSigs);

        // Test with signer1 (sufficient weight)
        bytes[] memory sufficientSigs = new bytes[](1);
        sufficientSigs[0] = _signValue(STRATEGY_B, value, confidence, nonce, expiry, signer1Key);

        valuer.updateValue(STRATEGY_B, value, confidence, nonce, expiry, sufficientSigs);
        assertEq(valuer.getValue(STRATEGY_B), value);
    }

    function testUpdateValueStaleNonce() public {
        // First update
        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signValue(STRATEGY_A, 1000e18, 95, 2, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 2, block.timestamp + 1 hours, signatures1);

        // Try with old nonce (should revert with StaleNonce)
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(STRATEGY_A, 2000e18, 95, 1, block.timestamp + 1 hours, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.StaleNonce.selector);
        valuer.updateValue(STRATEGY_A, 2000e18, 95, 1, block.timestamp + 1 hours, signatures2);

        // Value should still be from first update
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
    }

    /**
     * @notice Test L-02 fix: Nonce gap validation prevents excessive nonce jumps
     * @dev This validates the security fix ensuring nonce cannot jump too far ahead
     */
    function testUpdateValueNonceGapWithinLimit() public {
        // L-02 SECURITY FIX: Test normal nonce progression within MAX_NONCE_GAP (1000)

        // First update with nonce 1
        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures1);

        // Second update with nonce 1001 (exactly MAX_NONCE_GAP away) - should succeed
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(STRATEGY_A, 1100e18, 95, 1001, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1100e18, 95, 1001, block.timestamp + 1 hours, signatures2);

        IUniversalValuerOffchain.ValueReport memory report = valuer.getReport(STRATEGY_A);
        assertEq(report.nonce, 1001, "Nonce should be updated to 1001");
        assertEq(valuer.getValue(STRATEGY_A), 1100e18);
    }

    /**
     * @notice Test L-02 fix: Nonce gap exceeding MAX_NONCE_GAP should revert
     * @dev Prevents setting nonce to max value which would brick emergencyUpdate
     */
    function testUpdateValueNonceGapExceedsLimit() public {
        // L-02 SECURITY FIX: Test that nonce cannot jump more than MAX_NONCE_GAP (1000)

        // First update with nonce 1
        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures1);

        // Try update with nonce 1002 (MAX_NONCE_GAP + 1) - should revert
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(STRATEGY_A, 1100e18, 95, 1002, block.timestamp + 1 hours, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.NonceGapTooLarge.selector);
        valuer.updateValue(STRATEGY_A, 1100e18, 95, 1002, block.timestamp + 1 hours, signatures2);

        // Value should still be from first update
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
        IUniversalValuerOffchain.ValueReport memory report = valuer.getReport(STRATEGY_A);
        assertEq(report.nonce, 1, "Nonce should still be 1");
    }

    /**
     * @notice Test L-02 fix: Prevent nonce from being set to max value
     * @dev Setting nonce to type(uint256).max would cause emergencyUpdate to overflow
     */
    function testUpdateValueNonceMaxValue() public {
        // L-02 SECURITY FIX: Setting nonce to type(uint256).max would brick emergencyUpdate
        // because emergencyUpdate does: nonce + 1, which would overflow

        // First update with nonce 1
        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures1);

        // Try to set nonce to type(uint256).max - should revert due to gap check
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(STRATEGY_A, 1100e18, 95, type(uint256).max, block.timestamp + 1 hours, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.NonceGapTooLarge.selector);
        valuer.updateValue(STRATEGY_A, 1100e18, 95, type(uint256).max, block.timestamp + 1 hours, signatures2);

        // Value should still be from first update
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
    }

    /**
     * @notice Test L-02 fix: Batch update nonce gap validation
     * @dev Same nonce gap validation should apply to batch updates
     */
    function testBatchUpdateNonceGapExceedsLimit() public {
        // L-02 SECURITY FIX: Batch updates should also validate nonce gap

        // First update for both strategies
        bytes32[] memory strategyIds1 = new bytes32[](2);
        strategyIds1[0] = STRATEGY_A;
        strategyIds1[1] = STRATEGY_B;

        uint256[] memory values1 = new uint256[](2);
        values1[0] = 1000e18;
        values1[1] = 2000e18;

        uint256[] memory confidences1 = new uint256[](2);
        confidences1[0] = 95;
        confidences1[1] = 95;

        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signBatch(strategyIds1, values1, confidences1, 1, block.timestamp + 1 hours, signer1Key);
        valuer.batchUpdateValues(strategyIds1, values1, confidences1, 1, block.timestamp + 1 hours, signatures1);

        // Try batch update with nonce gap > MAX_NONCE_GAP - should revert
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signBatch(strategyIds1, values1, confidences1, 1002, block.timestamp + 1 hours, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.NonceGapTooLarge.selector);
        valuer.batchUpdateValues(strategyIds1, values1, confidences1, 1002, block.timestamp + 1 hours, signatures2);

        // Values should still be from first update
        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
        assertEq(valuer.getValue(STRATEGY_B), 2000e18);
    }

    function testUpdateValueExpiredSignature() public {
        uint256 expiry = block.timestamp - 1; // Already expired
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, expiry, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.SignatureExpired.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, expiry, signatures);
    }

    function testUpdateValueTooFarExpiry() public {
        uint256 expiry = block.timestamp + 2 hours; // Too far in future
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, expiry, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.SignatureExpiryTooFar.selector);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, expiry, signatures);
    }

    function testUpdateValueMinInterval() public {
        // First update
        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures1);

        // Try immediate update with small price change (should fail due to min interval)
        // The change is 0.1% which is below the 5% push threshold
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(STRATEGY_A, 1001e18, 95, 2, block.timestamp + 1 hours, signer1Key);

        vm.expectRevert(IUniversalValuerOffchain.UpdateTooFrequent.selector);
        valuer.updateValue(STRATEGY_A, 1001e18, 95, 2, block.timestamp + 1 hours, signatures2);

        // Fast forward past the configured min interval (1 hour for STRATEGY_A)
        vm.warp(block.timestamp + 1 hours + 1);

        // Now it should work (need new signature with updated expiry after warp)
        uint256 newExpiry = block.timestamp + 30 minutes; // Valid expiry within MAX_SIGNATURE_AGE (1 hour)
        bytes[] memory signatures3 = new bytes[](1);
        signatures3[0] = _signValue(STRATEGY_A, 1001e18, 95, 3, newExpiry, signer1Key);
        valuer.updateValue(STRATEGY_A, 1001e18, 95, 3, newExpiry, signatures3);
        assertEq(valuer.getValue(STRATEGY_A), 1001e18);
    }

    /* BATCH UPDATE TESTS */

    function testBatchUpdateValues() public {
        bytes32[] memory strategyIds = new bytes32[](3);
        strategyIds[0] = STRATEGY_A;
        strategyIds[1] = STRATEGY_B;
        strategyIds[2] = STRATEGY_C;

        uint256[] memory values = new uint256[](3);
        values[0] = 1000e18;
        values[1] = 2000e18;
        values[2] = 3000e18;

        uint256[] memory confidences = new uint256[](3);
        confidences[0] = 95;
        confidences[1] = 98;
        confidences[2] = 96; // Use 96% to meet global defaultConfidenceThreshold (95%)

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatch(strategyIds, values, confidences, nonce, expiry, signer1Key);

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        assertEq(valuer.getValue(STRATEGY_A), 1000e18);
        assertEq(valuer.getValue(STRATEGY_B), 2000e18);
        assertEq(valuer.getValue(STRATEGY_C), 3000e18);
    }

    function testBatchUpdateValuesArrayMismatch() public {
        bytes32[] memory strategyIds = new bytes32[](2);
        uint256[] memory values = new uint256[](3); // Mismatch!
        uint256[] memory confidences = new uint256[](3);
        bytes[] memory signatures = new bytes[](1);

        vm.expectRevert(IUniversalValuerOffchain.ArrayLengthMismatch.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, block.timestamp + 1 hours, signatures);
    }

    /* REQUEST UPDATE TESTS */

    function testRequestUpdate() public {
        // Setup initial value
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures);

        // Fast forward to make it stale
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        vm.expectEmit(true, true, true, true);
        emit UpdateRequested(STRATEGY_A, address(this), IUniversalValuerOffchain.UpdateReason.STALENESS);

        valuer.requestUpdate(STRATEGY_A);
    }

    function testNeedsUpdate() public {
        // Setup initial value
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures);

        // Initially doesn't need update
        assertFalse(valuer.needsUpdate(STRATEGY_A));

        // Fast forward to make it stale
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        // Now needs update
        assertTrue(valuer.needsUpdate(STRATEGY_A));
    }

    /* SIGNER MANAGEMENT TESTS */

    function testInitiateSignerChange() public {
        address newSigner = address(0x123);

        vm.startPrank(owner);

        // First add the signer
        vm.expectEmit(true, true, true, true);
        emit SignerConfigured(newSigner, true, 50);
        valuer.initiateSignerChange(newSigner, true, 50);
        assertTrue(valuer.isAuthorizedSigner(newSigner));

        // Then test removal initiation
        vm.expectEmit(true, true, true, true);
        emit SignerRemovalInitiated(newSigner, block.timestamp + SIGNER_TIMELOCK);
        valuer.initiateSignerChange(newSigner, false, 0);

        // Check pending state
        assertTrue(valuer.pendingSignerRemoval(newSigner));
        assertEq(valuer.signerChangeTimestamp(newSigner), block.timestamp + SIGNER_TIMELOCK);

        vm.stopPrank();
    }

    function testExecuteSignerRemoval() public {
        address signerToRemove = signer3;

        vm.startPrank(owner);

        // Initiate removal
        valuer.initiateSignerChange(signerToRemove, false, 0);

        // Try immediate execution (should fail)
        vm.expectRevert(IUniversalValuerOffchain.SignerRemovalTimelockNotExpired.selector);
        valuer.executeSignerRemoval(signerToRemove);

        // Fast forward
        vm.warp(block.timestamp + SIGNER_TIMELOCK + 1);

        // Now should work
        valuer.executeSignerRemoval(signerToRemove);

        // Verify removed
        assertFalse(valuer.isAuthorizedSigner(signerToRemove));

        vm.stopPrank();
    }

    function testCancelSignerRemoval() public {
        address newSigner = address(0x123);

        vm.startPrank(owner);

        // First authorize the signer
        valuer.initiateSignerChange(newSigner, true, 50);
        assertTrue(valuer.isAuthorizedSigner(newSigner));

        // Then initiate removal (this sets pendingSignerRemoval)
        valuer.initiateSignerChange(newSigner, false, 0);
        assertTrue(valuer.pendingSignerRemoval(newSigner));

        vm.expectEmit(true, true, true, true);
        emit SignerRemovalCancelled(newSigner);

        valuer.cancelSignerRemoval(newSigner);
        assertFalse(valuer.pendingSignerRemoval(newSigner));

        vm.stopPrank();
    }

    /* CONFIGURATION TESTS */

    function testConfigureStrategy() public {
        bytes32 newStrategy = keccak256("NEW_STRATEGY");

        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit StrategyConfigured(newStrategy, 2 hours, 24 hours, 1000);

        // L-05 FIX: Use valid parameters that meet validation requirements
        valuer.configureStrategy(newStrategy, 2 hours, 24 hours, 1000, 95);

        // Check the configuration was set (public mapping returns tuple)
        (uint256 minInterval, uint256 maxStale, uint256 threshold, uint256 minConf) = valuer.updateConfigs(newStrategy);
        assertEq(minInterval, 2 hours);
        assertEq(maxStale, 24 hours);
        assertEq(threshold, 1000);
        assertEq(minConf, 95);

        vm.stopPrank();
    }

    function testSetRequiredWeight() public {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit RequiredWeightUpdated(150);

        valuer.setRequiredWeight(150);
        assertEq(valuer.requiredWeight(), 150);

        vm.stopPrank();
    }

    function testSetPriceChangeBounds() public {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit PriceChangeBoundsSet(STRATEGY_A, 2000);

        valuer.setPriceChangeBounds(STRATEGY_A, 2000);
        assertEq(valuer.maxPriceChangeBps(STRATEGY_A), 2000);

        vm.stopPrank();
    }

    /**
     * @notice Test L-01 fix: setPriceChangeBounds should enforce MAX_PRICE_CHANGE_BPS as absolute upper limit
     * @dev This validates the security fix ensuring maxChangeBps cannot exceed MAX_PRICE_CHANGE_BPS (50%)
     */
    function testSetPriceChangeBoundsExceedsMaximum() public {
        vm.startPrank(owner);

        // L-01 SECURITY FIX: Attempting to set maxChangeBps above MAX_PRICE_CHANGE_BPS (5000 = 50%) should revert
        vm.expectRevert(IUniversalValuerOffchain.InvalidPriceChangeBounds.selector);
        valuer.setPriceChangeBounds(STRATEGY_A, 5001); // Just above 50% limit

        vm.expectRevert(IUniversalValuerOffchain.InvalidPriceChangeBounds.selector);
        valuer.setPriceChangeBounds(STRATEGY_A, 7000); // 70% - should not be allowed

        vm.expectRevert(IUniversalValuerOffchain.InvalidPriceChangeBounds.selector);
        valuer.setPriceChangeBounds(STRATEGY_A, 10000); // 100% - BASIS_POINTS but above MAX_PRICE_CHANGE_BPS

        // Setting exactly at MAX_PRICE_CHANGE_BPS should succeed
        vm.expectEmit(true, true, true, true);
        emit PriceChangeBoundsSet(STRATEGY_A, 5000);
        valuer.setPriceChangeBounds(STRATEGY_A, 5000); // Exactly 50% - should succeed
        assertEq(valuer.maxPriceChangeBps(STRATEGY_A), 5000);

        // Setting below MAX_PRICE_CHANGE_BPS should also succeed
        vm.expectEmit(true, true, true, true);
        emit PriceChangeBoundsSet(STRATEGY_B, 3000);
        valuer.setPriceChangeBounds(STRATEGY_B, 3000); // 30% - should succeed
        assertEq(valuer.maxPriceChangeBps(STRATEGY_B), 3000);

        vm.stopPrank();
    }

    function testSetFallbackValue() public {
        uint256 fallbackValue = 500e18;

        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit FallbackValueSet(STRATEGY_A, fallbackValue);

        valuer.setFallbackValue(STRATEGY_A, fallbackValue);
        assertEq(valuer.fallbackValues(STRATEGY_A), fallbackValue);

        vm.stopPrank();
    }

    /* EMERGENCY MODE TESTS */

    function testSetEmergencyMode() public {
        vm.startPrank(owner);

        vm.expectEmit(true, true, true, true);
        emit EmergencyModeToggled(true);

        valuer.setEmergencyMode(true);
        assertTrue(valuer.emergencyMode());

        // Set up a value report first
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.setEmergencyMode(false); // Temporarily disable to allow update
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures);
        valuer.setEmergencyMode(true); // Re-enable emergency mode

        // Make the report stale by warping time
        vm.warp(block.timestamp + 25 hours); // Beyond MAX_STALENESS (24 hours)

        // Set fallback value - should be used when report is stale
        valuer.setFallbackValue(STRATEGY_A, 999e18);
        assertEq(valuer.getValue(STRATEGY_A), 999e18);

        vm.stopPrank();
    }

    function testEmergencyUpdate() public {
        vm.startPrank(owner);

        valuer.setEmergencyMode(true);

        vm.expectEmit(true, true, true, true);
        emit EmergencyValueUpdate(STRATEGY_A, 5000e18);

        valuer.emergencyUpdate(STRATEGY_A, 5000e18);

        IUniversalValuerOffchain.ValueReport memory report = valuer.getReport(STRATEGY_A);
        assertEq(report.value, 5000e18);
        assertEq(report.confidence, 100); // Emergency updates have full confidence

        vm.stopPrank();
    }

    function testEmergencyUpdateNotInEmergencyMode() public {
        vm.startPrank(owner);

        vm.expectRevert(IUniversalValuerOffchain.NotInEmergencyMode.selector);
        valuer.emergencyUpdate(STRATEGY_A, 5000e18);

        vm.stopPrank();
    }

    function testRequestUpdateBlockedInEmergencyMode() public {
        // L-06 FIX: Test that requestUpdate is blocked during emergency mode
        vm.startPrank(owner);
        valuer.setEmergencyMode(true);
        vm.stopPrank();

        // Attempt to call requestUpdate during emergency mode should revert
        vm.expectRevert(IUniversalValuerOffchain.EmergencyMode.selector);
        valuer.requestUpdate(STRATEGY_A);
    }

    /* ACCESS CONTROL TESTS */

    function testOnlyOwnerFunctions() public {
        vm.startPrank(unauthorized);

        vm.expectRevert(IUniversalValuerOffchain.NotAuthorized.selector);
        valuer.initiateSignerChange(address(0x123), true, 50);

        vm.expectRevert(IUniversalValuerOffchain.NotAuthorized.selector);
        valuer.executeSignerRemoval(signer1);

        vm.expectRevert(IUniversalValuerOffchain.NotAuthorized.selector);
        valuer.setRequiredWeight(100);

        vm.expectRevert(IUniversalValuerOffchain.NotAuthorized.selector);
        valuer.setEmergencyMode(true);

        vm.stopPrank();
    }

    /* GET TOTAL VALUE TESTS */

    function testGetTotalValue() public {
        // Create a simple mock adapter that returns STRATEGY_A as active
        SimpleMockAdapter mockAdapter = new SimpleMockAdapter();

        // Setup some values
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures);

        // Give mock adapter some idle assets
        asset.mint(address(mockAdapter), 500e18);

        uint256 totalValue = valuer.getTotalValue(address(mockAdapter));
        // Should be strategy value (1000e18) + idle assets (500e18)
        assertEq(totalValue, 1500e18);
    }

    function testGetTotalValueStaleReports() public {
        // Create a simple mock adapter that returns STRATEGY_A as active
        SimpleMockAdapter mockAdapter = new SimpleMockAdapter();

        // Setup value
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures);

        // Fast forward to make stale
        vm.warp(block.timestamp + MAX_STALENESS + 1);

        uint256 totalValue = valuer.getTotalValue(address(mockAdapter));
        // SECURITY FIX: Should still return last known value even if stale to prevent manipulation
        // This prevents malicious users from exploiting price drops when values go stale
        assertEq(totalValue, 1000e18);
    }

    function testGetTotalValueLowConfidence() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(40);

        // Configure strategy to accept low confidence updates for this test
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            1000,
            50  // Allow 50% confidence for this test
        );
        vm.stopPrank();

        // Create a simple mock adapter that returns STRATEGY_A as active
        SimpleMockAdapter mockAdapter = new SimpleMockAdapter();

        // Setup value with low confidence
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 50, 1, block.timestamp + 1 hours, signer1Key); // Low confidence
        valuer.updateValue(STRATEGY_A, 1000e18, 50, 1, block.timestamp + 1 hours, signatures);

        uint256 totalValue = valuer.getTotalValue(address(mockAdapter));
        // SECURITY FIX: Should still return value even with low confidence to prevent manipulation
        // This prevents malicious users from exploiting price drops when confidence is low
        assertEq(totalValue, 1000e18);
    }

    /* VIEW FUNCTION TESTS */

    function testGetValue() public {
        // SECURITY FIX (security_issues_5nov2025_3.md Issue #1): No value set - should revert with ValueTooStale
        // Changed from LowConfidence because uninitialized reports (timestamp==0) now check fallback first
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.getValue(STRATEGY_A);

        // Set value
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1234e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1234e18, 95, 1, block.timestamp + 1 hours, signatures);

        assertEq(valuer.getValue(STRATEGY_A), 1234e18);
    }

    function testIsAuthorizedSigner() public {
        assertTrue(valuer.isAuthorizedSigner(signer1));
        assertTrue(valuer.isAuthorizedSigner(signer2));
        assertTrue(valuer.isAuthorizedSigner(signer3));
        assertFalse(valuer.isAuthorizedSigner(unauthorized));
    }

    /* PRICE VALIDATION TESTS */

    function testPriceChangeBoundsValidation() public {
        vm.startPrank(owner);
        // Set 10% max price change
        valuer.setPriceChangeBounds(STRATEGY_A, 1000);
        vm.stopPrank();

        // First update
        bytes[] memory signatures1 = new bytes[](1);
        signatures1[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures1);

        vm.warp(block.timestamp + MIN_UPDATE_INTERVAL + 1);

        // Try update with >10% change (should fail)
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(STRATEGY_A, 1200e18, 95, 2, block.timestamp + 1 hours, signer1Key);

        // Price change exceeds bounds - don't check exact values
        vm.expectRevert();
        valuer.updateValue(STRATEGY_A, 1200e18, 95, 2, block.timestamp + 1 hours, signatures2);

        // Update with <10% change (should work)
        bytes[] memory signatures3 = new bytes[](1);
        signatures3[0] = _signValue(STRATEGY_A, 1050e18, 95, 2, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1050e18, 95, 2, block.timestamp + 1 hours, signatures3);

        assertEq(valuer.getValue(STRATEGY_A), 1050e18);
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
        bytes32 messageHash = keccak256(abi.encode(
            strategyId,
            value,
            confidence,
            nonce,
            expiry,
            block.chainid,
            address(valuer)
        ));

        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _signBatch(
        bytes32[] memory strategyIds,
        uint256[] memory values,
        uint256[] memory confidences,
        uint256 nonce,
        uint256 expiry,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        // Include domain separation to prevent cross-chain/cross-instance replay
        bytes32 batchHash = keccak256(abi.encode(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            block.chainid,
            address(valuer)
        ));

        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            batchHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedHash);
        return abi.encodePacked(r, s, v);
    }

    function _mockAllocation() internal {
        // Setup vault and allocate to make strategy active
        asset.mint(address(vault), 100e18);

        vm.startPrank(owner);
        vault.setCurator(owner);

        // Add adapter through timelock
        bytes memory addAdapterCall = abi.encodeWithSelector(vault.addAdapter.selector, address(adapter));
        vault.submit(addAdapterCall);
        vm.warp(block.timestamp + 1);
        vault.addAdapter(address(adapter));

        // Set allocator role
        bytes memory setAllocatorCall = abi.encodeWithSelector(vault.setIsAllocator.selector, owner, true);
        vault.submit(setAllocatorCall);
        vm.warp(block.timestamp + 1);
        vault.setIsAllocator(owner, true);

        // Set caps
        bytes memory idData = bytes("STRATEGY_A");
        bytes memory setAbsCapCall = abi.encodeWithSelector(vault.increaseAbsoluteCap.selector, idData, 1000e18);
        vault.submit(setAbsCapCall);
        vm.warp(block.timestamp + 1);
        vault.increaseAbsoluteCap(idData, 1000e18);

        bytes memory setRelCapCall = abi.encodeWithSelector(vault.increaseRelativeCap.selector, idData, 1e18);
        vault.submit(setRelCapCall);
        vm.warp(block.timestamp + 1);
        vault.increaseRelativeCap(idData, 1e18);

        // Allocate
        bytes memory allocData = abi.encode(
            STRATEGY_A,
            100e18,
            false,
            new IUniversalAdapterEscrow.Call[](0)
        );
        vault.allocate(address(adapter), allocData, 100e18);

        vm.stopPrank();
    }

    /**
     * @notice Test M-05 fix: Pending signer deactivation should exclude signers from verification
     */
    function testPendingSignerDeactivationExcluded() public {
        // Setup initial signer
        uint256 signerKey = 0x1234;
        address testSigner = vm.addr(signerKey);

        vm.prank(owner);
        valuer.initiateSignerChange(testSigner, true, 100);

        // Set required weight to 100 (so we need testSigner's signature)
        vm.prank(owner);
        valuer.setRequiredWeight(100);

        // Configure strategy
        vm.prank(owner);
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,    // minUpdateInterval
            24 hours,     // maxStaleness (at maximum allowed)
            1000,         // pushThreshold (10%)
            95            // minConfidence
        );

        // Create a valid signature for value update
        uint256 value = 1000e18;
        uint256 confidence = 95;
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 30 minutes;

        bytes32 messageHash = keccak256(abi.encode(
            STRATEGY_A,
            value,
            confidence,
            nonce,
            expiry,
            block.chainid,
            address(valuer)
        ));

        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, ethSignedHash);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);

        // First: Update should succeed with active signer
        valuer.updateValue(STRATEGY_A, value, confidence, nonce, expiry, signatures);
        assertEq(valuer.getValue(STRATEGY_A), value, "Initial update should succeed");

        // Now initiate signer removal (sets pending deactivation)
        vm.prank(owner);
        valuer.initiateSignerChange(testSigner, false, 0);

        // Check that signer is still authorized but has pending deactivation
        assertTrue(valuer.isAuthorizedSigner(testSigner), "Signer should still be authorized");
        assertTrue(valuer.signerChangeTimestamp(testSigner) > block.timestamp, "Should have future deactivation timestamp");

        // Advance time to exactly match signer timelock expiry (24 hours)
        vm.warp(block.timestamp + 24 hours); // Exactly at 24-hour SIGNER_TIMELOCK expiry

        // Note: isAuthorizedSigner() only checks basic authorization, not pending removal
        // The actual exclusion logic is in _verifySignatures during updateValue

        // Try to update with pending deactivated signer - should fail
        // Use a small price change to avoid price bounds validation
        uint256 testValue = 1001e18; // Only 0.1% change
        uint256 testNonce = 2;
        uint256 currentTime = block.timestamp;
        uint256 testExpiry = currentTime + 59 minutes; // Maximum allowed (just under 1 hour)

        bytes32 testMessageHash = keccak256(abi.encode(
            STRATEGY_A,
            testValue,
            confidence,
            testNonce,
            testExpiry,
            block.chainid,
            address(valuer)
        ));

        bytes32 testEthSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            testMessageHash
        ));

        (uint8 testV, bytes32 testR, bytes32 testS) = vm.sign(signerKey, testEthSignedHash);
        bytes[] memory testSignatures = new bytes[](1);
        testSignatures[0] = abi.encodePacked(testR, testS, testV);

        // This should fail because signer has pending deactivation and timelock expired
        vm.expectRevert(IUniversalValuerOffchain.InsufficientSignatures.selector);
        valuer.updateValue(STRATEGY_A, testValue, confidence, testNonce, testExpiry, testSignatures);

        // Verify the value wasn't updated
        assertEq(valuer.getValue(STRATEGY_A), value, "Value should not be updated with pending deactivated signer");
    }

    /**
     * @notice Test M-06 fix: Confidence check should reject updates with insufficient confidence
     */
    function testLowConfidenceRejected() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // Configure strategy with minimum confidence requirement
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,    // minUpdateInterval
            24 hours,     // maxStaleness
            1000,         // pushThreshold (10%)
            90            // minConfidence - require at least 90% confidence
        );
        vm.stopPrank();

        // Create a valid signature for value update with low confidence
        uint256 value = 1000e18;
        uint256 lowConfidence = 50;  // Only 50% confidence, below the 90% requirement
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 30 minutes;

        bytes32 messageHash = keccak256(abi.encode(
            STRATEGY_A,
            value,
            lowConfidence,
            nonce,
            expiry,
            block.chainid,
            address(valuer)
        ));

        bytes32 ethSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            messageHash
        ));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signer1Key, ethSignedHash);
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = abi.encodePacked(r, s, v);

        // Should revert due to low confidence
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.updateValue(STRATEGY_A, value, lowConfidence, nonce, expiry, signatures);

        // Now try with sufficient confidence (95% to meet both strategy and global requirements)
        uint256 goodConfidence = 95;
        uint256 newNonce = 2;

        bytes32 newMessageHash = keccak256(abi.encode(
            STRATEGY_A,
            value,
            goodConfidence,
            newNonce,
            expiry,
            block.chainid,
            address(valuer)
        ));

        bytes32 newEthSignedHash = keccak256(abi.encodePacked(
            "\x19Ethereum Signed Message:\n32",
            newMessageHash
        ));

        (uint8 v2, bytes32 r2, bytes32 s2) = vm.sign(signer1Key, newEthSignedHash);
        signatures[0] = abi.encodePacked(r2, s2, v2);

        // This should succeed with sufficient confidence
        valuer.updateValue(STRATEGY_A, value, goodConfidence, newNonce, expiry, signatures);
        assertEq(valuer.getValue(STRATEGY_A), value, "Value should be updated with sufficient confidence");
    }

    /**
     * @notice Test M-06 fix for batch updates: Should reject batch updates with insufficient confidence
     */
    function testBatchUpdateLowConfidenceRejected() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // Configure strategies with minimum confidence requirements
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,    // minUpdateInterval
            24 hours,     // maxStaleness
            1000,         // pushThreshold
            85            // minConfidence - require at least 85% confidence
        );

        valuer.configureStrategy(
            STRATEGY_B,
            5 minutes,
            24 hours,
            1000,
            90            // minConfidence - require at least 90% confidence
        );
        vm.stopPrank();

        // Prepare batch update with one strategy having low confidence
        bytes32[] memory strategyIds = new bytes32[](2);
        uint256[] memory values = new uint256[](2);
        uint256[] memory confidences = new uint256[](2);

        strategyIds[0] = STRATEGY_A;
        strategyIds[1] = STRATEGY_B;
        values[0] = 1000e18;
        values[1] = 2000e18;
        confidences[0] = 85;  // Meets STRATEGY_A requirement
        confidences[1] = 80;  // Below STRATEGY_B requirement (90)

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        // Should revert due to STRATEGY_B's low confidence
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        // Now try with sufficient confidence for both
        confidences[0] = 95;  // Meets both STRATEGY_A (85) and global (95) requirements
        confidences[1] = 95;  // Meets both STRATEGY_B (90) and global (95) requirements

        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        // This should succeed
        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);
        assertEq(valuer.getValue(STRATEGY_A), values[0], "STRATEGY_A should be updated");
        assertEq(valuer.getValue(STRATEGY_B), values[1], "STRATEGY_B should be updated");
    }

    /**
     * @notice Test M-08 fix: configureStrategy should reject when pushThreshold > maxPriceChangeBps
     */
    function testPushThresholdExceedsMaxChangeBounds() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // First set a price change bound
        valuer.setPriceChangeBounds(STRATEGY_A, 2000); // 20% max change

        // Try to configure strategy with pushThreshold > maxPriceChangeBps
        vm.expectRevert(abi.encodeWithSelector(
            IUniversalValuerOffchain.PushThresholdExceedsMaxChange.selector,
            3000, // pushThreshold
            2000  // maxChange
        ));
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            3000, // 30% pushThreshold > 20% maxChange
            90
        );
        vm.stopPrank();

        // Should work when pushThreshold <= maxPriceChangeBps
        vm.prank(owner);
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            1500, // 15% pushThreshold <= 20% maxChange
            90
        );
    }

    /**
     * @notice Test M-08 fix: setPriceChangeBounds should reject when bounds conflict with existing pushThreshold
     */
    function testPriceChangeBoundsConflictWithPushThreshold() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // First configure strategy with pushThreshold
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            3000, // 30% pushThreshold
            90
        );
        vm.stopPrank();

        // Try to set price bounds lower than existing pushThreshold
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(
            IUniversalValuerOffchain.PushThresholdExceedsMaxChange.selector,
            3000, // pushThreshold
            2000  // maxChange
        ));
        valuer.setPriceChangeBounds(STRATEGY_A, 2000); // 20% < 30%

        // Should work when bounds >= pushThreshold
        vm.prank(owner);
        valuer.setPriceChangeBounds(STRATEGY_A, 3500); // 35% >= 30%
    }

    /**
     * @notice Test M-08 fix: pushThreshold validation with default MAX_PRICE_CHANGE_BPS
     */
    function testPushThresholdWithDefaultMaxChange() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // Try to configure strategy with pushThreshold > default MAX_PRICE_CHANGE_BPS (50%)
        // L-05 FIX: This will now trigger InvalidPriceChangeBounds before PushThresholdExceedsMaxChange
        vm.expectRevert(IUniversalValuerOffchain.InvalidPriceChangeBounds.selector);
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            6000, // 60% pushThreshold > 50% default MAX_PRICE_CHANGE_BPS
            90
        );
        vm.stopPrank();

        // Should work when pushThreshold <= default MAX_PRICE_CHANGE_BPS
        vm.prank(owner);
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            4000, // 40% pushThreshold <= 50% default
            90
        );
    }

    /**
     * @notice Test L-01 fix: Verify price bounds validation works with optimized calculation
     */
    function testOptimizedPriceBoundsValidation() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // Configure strategy with price bounds
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            3000, // 30% pushThreshold
            90
        );
        vm.stopPrank();

        vm.prank(owner);
        valuer.setPriceChangeBounds(STRATEGY_A, 4000); // 40% max change

        // First update to establish a baseline
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000e18, 95, 1, block.timestamp + 1 hours, signatures);

        // Update with change that exceeds price bounds (should revert)
        vm.warp(block.timestamp + 6 minutes); // Bypass update interval
        signatures[0] = _signValue(STRATEGY_A, 1500e18, 95, 2, block.timestamp + 1 hours, signer1Key); // 50% increase > 40% limit

        vm.expectRevert(abi.encodeWithSelector(
            IUniversalValuerOffchain.PriceChangeExceedsBounds.selector,
            5000, // 50% change
            4000  // 40% limit
        ));
        valuer.updateValue(STRATEGY_A, 1500e18, 95, 2, block.timestamp + 1 hours, signatures);

        // Update with change within bounds (should succeed)
        signatures[0] = _signValue(STRATEGY_A, 1300e18, 95, 3, block.timestamp + 1 hours, signer1Key); // 30% increase < 40% limit
        valuer.updateValue(STRATEGY_A, 1300e18, 95, 3, block.timestamp + 1 hours, signatures);

        assertEq(valuer.getValue(STRATEGY_A), 1300e18, "Value should be updated");
    }

    /**
     * @notice Test L-02 fix: Verify batchUpdateValues includes all missing validation checks
     */
    function testBatchUpdateValuesValidationChecks() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // Configure strategies with different parameters
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,  // minUpdateInterval
            24 hours,   // maxStaleness
            2000,       // 20% pushThreshold
            90          // minConfidence
        );

        valuer.configureStrategy(
            STRATEGY_B,
            10 minutes, // different minUpdateInterval
            24 hours,
            3000,       // 30% pushThreshold
            95          // minConfidence
        );

        // Set price bounds
        valuer.setPriceChangeBounds(STRATEGY_A, 5000); // 50% max change
        valuer.setPriceChangeBounds(STRATEGY_B, 4000); // 40% max change
        vm.stopPrank();

        // Initial batch update to establish baseline
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = STRATEGY_A;
        strategyIds[1] = STRATEGY_B;

        uint256[] memory values = new uint256[](2);
        values[0] = 1000e18;
        values[1] = 2000e18;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 95; // Meets both strategy and global requirements
        confidences[1] = 95;

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        // Advance time by 3 minutes (less than both strategies' intervals)
        vm.warp(block.timestamp + 3 minutes);

        // Attempt batch update with changes below push threshold
        values[0] = 1010e18; // 1% change < 20% pushThreshold for STRATEGY_A
        values[1] = 2020e18; // 1% change < 30% pushThreshold for STRATEGY_B
        nonce = 2;
        expiry = block.timestamp + 1 hours;

        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        // ATOMICITY FIX: Batch updates are now atomic - this should revert instead of skipping
        vm.expectRevert(IUniversalValuerOffchain.UpdateTooFrequent.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        // Values should remain unchanged due to atomic revert
        assertEq(valuer.getValue(STRATEGY_A), 1000e18, "STRATEGY_A should remain unchanged (atomic revert)");
        assertEq(valuer.getValue(STRATEGY_B), 2000e18, "STRATEGY_B should remain unchanged (atomic revert)");

        // Now test with sufficient change (above push threshold)
        values[0] = 1250e18; // 25% change > 20% pushThreshold for STRATEGY_A
        values[1] = 2700e18; // 35% change > 30% pushThreshold for STRATEGY_B
        nonce = 3;
        expiry = block.timestamp + 1 hours;

        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        // Values should be updated since change exceeds push threshold
        assertEq(valuer.getValue(STRATEGY_A), 1250e18, "STRATEGY_A should be updated");
        assertEq(valuer.getValue(STRATEGY_B), 2700e18, "STRATEGY_B should be updated");
    }

    /**
     * @notice Test L-02 fix: Verify price bounds validation in batch updates
     */
    function testBatchUpdatePriceBoundsValidation() public {
        // L-05 FIX: Lower default confidence threshold to allow strategy configuration
        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // Configure strategy
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            2000, // 20% pushThreshold
            90
        );

        valuer.setPriceChangeBounds(STRATEGY_A, 3000); // 30% max change
        vm.stopPrank();

        // Initial update
        bytes32[] memory strategyIds = new bytes32[](1);
        strategyIds[0] = STRATEGY_A;

        uint256[] memory values = new uint256[](1);
        values[0] = 1000e18;

        uint256[] memory confidences = new uint256[](1);
        confidences[0] = 95;

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        // Advance time beyond update interval
        vm.warp(block.timestamp + 6 minutes);

        // Try to update with change exceeding price bounds
        values[0] = 1400e18; // 40% change > 30% limit
        nonce = 2;
        expiry = block.timestamp + 1 hours;

        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        // L-02 FIX: Should revert due to price bounds validation
        vm.expectRevert(abi.encodeWithSelector(
            IUniversalValuerOffchain.PriceChangeExceedsBounds.selector,
            4000, // 40% change
            3000  // 30% limit
        ));
        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        // Try with change within bounds
        values[0] = 1250e18; // 25% change < 30% limit
        nonce = 3;
        expiry = block.timestamp + 1 hours;

        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);
        assertEq(valuer.getValue(STRATEGY_A), 1250e18, "Value should be updated within bounds");
    }

    /**
     * @notice Test L-02 fix: Verify mixed validation scenarios in batch
     */
    function testBatchUpdateMixedValidationScenarios() public {
        // ATOMICITY FIX: Batch updates are now atomic - if ANY strategy fails validation, the ENTIRE batch reverts
        // This test has been updated to reflect the security fix that prevents partial update attacks

        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(80);

        // Configure strategies differently
        valuer.configureStrategy(
            STRATEGY_A,
            5 minutes,
            24 hours,
            2000, // 20% pushThreshold
            90
        );

        valuer.configureStrategy(
            STRATEGY_B,
            5 minutes,
            24 hours,
            1000, // 10% pushThreshold
            90
        );
        vm.stopPrank();

        // Initial updates
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
        uint256 expiry = block.timestamp + 1 hours;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        // Advance time by 3 minutes (less than minUpdateInterval)
        vm.warp(block.timestamp + 3 minutes);

        // Mixed scenario: STRATEGY_A has sufficient change, STRATEGY_B doesn't
        values[0] = 1250e18; // 25% change > 20% pushThreshold (would pass individually)
        values[1] = 2010e18; // 0.5% change < 10% pushThreshold (would fail individually)
        nonce = 2;
        expiry = block.timestamp + 1 hours;

        signatures[0] = _signBatch(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signer1Key
        );

        // ATOMICITY FIX: Since STRATEGY_B fails validation (insufficient change before interval),
        // the ENTIRE batch now reverts instead of partially updating
        vm.expectRevert(IUniversalValuerOffchain.UpdateTooFrequent.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, signatures);

        // Both strategies should remain unchanged (atomic behavior)
        assertEq(valuer.getValue(STRATEGY_A), 1000e18, "STRATEGY_A should NOT update (atomic batch failed)");
        assertEq(valuer.getValue(STRATEGY_B), 2000e18, "STRATEGY_B should NOT update (validation failed)");
    }

    // L-03 FIX: Test cases for defaultConfidenceThreshold setter
    function testSetDefaultConfidenceThreshold() public {
        vm.startPrank(owner);

        // Test normal threshold values
        uint256 newThreshold = 85;
        vm.expectEmit(true, true, true, true);
        emit DefaultConfidenceThresholdUpdated(newThreshold);
        valuer.setDefaultConfidenceThreshold(newThreshold);
        assertEq(valuer.defaultConfidenceThreshold(), newThreshold, "Should update defaultConfidenceThreshold");

        // Test boundary values
        valuer.setDefaultConfidenceThreshold(0);
        assertEq(valuer.defaultConfidenceThreshold(), 0, "Should allow 0% confidence");

        valuer.setDefaultConfidenceThreshold(100);
        assertEq(valuer.defaultConfidenceThreshold(), 100, "Should allow 100% confidence");

        vm.stopPrank();
    }

    function testSetDefaultConfidenceThresholdInvalidValue() public {
        vm.startPrank(owner);

        // Test value above 100 should revert
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.setDefaultConfidenceThreshold(101);

        // Test very high invalid value
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.setDefaultConfidenceThreshold(999);

        vm.stopPrank();
    }

    function testSetDefaultConfidenceThresholdUnauthorized() public {
        vm.startPrank(unauthorized);

        vm.expectRevert(IUniversalValuerOffchain.NotAuthorized.selector);
        valuer.setDefaultConfidenceThreshold(50);

        vm.stopPrank();
    }

    function testL08StrategySpecificConfigTakesPrecedenceInGetValue() public {
        vm.startPrank(owner);

        // Set a higher confidence threshold
        valuer.setDefaultConfidenceThreshold(98);

        // Configure strategy with confidence requirement equal to global
        valuer.configureStrategy(STRATEGY_A, MIN_UPDATE_INTERVAL, MAX_STALENESS, 100, 98);

        vm.stopPrank();

        // Update with confidence that meets strategy requirement and global
        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 30 minutes;
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(
            STRATEGY_A,
            1000e18,
            98, // Meets both strategy requirement (98) and global (98)
            nonce,
            expiry,
            signer1Key
        );

        vm.startPrank(signer1);

        // updateValue should succeed (only checks strategy-specific minConfidence)
        valuer.updateValue(STRATEGY_A, 1000e18, 98, nonce, expiry, signatures);

        vm.stopPrank();

        // Now lower the global threshold to allow lower confidence strategies
        vm.prank(owner);
        valuer.setDefaultConfidenceThreshold(90);

        // Reconfigure strategy with lower confidence to test the difference
        vm.prank(owner);
        valuer.configureStrategy(STRATEGY_A, MIN_UPDATE_INTERVAL, MAX_STALENESS, 100, 95);

        // Update with confidence that meets strategy (95%) but will be below global when we raise it
        uint256 nonce2 = 2;
        bytes[] memory signatures2 = new bytes[](1);
        signatures2[0] = _signValue(
            STRATEGY_A,
            1100e18,
            96, // Meets strategy requirement (95%)
            nonce2,
            expiry,
            signer1Key
        );

        vm.startPrank(signer1);
        valuer.updateValue(STRATEGY_A, 1100e18, 96, nonce2, expiry, signatures2);
        vm.stopPrank();

        // Now raise the global threshold above the stored value
        vm.prank(owner);
        valuer.setDefaultConfidenceThreshold(97);

        // L-08 FIX: getValue should succeed because it uses strategy-specific minConfidence (95),
        // not global defaultConfidenceThreshold (97). Strategy config takes precedence.
        uint256 value = valuer.getValue(STRATEGY_A);
        assertEq(value, 1100e18);
    }

    function testL08FallbackToGlobalDefaultsWhenNoConfigSet() public {
        // L-08 FIX: Test that getValue() falls back to global defaults when no strategy config is set
        // Use a fresh strategy ID that hasn't been configured in setUp()
        bytes32 UNCONFIGURED_STRATEGY = keccak256("UNCONFIGURED_STRATEGY");

        vm.startPrank(owner);
        valuer.setDefaultConfidenceThreshold(90);
        vm.stopPrank();

        // Add a value without configuring strategy (config will have 0 values)
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(UNCONFIGURED_STRATEGY, 1000e18, 95, 1, block.timestamp + 1 hours, signer1Key);
        valuer.updateValue(UNCONFIGURED_STRATEGY, 1000e18, 95, 1, block.timestamp + 1 hours, signatures);

        // getValue() should succeed because confidence (95) >= defaultConfidenceThreshold (90)
        uint256 value = valuer.getValue(UNCONFIGURED_STRATEGY);
        assertEq(value, 1000e18);

        // Raise global threshold above confidence
        vm.prank(owner);
        valuer.setDefaultConfidenceThreshold(96);

        // Check what the current config values are for debugging
        (uint256 minUpdateInterval, uint256 maxStaleness, uint256 pushThreshold, uint256 minConfidence) =
            valuer.updateConfigs(UNCONFIGURED_STRATEGY);

        // Verify that strategy is not configured (config should be all zeros)
        assertEq(minConfidence, 0);
        assertEq(valuer.defaultConfidenceThreshold(), 96);

        // getValue() should now revert because confidence (95) < defaultConfidenceThreshold (96)
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.getValue(UNCONFIGURED_STRATEGY);
    }

    // L-05 FIX: Test cases for configureStrategy input validation
    function testConfigureStrategyValidInputs() public {
        vm.startPrank(owner);

        // Valid configuration should succeed
        valuer.configureStrategy(
            STRATEGY_A,
            MIN_UPDATE_INTERVAL, // Exactly minimum
            MAX_STALENESS,       // Exactly maximum
            1000,               // 10% push threshold
            95                  // Valid confidence
        );

        // Verify the configuration was set
        (uint256 minInterval, uint256 maxStale, uint256 pushThresh, uint256 minConf) =
            valuer.updateConfigs(STRATEGY_A);
        assertEq(minInterval, MIN_UPDATE_INTERVAL, "Should set minUpdateInterval");
        assertEq(maxStale, MAX_STALENESS, "Should set maxStaleness");
        assertEq(pushThresh, 1000, "Should set pushThreshold");
        assertEq(minConf, 95, "Should set minConfidence");

        vm.stopPrank();
    }

    function testConfigureStrategyInvalidMinUpdateInterval() public {
        vm.startPrank(owner);

        // L-18 Fix: Test new minimum bound (1 minute instead of old 5 minutes)
        vm.expectRevert(IUniversalValuerOffchain.UpdateTooFrequent.selector);
        valuer.configureStrategy(
            STRATEGY_A,
            59 seconds, // Below new minimum of 1 minute
            MAX_STALENESS,
            1000,
            95
        );

        vm.stopPrank();
    }

    function testConfigureStrategyInvalidMaxStaleness() public {
        vm.startPrank(owner);

        // L-18 Fix: Should revert for staleness above new maximum (7 days)
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.configureStrategy(
            STRATEGY_A,
            MIN_UPDATE_INTERVAL,
            7 days + 1 seconds, // Above new maximum (7 days)
            1000,
            95
        );

        vm.stopPrank();
    }

    function testConfigureStrategyInvalidPushThreshold() public {
        vm.startPrank(owner);

        // Should revert for pushThreshold above MAX_PRICE_CHANGE_BPS
        vm.expectRevert(IUniversalValuerOffchain.InvalidPriceChangeBounds.selector);
        valuer.configureStrategy(
            STRATEGY_A,
            MIN_UPDATE_INTERVAL,
            MAX_STALENESS,
            5001, // Above 50% (5000 basis points)
            95
        );

        vm.stopPrank();
    }

    function testConfigureStrategyInvalidMinConfidence() public {
        vm.startPrank(owner);

        // Should revert for confidence below defaultConfidenceThreshold (default is 90)
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.configureStrategy(
            STRATEGY_A,
            MIN_UPDATE_INTERVAL,
            MAX_STALENESS,
            1000,
            89 // Below default threshold of 90
        );

        // Should revert for confidence above 100
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.configureStrategy(
            STRATEGY_A,
            MIN_UPDATE_INTERVAL,
            MAX_STALENESS,
            1000,
            101 // Above 100%
        );

        vm.stopPrank();
    }

    /**
     * @notice Test L-03 fix: minUpdateInterval must be less than maxStaleness
     * @dev This validates the security fix preventing configuration conflicts where values become stale before they can be updated
     */
    function testConfigureStrategyUpdateIntervalExceedsStaleness() public {
        vm.startPrank(owner);

        // Case 1: minUpdateInterval = maxStaleness (should revert)
        vm.expectRevert(IUniversalValuerOffchain.UpdateIntervalExceedsStaleness.selector);
        valuer.configureStrategy(
            STRATEGY_A,
            12 hours,  // minUpdateInterval
            12 hours,  // maxStaleness - equal to minUpdateInterval
            1000,
            95
        );

        // Case 2: minUpdateInterval > maxStaleness (should revert)
        vm.expectRevert(IUniversalValuerOffchain.UpdateIntervalExceedsStaleness.selector);
        valuer.configureStrategy(
            STRATEGY_A,
            20 hours,  // minUpdateInterval
            12 hours,  // maxStaleness - less than minUpdateInterval
            1000,
            95
        );

        // Case 3: Edge case - minUpdateInterval just 1 second less than maxStaleness (should succeed)
        valuer.configureStrategy(
            STRATEGY_A,
            12 hours - 1,  // minUpdateInterval (just under maxStaleness)
            12 hours,      // maxStaleness
            1000,
            95
        );

        // Verify the configuration was set correctly
        (uint256 minInterval, uint256 maxStale, uint256 pushThresh, uint256 minConf) =
            valuer.updateConfigs(STRATEGY_A);
        assertEq(minInterval, 12 hours - 1, "Should set minUpdateInterval");
        assertEq(maxStale, 12 hours, "Should set maxStaleness");

        // Case 4: Valid configuration with minUpdateInterval significantly less than maxStaleness
        valuer.configureStrategy(
            STRATEGY_B,
            1 hours,   // minUpdateInterval
            24 hours,  // maxStaleness - much greater than minUpdateInterval
            1000,
            95
        );

        (minInterval, maxStale, pushThresh, minConf) = valuer.updateConfigs(STRATEGY_B);
        assertEq(minInterval, 1 hours, "Should set minUpdateInterval for STRATEGY_B");
        assertEq(maxStale, 24 hours, "Should set maxStaleness for STRATEGY_B");

        vm.stopPrank();
    }

    function testConfigureStrategyWithCustomConfidenceThreshold() public {
        vm.startPrank(owner);

        // Set a lower confidence threshold first
        valuer.setDefaultConfidenceThreshold(80);

        // Now should accept confidence at the new threshold
        valuer.configureStrategy(
            STRATEGY_A,
            MIN_UPDATE_INTERVAL,
            MAX_STALENESS,
            1000,
            80 // Equal to new threshold
        );

        // But should still reject below threshold
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.configureStrategy(
            STRATEGY_B,
            MIN_UPDATE_INTERVAL,
            MAX_STALENESS,
            1000,
            79 // Below new threshold
        );

        vm.stopPrank();
    }

    /* L-18 FIX TESTS */

    function testL18ConfiguredStrategyUsesConfigValues() public {
        vm.startPrank(owner);

        // L-18 Fix: Configured strategies should use config values, not constants

        // Configure strategy with specific staleness (12h, different from MAX_STALENESS 24h)
        valuer.configureStrategy(
            STRATEGY_A,
            MIN_UPDATE_INTERVAL, // 5 minutes
            12 hours, // Different from MAX_STALENESS (24 hours)
            1000,
            95
        );

        // Set up a report
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000, 95, 1, block.timestamp + 3600, signatures);

        // Forward time to 15 hours (exceeds config staleness of 12h but within MAX_STALENESS of 24h)
        vm.warp(block.timestamp + 15 hours);

        // Should revert with ValueTooStale because config.maxStaleness (12h) is used, not MAX_STALENESS (24h)
        vm.expectRevert(IUniversalValuerOffchain.ValueTooStale.selector);
        valuer.getValue(STRATEGY_A);

        vm.stopPrank();
    }

    function testL18ConfiguredStrategyUsesConfigConfidence() public {
        vm.startPrank(owner);

        // First set a lower default confidence threshold to allow the test
        valuer.setDefaultConfidenceThreshold(70);

        // Configure strategy with specific confidence requirement (80, higher than new default 70)
        valuer.configureStrategy(
            STRATEGY_A,
            MIN_UPDATE_INTERVAL,
            MAX_STALENESS,
            1000,
            80 // Higher than new defaultConfidenceThreshold (70)
        );

        // Set up a report with confidence 85 (above config 80, above new default 70)
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000, 85, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(STRATEGY_A, 1000, 85, 1, block.timestamp + 3600, signatures);

        // Should succeed because config.minConfidence (80) is used, not defaultConfidenceThreshold (70)
        uint256 value = valuer.getValue(STRATEGY_A);
        assertEq(value, 1000, "Should use config confidence, not default threshold");

        vm.stopPrank();
    }

    function testL18UnconfiguredStrategyUsesDefaults() public {
        vm.startPrank(owner);

        // L-18 Fix: Unconfigured strategies should still work with defaults

        // Use a fresh strategy ID that hasn't been configured
        bytes32 UNCONFIGURED_STRATEGY = keccak256("UNCONFIGURED_STRATEGY");

        // Set up a report for unconfigured strategy
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(UNCONFIGURED_STRATEGY, 1000, 95, 1, block.timestamp + 3600, signer1Key);
        valuer.updateValue(UNCONFIGURED_STRATEGY, 1000, 95, 1, block.timestamp + 3600, signatures);

        // Should succeed because it falls back to constants (MAX_STALENESS, defaultConfidenceThreshold)
        uint256 value = valuer.getValue(UNCONFIGURED_STRATEGY);
        assertEq(value, 1000, "Unconfigured strategy should work with defaults");

        vm.stopPrank();
    }

    event DefaultConfidenceThresholdUpdated(uint256 newThreshold);
}

contract SimpleMockAdapter {
    function getActiveStrategies() external pure returns (bytes32[] memory) {
        bytes32[] memory strategies = new bytes32[](1);
        strategies[0] = keccak256("STRATEGY_A");
        return strategies;
    }
}