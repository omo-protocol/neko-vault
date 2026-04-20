// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {OffchainKellyWeights} from "./MultiLegTypes.sol";

/// @title KellySignLib
/// @notice EIP-191 signature verification for `MultiLegController.submitKellyWeights`. Extracted
///         to a library to keep the controller under the EIP-170 runtime size limit. Stateless —
///         returns the recovered signer + the digest for replay-protection bookkeeping; the
///         controller enforces freshness and nonce uniqueness against its own storage.
library KellySignLib {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    /// @notice Recover the signer of an EIP-191-signed Kelly-weights digest bound to
    ///         `(strategyId, controller, chainId, nonce, validUntil, weights, totalNotional)`.
    function recoverSigner(
        bytes32 strategyId,
        address controller,
        OffchainKellyWeights calldata w,
        bytes calldata signature
    ) external view returns (address signer) {
        bytes32 digest = keccak256(
            abi.encode(
                strategyId,
                w.targetWeightBps,
                w.totalTargetNotional,
                w.validUntil,
                w.nonce,
                block.chainid,
                controller
            )
        ).toEthSignedMessageHash();
        signer = digest.recover(signature);
    }
}
