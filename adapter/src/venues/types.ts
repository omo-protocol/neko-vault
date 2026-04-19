import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
} from "../types.js";

/// Per-execute context injected by the server with infra addresses the adapter needs for
/// bridging realized USDC back to Base after a close-side delta-rebalance. Stateless from
/// the adapter's POV — plumbed each call.
export interface VenueExecContext {
  /// `BaseStrategyModule` address. CCTP `mintRecipient` when adapter bridges venue→Base USDC
  /// after a position close; controller's subsequent `REFILL_RESERVE` command then directs
  /// the module to credit the sleeve.
  moduleAddress: `0x${string}`;
}

/// Interface every venue adapter (PM, HL perp, HL spot, Pendle) implements.
/// Implementations are stateless per-request; credentials are TEE-injected per call.
export interface VenueAdapter {
  /// Unique identifier for the venue (keccak256 of the canonical name).
  readonly venueId: `0x${string}`;

  /// Open or close a leg. Returns normalized receipt (terminal when done). `ctx` is optional
  /// for back-compat with call-sites that don't need the CCTP-back path.
  execute(
    intent: ExecutionIntent,
    creds: VenueCredentials,
    ctx?: VenueExecContext
  ): Promise<NormalizedExecutionReceipt>;

  /// Current buffer balance on the venue side (USDC available for trading).
  getBuffer(creds: VenueCredentials): Promise<LegBufferSnapshot>;

  /// Mark-to-market value of the strategy's open positions on this venue.
  getPositionMarkValue(
    creds: VenueCredentials,
    strategyId: `0x${string}`
  ): Promise<bigint>;

  /// Close all open positions for this venue and withdraw USDC. Returns realized amount.
  closeAllAndWithdraw(
    creds: VenueCredentials,
    strategyId: `0x${string}`
  ): Promise<bigint>;
}
