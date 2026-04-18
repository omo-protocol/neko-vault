import {
  keccak256,
  toHex,
  toBytes,
  pad,
  concat,
  type Hex,
  type Address,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { encode as msgpackEncode } from "@msgpack/msgpack";
import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
} from "../types.js";
import { ExecStatus, Side, MarginMode } from "../types.js";
import type { VenueAdapter } from "./types.js";

/// HyperLiquid REST API base (mainnet). Set `HL_API_URL` env override if using testnet.
const HL_API_URL = process.env.HL_API_URL ?? "https://api.hyperliquid.xyz";

/// Venue IDs — must match Solidity constants.
export const V_HL_PERP = keccak256(toBytes("HYPERLIQUID-PERP"));
export const V_HL_SPOT = keccak256(toBytes("HYPERLIQUID-SPOT"));

/// Operator-maintained mapping: `marketRef` bytes32 → HL asset index + ticker. Populate per-strategy.
/// Legacy — use dynamic resolution via `loadHlMarketsFromApi` instead. Kept for back-compat.
export interface HlMarketEntry {
  assetIndex: number;
  szDecimals: number;
  tickerSymbol: string;
}

export type HlMarketRegistry = Record<Hex, HlMarketEntry>;

/// Canonical `marketRef` convention for HL legs: `keccak256(bytes(tickerSymbol))`.
/// e.g. for ETH perp, operator sets `leg.marketRef = keccak256(toBytes("ETH"))` when initializing
/// the controller. No JSON file needed — adapter resolves dynamically by fetching the HL meta.
export async function loadHlMarketsFromApi(apiUrl = HL_API_URL): Promise<HlMarketRegistry> {
  const reg: HlMarketRegistry = {};
  // Perp meta.
  const perpMeta = await fetch(`${apiUrl}/info`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: "meta" }),
  }).then((r) => r.json()).catch(() => null);
  const universe: Array<{ name: string; szDecimals: number }> = perpMeta?.universe ?? [];
  universe.forEach((u, i) => {
    const ref = keccak256(toBytes(u.name)) as Hex;
    reg[ref] = { assetIndex: i, szDecimals: u.szDecimals, tickerSymbol: u.name };
  });
  // Spot meta — spot asset indices are offset by 10000 per HL convention.
  const spotMeta = await fetch(`${apiUrl}/info`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ type: "spotMeta" }),
  }).then((r) => r.json()).catch(() => null);
  const tokens: Array<{ name: string; szDecimals: number; index: number }> = spotMeta?.tokens ?? [];
  tokens.forEach((t) => {
    const ref = keccak256(toBytes(`SPOT:${t.name}`)) as Hex;
    if (!reg[ref]) {
      reg[ref] = { assetIndex: 10000 + t.index, szDecimals: t.szDecimals, tickerSymbol: t.name };
    }
  });
  return reg;
}

interface HlOrderAction {
  type: "order";
  orders: Array<{
    a: number;
    b: boolean;
    p: string;
    s: string;
    r: boolean;
    t: { limit: { tif: "Ioc" | "Gtc" } };
  }>;
  grouping: "na";
}

interface HlSignedExchangeReq {
  action: unknown;
  nonce: number;
  signature: { r: Hex; s: Hex; v: number };
  vaultAddress?: Address;
}

/// HyperLiquid adapter covering both perp (`V_HL_PERP`) and spot (`V_HL_SPOT`) venues.
/// `execute` submits IOC market orders, polls fills, and returns a normalized receipt.
export class HyperliquidAdapter implements VenueAdapter {
  constructor(
    public readonly venueId: typeof V_HL_PERP | typeof V_HL_SPOT,
    private readonly markets: HlMarketRegistry
  ) {}

  private isPerp(): boolean {
    return this.venueId === V_HL_PERP;
  }

  async execute(intent: ExecutionIntent, creds: VenueCredentials): Promise<NormalizedExecutionReceipt> {
    if (!creds.hlPrivateKey) return failReceipt(intent, "no HL key");
    const market = this.markets[intent.marketRef];
    if (!market) return failReceipt(intent, "unknown marketRef");

    const account = privateKeyToAccount(creds.hlPrivateKey);

    // Set margin mode for perp (isolated / cross) before placing the order. For spot this is a no-op.
    if (this.isPerp()) {
      try {
        await this.setMarginMode(account.address, creds.hlPrivateKey, market.assetIndex, intent.marginMode);
      } catch {
        // Margin-mode already set, or venue rejected — proceed; the order may still fill under the current mode.
      }
    }

    // Get mid-price to estimate size from USD notional.
    const mid = await this.getMidPrice(market.tickerSymbol);
    if (mid <= 0) return failReceipt(intent, "no mid price");
    const sizeBase = Number(intent.targetNotionalUsd) / 1e6 / mid;
    const sizeStr = sizeBase.toFixed(market.szDecimals);

    const action: HlOrderAction = {
      type: "order",
      orders: [
        {
          a: market.assetIndex,
          b: intent.side === Side.Buy,
          p: "0", // market order: price = 0 with IOC
          s: sizeStr,
          r: false,
          t: { limit: { tif: "Ioc" } },
        },
      ],
      grouping: "na",
    };

    const nonce = Date.now();
    const resp = await this.signAndPost(action, nonce, creds.hlPrivateKey);
    if (resp?.status !== "ok") return failReceipt(intent, `hl order rejected: ${JSON.stringify(resp).slice(0, 150)}`);

    // Poll user fills for the nonce-tagged fills (up to ~30s).
    const filled = await this.pollFilled(account.address, market.assetIndex, nonce, 30);
    if (!filled) return failReceipt(intent, "no fill within timeout");

    return {
      cycleId: intent.cycleId,
      venue: intent.venue,
      status: filled.filledUsd >= intent.targetNotionalUsd ? ExecStatus.Filled : ExecStatus.PartialFill,
      filledNotionalUsd: filled.filledUsd,
      filledBaseQty: filled.filledBase,
      avgPriceE18: filled.avgPriceE18,
      externalOrderId: pad(toHex(filled.oid), { size: 32 }) as Hex,
      externalAccountRef: pad(account.address, { size: 32 }) as Hex,
      terminal: true,
      rawPayloadHash: keccak256(toBytes(JSON.stringify(resp))),
    };
  }

  async getBuffer(creds: VenueCredentials): Promise<LegBufferSnapshot> {
    if (!creds.hlPrivateKey) return { bufferUsd: 0n, timestamp: nowSec() };
    const account = privateKeyToAccount(creds.hlPrivateKey);
    if (this.isPerp()) {
      const state = await this.hlInfo({ type: "clearinghouseState", user: account.address });
      const withdrawable = parseFloat(state?.withdrawable ?? "0");
      return { bufferUsd: BigInt(Math.floor(withdrawable * 1e6)), timestamp: nowSec() };
    } else {
      const state = await this.hlInfo({ type: "spotClearinghouseState", user: account.address });
      // USDC balance on spot
      const bal = Array.isArray(state?.balances) ? state.balances : [];
      const usdc = bal.find((b: { coin: string }) => b.coin === "USDC");
      const amount = parseFloat(usdc?.total ?? "0");
      return { bufferUsd: BigInt(Math.floor(amount * 1e6)), timestamp: nowSec() };
    }
  }

  async getPositionMarkValue(creds: VenueCredentials, _strategyId: Hex): Promise<bigint> {
    if (!creds.hlPrivateKey) return 0n;
    const account = privateKeyToAccount(creds.hlPrivateKey);
    if (this.isPerp()) {
      const state = await this.hlInfo({ type: "clearinghouseState", user: account.address });
      const positions = Array.isArray(state?.assetPositions) ? state.assetPositions : [];
      let total = 0;
      for (const p of positions) {
        const margin = parseFloat(p?.position?.marginUsed ?? "0");
        const upnl = parseFloat(p?.position?.unrealizedPnl ?? "0");
        total += margin + upnl;
      }
      return BigInt(Math.floor(total * 1e6));
    } else {
      const state = await this.hlInfo({ type: "spotClearinghouseState", user: account.address });
      const bal = Array.isArray(state?.balances) ? state.balances : [];
      let total = 0;
      for (const b of bal) {
        if (b.coin === "USDC") total += parseFloat(b.total);
        else {
          const mid = await this.getMidPrice(b.coin);
          total += parseFloat(b.total) * mid;
        }
      }
      return BigInt(Math.floor(total * 1e6));
    }
  }

  async closeAllAndWithdraw(creds: VenueCredentials, _strategyId: Hex): Promise<bigint> {
    if (!creds.hlPrivateKey) return 0n;
    const account = privateKeyToAccount(creds.hlPrivateKey);

    if (this.isPerp()) {
      const state = await this.hlInfo({ type: "clearinghouseState", user: account.address });
      const positions = Array.isArray(state?.assetPositions) ? state.assetPositions : [];
      for (const p of positions) {
        const szi = parseFloat(p?.position?.szi ?? "0");
        if (szi === 0) continue;
        const entry = Object.values(this.markets).find((m) => m.tickerSymbol === p.position.coin);
        if (!entry) continue;
        const action: HlOrderAction = {
          type: "order",
          orders: [
            {
              a: entry.assetIndex,
              b: szi < 0, // opposite side to close
              p: "0",
              s: Math.abs(szi).toFixed(entry.szDecimals),
              r: true,
              t: { limit: { tif: "Ioc" } },
            },
          ],
          grouping: "na",
        };
        await this.signAndPost(action, Date.now(), creds.hlPrivateKey);
      }
    } else {
      // Spot: sell all non-USDC balances.
      const state = await this.hlInfo({ type: "spotClearinghouseState", user: account.address });
      const bal = Array.isArray(state?.balances) ? state.balances : [];
      for (const b of bal) {
        if (b.coin === "USDC") continue;
        const entry = Object.values(this.markets).find((m) => m.tickerSymbol === b.coin);
        if (!entry) continue;
        const size = parseFloat(b.total);
        if (size <= 0) continue;
        const action: HlOrderAction = {
          type: "order",
          orders: [
            {
              a: entry.assetIndex,
              b: false, // sell
              p: "0",
              s: size.toFixed(entry.szDecimals),
              r: false,
              t: { limit: { tif: "Ioc" } },
            },
          ],
          grouping: "na",
        };
        await this.signAndPost(action, Date.now(), creds.hlPrivateKey);
      }
    }

    // Read post-close withdrawable and issue withdraw3 → HyperEVM for the adapter to CCTP-back.
    const post = await this.hlInfo(
      this.isPerp()
        ? { type: "clearinghouseState", user: account.address }
        : { type: "spotClearinghouseState", user: account.address }
    );
    const withdrawableStr = this.isPerp()
      ? post?.withdrawable
      : (post?.balances ?? []).find((b: { coin: string }) => b.coin === "USDC")?.total;
    const withdrawable = parseFloat(withdrawableStr ?? "0");
    if (withdrawable > 0) {
      // HL withdraw3 action: amount in USD, destination = HyperEVM account (the adapter's HyperEVM EOA).
      const action = {
        type: "withdraw3",
        destination: account.address, // HyperEVM EOA = perp account address (same EOA)
        amount: withdrawable.toFixed(6),
        time: Date.now(),
      };
      await this.signAndPost(action, action.time, creds.hlPrivateKey);
    }

    return BigInt(Math.floor(withdrawable * 1e6));
  }

  // ─── Helpers ─────────────────────────────────────────────────────────────

  private async hlInfo(body: unknown): Promise<any> {
    const res = await fetch(`${HL_API_URL}/info`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) return null;
    return res.json();
  }

  private async getMidPrice(ticker: string): Promise<number> {
    const all = await this.hlInfo({ type: "allMids" });
    const price = parseFloat(all?.[ticker] ?? "0");
    return isFinite(price) ? price : 0;
  }

  private async pollFilled(
    user: Address,
    _assetIdx: number,
    clientOrderId: number,
    timeoutSec: number
  ): Promise<{ filledUsd: bigint; filledBase: bigint; avgPriceE18: bigint; oid: number } | null> {
    const deadline = Date.now() + timeoutSec * 1000;
    while (Date.now() < deadline) {
      const fills = await this.hlInfo({ type: "userFills", user });
      if (Array.isArray(fills)) {
        const recent = fills.filter((f: { time: number; coin: string }) => f.time >= clientOrderId - 5_000);
        if (recent.length > 0) {
          const rel = recent.filter((f: { coin: string }) => f.coin !== undefined);
          if (rel.length > 0) {
            let usd = 0, base = 0, price = 0, oid = 0;
            for (const f of rel) {
              const fPx = parseFloat(f.px);
              const fSz = parseFloat(f.sz);
              usd += fPx * fSz;
              base += fSz;
              price = fPx;
              oid = f.oid ?? 0;
            }
            return {
              filledUsd: BigInt(Math.floor(usd * 1e6)),
              filledBase: BigInt(Math.floor(base * 1e18)),
              avgPriceE18: BigInt(Math.floor(price * 1e18)),
              oid,
            };
          }
        }
      }
      await sleep(1000);
    }
    return null;
  }

  private async setMarginMode(
    _user: Address,
    key: Hex,
    assetIdx: number,
    mode: MarginMode
  ): Promise<unknown> {
    const action = {
      type: "updateLeverage",
      asset: assetIdx,
      isCross: mode === MarginMode.Cross,
      leverage: 1, // operator can extend to per-strategy leverage
    };
    return this.signAndPost(action, Date.now(), key);
  }

  /// Signs and POSTs to /exchange. Uses HL's phantom-agent EIP-712 scheme.
  private async signAndPost(action: unknown, nonce: number, key: Hex): Promise<any> {
    const account = privateKeyToAccount(key);
    const actionHash = hashAction(action, nonce);
    const phantomAgent = { source: "a", connectionId: actionHash } as const;

    const signature = await account.signTypedData({
      domain: {
        name: "Exchange",
        version: "1",
        chainId: 1337,
        verifyingContract: "0x0000000000000000000000000000000000000000",
      },
      types: {
        Agent: [
          { name: "source", type: "string" },
          { name: "connectionId", type: "bytes32" },
        ],
      },
      primaryType: "Agent",
      message: phantomAgent,
    });

    const sig = splitSig(signature);
    const body: HlSignedExchangeReq = { action, nonce, signature: sig };
    const res = await fetch(`${HL_API_URL}/exchange`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
    });
    if (!res.ok) return null;
    return res.json();
  }
}

function failReceipt(intent: ExecutionIntent, _reason: string): NormalizedExecutionReceipt {
  return {
    cycleId: intent.cycleId,
    venue: intent.venue,
    status: ExecStatus.Failed,
    filledNotionalUsd: 0n,
    filledBaseQty: 0n,
    avgPriceE18: 0n,
    externalOrderId: pad(toHex(0), { size: 32 }) as Hex,
    externalAccountRef: pad(toHex(0), { size: 32 }) as Hex,
    terminal: true,
    rawPayloadHash: keccak256(toBytes("fail")),
  };
}

function nowSec(): bigint {
  return BigInt(Math.floor(Date.now() / 1000));
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function splitSig(sig: Hex): { r: Hex; s: Hex; v: number } {
  const raw = sig.slice(2);
  return {
    r: ("0x" + raw.slice(0, 64)) as Hex,
    s: ("0x" + raw.slice(64, 128)) as Hex,
    v: parseInt(raw.slice(128, 130), 16),
  };
}

/// HL's canonical action hashing:
///   keccak256( concat( msgpack(action), nonce_be8, vaultAddress20_or_0x00 ) )
///
/// Matches the Python SDK (`hyperliquid-python-sdk`) byte-for-byte.
/// Accepts an optional sub-account vault address; pass `undefined`/`null` for the default account.
function hashAction(action: unknown, nonce: number, vaultAddress?: Address): Hex {
  const actionBytes = msgpackEncode(action);
  const nonceBytes = toBytes(pad(toHex(BigInt(nonce)), { size: 8 }));
  const vaultBytes = vaultAddress
    ? concat([toBytes("0x01"), toBytes(vaultAddress)])
    : toBytes("0x00");
  return keccak256(concat([actionBytes, nonceBytes, vaultBytes]));
}
