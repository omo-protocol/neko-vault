import type { Hex, Address } from "viem";

// ─── Enums (must match Solidity ordinals in SharedVenueTypes.sol) ───────────

export enum ExecStatus {
  Pending = 0,
  Filled = 1,
  PartialFill = 2,
  Failed = 3,
  Expired = 4,
}

export enum Side {
  Buy = 0,
  Sell = 1,
}

export enum MarginMode {
  Isolated = 0,
  Cross = 1,
}

export enum CommandType {
  TOPUP_PM_BUFFER = 0,
  TOPUP_HL_BUFFER = 1,
  PAUSE = 2,
  REFILL_RESERVE = 3,
}

// ─── ExecutionIntent ────────────────────────────────────────────────────────

export interface ExecutionIntent {
  cycleId: Hex;
  venue: Hex;
  marketRef: Hex;
  side: Side;
  targetNotionalUsd: bigint;
  maxSlippageBps: number;
  expiryBlock: bigint;
  idempotencyKey: Hex;
  marginMode: MarginMode;
}

export interface NormalizedExecutionReceipt {
  cycleId: Hex;
  venue: Hex;
  status: ExecStatus;
  filledNotionalUsd: bigint;
  filledBaseQty: bigint;
  avgPriceE18: bigint;
  externalOrderId: Hex;
  externalAccountRef: Hex;
  terminal: boolean;
  rawPayloadHash: Hex;
}

// ─── CommandEnvelope (matches CrossVenueCommandLib.CommandEnvelope) ─────────

export interface CommandEnvelope {
  cycleId: Hex;
  commandType: CommandType;
  dstVault: Address;
  asset: Address;
  amount: bigint;
  destinationRef: Hex;
  payloadHash: Hex;
  nonce: bigint;
  deadline: bigint;
  ritualTxHash: Hex;
}

// ─── Buffer snapshots ───────────────────────────────────────────────────────

export interface LegBufferSnapshot {
  bufferUsd: bigint;
  timestamp: bigint;
}

// ─── Valuation response (used by /valuation endpoint → controller callback) ─

export interface ValuationSyncResponse {
  navUsd: bigint;
  baseReserveUsd: bigint;
  baseTxHash: Hex;
  baseSuccess: boolean;
}

// ─── Venue credentials (TEE-injected via secret headers) ────────────────────

export interface VenueCredentials {
  hlPrivateKey?: Hex;
  pmPrivateKey?: Hex;
  pmApiKey?: string;
  pmApiSecret?: string;
  pmApiPassphrase?: string;
  baseSignerKey?: Hex; // TEE-injected Base EOA for /base/execute-command + /valuation push
  valuerSignerKey?: Hex; // TEE-injected valuer signer (may equal baseSignerKey)
}

// ─── Async HTTP envelope (Long-Running HTTP result format) ──────────────────

export interface AsyncHttpEnvelope {
  statusCode: number;
  headers: [string, string][];
  cookies: string[];
  body: Hex;
  errorMessage: string;
}
