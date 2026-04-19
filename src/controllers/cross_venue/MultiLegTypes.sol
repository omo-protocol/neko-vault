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

// Sentinel for `referenceLegIndex` on a reference leg (the exposure this leg group is taking).
// Hedge legs point at another leg's index; reference legs use this sentinel.
uint8 constant REF_LEG_SENTINEL = type(uint8).max;

/// @notice Per-leg configuration. Delta-managed framework:
///           • Reference leg (`referenceLegIndex == REF_LEG_SENTINEL`): notional sized from cycle
///             target × |weightBps|/10000. Carries the exposure the strategy wants.
///           • Hedge leg (`referenceLegIndex < legCount`): notional = referenceLeg.fill × w × β
///             where `w = |weightBps|/10000` and `β = betaBps/10000`. Sign of `weightBps` carries
///             the direction (+ same side as reference, − opposite — i.e. hedge).
///         Classic delta-neutral is `w=1.0, β=1.0` on a hedge leg pointing at a long spot ref.
///         Partial hedge is any w<1.0; cross-instrument hedge is β≠1.0 (e.g. BTC perp hedging
///         ETH spot at some empirical beta).
struct LegConfig {
    bytes32 venue;
    bytes32 marketRef;
    int16 weightBps;
    /// @dev Hard cap on `|weightBps|` applied to BOTH the static weight and any Kelly override.
    ///      Set to 0 to skip the cap. Operator uses this to bound quant/Kelly risk — Kelly can't
    ///      exceed this value even if signed and fresh.
    uint16 maxAbsWeightBps;
    /// @dev Framework: reference leg index, or `REF_LEG_SENTINEL` when this IS the reference.
    ///      Replaces the old boolean `sizeFromPrevFill` (which assumed ref=leg[idx-1], β=1).
    uint8 referenceLegIndex;
    /// @dev Framework: instrument-level hedge ratio in bps (10000 = 1.0). SIGNED to support
    ///      anti-correlated instruments (PM YES/NO have β = -1.0; HL perp vs spot have β = +1.0;
    ///      BTC perp hedging ETH spot at empirical 0.65 is β = +6500). Magnitude sizes the
    ///      hedge; sign combined with weightBps sign gives the order direction (BUY/SELL) on
    ///      the hedge instrument. Only consulted for hedge legs; reference legs ignore.
    int16 betaBps;
    /// @dev Framework: rebalance drift tolerance in bps of w (1000 = 10% drift allowed).
    ///      `tick()` auto-triggers a rebalance cycle when
    ///      `|w_effective − w_target| > driftToleranceBps` on any hedge leg. 0 = no auto-drift
    ///      rebalance (operator-driven only). Only consulted for hedge legs.
    uint16 driftToleranceBps;
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

/// @notice Off-chain Kelly override. Framework: Kelly solves for BOTH size and weight — the
///         vector `targetWeightBps[i]` per leg lets the signer push time-varying hedge ratios
///         that adapt to conviction. Replay-protected by `nonce`; operator-set `validUntil`
///         bounds freshness. Signed by `kellySigner` (EIP-191 over encoded digest).
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
/// @notice Emitted when the scheduler auto-triggers a partial unwind because the latest
///         valuation reported Base reserve below `minBaseReserveUsd`.
event AutoUnwindTriggered(bytes32 indexed cycleId, uint256 baseReserveUsd, uint256 targetRefillUsd);
/// @notice Emitted when controller detects more LEG_FAILED auto-clears than `legFailThreshold`
///         — operator should investigate rather than let retries burn RitualWallet gas.
event LegFailThresholdHit(uint256 count);
event MultiLegFundingReceiptIngested(
    bytes32 indexed cycleId, uint8 legIndex, CrossVenueCommandLib.CommandType commandType, ExecStatus status
);

/// @notice Emitted after a valuation sync pushes NAV to Base. Logs the Base tx hash returned
///         by the TEE adapter so indexers can confirm the updateValue landed on-chain.
event ValuationPushed(uint256 navUsd, uint256 baseReserveUsd, bytes32 baseTxHash, bool baseSuccess);
