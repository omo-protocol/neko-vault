// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {UniversalValuerOffchain} from "../../src/valuers/UniversalValuerOffchain.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @title BatchReplayAttackPrevention
/// @notice Tests that batch signature replay attacks are prevented through domain separation
/// @dev Validates that including block.chainid and address(this) in batch signatures prevents:
///      1. Cross-chain replay attacks (same signature on different chains)
///      2. Cross-instance replay attacks (same signature on different valuer instances)
contract BatchReplayAttackPrevention is Test {
    UniversalValuerOffchain public valuer1;
    UniversalValuerOffchain public valuer2;
    MockERC20 public asset;

    address public owner = address(this);
    uint256 public signerKey = 0x1234;
    address public signer;

    bytes32 public strategyA = keccak256("strategyA");
    bytes32 public strategyB = keccak256("strategyB");

    function setUp() public {
        signer = vm.addr(signerKey);

        asset = new MockERC20("Test Asset", "TA", 18);

        // Deploy two valuer instances (simulating different instances)
        valuer1 = new UniversalValuerOffchain(owner, address(asset));
        valuer2 = new UniversalValuerOffchain(owner, address(asset));

        // Setup valuer1
        valuer1.initiateSignerChange(signer, true, 100);
        valuer1.setRequiredWeight(100);
        valuer1.configureStrategy(strategyA, 5 minutes, 24 hours, 500, 95);
        valuer1.configureStrategy(strategyB, 5 minutes, 24 hours, 500, 95);

        // Setup valuer2 with same configuration
        valuer2.initiateSignerChange(signer, true, 100);
        valuer2.setRequiredWeight(100);
        valuer2.configureStrategy(strategyA, 5 minutes, 24 hours, 500, 95);
        valuer2.configureStrategy(strategyB, 5 minutes, 24 hours, 500, 95);
    }

    /// @notice Helper to create batch signature for a specific valuer instance
    function _createBatchSignatureForValuer(
        address valuerAddress,
        bytes32[] memory strategyIds,
        uint256[] memory values,
        uint256[] memory confidences,
        uint256 nonce,
        uint256 expiry,
        uint256 privateKey
    ) internal view returns (bytes memory) {
        // Include domain separation with valuer address
        bytes32 batchHash = keccak256(abi.encode(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            block.chainid,
            valuerAddress
        ));
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", batchHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, messageHash);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Helper to create batch signature with wrong chain ID
    function _createBatchSignatureWithChainId(
        address valuerAddress,
        uint256 chainId,
        bytes32[] memory strategyIds,
        uint256[] memory values,
        uint256[] memory confidences,
        uint256 nonce,
        uint256 expiry,
        uint256 privateKey
    ) internal pure returns (bytes memory) {
        // Include domain separation with custom chain ID
        bytes32 batchHash = keccak256(abi.encode(
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            chainId,
            valuerAddress
        ));
        bytes32 messageHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", batchHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, messageHash);
        return abi.encodePacked(r, s, v);
    }

    /// @notice Test that a signature created for valuer1 cannot be used on valuer2
    function testCrossInstanceReplayPrevented() public {
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;

        uint256[] memory values = new uint256[](2);
        values[0] = 100e6;
        values[1] = 200e6;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 95;
        confidences[1] = 95;

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        // Create signature for valuer1
        bytes memory sig1 = _createBatchSignatureForValuer(
            address(valuer1),
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signerKey
        );

        bytes[] memory sigs1 = new bytes[](1);
        sigs1[0] = sig1;

        // Valid update on valuer1 should succeed
        valuer1.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, sigs1);

        // Verify values were set on valuer1
        uint256 val1A = valuer1.getValue(strategyA);
        assertEq(val1A, 100e6, "Valuer1 strategyA should be updated");

        // Try to replay same signature on valuer2 - should fail because signature includes address(valuer1)
        vm.expectRevert(); // Will revert with InsufficientSignatures due to signature mismatch
        valuer2.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, sigs1);

        // Verify values were NOT set on valuer2 by checking if it reverts (no valid report yet)
        vm.expectRevert(); // LowConfidence because no value has been set
        valuer2.getValue(strategyA);
    }

    /// @notice Test that a signature from a different chain ID is rejected
    function testCrossChainReplayPrevented() public {
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;

        uint256[] memory values = new uint256[](2);
        values[0] = 100e6;
        values[1] = 200e6;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 95;
        confidences[1] = 95;

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        // Create signature with wrong chain ID (simulate another chain)
        uint256 wrongChainId = block.chainid + 1;
        bytes memory sigWrongChain = _createBatchSignatureWithChainId(
            address(valuer1),
            wrongChainId,
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signerKey
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sigWrongChain;

        // Should fail because chain ID doesn't match
        vm.expectRevert(); // Will revert with InsufficientSignatures due to signature mismatch
        valuer1.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, sigs);

        // Verify values were NOT set - getValue should revert due to no valid report
        vm.expectRevert(); // LowConfidence because no value has been set
        valuer1.getValue(strategyA);
    }

    /// @notice Test that correct signature with domain separation works
    function testValidBatchWithDomainSeparationWorks() public {
        bytes32[] memory strategyIds = new bytes32[](2);
        strategyIds[0] = strategyA;
        strategyIds[1] = strategyB;

        uint256[] memory values = new uint256[](2);
        values[0] = 100e6;
        values[1] = 200e6;

        uint256[] memory confidences = new uint256[](2);
        confidences[0] = 95;
        confidences[1] = 95;

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        // Create correct signature for valuer1
        bytes memory sig = _createBatchSignatureForValuer(
            address(valuer1),
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signerKey
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sig;

        // Should succeed
        valuer1.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, sigs);

        // Verify values were set correctly
        uint256 valA = valuer1.getValue(strategyA);
        uint256 valB = valuer1.getValue(strategyB);
        assertEq(valA, 100e6, "StrategyA should be updated");
        assertEq(valB, 200e6, "StrategyB should be updated");
    }

    /// @notice Fuzz test: Verify domain separation prevents replay across chain IDs
    function testFuzzCrossChainReplayPrevented(uint256 wrongChainId) public {
        // Ensure wrong chain ID is different from current
        vm.assume(wrongChainId != block.chainid);
        vm.assume(wrongChainId < type(uint64).max); // Reasonable chain ID range

        bytes32[] memory strategyIds = new bytes32[](1);
        strategyIds[0] = strategyA;

        uint256[] memory values = new uint256[](1);
        values[0] = 100e6;

        uint256[] memory confidences = new uint256[](1);
        confidences[0] = 95;

        uint256 nonce = 1;
        uint256 expiry = block.timestamp + 1 hours;

        // Create signature with wrong chain ID
        bytes memory sigWrongChain = _createBatchSignatureWithChainId(
            address(valuer1),
            wrongChainId,
            strategyIds,
            values,
            confidences,
            nonce,
            expiry,
            signerKey
        );

        bytes[] memory sigs = new bytes[](1);
        sigs[0] = sigWrongChain;

        // Should always fail
        vm.expectRevert();
        valuer1.batchUpdateValues(strategyIds, values, confidences, nonce, expiry, sigs);
    }
}
