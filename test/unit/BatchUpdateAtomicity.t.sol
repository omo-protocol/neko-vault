// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {UniversalValuerOffchain} from "../../src/valuers/UniversalValuerOffchain.sol";
import {IUniversalValuerOffchain} from "../../src/adapters/interfaces/IUniversalValuerOffchain.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockUniversalAdapterEscrow} from "../mocks/MockUniversalAdapterEscrow.sol";

/**
 * @title BatchUpdateAtomicity
 * @notice Tests for the CRITICAL batch update atomicity vulnerability fix
 * @dev Verifies that batchUpdateValues is now atomic - either all updates succeed or entire batch reverts
 *      This prevents the value manipulation attack where partial updates could inflate getTotalValue
 */
contract BatchUpdateAtomicity is Test {
    UniversalValuerOffchain valuer;
    MockERC20 asset;
    MockUniversalAdapterEscrow escrow;

    address owner = address(0x1);
    address signer1;
    uint256 signer1Key;
    address signer2;
    uint256 signer2Key;

    bytes32 strategyA = keccak256("STRATEGY_A");
    bytes32 strategyB = keccak256("STRATEGY_B");
    bytes32 strategyC = keccak256("STRATEGY_C");

    function setUp() public {
        // Generate signers
        (signer1, signer1Key) = makeAddrAndKey("signer1");
        (signer2, signer2Key) = makeAddrAndKey("signer2");

        asset = new MockERC20("USDC", "USDC", 6);
        valuer = new UniversalValuerOffchain(owner, address(asset));

        // Setup mock escrow
        bytes32[] memory strategies = new bytes32[](3);
        strategies[0] = strategyA;
        strategies[1] = strategyB;
        strategies[2] = strategyC;
        escrow = new MockUniversalAdapterEscrow(strategies);

        // Configure signers
        vm.startPrank(owner);
        valuer.initiateSignerChange(signer1, true, 1);
        valuer.initiateSignerChange(signer2, true, 1);
        valuer.setRequiredWeight(1);

        // Configure strategies
        valuer.configureStrategy(strategyA, 5 minutes, 24 hours, 500, 95); // 5% push threshold
        valuer.configureStrategy(strategyB, 5 minutes, 24 hours, 500, 95);
        valuer.configureStrategy(strategyC, 5 minutes, 24 hours, 500, 95);
        vm.stopPrank();
    }

    /// @notice Helper to create batch update signature
    function _createBatchSignature(
        bytes32[] memory strategyIds,
        uint256[] memory values,
        uint256[] memory confidences,
        uint256 nonce,
        uint256 expiry,
        uint256 signerKey
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
        
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", batchHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerKey, messageHash);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Test that batch update is now atomic - reverts on stale nonce
    function testBatchUpdateRevertsOnStaleNonce() public {
        // Initial update for all strategies
        bytes32[] memory strategyIds = new bytes32[](3);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;
        strategyIds[2] = strategyC;

        uint256[] memory values = new uint256[](3);
        values[0] = 100e6;
        values[1] = 200e6;
        values[2] = 150e6;

        uint256[] memory confidences = new uint256[](3);
        confidences[0] = 98;
        confidences[1] = 97;
        confidences[2] = 96;

        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        vm.prank(owner);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        // Verify initial state
        assertEq(valuer.getValue(strategyA), 100e6);
        assertEq(valuer.getValue(strategyB), 200e6);
        assertEq(valuer.getValue(strategyC), 150e6);

        // Now attempt batch update with SAME nonce (should revert entirely)
        values[0] = 110e6; // Try to update A
        values[1] = 210e6; // Try to update B
        values[2] = 160e6; // Try to update C

        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        // CRITICAL: This should revert ENTIRELY, not skip any strategies
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.StaleNonce.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        // Verify NO strategies were updated (atomicity)
        assertEq(valuer.getValue(strategyA), 100e6, "Strategy A should NOT be updated");
        assertEq(valuer.getValue(strategyB), 200e6, "Strategy B should NOT be updated");
        assertEq(valuer.getValue(strategyC), 150e6, "Strategy C should NOT be updated");
    }

    /// @notice Test that batch update reverts on UpdateTooFrequent
    function testBatchUpdateRevertsOnUpdateTooFrequent() public {
        // Initial update
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;

        uint256[] memory values = new uint256[](2);
        values[0] = 100e6;
        values[1] = 200e6;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 98;
        confidences[1] = 97;

        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        vm.prank(owner);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        // Attempt update too soon with small change (< 5% pushThreshold)
        vm.warp(block.timestamp + 2 minutes); // Less than 5 minute minUpdateInterval

        values[0] = 102e6; // 2% change - below 5% threshold
        values[1] = 204e6; // 2% change - below 5% threshold

        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 2, expiry, signer1Key);

        // CRITICAL: Should revert ENTIRELY, not skip strategies
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.UpdateTooFrequent.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, 2, expiry, signatures);

        // Verify NO strategies were updated
        assertEq(valuer.getValue(strategyA), 100e6, "Strategy A should NOT be updated");
        assertEq(valuer.getValue(strategyB), 200e6, "Strategy B should NOT be updated");
    }

    /// @notice Test the original attack scenario - batch with mixed valid/invalid updates
    function testOriginalAttackScenarioNowPrevented() public {
        // Setup: Initial values
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;

        uint256[] memory values = new uint256[](2);
        values[0] = 100e6;
        values[1] = 100e6;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 98;
        confidences[1] = 98;

        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        vm.prank(owner);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        // ATTACK SCENARIO: Attacker tries to update A to 80 but keep B stale at 100
        // This would inflate getTotalValue to 180 instead of correct 160
        vm.warp(block.timestamp + 2 minutes); // Too soon for normal update

        values[0] = 80e6;  // 20% drop - exceeds 5% pushThreshold (should succeed)
        values[1] = 80e6;  // 20% drop - but we'll use STALE nonce to try to skip it

        // Try to use same nonce for entire batch
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        // OLD BEHAVIOR: Would update A but skip B, leaving getTotalValue = 180
        // NEW BEHAVIOR: Reverts ENTIRE batch due to stale nonce
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.StaleNonce.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        // Verify attack failed - both strategies keep original values
        assertEq(valuer.getValue(strategyA), 100e6, "Strategy A unchanged");
        assertEq(valuer.getValue(strategyB), 100e6, "Strategy B unchanged");
    }

    /// @notice Test that valid batch updates still work correctly
    function testValidBatchUpdateSucceeds() public {
        bytes32[] memory strategyIds = new bytes32[](3);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;
        strategyIds[2] = strategyC;

        uint256[] memory values = new uint256[](3);
        values[0] = 100e6;
        values[1] = 200e6;
        values[2] = 150e6;

        uint256[] memory confidences = new uint256[](3);
        confidences[0] = 98;
        confidences[1] = 97;
        confidences[2] = 96;

        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        // Should succeed when all validations pass
        vm.prank(owner);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        assertEq(valuer.getValue(strategyA), 100e6);
        assertEq(valuer.getValue(strategyB), 200e6);
        assertEq(valuer.getValue(strategyC), 150e6);
    }

    /// @notice Test batch update reverts if ANY strategy has low confidence
    function testBatchUpdateRevertsOnLowConfidence() public {
        bytes32[] memory strategyIds = new bytes32[](3);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;
        strategyIds[2] = strategyC;

        uint256[] memory values = new uint256[](3);
        values[0] = 100e6;
        values[1] = 200e6;
        values[2] = 150e6;

        uint256[] memory confidences = new uint256[](3);
        confidences[0] = 98;
        confidences[1] = 90; // Below 95% minimum - should revert ENTIRE batch
        confidences[2] = 96;

        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        // CRITICAL: Should revert ENTIRE batch
        vm.prank(owner);
        vm.expectRevert(IUniversalValuerOffchain.LowConfidence.selector);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);
    }

    /// @notice Test batch update with large price changes across all strategies
    function testBatchUpdateWithSignificantChanges() public {
        // Initial update
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;

        uint256[] memory values = new uint256[](2);
        values[0] = 100e6;
        values[1] = 200e6;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 98;
        confidences[1] = 98;

        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        vm.prank(owner);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        // Update with significant changes (>5% threshold) before interval elapses
        vm.warp(block.timestamp + 2 minutes);

        values[0] = 110e6; // 10% increase - exceeds 5% threshold
        values[1] = 220e6; // 10% increase - exceeds 5% threshold

        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 2, expiry, signer1Key);

        // Should succeed because changes exceed pushThreshold
        vm.prank(owner);
        valuer.batchUpdateValues(strategyIds, values, confidences, 2, expiry, signatures);

        assertEq(valuer.getValue(strategyA), 110e6);
        assertEq(valuer.getValue(strategyB), 220e6);
    }

    /// @notice Test that batch update updates all strategy values and remains healthy
    function testBatchUpdateWithMultipleStrategies() public {
        bytes32[] memory strategyIds = new bytes32[](3);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;
        strategyIds[2] = strategyC;

        uint256[] memory values = new uint256[](3);
        values[0] = 100e6;
        values[1] = 200e6;
        values[2] = 150e6;

        uint256[] memory confidences = new uint256[](3);
        confidences[0] = 98;
        confidences[1] = 97;
        confidences[2] = 96;

        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        vm.prank(owner);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        // Verify all strategies were updated
        assertEq(valuer.getValue(strategyA), 100e6, "Strategy A value correct");
        assertEq(valuer.getValue(strategyB), 200e6, "Strategy B value correct");
        assertEq(valuer.getValue(strategyC), 150e6, "Strategy C value correct");

        // Verify valuation is healthy after batch update
        assertTrue(valuer.isValuationHealthy(address(escrow)), "Valuation should be healthy");
    }

    /// @notice Fuzz test: Batch updates with random valid parameters should always be atomic
    function testFuzzBatchUpdateAtomicity(
        uint256 valueA,
        uint256 valueB,
        uint8 confidenceA,
        uint8 confidenceB
    ) public {
        valueA = bound(valueA, 1e6, 1000e6);
        valueB = bound(valueB, 1e6, 1000e6);
        confidenceA = uint8(bound(confidenceA, 95, 100));
        confidenceB = uint8(bound(confidenceB, 95, 100));

        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;

        uint256[] memory values = new uint256[](2);
        values[0] = valueA;
        values[1] = valueB;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = confidenceA;
        confidences[1] = confidenceB;

        uint256 expiry = block.timestamp + 30 minutes;

        bytes[] memory signatures = new bytes[](1);
        signatures[0] = _createBatchSignature(strategyIds, values, confidences, 1, expiry, signer1Key);

        // Should succeed and update both atomically
        vm.prank(owner);
        valuer.batchUpdateValues(strategyIds, values, confidences, 1, expiry, signatures);

        assertEq(valuer.getValue(strategyA), valueA);
        assertEq(valuer.getValue(strategyB), valueB);
    }
}
