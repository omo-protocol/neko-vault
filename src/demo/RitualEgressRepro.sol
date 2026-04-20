// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @title RitualEgressRepro
/// @notice Minimal repro contract for demonstrating that the Ritual TEE long-running HTTP
///         precompile (`0x0805`) does not deliver to our adapter endpoint.
///
///         Usage:
///           1. Deploy on Ritual mainnet (rpc.ritualfoundation.org). Fund its RitualWallet.
///           2. Set executor via `setExecutor(addr)` — pick any valid TEE from TEEServiceRegistry.
///           3. Call `ping()` from an EOA that has RitualWallet balance + lock.
///           4. Watch for `HttpResult` event. If it never fires, the TEE didn't deliver.
///
///         The GET request hits `http://5.78.25.213:3000/health` which returns JSON.
///         Status 200 is expected; any non-2xx or null body indicates the executor never
///         reached the endpoint.
contract RitualEgressRepro {
    address public constant LONG_RUNNING_HTTP = address(0x0805);
    address public constant ASYNC_DELIVERY = 0x5A16214fF555848411544b005f7Ac063742f39F6;
    address public constant RITUAL_WALLET = 0x532F0dF0896F353d8C3DD8cc134e8129DA2a3948;

    address public owner;
    address public executor;
    string public adapterUrl = "http://5.78.25.213:3000/health";

    bytes32 public lastJobId;
    uint16 public lastStatusCode;
    bytes public lastBody;
    string public lastErrorMessage;
    uint256 public lastCompletedBlock;

    event Pinged(bytes32 indexed jobId, address executor, string url);
    event HttpResult(bytes32 indexed jobId, uint16 statusCode, uint256 bodyLen, string errorMessage);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    constructor(address _executor) {
        owner = msg.sender;
        executor = _executor;
    }

    receive() external payable {}

    function setExecutor(address _executor) external onlyOwner {
        executor = _executor;
    }

    function setAdapterUrl(string calldata u) external onlyOwner {
        adapterUrl = u;
    }

    /// @notice Fire a single long-running HTTP GET to `adapterUrl`. Callback is `onResult`.
    function ping() external {
        bytes[] memory emptyBytes = new bytes[](0);
        string[] memory emptyStrs = new string[](0);

        bytes memory encoded = abi.encode(
            // Base executor fields (5)
            executor,
            emptyBytes,             // encryptedSecrets
            uint256(30),            // ttl
            emptyBytes,             // secretSignatures
            bytes(""),              // userPublicKey
            // Polling config (3)
            uint64(5),              // pollIntervalBlocks
            uint64(500),            // maxPollBlock
            "{{TASK_ID}}",
            // Delivery config (6)
            address(this),          // deliveryTarget
            this.onResult.selector, // deliverySelector
            uint256(300_000),       // deliveryGasLimit
            uint256(1_000_000_000),
            uint256(100_000_000),
            uint256(0),
            // Initial HTTP request (6)
            adapterUrl,
            uint8(1),               // GET
            emptyStrs,              // headersKeys
            emptyStrs,              // headersValues
            bytes(""),              // body
            ".status",              // taskIdJsonPath — doesn't matter for a single-shot
            // Poll request (6)
            adapterUrl,
            uint8(1),
            emptyStrs,
            emptyStrs,
            bytes(""),
            '.status == "ok"',      // statusJsonPath — our /health returns {"status":"ok"}
            // Result request (6)
            "",                     // use poll response
            uint8(0),
            emptyStrs,
            emptyStrs,
            bytes(""),
            ".status",
            // DKMS + PII (3)
            uint256(0),
            uint8(0),
            false
        );

        (bool ok,) = LONG_RUNNING_HTTP.call(encoded);
        require(ok, "precompile call failed");

        bytes32 jobId = keccak256(abi.encodePacked("ping", block.number, block.timestamp));
        lastJobId = jobId;
        emit Pinged(jobId, executor, adapterUrl);
    }

    /// @notice Callback from AsyncDelivery. If this fires, TEE CAN reach our endpoint. If not,
    ///         TEE egress is blocked or the request was dropped silently.
    function onResult(bytes32 jobId, bytes calldata result) external {
        require(msg.sender == ASYNC_DELIVERY, "not async delivery");
        (uint16 statusCode, , , bytes memory body, string memory errorMessage) =
            abi.decode(result, (uint16, string[], string[], bytes, string));
        lastStatusCode = statusCode;
        lastBody = body;
        lastErrorMessage = errorMessage;
        lastCompletedBlock = block.number;
        emit HttpResult(jobId, statusCode, body.length, errorMessage);
    }
}
