import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
} from "../types.js";

/// Interface every venue adapter (PM, HL perp, HL spot, Pendle) implements.
/// Implementations are stateless per-request; credentials are TEE-injected per call.
export interface VenueAdapter {
  /// Unique identifier for the venue (keccak256 of the canonical name).
  readonly venueId: `0x${string}`;

  /// Open or close a leg. Returns normalized receipt (terminal when done).
  execute(
    intent: ExecutionIntent,
    creds: VenueCredentials
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
