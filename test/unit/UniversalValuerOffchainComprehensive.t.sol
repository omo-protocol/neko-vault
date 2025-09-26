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

        // Configure strategies
        valuer.configureStrategy(STRATEGY_A, 1 hours, 24 hours, 500, 95);
        valuer.configureStrategy(STRATEGY_B, 1 hours, 24 hours, 500, 95);
        valuer.configureStrategy(STRATEGY_C, 1 hours, 24 hours, 500, 85);
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
        emit StrategyConfigured(newStrategy, 2 hours, 48 hours, 1000);

        valuer.configureStrategy(newStrategy, 2 hours, 48 hours, 1000, 90);

        // Check the configuration was set (public mapping returns tuple)
        (uint256 minInterval, uint256 maxStale, uint256 threshold, uint256 minConf) = valuer.updateConfigs(newStrategy);
        assertEq(minInterval, 2 hours);
        assertEq(maxStale, 48 hours);
        assertEq(threshold, 1000);
        assertEq(minConf, 90);

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
        // Should only return idle assets (0) since report is stale
        assertEq(totalValue, 0);
    }

    function testGetTotalValueLowConfidence() public {
        // Create a simple mock adapter that returns STRATEGY_A as active
        SimpleMockAdapter mockAdapter = new SimpleMockAdapter();

        // Setup value with low confidence
        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _signValue(STRATEGY_A, 1000e18, 50, 1, block.timestamp + 1 hours, signer1Key); // Low confidence
        valuer.updateValue(STRATEGY_A, 1000e18, 50, 1, block.timestamp + 1 hours, signatures);

        uint256 totalValue = valuer.getTotalValue(address(mockAdapter));
        // Should be 0 since confidence is below threshold
        assertEq(totalValue, 0);
    }

    /* VIEW FUNCTION TESTS */

    function testGetValue() public {
        // No value set - should revert with LowConfidence
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
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
        bytes32 batchHash = keccak256(abi.encode(strategyIds, values, confidences, nonce, expiry));

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
}

contract SimpleMockAdapter {
    function getActiveStrategies() external pure returns (bytes32[] memory) {
        bytes32[] memory strategies = new bytes32[](1);
        strategies[0] = keccak256("STRATEGY_A");
        return strategies;
    }
}