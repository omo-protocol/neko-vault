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
        uint256 ttl; // runtime-tunable — passed in from controller storage, not hardcoded
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
            req.ttl,
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
            // DKMS + PII (3) — dkmsKeyIndex=0 = not using dKMS; dkmsKeyFormat=0 = disabled.
            // piiEnabled=false: TEE skips SECRET_NAME substitution. Setting this true caused
            // silent failures in long-running HTTP when encryptedSecrets didn't decrypt cleanly.
            // Since adapter uses plaintext secrets received via its own TLS, substitution isn't
            // needed here — revisit if we ever need on-wire secret injection.
            uint256(0),
            uint8(0),
            false
        );
    }

    /// @notice Submit a request, reverting on precompile failure.
    function submit(HttpRequest memory req, Polling memory polling, Delivery memory delivery) internal {
        (bool ok,) = RitualPrecompiles.LONG_RUNNING_HTTP.call(buildEncoded(req, polling, delivery));
        require(ok, "long-running http failed");
    }

    /// @notice Decode the standard async HTTP response envelope delivered by AsyncDelivery.
    ///         When `resultJsonPath` extracts a JSON string, the TEE unwraps the quotes and
    ///         writes the raw UTF-8 bytes of the string into `body`. Our adapters return
    ///         `{"result":"0x<hex>"}`, so body arrives as ASCII bytes of a hex string. We
    ///         auto-decode the hex here so callers can `abi.decode(body, (...))` directly.
    function decodeEnvelope(bytes calldata raw)
        internal
        view
        returns (uint16 statusCode, bytes memory body, string memory errorMessage)
    {
        string[] memory _headers;
        string[] memory _cookies;
        bytes memory rawBody;
        (statusCode, _headers, _cookies, rawBody, errorMessage) =
            abi.decode(raw, (uint16, string[], string[], bytes, string));
        body = HexDecodeLib.maybeHexDecode(rawBody);
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

/// @notice External library so callers (controllers) don't inline the hex loop —
///         keeps MultiLegController runtime under EIP-170.
library HexDecodeLib {
    /// @notice If `input` looks like ASCII hex ("0x..." or plain hex of even length),
    ///         decode it to raw bytes. Otherwise return it unchanged.
    function maybeHexDecode(bytes memory input) external pure returns (bytes memory) {
        uint256 len = input.length;
        uint256 start;
        if (len >= 2 && input[0] == 0x30 && (input[1] == 0x78 || input[1] == 0x58)) {
            start = 2;
            len -= 2;
        }
        if (len == 0 || (len & 1) != 0) return input;
        bytes memory out = new bytes(len / 2);
        for (uint256 i; i < len; i += 2) {
            (uint8 hi, bool okHi) = _hexNibble(uint8(input[start + i]));
            (uint8 lo, bool okLo) = _hexNibble(uint8(input[start + i + 1]));
            if (!okHi || !okLo) return input;
            out[i / 2] = bytes1((hi << 4) | lo);
        }
        return out;
    }

    function _hexNibble(uint8 c) private pure returns (uint8 v, bool ok) {
        if (c >= 0x30 && c <= 0x39) return (c - 0x30, true);
        if (c >= 0x61 && c <= 0x66) return (c - 0x61 + 10, true);
        if (c >= 0x41 && c <= 0x46) return (c - 0x41 + 10, true);
        return (0, false);
    }
}
