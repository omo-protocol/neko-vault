import {
  type Hex,
  decodeAbiParameters,
  encodeAbiParameters,
  type AbiParameter,
} from "viem";
import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  CommandEnvelope,
  LegBufferSnapshot,
  ValuationSyncResponse,
} from "./types.js";

// ─── ABI parameter definitions (match Solidity structs exactly) ─────────────

const EXEC_INTENT_ABI: AbiParameter[] = [
  {
    type: "tuple",
    components: [
      { name: "cycleId", type: "bytes32" },
      { name: "venue", type: "bytes32" },
      { name: "marketRef", type: "bytes32" },
      { name: "side", type: "uint8" },
      { name: "targetNotionalUsd", type: "uint256" },
      { name: "maxSlippageBps", type: "uint16" },
      { name: "expiryBlock", type: "uint256" },
      { name: "idempotencyKey", type: "bytes32" },
      { name: "marginMode", type: "uint8" },
    ],
  },
];

const RECEIPT_ABI: AbiParameter[] = [
  {
    type: "tuple",
    components: [
      { name: "cycleId", type: "bytes32" },
      { name: "venue", type: "bytes32" },
      { name: "status", type: "uint8" },
      { name: "filledNotionalUsd", type: "uint256" },
      { name: "filledBaseQty", type: "uint256" },
      { name: "avgPriceE18", type: "uint256" },
      { name: "externalOrderId", type: "bytes32" },
      { name: "externalAccountRef", type: "bytes32" },
      { name: "terminal", type: "bool" },
      { name: "rawPayloadHash", type: "bytes32" },
    ],
  },
];

const COMMAND_ENVELOPE_ABI: AbiParameter[] = [
  {
    type: "tuple",
    components: [
      { name: "cycleId", type: "bytes32" },
      { name: "commandType", type: "uint8" },
      { name: "dstVault", type: "address" },
      { name: "asset", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "destinationRef", type: "bytes32" },
      { name: "payloadHash", type: "bytes32" },
      { name: "nonce", type: "uint256" },
      { name: "deadline", type: "uint256" },
      { name: "ritualTxHash", type: "bytes32" },
    ],
  },
];

const BUFFER_SNAPSHOT_ARRAY_ABI: AbiParameter[] = [
  {
    type: "tuple[]",
    components: [
      { name: "bufferUsd", type: "uint256" },
      { name: "timestamp", type: "uint256" },
    ],
  },
];

const VALUATION_RESPONSE_ABI: AbiParameter[] = [
  { type: "uint256" }, // navUsd
  { type: "uint256" }, // baseReserveUsd
  { type: "bytes32" }, // baseTxHash
  { type: "bool" }, // baseSuccess
];

const UNWIND_RESULT_ABI: AbiParameter[] = [{ type: "uint256" }]; // realizedUsd

// ─── Decode (called on received payloads from Ritual controllers) ──────────

export function decodeExecutionIntent(raw: Hex): ExecutionIntent {
  const [t] = decodeAbiParameters(EXEC_INTENT_ABI, raw);
  return t as unknown as ExecutionIntent;
}

export function decodeCommandEnvelope(raw: Hex): CommandEnvelope {
  const [t] = decodeAbiParameters(COMMAND_ENVELOPE_ABI, raw);
  return t as unknown as CommandEnvelope;
}

// ─── Encode (for response bodies the controller callbacks decode) ──────────

export function encodeExecutionReceipt(r: NormalizedExecutionReceipt): Hex {
  return encodeAbiParameters(RECEIPT_ABI, [r]);
}

export function encodeBufferSnapshots(snaps: LegBufferSnapshot[]): Hex {
  return encodeAbiParameters(BUFFER_SNAPSHOT_ARRAY_ABI, [snaps]);
}

export function encodeValuationResponse(v: ValuationSyncResponse): Hex {
  return encodeAbiParameters(VALUATION_RESPONSE_ABI, [
    v.navUsd,
    v.baseReserveUsd,
    v.baseTxHash,
    v.baseSuccess,
  ]);
}

export function encodeUnwindResult(realizedUsd: bigint): Hex {
  return encodeAbiParameters(UNWIND_RESULT_ABI, [realizedUsd]);
}
