// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {RitualPrecompiles} from "../interfaces/ritual/IRitualPrecompiles.sol";
import {RitualHttpLib} from "../controllers/cross_venue/RitualHttpLib.sol";

/// @title CallbackAsyncChain — live probe for "can an async callback emit another async call?"
/// @notice Deploy on Ritual, fund the contract's RitualWallet, call `kickoff()`.
///         Observe whether `firstDelivery` succeeds (chained) or emits `ChainFailed` (blocked).
///
///         Two paths are demonstrated:
///           (A) DEFERRED — the callback sets a flag, a later external `dispatchDeferred()` (called
///               from a fresh tx / scheduler tick) fires the second async call. This is the
///               pattern our controllers use today. Always works.
///           (B) INLINE   — the callback itself calls the precompile immediately. If Ritual
///               enforces "one async per tx" against the AsyncDelivery delivery tx, this reverts
///               or the AsyncDelivery layer emits `DeliveryFailed`. If long-running (0x0805) is
///               exempt (per `ritual-meta-projection` skill), it succeeds.
///
///         `mode` selects which path the first callback takes, so a single deployment can probe
///         both patterns across two kickoff runs. Results land in `trace` events.
contract CallbackAsyncChain {
    address public owner;
    address public executor;
    bytes public firstPayload;
    bytes public secondPayload;

    enum Mode {
        DEFERRED,
        INLINE
    }

    Mode public mode;

    bool public firstDone;
    bool public secondDone;
    bytes public firstBody;
    bytes public secondBody;

    bytes32 public pendingJobId;
    bool public deferredPending;

    event Kickoff(bytes32 indexed jobId);
    event FirstDelivered(bytes body);
    event SecondSubmitted(bytes32 indexed jobId, string path);
    event SecondDelivered(bytes body);
    event ChainFailed(string where, string reason);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyAsyncDelivery() {
        require(msg.sender == RitualPrecompiles.ASYNC_DELIVERY, "not async delivery");
        _;
    }

    constructor(address _executor, bytes memory _firstPayload, bytes memory _secondPayload) {
        owner = msg.sender;
        executor = _executor;
        firstPayload = _firstPayload;
        secondPayload = _secondPayload;
        mode = Mode.DEFERRED;
    }

    receive() external payable {}

    function setMode(Mode m) external onlyOwner {
        mode = m;
    }

    /// @notice Fire the first 0x0805 call. Callback routes to `firstDelivery`.
    function kickoff(string calldata url) external onlyOwner {
        firstDone = false;
        secondDone = false;
        delete firstBody;
        delete secondBody;
        deferredPending = false;

        _submitAsync(url, firstPayload, this.firstDelivery.selector);
        emit Kickoff(bytes32(0)); // jobId arrives via AsyncDelivery events, not the submit return
    }

    /// @notice Phase-2 delivery callback for the FIRST async call.
    ///         - DEFERRED mode: flag `deferredPending`; a later tx calls `dispatchDeferred`.
    ///         - INLINE mode: immediately fire the second 0x0805 call. This is the interesting
    ///           experiment — it probes whether the delivery tx can host another async submit.
    function firstDelivery(bytes32, /*jobId*/ bytes calldata response) external onlyAsyncDelivery {
        (uint16 status, bytes memory body, string memory err) = RitualHttpLib.decodeEnvelope(response);
        if (status >= 400 || bytes(err).length != 0) {
            emit ChainFailed("first", err);
            return;
        }
        firstBody = body;
        firstDone = true;
        emit FirstDelivered(body);

        if (mode == Mode.DEFERRED) {
            deferredPending = true;
            return;
        }

        // INLINE path — this is what the "one async per tx" rule is about. If Ritual blocks
        // nested async submission here, the submit reverts or AsyncDelivery sees the delivery
        // tx itself fail with DeliveryFailed. Instrument with a try/catch-like flag so we can
        // tell "call returned false" from "entire delivery tx reverted".
        try this._submitSecondInline() {
            // ok — precompile accepted a second async within the same delivery tx.
        } catch Error(string memory reason) {
            emit ChainFailed("inline-submit", reason);
        } catch (bytes memory) {
            emit ChainFailed("inline-submit", "low-level revert");
        }
    }

    /// @notice Separately-callable (external self-call so try/catch works) inline submit.
    function _submitSecondInline() external {
        require(msg.sender == address(this), "self only");
        _submitAsync("https://httpbin.org/anything", secondPayload, this.secondDelivery.selector);
        emit SecondSubmitted(bytes32(0), "inline");
    }

    /// @notice Called from a fresh tx (or a scheduler tick) after DEFERRED kickoff to complete
    ///         the chain. This is how our MultiLeg / PtLoop controllers dispatch deferred
    ///         intents today.
    function dispatchDeferred(string calldata url) external onlyOwner {
        require(deferredPending, "nothing deferred");
        deferredPending = false;
        _submitAsync(url, secondPayload, this.secondDelivery.selector);
        emit SecondSubmitted(bytes32(0), "deferred");
    }

    function secondDelivery(bytes32, /*jobId*/ bytes calldata response) external onlyAsyncDelivery {
        (uint16 status, bytes memory body, string memory err) = RitualHttpLib.decodeEnvelope(response);
        if (status >= 400 || bytes(err).length != 0) {
            emit ChainFailed("second", err);
            return;
        }
        secondBody = body;
        secondDone = true;
        emit SecondDelivered(body);
    }

    function _submitAsync(string memory url, bytes memory payload, bytes4 callback) internal {
        bytes[] memory noSecrets;
        bytes[] memory noSigs;
        string[] memory noHeaderKeys;
        string[] memory noHeaderValues;

        RitualHttpLib.HttpRequest memory req = RitualHttpLib.HttpRequest({
            url: url,
            payload: payload,
            executor: executor,
            encryptedSecrets: noSecrets,
            secretSignatures: noSigs,
            secretHeaderKeys: noHeaderKeys,
            secretHeaderValues: noHeaderValues,
            ttl: 30
        });

        RitualHttpLib.Polling memory polling =
            RitualHttpLib.Polling({pollIntervalBlocks: 25, maxPollBlock: 4500});

        RitualHttpLib.Delivery memory delivery =
            RitualHttpLib.Delivery({target: address(this), callback: callback, gasLimit: 2_000_000});

        RitualHttpLib.submit(req, polling, delivery);
    }
}
