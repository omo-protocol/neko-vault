// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

/// @notice External library for admin setters that operate on dynamic arrays of dynamic types.
///         The array-rewrite pattern (delete + push loop) carries a surprising amount of
///         bytecode because ABI-decoding `bytes[]` / `string[]` from calldata inflates the
///         codegen. Moving it here keeps MultiLegController / PtLoopController under EIP-170.
///
///         Uses `external` linkage so Solidity emits DELEGATECALL — library runs in the
///         caller's storage context, so the storage-pointer parameters resolve to the
///         controller's own storage slots.
library ControllerAdminLib {
    error LengthMismatch();

    function applySecrets(
        bytes[] storage blobs,
        bytes[] storage sigs,
        bytes[] calldata newBlobs,
        bytes[] calldata newSigs
    ) external {
        if (newBlobs.length != newSigs.length) revert LengthMismatch();
        while (blobs.length > 0) {
            blobs.pop();
            sigs.pop();
        }
        for (uint256 i; i < newBlobs.length; i++) {
            blobs.push(newBlobs[i]);
            sigs.push(newSigs[i]);
        }
    }

    function applyHeaders(
        string[] storage keys,
        string[] storage values,
        string[] calldata newKeys,
        string[] calldata newValues
    ) external {
        if (newKeys.length != newValues.length) revert LengthMismatch();
        while (keys.length > 0) {
            keys.pop();
            values.pop();
        }
        for (uint256 i; i < newKeys.length; i++) {
            keys.push(newKeys[i]);
            values.push(newValues[i]);
        }
    }
}
