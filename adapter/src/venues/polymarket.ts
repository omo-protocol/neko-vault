import { keccak256, toBytes, toHex, pad, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
} from "../types.js";
import { ExecStatus, Side } from "../types.js";
import type { VenueAdapter } from "./types.js";

/// Polymarket CLOB API base.
const PM_API_URL = process.env.PM_API_URL ?? "https://clob.polymarket.com";

/// Venue ID — must match Solidity constant.
export const V_POLYMARKET = keccak256(toBytes("POLYMARKET"));

/// PM market registry: `marketRef` bytes32 → CLOB token ID + tick size (in USDC).
/// Legacy — prefer the canonical convention where `marketRef = bytes32(tokenId)` directly (the PM
/// CTF token id fits in a uint256). When marketRef is empty or unknown in the registry, we
/// decode marketRef as uint256(tokenId) and use default tickSize/minOrderSize.
export interface PmMarketEntry {
  tokenId: string; // ERC-1155 CTF token id (stringified uint)
  tickSize: number; // e.g. 0.01
  minOrderSize: number; // in base units
}

export type PmMarketRegistry = Record<Hex, PmMarketEntry>;

const DEFAULT_PM_TICK_SIZE = 0.01;
const DEFAULT_PM_MIN_ORDER_SIZE = 5;

/// Resolve a marketRef to a PM market entry. If operator pre-registered the marketRef, use that
/// entry; otherwise decode marketRef as uint256(tokenId) and apply defaults.
export function resolvePmMarket(marketRef: Hex, registry: PmMarketRegistry = {}): PmMarketEntry {
  const pre = registry[marketRef];
  if (pre) return pre;
  return {
    tokenId: BigInt(marketRef).toString(),
    tickSize: DEFAULT_PM_TICK_SIZE,
    minOrderSize: DEFAULT_PM_MIN_ORDER_SIZE,
  };
}

/// Polymarket adapter. Orders are EIP-712 signed and posted to the CLOB REST API.
/// Optional `pmApiKey`/`pmApiSecret`/`pmApiPassphrase` enable higher rate limits but aren't required.
export class PolymarketAdapter implements VenueAdapter {
  readonly venueId = V_POLYMARKET;
  constructor(private readonly markets: PmMarketRegistry) {}

  async execute(intent: ExecutionIntent, creds: VenueCredentials): Promise<NormalizedExecutionReceipt> {
    if (!creds.pmPrivateKey) return failReceipt(intent);
    // Dynamic resolution: prefer registry entry, else decode marketRef → tokenId with defaults.
    const market = resolvePmMarket(intent.marketRef, this.markets);
    if (!market.tokenId || market.tokenId === "0") return failReceipt(intent);

    const account = privateKeyToAccount(creds.pmPrivateKey);
    const side = intent.side === Side.Buy ? "BUY" : "SELL";
    const price = 0.5; // market order — pick mid-ish; CLOB matches at best available
    const sizeBase = Number(intent.targetNotionalUsd) / 1e6 / price;
    if (sizeBase < market.minOrderSize) return failReceipt(intent);

    // Build EIP-712 order (simplified — real PM order schema has more fields: feeRateBps, expiry, salt, etc.)
    const order = {
      salt: BigInt(Math.floor(Date.now() * 1000 + Math.random() * 1000)),
      maker: account.address,
      signer: account.address,
      taker: "0x0000000000000000000000000000000000000000" as Hex,
      tokenId: BigInt(market.tokenId),
      makerAmount: BigInt(Math.floor(sizeBase * price * 1e6)),
      takerAmount: BigInt(Math.floor(sizeBase * 1e6)),
      expiration: 0n,
      nonce: 0n,
      feeRateBps: 0n,
      side: side === "BUY" ? 0 : 1,
      signatureType: 0,
    };

    const signature = await account.signTypedData({
      domain: {
        name: "Polymarket CTF Exchange",
        version: "1",
        chainId: 137,
        verifyingContract: "0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E",
      },
      types: {
        Order: [
          { name: "salt", type: "uint256" },
          { name: "maker", type: "address" },
          { name: "signer", type: "address" },
          { name: "taker", type: "address" },
          { name: "tokenId", type: "uint256" },
          { name: "makerAmount", type: "uint256" },
          { name: "takerAmount", type: "uint256" },
          { name: "expiration", type: "uint256" },
          { name: "nonce", type: "uint256" },
          { name: "feeRateBps", type: "uint256" },
          { name: "side", type: "uint8" },
          { name: "signatureType", type: "uint8" },
        ],
      },
      primaryType: "Order",
      message: order,
    });

    const headers: Record<string, string> = {
      "Content-Type": "application/json",
      "POLY_ADDRESS": account.address,
      "POLY_SIGNATURE": signature,
      "POLY_TIMESTAMP": Math.floor(Date.now() / 1000).toString(),
      "POLY_NONCE": "0",
    };
    if (creds.pmApiKey) {
      headers["POLY_API_KEY"] = creds.pmApiKey;
      if (creds.pmApiSecret) headers["POLY_SECRET"] = creds.pmApiSecret;
      if (creds.pmApiPassphrase) headers["POLY_PASSPHRASE"] = creds.pmApiPassphrase;
    }

    const res = await fetch(`${PM_API_URL}/order`, {
      method: "POST",
      headers,
      body: JSON.stringify({ order, owner: account.address, orderType: "FOK" }),
    });
    if (!res.ok) return failReceipt(intent);
    const data: any = await res.json();

    const filledSize = parseFloat(data?.makerAssetsFilled ?? data?.filled ?? "0");
    const filledUsd = filledSize * price;
    return {
      cycleId: intent.cycleId,
      venue: this.venueId,
      status: filledSize >= sizeBase * 0.99 ? ExecStatus.Filled : filledSize > 0 ? ExecStatus.PartialFill : ExecStatus.Failed,
      filledNotionalUsd: BigInt(Math.floor(filledUsd * 1e6)),
      filledBaseQty: BigInt(Math.floor(filledSize * 1e18)),
      avgPriceE18: BigInt(Math.floor(price * 1e18)),
      externalOrderId: data?.orderID ? pad(toHex(BigInt("0x" + data.orderID.replace(/-/g, "").slice(0, 64))), { size: 32 }) as Hex : pad(toHex(0), { size: 32 }) as Hex,
      externalAccountRef: pad(account.address, { size: 32 }) as Hex,
      terminal: true,
      rawPayloadHash: keccak256(toBytes(JSON.stringify(data))),
    };
  }

  async getBuffer(creds: VenueCredentials): Promise<LegBufferSnapshot> {
    if (!creds.pmPrivateKey) return zeroBuf();
    const account = privateKeyToAccount(creds.pmPrivateKey);
    try {
      const res = await fetch(`${PM_API_URL}/balance`, {
        headers: {
          "POLY_ADDRESS": account.address,
          ...(creds.pmApiKey
            ? {
                "POLY_API_KEY": creds.pmApiKey,
                "POLY_SECRET": creds.pmApiSecret ?? "",
                "POLY_PASSPHRASE": creds.pmApiPassphrase ?? "",
              }
            : {}),
        },
      });
      if (!res.ok) return zeroBuf();
      const data: any = await res.json();
      const usdc = parseFloat(data?.USDC?.balance ?? data?.balance ?? "0");
      return { bufferUsd: BigInt(Math.floor(usdc * 1e6)), timestamp: nowSec() };
    } catch {
      return zeroBuf();
    }
  }

  async getPositionMarkValue(creds: VenueCredentials, _strategyId: Hex): Promise<bigint> {
    if (!creds.pmPrivateKey) return 0n;
    const account = privateKeyToAccount(creds.pmPrivateKey);
    try {
      const res = await fetch(`${PM_API_URL}/positions?user=${account.address}`);
      if (!res.ok) return 0n;
      const positions: any[] = await res.json();
      let total = 0;
      for (const p of positions) {
        const sz = parseFloat(p?.size ?? "0");
        const px = parseFloat(p?.curPrice ?? p?.avgPrice ?? "0");
        total += sz * px;
      }
      return BigInt(Math.floor(total * 1e6));
    } catch {
      return 0n;
    }
  }

  async closeAllAndWithdraw(creds: VenueCredentials, strategyId: Hex): Promise<bigint> {
    if (!creds.pmPrivateKey) return 0n;
    const account = privateKeyToAccount(creds.pmPrivateKey);

    // 1. Fetch open positions from PM.
    let positions: any[] = [];
    try {
      const res = await fetch(`${PM_API_URL}/positions?user=${account.address}`);
      if (res.ok) positions = await res.json();
    } catch {}

    // 2. For each position with size > 0, post a signed SELL order via this.execute() with Side.Sell.
    //    Reusing execute() keeps the EIP-712 signing + POLY header logic in one place.
    for (const p of positions) {
      const sz = parseFloat(p?.size ?? "0");
      if (sz <= 0) continue;
      const tokenIdStr: string | undefined = p?.asset ?? p?.tokenId;
      if (!tokenIdStr) continue;

      const marketRef = (`0x${BigInt(tokenIdStr).toString(16).padStart(64, "0")}`) as Hex;
      const curPrice = parseFloat(p?.curPrice ?? p?.avgPrice ?? "0") || 0.5;
      const notionalUsd = BigInt(Math.floor(sz * curPrice * 1e6));
      if (notionalUsd === 0n) continue;

      const sellIntent: ExecutionIntent = {
        cycleId: strategyId, // use strategyId as correlation for unwind-time intents
        venue: this.venueId,
        marketRef,
        side: Side.Sell,
        targetNotionalUsd: notionalUsd,
        maxSlippageBps: 100, // wider on unwind to prioritize completion
        expiryBlock: 0n,
        idempotencyKey: (`0x${BigInt(tokenIdStr).toString(16).padStart(64, "0")}`) as Hex,
        marginMode: 0,
      };
      // Errors are swallowed — a failure on one position shouldn't block the others.
      try {
        await this.execute(sellIntent, creds);
      } catch {}
    }

    // 3. Read post-close USDC balance on PM. The actual Polygon withdrawal (from PM's Exchange
    //    contract to the EOA's Polygon wallet) + subsequent OFT-back to Base is orchestrated by
    //    the adapter's Polygon-side module — not this venue adapter.
    const buf = await this.getBuffer(creds);
    return buf.bufferUsd;
  }
}

function failReceipt(intent: ExecutionIntent): NormalizedExecutionReceipt {
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
    rawPayloadHash: keccak256(toBytes("pm-fail")),
  };
}

function zeroBuf(): LegBufferSnapshot {
  return { bufferUsd: 0n, timestamp: nowSec() };
}

function nowSec(): bigint {
  return BigInt(Math.floor(Date.now() / 1000));
}
