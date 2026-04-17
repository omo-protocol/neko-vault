// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.28;

import {CrossVenueCommandLib} from "../../base/CrossVenueCommandLib.sol";
import {
    Side,
    MarginMode,
    ExecStatus,
    ExecutionIntent,
    NormalizedExecutionReceipt,
    FundingReceipt
} from "./SharedVenueTypes.sol";

uint8 constant MAX_LEGS = 8;

// The three allowed MultiLeg venue identifiers. Any other venue is rejected at init.
// HL perp and HL spot share the same Base→HL funding rail (TOPUP_HL_BUFFER); the adapter routes
// within HyperLiquid by venue bytes32.
bytes32 constant ML_VENUE_HL_PERP = keccak256("HYPERLIQUID-PERP");
bytes32 constant ML_VENUE_HL_SPOT = keccak256("HYPERLIQUID-SPOT");
bytes32 constant ML_VENUE_PM = keccak256("POLYMARKET");

enum MultiLegFundingState {
    OK,
    TOPUP_PENDING,
    STALE,
    PAUSED
}

enum MultiLegTradingState {
    IDLE,
    LEG_PENDING,
    VALUATION_PENDING,
    READY,
    LEG_FAILED,
    UNHEDGED,
    RECOVERY_REQUIRED,
    PAUSED,
    UNWIND_PENDING
}

/// @notice Per-leg configuration. `venue` MUST be one of `ML_VENUE_HL_PERP`, `ML_VENUE_HL_SPOT`,
///         or `ML_VENUE_PM`. The controller hardcodes venue → command-type mapping:
///           • HL perp / HL spot → `TOPUP_HL_BUFFER` (same Base→HL funding rail)
///           • PM → `TOPUP_PM_BUFFER`
///         **Directionality is inherent in `weightBps`**:
///           • HL perp: positive = long, negative = short.
///           • HL spot: positive = buy (only). Negative weight is rejected at init (can't sell what you don't hold).
///           • PM: positive = buy YES, negative = buy NO (venue-specific interpretation by adapter).
///         Magnitude = share of cycle notional (or of previous-leg fill when `sizeFromPrevFill = true`).
///         Examples:
///           • Basis (HL spot + HL perp): leg 0 spot +5000, leg 1 perp -5000 sized from prev fill.
///           • 2-leg hedge (PM + HL perp): leg 0 PM +5000, leg 1 perp -10000 sized from prev fill.
///           • Portfolio (PM + HL spot + HL perp): +4000 / +3000 / -3000 (perp hedge).
/// @dev Note on PM semantics: for PM legs, `marketRef` MUST uniquely identify the outcome token
///      (e.g. `keccak256(abi.encodePacked(pmMarketId, outcomeTokenId))`) — YES, NO, or any MCQ
///      option is a distinct leg. Hedge directionality on PM is strategy-level (operator pairs
///      outcomes across legs to shape the payoff); the +/- weight sign on a PM leg means simply
///      "buy this outcome token" (+) or "sell existing holdings of this outcome" (-), NOT
///      long/short. HL perp legs follow the standard long/short convention; HL spot is buy-only.
struct LegConfig {
    bytes32 venue;
    bytes32 marketRef;
    int16 weightBps;
    /// @dev Hard cap on `|weightBps|` applied to BOTH the static weight and any Kelly override.
    ///      Set to 0 to skip the cap. Operator uses this to bound quant/Kelly risk — Kelly can't
    ///      exceed this value even if signed and fresh.
    uint16 maxAbsWeightBps;
    bool sizeFromPrevFill;
    uint16 maxSlippageBps;
    uint256 bufferTargetUsd;
    uint256 bufferMinUsd;
    bytes32 destinationRef;
    /// @dev Only meaningful for HL-PERP legs. HL-SPOT / POLYMARKET legs ignore.
    MarginMode marginMode;
}

/// @notice Per-leg buffer snapshot reported by adapter.
struct LegBufferSnapshot {
    uint256 bufferUsd;
    uint256 timestamp;
}

/// @notice Per-leg fill record for the active cycle.
struct LegFill {
    ExecStatus status;
    uint256 filledNotionalUsd;
    uint256 avgPriceE18;
    bytes32 externalOrderId;
}

/// @notice Off-chain Kelly override. Optional; if absent or expired, controller falls back to static weights.
///         Signed by `kellySigner`. Replay-protected by `nonce`; operator-set `validUntil` bounds freshness.
struct OffchainKellyWeights {
    int16[MAX_LEGS] targetWeightBps; // signed, same semantics as LegConfig.weightBps
    uint256 totalTargetNotional;
    uint256 validUntil;
    bytes32 nonce;
}

// ─── Events ─────────────────────────────────────────────────────────────────

event MultiLegCycleRequested(bytes32 indexed cycleId, uint256 targetNotionalUsd, uint8 legCount);
event MultiLegLegSubmitted(bytes32 indexed cycleId, uint8 legIndex, bytes32 jobId, uint256 targetNotionalUsd);
event MultiLegLegFill(bytes32 indexed cycleId, uint8 legIndex, ExecStatus status, uint256 filledNotionalUsd);
event MultiLegCycleCompleted(bytes32 indexed cycleId);
event MultiLegRecoveryMarked(bytes32 indexed cycleId, uint8 failedLegIndex, string reason);
event MultiLegFundingStateChanged(MultiLegFundingState indexed next);
event MultiLegTradingStateChanged(MultiLegTradingState indexed next);
event MultiLegBufferSnapshotUpdated(uint8 legIndex, uint256 bufferUsd, uint256 timestamp);
event MultiLegBufferSyncSubmitted(bytes32 jobId);
event MultiLegKellyApplied(bytes32 indexed nonce, uint256 totalTargetNotional, uint256 validUntil);
event MultiLegFundingReceiptIngested(
    bytes32 indexed cycleId, uint8 legIndex, CrossVenueCommandLib.CommandType commandType, ExecStatus status
);

/// @notice Emitted after a valuation sync pushes NAV to Base. Logs the Base tx hash returned
///         by the TEE adapter so indexers can confirm the updateValue landed on-chain.
event ValuationPushed(uint256 navUsd, uint256 baseReserveUsd, bytes32 baseTxHash, bool baseSuccess);

/// @notice Emitted when the scheduler auto-triggers an unwind because Base reserve fell below
///         `minReserveUsd` per the latest valuation-sync report.
event AutoUnwindTriggered(bytes32 indexed cycleId, uint256 baseReserveUsd, uint256 targetRefillUsd);
