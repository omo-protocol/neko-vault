// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title RitualBodyProbe
/// @notice Minimal repro that uses the FULL 2-phase long-running HTTP pattern against our
///         adapter's /buffers endpoint. Captures the raw body bytes delivered by the TEE so
///         we can inspect whether it's ASCII hex (UTF-8 of "0x...") or raw abi-encoded bytes.
///
///         Usage:
///           1. Deploy on Ritual.
///           2. setExecutor(workingExecutor) — use 0xEaCC86... which is confirmed live.
///           3. Fund its RitualWallet (owner EOA must have balance + lock).
///           4. probe() → waits for Phase 2 delivery → body stored in `lastBody`.
contract RitualBodyProbe {
    address public constant LONG_RUNNING_HTTP = address(0x0805);
    address public constant ASYNC_DELIVERY = 0x5A16214fF555848411544b005f7Ac063742f39F6;

    address public owner;
    address public executor;
    string public adapterUrl = "http://5.78.25.213:3000/buffers";

    bytes32 public lastJobId;
    uint16 public lastStatusCode;
    bytes public lastBody;
    string public lastErrorMessage;
    uint256 public lastCompletedBlock;

    /// @dev Decoded view of the body if it looks like ASCII hex.
    bytes public lastBodyHexDecoded;
    /// @dev True when body started with ASCII "0x".
    bool public lastBodyLooksHex;

    event Probed(bytes32 indexed jobId, address executor);
    event BodyReceived(bytes32 indexed jobId, uint16 statusCode, uint256 rawLen, bool looksHex, uint256 decodedLen);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _executor) {
        owner = msg.sender;
        executor = _executor;
    }

    receive() external payable {}

    function setExecutor(address _executor) external onlyOwner { executor = _executor; }
    function setAdapterUrl(string calldata u) external onlyOwner { adapterUrl = u; }

    /// @notice Probe /buffers with a 2-phase task_id pattern. Matches our controllers' config.
    function probe() external {
        bytes[] memory emptyBytes = new bytes[](0);
        string[] memory emptyStrs = new string[](0);
        string[] memory ct = new string[](1);
        string[] memory ctv = new string[](1);
        ct[0] = "Content-Type";
        ctv[0] = "application/json";

        bytes memory encoded = abi.encode(
            executor, emptyBytes, uint256(30), emptyBytes, bytes(""),
            uint64(5), uint64(400), "{{TASK_ID}}",
            address(this), this.onResult.selector, uint256(2_000_000),
            uint256(1_000_000_000), uint256(100_000_000), uint256(0),
            string(abi.encodePacked(adapterUrl)),
            uint8(2), ct, ctv,
            abi.encode(bytes32(uint256(1))),
            ".task_id",
            string(abi.encodePacked(adapterUrl, "/status/{{TASK_ID}}")),
            uint8(1), emptyStrs, emptyStrs, bytes(""),
            '.status == "completed"',
            "", uint8(0), emptyStrs, emptyStrs, bytes(""), ".result",
            uint256(0), uint8(0), false
        );

        (bool ok,) = LONG_RUNNING_HTTP.call(encoded);
        require(ok, "precompile failed");

        bytes32 jobId = keccak256(abi.encodePacked("probe", block.number));
        lastJobId = jobId;
        emit Probed(jobId, executor);
    }

    function onResult(bytes32 jobId, bytes calldata result) external {
        require(msg.sender == ASYNC_DELIVERY, "not async delivery");
        (uint16 statusCode, , , bytes memory body, string memory errMsg) =
            abi.decode(result, (uint16, string[], string[], bytes, string));
        lastStatusCode = statusCode;
        lastBody = body;
        lastErrorMessage = errMsg;
        lastCompletedBlock = block.number;

        bool looksHex = body.length >= 2 && body[0] == 0x30 && (body[1] == 0x78 || body[1] == 0x58);
        lastBodyLooksHex = looksHex;
        if (looksHex) {
            lastBodyHexDecoded = _hexDecode(body);
        } else {
            delete lastBodyHexDecoded;
        }
        emit BodyReceived(jobId, statusCode, body.length, looksHex, lastBodyHexDecoded.length);
    }

    function _hexDecode(bytes memory input) internal pure returns (bytes memory out) {
        uint256 len = input.length - 2;
        if (len == 0 || (len & 1) != 0) return new bytes(0);
        out = new bytes(len / 2);
        for (uint256 i; i < len; i += 2) {
            uint8 hi = _nib(uint8(input[2 + i]));
            uint8 lo = _nib(uint8(input[2 + i + 1]));
            out[i / 2] = bytes1((hi << 4) | lo);
        }
    }

    function _nib(uint8 c) internal pure returns (uint8) {
        if (c >= 0x30 && c <= 0x39) return c - 0x30;
        if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
        if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
        return 0;
    }
}
