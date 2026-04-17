// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {CrossVenueCommandLib} from "../../base/CrossVenueCommandLib.sol";

/// @notice Execution status returned by adapter for a single leg.
enum ExecStatus {
    Pending,
    Filled,
    PartialFill,
    Failed,
    Expired
}

/// @notice Side flag for market orders.
enum Side {
    Buy,
    Sell
}

/// @notice Margin mode for venues that support it (HL perp). Adapter reads this off the intent
///         and sets the venue account's margin mode before placing the order.
///         `Isolated` (default): margin locked per-position; liquidation blast radius is that leg.
///         `Cross`: shared margin across all positions on the HL account — more efficient but
///         one bad position can liquidate others.
///         Non-perp venues (HL spot, Polymarket, Pendle) ignore this field.
enum MarginMode {
    Isolated,
    Cross
}

/// @notice Intent sent to venue adapter for execution.
struct ExecutionIntent {
    bytes32 cycleId;
    bytes32 venue;
    bytes32 marketRef;
    Side side;
    uint256 targetNotionalUsd;
    uint16 maxSlippageBps;
    uint256 expiryBlock;
    bytes32 idempotencyKey;
    MarginMode marginMode; // meaningful only for HL-PERP; other venues ignore
}

/// @notice Normalized receipt returned by adapter after a leg completes.
struct NormalizedExecutionReceipt {
    bytes32 cycleId;
    bytes32 venue;
    ExecStatus status;
    uint256 filledNotionalUsd;
    uint256 filledBaseQty;
    uint256 avgPriceE18;
    bytes32 externalOrderId;
    bytes32 externalAccountRef;
    bool terminal;
    bytes32 rawPayloadHash;
}

/// @notice Normalized funding receipt posted by operator/adapter after a top-up settles on the venue side.
struct FundingReceipt {
    bytes32 cycleId;
    CrossVenueCommandLib.CommandType commandType;
    ExecStatus status;
    uint256 requestedAmount;
    uint256 deliveredAmount;
    bytes32 externalTransferRef;
    bool terminal;
    bytes32 rawPayloadHash;
}

/// @notice One line of the valuation report. Aggregated across all buckets for share-price accounting.
struct ValuationBucket {
    bytes32 bucketId;
    uint256 valueUsd;
    uint16 confidenceBps;
    uint256 timestamp;
}

// ─── Events (shared across all archetypes) ──────────────────────────────────

/// @notice Emitted when the controller wants Base to execute a signed CommandEnvelope.
///         Same fields as CrossVenueCommandLib.CommandEnvelope — the adapter (or any future relay)
///         signs these into EIP-712 and posts to BaseExecutionGateway.executeCommand.
event CommandReady(
    bytes32 indexed cycleId,
    CrossVenueCommandLib.CommandType indexed commandType,
    address dstVault,
    address asset,
    uint256 amount,
    bytes32 destinationRef,
    bytes32 payloadHash,
    uint256 nonce,
    uint256 deadline,
    bytes32 ritualTxHash
);

/// @notice Emitted when the adapter returns a Base tx hash for a signed CommandEnvelope submission.
event BaseCommandSubmitted(bytes32 indexed envelopeNonce, bytes32 baseTxHash, bool baseSuccess);

/// @notice Emitted when the scheduled-tx command push path fails (HTTP / signing / RPC error).
event BaseCommandFailed(bytes32 indexed envelopeNonce, uint16 statusCode, string errorMessage);

/// @notice Emitted when Ritual has unwound venue positions and USDC is ready to be refilled into Base reserve.
event ReserveRefillReady(bytes32 indexed cycleId, uint256 amountUsd);
