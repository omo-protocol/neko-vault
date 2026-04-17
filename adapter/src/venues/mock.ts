import { keccak256, pad, toHex } from "viem";
import type { ExecutionIntent, NormalizedExecutionReceipt, VenueCredentials, LegBufferSnapshot } from "../types.js";
import { ExecStatus } from "../types.js";
import type { VenueAdapter } from "./types.js";

/// Mock venue adapter for integration testing. Always fills `intent.targetNotionalUsd`.
export class MockVenueAdapter implements VenueAdapter {
  constructor(public readonly venueId: `0x${string}`) {}

  async execute(intent: ExecutionIntent, _creds: VenueCredentials): Promise<NormalizedExecutionReceipt> {
    return {
      cycleId: intent.cycleId,
      venue: intent.venue,
      status: ExecStatus.Filled,
      filledNotionalUsd: intent.targetNotionalUsd,
      filledBaseQty: 0n,
      avgPriceE18: 10n ** 18n,
      externalOrderId: pad(toHex(1), { size: 32 }) as `0x${string}`,
      externalAccountRef: pad(toHex(0), { size: 32 }) as `0x${string}`,
      terminal: true,
      rawPayloadHash: keccak256(new TextEncoder().encode("mock")),
    };
  }

  async getBuffer(_creds: VenueCredentials): Promise<LegBufferSnapshot> {
    return { bufferUsd: 100_000_000n, timestamp: BigInt(Math.floor(Date.now() / 1000)) };
  }

  async getPositionMarkValue(): Promise<bigint> {
    return 0n;
  }

  async closeAllAndWithdraw(): Promise<bigint> {
    return 0n;
  }
}
