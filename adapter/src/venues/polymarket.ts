import { keccak256, toBytes, toHex, pad, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { polygon as viemPolygon } from "viem/chains";
import {
  ClobClient,
  Side as PmSide,
  OrderType as PmOrderType,
  Chain as PmChain,
  AssetType as PmAssetType,
  type TickSize as PmTickSize,
} from "@polymarket/clob-client-v2";
import { unwindPmOutbound } from "../bridges/index.js";
import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
} from "../types.js";
import { ExecStatus, Side } from "../types.js";
import type { VenueAdapter, VenueExecContext } from "./types.js";

/// Polymarket CLOB API base — passed as `host` to ClobClient; only the SDK talks to it.
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

/// Polymarket adapter. Signing + order construction + CLOB submission delegated to the official
/// `@polymarket/clob-client` SDK. Optional API creds enable higher rate limits but aren't required.
export class PolymarketAdapter implements VenueAdapter {
  readonly venueId = V_POLYMARKET;
  constructor(private readonly markets: PmMarketRegistry) {}

  // Cache derived CLOB L2 API credentials per address — the derivation is deterministic from
  // the signer, but requires one signed request to /auth/derive-api-key. Cache across cycles.
  private static apiCredsByAddr = new Map<string, any>();

  /// Lazily construct ClobClient per credentials. Uses viem walletClient — the SDK signer type
  /// accepts either an ethers v5 Signer OR a viem WalletClient; viem avoids the ethers version
  /// mismatch (SDK is v5-pinned, our repo is v6). Derives L2 API creds on first use per address.
  private async clobClient(pk: Hex): Promise<ClobClient> {
    const account = privateKeyToAccount(pk);
    const walletClient = createWalletClient({
      account,
      chain: viemPolygon,
      transport: http(process.env.POLYGON_RPC_URL ?? "https://polygon-bor-rpc.publicnode.com"),
    });
    const bootstrap = new ClobClient({ host: PM_API_URL, chain: PmChain.POLYGON, signer: walletClient as any });

    let creds = PolymarketAdapter.apiCredsByAddr.get(account.address.toLowerCase());
    if (!creds) {
      try {
        creds = await bootstrap.createOrDeriveApiKey();
        PolymarketAdapter.apiCredsByAddr.set(account.address.toLowerCase(), creds);
        console.log(`[pm] derived API key for ${account.address.slice(0, 10)}…`);
      } catch (err) {
        console.log(`[pm] deriveApiKey failed: ${String(err).slice(0, 150)}`);
        throw err;
      }
    }
    return new ClobClient({ host: PM_API_URL, chain: PmChain.POLYGON, signer: walletClient as any, creds });
  }

  /// Read current position size (CTF shares) for a PM tokenId via the SDK's
  /// `getBalanceAllowance(CONDITIONAL, token_id)` endpoint. Used for delta-rebalance so duplicate
  /// /leg/execute retries converge to target instead of double-buying.
  private async currentPositionBase(client: ClobClient, tokenId: string): Promise<number> {
    try {
      const resp = await client.getBalanceAllowance({
        asset_type: PmAssetType.CONDITIONAL,
        token_id: tokenId,
      });
      // CTF shares are reported in USDC-denominated 6-decimal atomic units.
      return Number(BigInt(resp.balance ?? "0")) / 1e6;
    } catch {
      return 0;
    }
  }

  async execute(intent: ExecutionIntent, creds: VenueCredentials, ctx?: VenueExecContext): Promise<NormalizedExecutionReceipt> {
    if (!creds.pmPrivateKey) { console.log("[pm] no key"); return failReceipt(intent); }
    const market = resolvePmMarket(intent.marketRef, this.markets);
    if (!market.tokenId || market.tokenId === "0") { console.log(`[pm] bad tokenId ${market.tokenId}`); return failReceipt(intent); }

    const account = privateKeyToAccount(creds.pmPrivateKey);
    const client = await this.clobClient(creds.pmPrivateKey);

    // Fetch best bid/ask to compute a midpoint used for sizing + fill price.
    let bestBid: number, bestAsk: number;
    try {
      const book = await client.getOrderBook(market.tokenId);
      bestBid = parseFloat(book.bids?.[0]?.price ?? "0");
      bestAsk = parseFloat(book.asks?.[0]?.price ?? "0");
      console.log(`[pm] book token=${market.tokenId.slice(0,10)} bid=${bestBid} ask=${bestAsk}`);
      if (!bestBid || !bestAsk) return failReceipt(intent);
    } catch (err) {
      console.log(`[pm] book fetch failed: ${String(err).slice(0,150)}`);
      return failReceipt(intent);
    }
    const mid = (bestBid + bestAsk) / 2;

    // DELTA REBALANCE (PM): controller's `intent.side + targetNotionalUsd` is the absolute target
    // position (in USD). Read current CTF holdings (signed as + long), compute delta, only trade
    // the delta. Duplicate intents converge to target → no double-buy on retries.
    const targetUsd = Number(intent.targetNotionalUsd) / 1e6;
    const wantsLong = intent.side === Side.Buy;
    const targetSignedUsd = wantsLong ? targetUsd : 0; // PM: "sell" means "hold zero" (or sell existing)
    const currentBase = await this.currentPositionBase(client, market.tokenId);
    const currentUsd = currentBase * mid;
    const deltaUsd = targetSignedUsd - currentUsd;
    const tolUsd = 1.0;
    console.log(`[pm] rebalance token=${market.tokenId.slice(0,10)} target=$${targetSignedUsd.toFixed(2)} current=$${currentUsd.toFixed(2)} delta=$${deltaUsd.toFixed(2)}`);

    if (Math.abs(deltaUsd) <= tolUsd) {
      // Already at target — return synthetic Filled receipt at current position.
      return {
        cycleId: intent.cycleId,
        venue: this.venueId,
        status: ExecStatus.Filled,
        filledNotionalUsd: BigInt(Math.floor(targetUsd * 1e6)),
        filledBaseQty: BigInt(Math.floor(currentBase * 1e18)),
        avgPriceE18: BigInt(Math.floor(mid * 1e18)),
        externalOrderId: pad(toHex(0), { size: 32 }) as Hex,
        externalAccountRef: pad(account.address, { size: 32 }) as Hex,
        terminal: true,
        rawPayloadHash: keccak256(toBytes(`pm-rebalance-noop:${market.tokenId}:${currentBase}`)),
      };
    }

    const orderIsBuy = deltaUsd > 0;
    const side = orderIsBuy ? PmSide.BUY : PmSide.SELL;
    const price = orderIsBuy ? Math.min(bestAsk + market.tickSize, 0.99) : Math.max(bestBid - market.tickSize, 0.01);
    const sizeBase = Math.abs(deltaUsd) / price;
    if (sizeBase < market.minOrderSize) {
      // Two cases: (a) we already have a position (currentBase > 0) and the rebalance delta is
      // too small to execute — report target USD as filled (drift-within-min-tick is fine). (b)
      // opening from scratch and target position is below min — report Failed so controller
      // enters LEG_FAILED cleanly instead of believing a phantom position exists.
      console.log(`[pm] delta ${sizeBase} < min ${market.minOrderSize}, currentBase=${currentBase}`);
      if (currentBase <= 0) {
        return {
          cycleId: intent.cycleId,
          venue: this.venueId,
          status: ExecStatus.Failed,
          filledNotionalUsd: 0n,
          filledBaseQty: 0n,
          avgPriceE18: BigInt(Math.floor(mid * 1e18)),
          externalOrderId: pad(toHex(0), { size: 32 }) as Hex,
          externalAccountRef: pad(account.address, { size: 32 }) as Hex,
          terminal: true,
          rawPayloadHash: keccak256(toBytes(`pm-below-min-open:${market.tokenId}:${sizeBase}`)),
        };
      }
      // Drift rebalance can't execute through min order size — keep current position.
      return {
        cycleId: intent.cycleId,
        venue: this.venueId,
        status: ExecStatus.Filled,
        filledNotionalUsd: BigInt(Math.floor(currentUsd * 1e6)),
        filledBaseQty: BigInt(Math.floor(currentBase * 1e18)),
        avgPriceE18: BigInt(Math.floor(mid * 1e18)),
        externalOrderId: pad(toHex(0), { size: 32 }) as Hex,
        externalAccountRef: pad(account.address, { size: 32 }) as Hex,
        terminal: true,
        rawPayloadHash: keccak256(toBytes(`pm-drift-below-min:${market.tokenId}:${deltaUsd}`)),
      };
    }

    try {
      // v2 market-order (FOK/FAK) path: `amount` is USD for BUY, shares for SELL.
      const amount = orderIsBuy ? Math.abs(deltaUsd) : sizeBase;
      const resp = (await client.createAndPostMarketOrder(
        {
          tokenID: market.tokenId,
          price: Math.round(price / market.tickSize) * market.tickSize,
          amount,
          side,
        },
        { tickSize: market.tickSize.toString() as PmTickSize },
        PmOrderType.FOK,
      )) as Record<string, unknown>;
      console.log(`[pm] order ${orderIsBuy?'BUY':'SELL'} amount=${amount.toFixed(3)} px=${price}`);
      console.log(`[pm] resp: ${JSON.stringify(resp).slice(0,300)}`);

      // CLOSE-SIDE CCTP-BACK: if this rebalance SHRANK our PM exposure (SELL side), the freed
      // USDC.e is now on our Polygon EOA. Bridge it to the Base module via CCTP V2 + mint on
      // Base inline. BLOCKING: the /leg/execute response must NOT return before Base mint is
      // confirmed, otherwise the controller's next REFILL_RESERVE finds the module empty.
      const freedUsd = currentUsd - targetSignedUsd; // positive when shrinking a long
      if (freedUsd > 1.0 && ctx?.moduleAddress) {
        if (!creds.baseSignerKey) {
          throw new Error("missing x-base-signer-key — can't finalize PM→Base CCTP on unwind");
        }
        const micros = BigInt(Math.floor(freedUsd * 1e6));
        console.log(`[pm] position shrank $${freedUsd.toFixed(2)} — unwindPmOutbound → module ${ctx.moduleAddress}`);
        // baseSignerKey is TEE-injected per request via `x-base-signer-key` header.
        const r = await unwindPmOutbound(creds.pmPrivateKey!, ctx.moduleAddress, micros, creds.baseSignerKey);
        console.log(`[pm] CCTP-back complete: burn=${r.burnTxHash} mint=${r.baseReceiveTxHash}`);
      }

      return {
        cycleId: intent.cycleId,
        venue: this.venueId,
        // Report target as the resulting position (framework: downstream legs size off target).
        status: ExecStatus.Filled,
        filledNotionalUsd: BigInt(Math.floor(targetUsd * 1e6)),
        filledBaseQty: BigInt(Math.floor((targetUsd / mid) * 1e18)),
        avgPriceE18: BigInt(Math.floor(price * 1e18)),
        externalOrderId: resp?.orderID
          ? pad(toHex(BigInt("0x" + String(resp.orderID).replace(/-/g, "").slice(0, 64))), { size: 32 }) as Hex
          : pad(toHex(0), { size: 32 }) as Hex,
        externalAccountRef: pad(account.address, { size: 32 }) as Hex,
        terminal: true,
        rawPayloadHash: keccak256(toBytes(JSON.stringify({ resp, targetUsd, deltaUsd }))),
      };
    } catch (err) {
      console.log(`[pm] order error: ${String(err).slice(0,300)}`);
      return failReceipt(intent);
    }
  }

  async getBuffer(creds: VenueCredentials): Promise<LegBufferSnapshot> {
    if (!creds.pmPrivateKey) return zeroBuf();
    // SDK-only: the CLOB's getBalanceAllowance(COLLATERAL) reports the user's USDC-denominated
    // collateral allocated for PM — same source of truth as the CLOB uses for order matching.
    // L1+L2 auth is derived automatically from the TEE-forwarded pmPrivateKey inside clobClient().
    try {
      const client = await this.clobClient(creds.pmPrivateKey);
      const resp = await client.getBalanceAllowance({ asset_type: PmAssetType.COLLATERAL });
      return { bufferUsd: BigInt(resp.balance ?? "0"), timestamp: nowSec() };
    } catch {
      return zeroBuf();
    }
  }

  async getPositionMarkValue(creds: VenueCredentials, _strategyId: Hex): Promise<bigint> {
    if (!creds.pmPrivateKey) return 0n;
    // SDK-only: iterate the operator-supplied markets registry — for each known tokenId,
    // ask the SDK for the current CTF balance + midpoint.
    const client = await this.clobClient(creds.pmPrivateKey);
    let totalUsd = 0;
    for (const entry of Object.values(this.markets)) {
      try {
        const bal = await this.currentPositionBase(client, entry.tokenId);
        if (bal <= 0) continue;
        const mid = (await client.getMidpoint(entry.tokenId)) as { mid?: string } | number | string;
        const midNum =
          typeof mid === "number" ? mid :
          typeof mid === "string" ? parseFloat(mid) :
          parseFloat((mid as any)?.mid ?? "0");
        if (!midNum) continue;
        totalUsd += bal * midNum;
      } catch {}
    }
    return BigInt(Math.floor(totalUsd * 1e6));
  }

  async closeAllAndWithdraw(creds: VenueCredentials, strategyId: Hex): Promise<bigint> {
    if (!creds.pmPrivateKey) return 0n;
    const client = await this.clobClient(creds.pmPrivateKey);

    // SDK-only: walk the markets registry — for each tokenId we track, read the CTF balance
    // via `getBalanceAllowance`, and if non-zero route a SELL through this.execute()
    // (which reuses SDK signing for the order).
    for (const [marketRef, entry] of Object.entries(this.markets) as [Hex, PmMarketEntry][]) {
      try {
        const baseQty = await this.currentPositionBase(client, entry.tokenId);
        if (baseQty <= 0) continue;
        const mid = (await client.getMidpoint(entry.tokenId)) as { mid?: string } | number | string;
        const midNum =
          typeof mid === "number" ? mid :
          typeof mid === "string" ? parseFloat(mid) :
          parseFloat((mid as any)?.mid ?? "0");
        if (!midNum) continue;

        const notionalUsd = BigInt(Math.floor(baseQty * midNum * 1e6));
        if (notionalUsd === 0n) continue;

        const sellIntent: ExecutionIntent = {
          cycleId: strategyId,
          venue: this.venueId,
          marketRef,
          side: Side.Sell,
          targetNotionalUsd: notionalUsd,
          maxSlippageBps: 100,
          expiryBlock: 0n,
          idempotencyKey: marketRef,
          marginMode: 0,
        };
        await this.execute(sellIntent, creds);
      } catch {}
    }

    // Post-unwind USDC collateral — exactly what `unwindPmOutbound` can CCTP-burn back to Base.
    // SDK reports the collateral balance tracked by the CLOB (same value the caller would see
    // after reconciliation), which is the correct signal for the unwind amount.
    try {
      const resp = await client.getBalanceAllowance({ asset_type: PmAssetType.COLLATERAL });
      return BigInt(resp.balance ?? "0");
    } catch {
      return 0n;
    }
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

// Ritual `block.timestamp` is ms — see hyperliquid.ts equivalent comment.
function nowSec(): bigint {
  return BigInt(Date.now());
}
