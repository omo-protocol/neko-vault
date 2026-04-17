// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {RitualPrecompiles} from "../../interfaces/ritual/IRitualPrecompiles.sol";

/// @title RitualHttpLib
/// @notice Canonical Long-Running HTTP precompile (0x0805) envelope construction.
///         Shared by PmHl / MultiLeg / PtLoop controllers so the request shape is
///         kept in exactly one place.
///
///         Secrets are carried as ECIES blobs encrypted to the executor's public key.
///         The caller (controller) owns the blobs + their owner-EOA signatures and
///         passes them in per request. `dkmsKeyIndex=0` is used throughout — dKMS is
///         not required; access delegation is handled via `SecretsAccessControl`.
library RitualHttpLib {
    struct Delivery {
        address target;
        bytes4 callback;
        uint256 gasLimit;
    }

    struct Polling {
        uint64 pollIntervalBlocks;
        uint64 maxPollBlock;
    }

    struct HttpRequest {
        string url;
        bytes payload;
        address executor;
        bytes[] encryptedSecrets;
        bytes[] secretSignatures;
        string[] secretHeaderKeys;
        string[] secretHeaderValues;
    }

    /// @notice Build the abi-encoded request for the Long-Running HTTP precompile.
    function buildEncoded(HttpRequest memory req, Polling memory polling, Delivery memory delivery)
        internal
        pure
        returns (bytes memory)
    {
        string[] memory pollHeaders = _emptyStringArray();
        return abi.encode(
            // Base executor fields (5)
            req.executor,
            req.encryptedSecrets,
            uint256(polling.maxPollBlock),
            req.secretSignatures,
            bytes(""),
            // Polling config (3)
            polling.pollIntervalBlocks,
            polling.maxPollBlock,
            "{{TASK_ID}}",
            // Delivery config (6)
            delivery.target,
            delivery.callback,
            delivery.gasLimit,
            uint256(1_000_000_000),
            uint256(100_000_000),
            uint256(0),
            // Initial HTTP request (6)
            req.url,
            uint8(2),
            _mergedHeaderKeys(req.secretHeaderKeys),
            _mergedHeaderValues(req.secretHeaderValues),
            req.payload,
            ".task_id",
            // Poll request (6)
            string(abi.encodePacked(req.url, "/status/{{TASK_ID}}")),
            uint8(1),
            pollHeaders,
            pollHeaders,
            bytes(""),
            '.status == "completed"',
            // Result request (6)
            "",
            uint8(0),
            pollHeaders,
            pollHeaders,
            bytes(""),
            ".result",
            // DKMS + PII (3) — dkmsKeyIndex=0 means "not using dKMS"; secrets come from `encryptedSecrets`.
            uint256(0),
            uint8(1),
            false
        );
    }

    /// @notice Submit a request, reverting on precompile failure.
    function submit(HttpRequest memory req, Polling memory polling, Delivery memory delivery) internal {
        (bool ok,) = RitualPrecompiles.LONG_RUNNING_HTTP.call(buildEncoded(req, polling, delivery));
        require(ok, "long-running http failed");
    }

    /// @notice Decode the standard async HTTP response envelope delivered by AsyncDelivery.
    function decodeEnvelope(bytes calldata raw)
        internal
        pure
        returns (uint16 statusCode, bytes memory body, string memory errorMessage)
    {
        string[] memory _headers;
        string[] memory _cookies;
        (statusCode, _headers, _cookies, body, errorMessage) =
            abi.decode(raw, (uint16, string[], string[], bytes, string));
    }

    function _emptyStringArray() private pure returns (string[] memory) {
        return new string[](0);
    }

    function _mergedHeaderKeys(string[] memory extraKeys) private pure returns (string[] memory merged) {
        uint256 n = extraKeys.length;
        merged = new string[](1 + n);
        merged[0] = "Content-Type";
        for (uint256 i; i < n; ++i) {
            merged[i + 1] = extraKeys[i];
        }
    }

    function _mergedHeaderValues(string[] memory extraValues) private pure returns (string[] memory merged) {
        uint256 n = extraValues.length;
        merged = new string[](1 + n);
        merged[0] = "application/json";
        for (uint256 i; i < n; ++i) {
            merged[i + 1] = extraValues[i];
        }
    }
}
