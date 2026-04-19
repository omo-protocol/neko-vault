import { keccak256, toBytes, toHex, pad, createPublicClient, createWalletClient, http, defineChain, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { polygon as viemPolygon } from "viem/chains";
import { ClobClient, Side as PmSide, OrderType as PmOrderType, Chain as PmChain } from "@polymarket/clob-client";
import { depositForBurn, DOMAIN } from "../bridges/cctp.js";
import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
} from "../types.js";
import { ExecStatus, Side } from "../types.js";
import type { VenueAdapter, VenueExecContext } from "./types.js";

/// Polymarket CLOB API base.
const PM_API_URL = process.env.PM_API_URL ?? "https://clob.polymarket.com";

/// Polygon USDC.e (bridged) — what CCTP mints to on Polygon.
const POLYGON_USDC_E = "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359";

const polygonChain = defineChain({
  id: 137,
  name: "Polygon",
  nativeCurrency: { name: "POL", symbol: "POL", decimals: 18 },
  rpcUrls: { default: { http: [process.env.POLYGON_RPC_URL ?? "https://polygon-bor-rpc.publicnode.com"] } },
});
const polygonPub = createPublicClient({ chain: polygonChain, transport: http() });

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
    const bootstrap = new ClobClient(PM_API_URL, PmChain.POLYGON, walletClient as any);

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
    return new ClobClient(PM_API_URL, PmChain.POLYGON, walletClient as any, creds);
  }

  /// Read current position size (token holdings) for a given PM tokenId. Used for delta-rebalance
  /// so duplicate /leg/execute retries converge to target instead of double-buying.
  private async currentPositionBase(ownerAddress: `0x${string}`, tokenId: string): Promise<number> {
    try {
      // Polymarket publishes user positions via CLOB — use SDK if available, fall back to CTF
      // ERC-1155 balance on Polygon (authoritative source, same query path every time).
      const ctfBalance = (await polygonPub.readContract({
        address: "0x4D97DCd97eC945f40cF65F87097ACe5EA0476045", // Polymarket CTF
        abi: [{
          name: "balanceOf", type: "function", stateMutability: "view",
          inputs: [{ name: "account", type: "address" }, { name: "id", type: "uint256" }],
          outputs: [{ name: "", type: "uint256" }],
        }],
        functionName: "balanceOf",
        args: [ownerAddress, BigInt(tokenId)],
      })) as bigint;
      // CTF shares have 6 decimals (USDC-denominated).
      return Number(ctfBalance) / 1e6;
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
    const currentBase = await this.currentPositionBase(account.address, market.tokenId);
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
      console.log(`[pm] delta ${sizeBase} < min ${market.minOrderSize}, skip`);
      // Still report target as filled — the drift is too small to trade through min order size.
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
        rawPayloadHash: keccak256(toBytes(`pm-rebalance-below-min:${market.tokenId}:${deltaUsd}`)),
      };
    }

    try {
      const signed = await client.createOrder({
        tokenID: market.tokenId,
        price: Math.round(price / market.tickSize) * market.tickSize,
        size: sizeBase,
        side,
      });
      console.log(`[pm] order signed ${orderIsBuy?'BUY':'SELL'} sz=${sizeBase.toFixed(3)} px=${price}, posting...`);
      const resp = (await client.postOrder(signed, PmOrderType.FOK)) as Record<string, unknown>;
      console.log(`[pm] resp: ${JSON.stringify(resp).slice(0,300)}`);

      // CLOSE-SIDE CCTP-BACK: if this rebalance SHRANK our PM exposure (SELL side), the freed
      // USDC.e is now on our Polygon EOA. Bridge it to the Base module via CCTP V2 Fast Transfer
      // so the controller's subsequent REFILL_RESERVE command finds USDC at the module to push
      // into the sleeve. Fire-and-forget; failures logged but non-fatal for the leg response.
      const freedUsd = currentUsd - targetSignedUsd; // positive when shrinking a long
      if (freedUsd > 1.0 && ctx?.moduleAddress) {
        const micros = BigInt(Math.floor(freedUsd * 1e6));
        console.log(`[pm] position shrank $${freedUsd.toFixed(2)} — firing CCTP-back to module ${ctx.moduleAddress}`);
        (async () => {
          try {
            const { pub: polyPub, wallet: polyWallet } = (() => {
              const pub = createPublicClient({ chain: viemPolygon, transport: http(process.env.POLYGON_RPC_URL ?? "https://polygon-bor-rpc.publicnode.com") });
              const wallet = createWalletClient({ chain: viemPolygon, transport: http(), account });
              return { pub, wallet };
            })();
            await depositForBurn(polyWallet, polyPub, {
              amount: micros,
              destinationDomain: DOMAIN.BASE,
              mintRecipient: ctx.moduleAddress,
              usdc: POLYGON_USDC_E,
            });
            console.log(`[pm] CCTP-back burn fired, $${freedUsd.toFixed(2)} Polygon→Base`);
          } catch (err) {
            console.log(`[pm] CCTP-back failed (non-fatal): ${String(err).slice(0, 200)}`);
          }
        })();
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
    const account = privateKeyToAccount(creds.pmPrivateKey);
    // Buffer is raw USDC.e on Polygon at the PM wallet EOA — what CCTP mints to, and what
    // the CLOB sees as deposited collateral once CTFExchange allowance is in place
    // (ensurePmApproval runs in settlePmInbound post-burn). The PM CLOB `/balance` endpoint
    // requires auth + proxy-address setup; reading wallet USDC directly is the source of truth.
    try {
      const bal = (await polygonPub.readContract({
        address: POLYGON_USDC_E,
        abi: [{ name: "balanceOf", type: "function", stateMutability: "view",
          inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] }],
        functionName: "balanceOf",
        args: [account.address],
      })) as bigint;
      return { bufferUsd: bal, timestamp: nowSec() };
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

    // 3. Read ERC20 USDC.balanceOf(EOA) on Polygon — that's what's directly CCTP-burnable via
    //    `unwindPmOutbound`. If PM settles positions via a CTF Exchange proxy wallet
    //    instead of the EOA, the user (or adapter with proxy-owner auth) must first move USDC
    //    from the proxy to the EOA — via PM's "Cash Out" UI or a direct transfer from the proxy
    //    contract. We don't attempt that here because the proxy mechanism is account-specific.
    try {
      const { createPublicClient, http: viemHttp, defineChain } = await import("viem");
      const polygon = defineChain({
        id: 137,
        name: "Polygon",
        nativeCurrency: { name: "POL", symbol: "POL", decimals: 18 },
        rpcUrls: { default: { http: ["https://polygon-bor-rpc.publicnode.com"] } },
      });
      const pub = createPublicClient({ chain: polygon, transport: viemHttp() });
      const USDC_E = "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174" as const;
      const erc20Abi = [{
        name: "balanceOf", type: "function", stateMutability: "view",
        inputs: [{ name: "account", type: "address" }],
        outputs: [{ name: "", type: "uint256" }],
      }] as const;
      const bal = (await pub.readContract({
        address: USDC_E, abi: erc20Abi, functionName: "balanceOf", args: [account.address],
      })) as bigint;
      return bal;
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
