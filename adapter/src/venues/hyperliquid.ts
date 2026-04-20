import {
  keccak256,
  toHex,
  toBytes,
  pad,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { Hyperliquid, type ClearinghouseState, type SpotClearinghouseState, type OrderResponse } from "hyperliquid";
import { unwindHlOutbound } from "../bridges/index.js";
import { reconcileCctpForDestRef } from "../bridges/cctpReconcile.js";
import { DOMAIN } from "../bridges/cctp.js";
import { createPublicClient, createWalletClient, defineChain, http, type Address } from "viem";
import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
} from "../types.js";
import { ExecStatus, Side, MarginMode } from "../types.js";
import type { VenueAdapter, VenueExecContext } from "./types.js";

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

/// HyperLiquid adapter covering both perp (`V_HL_PERP`) and spot (`V_HL_SPOT`) venues.
/// Signing is delegated to the official `hyperliquid` SDK (handles EIP-712 phantom-agent +
/// msgpack action hashing). We only expose the high-level execute / close / info surface.
/// `execute` submits IOC market orders, polls fills, and returns a normalized receipt.
///
/// ISOLATION: assumes the supplied `x-hl-key` is a DEDICATED fresh EOA pre-funded with a small
/// amount of HYPE for HyperEVM gas. All orders trade this EOA directly — no subaccount logic.
/// HL's subaccount feature requires >$100k prior volume, which blocks low-volume strategies.
/// A fresh EOA gives the same isolation guarantee (operator's main account untouched) without
/// the volume gate. Operator creates the EOA off-adapter (see `scripts/freshHlWallet.ts` or
/// any key generator), funds it with ~0.05 HYPE for gas, updates CCTP HL mintRecipient and
/// clone's `x-hl-key` secret.
export class HyperliquidAdapter implements VenueAdapter {
  constructor(
    public readonly venueId: typeof V_HL_PERP | typeof V_HL_SPOT,
    private readonly markets: HlMarketRegistry
  ) {}

  private isPerp(): boolean {
    return this.venueId === V_HL_PERP;
  }

  /// @notice Sweep any USDC balance stranded on HyperEVM at the HL wallet into HyperCore via
  ///         `CoreDepositWallet.deposit`. Runs on every `/buffers` call so partial-failure
  ///         recovery is autonomous — no operator intervention needed if an adapter restart or
  ///         gateway reject interrupted the Base→HL top-up flow between CCTP mint and HyperCore
  ///         deposit. Dex split: the caller's own dex (spot/perp) gets min(half, all) per call.
  ///         When there are two HL venue adapters in a multi-leg clone (one spot, one perp),
  ///         each /buffers round-trip sweeps half, leaving the DN strategy funded on both sides.
  private async sweepStrandedHyperEvmToHyperCore(hlKey: Hex, perp: boolean): Promise<void> {
    const { createPublicClient, createWalletClient, http, defineChain } = await import("viem");
    const { forwardToHyperCore, HL } = await import("../bridges/hyperevm-forward.js");
    const hyperevm = defineChain({
      id: 999,
      name: "HyperEVM",
      nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
      rpcUrls: { default: { http: [process.env.HYPEREVM_RPC_URL ?? "https://rpc.hyperliquid.xyz/evm"] } },
    });
    const account = privateKeyToAccount(hlKey);
    const pub = createPublicClient({ chain: hyperevm, transport: http() });
    const bal = (await pub.readContract({
      address: HL.USDC,
      abi: [{ name: "balanceOf", type: "function", stateMutability: "view",
        inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] }],
      functionName: "balanceOf",
      args: [account.address],
    })) as bigint;
    // Ignore dust (<$0.10) — CoreDepositWallet rejects tiny deposits + HL charges account-creation fee.
    if (bal < 100_000n) return;
    // Sweep ALL stranded funds to the caller's dex. If multiple HL venue adapters exist in
    // the clone (any combination of HL_SPOT + HL_PERP + future HL venues), whichever /buffers
    // hits first takes it all — the controller's subsequent top-up flow will CCTP fresh funds
    // from the sleeve to any under-funded venue via its own destinationDex. Taking half would
    // be wrong for any leg count != 2 and adds complexity the strategy doesn't need.
    const wallet = createWalletClient({ chain: hyperevm, transport: http(), account });
    const dex = perp ? HL.DEST_PERPS : HL.DEST_SPOT;
    console.log(`[hl] sweep stranded HyperEVM USDC ${Number(bal) / 1e6} → HyperCore (dex=${dex})`);
    await forwardToHyperCore(wallet, pub, { amount: bal, destinationDex: dex });
  }

  async execute(intent: ExecutionIntent, creds: VenueCredentials, ctx?: VenueExecContext): Promise<NormalizedExecutionReceipt> {
    if (!creds.hlPrivateKey) { console.log("[hl] no key"); return failReceipt(intent, "no HL key"); }
    const market = this.markets[intent.marketRef];
    if (!market) { console.log(`[hl] unknown marketRef ${intent.marketRef.slice(0,12)}…`); return failReceipt(intent, "unknown marketRef"); }

    const account = privateKeyToAccount(creds.hlPrivateKey);
    const coinName = this.isPerp() ? `${market.tickerSymbol}-PERP` : `${market.tickerSymbol}-SPOT`;
    console.log(`[hl] connecting SDK for ${coinName}…`);
    const sdk = new Hyperliquid({ privateKey: creds.hlPrivateKey, enableWs: false, testnet: false });
    try {
      await sdk.connect();
    } catch (err) {
      console.log(`[hl] sdk.connect failed: ${String(err).slice(0,150)}`);
      return failReceipt(intent, "sdk connect");
    }

    try {
      if (this.isPerp()) {
        try {
          await sdk.exchange.updateLeverage(coinName, intent.marginMode === MarginMode.Cross ? "cross" : "isolated", 1);
        } catch (err) {
          console.log(`[hl] updateLeverage skipped: ${String(err).slice(0,80)}`);
        }
      }

      const mid = await this.getMidPrice(market.tickerSymbol);
      if (mid <= 0) { console.log(`[hl] no mid for ${market.tickerSymbol}`); return failReceipt(intent, "no mid price"); }

      // DELTA REBALANCE: read the (fresh, dedicated) EOA's position, only place the NET delta.
      // Duplicate intents become no-ops because position already matches target.
      const isBuy = intent.side === Side.Buy;
      const targetUsd = Number(intent.targetNotionalUsd) / 1e6;
      const targetSigned = isBuy ? targetUsd : -targetUsd;

      let currentSigned = 0;
      if (this.isPerp()) {
        const state = (await this.hlInfo({ type: "clearinghouseState", user: account.address }).catch(() => null)) as ClearinghouseState | null;
        const ap = (state?.assetPositions ?? []).find((x) => x?.position?.coin === market.tickerSymbol);
        if (ap) {
          const szi = parseFloat(ap.position.szi ?? "0");
          currentSigned = szi * mid;
        }
      } else {
        const state = (await this.hlInfo({ type: "spotClearinghouseState", user: account.address }).catch(() => null)) as SpotClearinghouseState | null;
        const b = (state?.balances ?? []).find((x) => x.coin === market.tickerSymbol);
        if (b) currentSigned = parseFloat(b.total ?? "0") * mid;
      }

      const deltaUsd = targetSigned - currentSigned;
      const tolUsd = 1.0; // $1 dead-band — don't chase dust
      console.log(`[hl] rebalance ${coinName}: target=$${targetSigned.toFixed(2)} current=$${currentSigned.toFixed(2)} delta=$${deltaUsd.toFixed(2)}`);

      if (Math.abs(deltaUsd) <= tolUsd) {
        // Already at target — return existing position as a synthetic Filled receipt.
        console.log(`[hl] within tolerance, no order. Reporting existing position as filled.`);
        const filledUsd = Math.abs(currentSigned);
        const filledBase = Math.abs(currentSigned) / mid;
        return {
          cycleId: intent.cycleId,
          venue: intent.venue,
          status: ExecStatus.Filled,
          filledNotionalUsd: BigInt(Math.floor(filledUsd * 1e6)),
          filledBaseQty: BigInt(Math.floor(filledBase * 1e18)),
          avgPriceE18: BigInt(Math.floor(mid * 1e18)),
          externalOrderId: pad(toHex(0), { size: 32 }) as Hex,
          externalAccountRef: pad(account.address, { size: 32 }) as Hex,
          terminal: true,
          rawPayloadHash: keccak256(toBytes(`rebalance-noop:${coinName}:${currentSigned}`)),
        };
      }

      // Net delta → real order. HL min-notional guard: venue rejects orders <$10 notional.
      // If the DELTA is below min, two cases: (a) fresh open below min → return Failed so
      // controller abandons cycle cleanly (LEG_FAILED at ref, UNHEDGED at hedge); (b) small
      // drift rebalance on an existing position → report current position as filled (we can't
      // tighten to exact target through the venue min, so accept the residual drift).
      const HL_MIN_NOTIONAL = 10.0;
      if (Math.abs(deltaUsd) < HL_MIN_NOTIONAL) {
        console.log(`[hl] delta $${deltaUsd.toFixed(2)} < $${HL_MIN_NOTIONAL} min — reporting ${Math.abs(currentSigned) > 0 ? "current-position" : "FAILED"}`);
        if (Math.abs(currentSigned) === 0) {
          return failReceipt(intent, `delta ${deltaUsd.toFixed(2)} below HL min ${HL_MIN_NOTIONAL}`);
        }
        return {
          cycleId: intent.cycleId,
          venue: intent.venue,
          status: ExecStatus.Filled,
          filledNotionalUsd: BigInt(Math.floor(Math.abs(currentSigned) * 1e6)),
          filledBaseQty: BigInt(Math.floor(Math.abs(currentSigned) / mid * 1e18)),
          avgPriceE18: BigInt(Math.floor(mid * 1e18)),
          externalOrderId: pad(toHex(0), { size: 32 }) as Hex,
          externalAccountRef: pad(account.address, { size: 32 }) as Hex,
          terminal: true,
          rawPayloadHash: keccak256(toBytes(`hl-drift-below-min:${coinName}:${deltaUsd}`)),
        };
      }

      const orderIsBuy = deltaUsd > 0;
      const deltaBase = Math.abs(deltaUsd) / mid;
      const sz = Number(deltaBase.toFixed(market.szDecimals));
      const limitPx = Number((orderIsBuy ? mid * 1.05 : mid * 0.95).toPrecision(5));
      console.log(`[hl] placing ${coinName} ${orderIsBuy?'BUY':'SELL'} sz=${sz} px=${limitPx} (delta $${deltaUsd.toFixed(2)})`);

      let resp: OrderResponse | null = null;
      try {
        resp = await sdk.exchange.placeOrder({
          coin: coinName,
          is_buy: orderIsBuy,
          sz,
          limit_px: limitPx,
          order_type: { limit: { tif: "Ioc" } },
          reduce_only: false,
        });
        console.log(`[hl] resp: ${JSON.stringify(resp).slice(0,300)}`);
      } catch (err) {
        console.log(`[hl] placeOrder threw: ${String(err).slice(0,300)}`);
        return failReceipt(intent, "placeOrder threw");
      }

      if (resp?.status !== "ok") {
        return failReceipt(intent, `hl order rejected: ${JSON.stringify(resp).slice(0, 200)}`);
      }
      // SDK's statuses only type `resting`/`filled`. HL runtime also returns `error: string` on
      // rejection — widen at the use-site.
      const statusEntry = resp.response.data.statuses[0] as
        | { resting: { oid: number } }
        | { filled: { oid: number; totalSz: string; avgPx: string } }
        | { error: string };
      if ("error" in statusEntry) {
        return failReceipt(intent, `hl order error: ${statusEntry.error}`);
      }

      const filled = "filled" in statusEntry ? statusEntry.filled : undefined;
      if (filled) {
        const avgPx = parseFloat(filled.avgPx);
        const totalSz = parseFloat(filled.totalSz);
        // Report the RESULTING position (target) as filledNotionalUsd, not the delta order size.
        const resultingSignedUsd = targetSigned;
        const resultingNotionalUsd = Math.abs(resultingSignedUsd);
        const resultingBaseQty = resultingNotionalUsd / mid;

        // CLOSE-SIDE CCTP-BACK: when the rebalance SHRANK our position (|currentSigned| >
        // |targetSigned|), USDC was freed on HyperCore. Bridge it to the Base module so the
        // controller's subsequent REFILL_RESERVE command finds USDC to push into the sleeve.
        // Fire-and-forget — HTTP handler returns immediately; `sendToEvmWithData` is a single
        // HL API action (no attestation wait) and Circle's automatic forwarder credits Base.
        const shrank = Math.abs(currentSigned) - Math.abs(resultingSignedUsd);
        if (shrank > 1.0 && ctx?.moduleAddress) {
          if (!creds.baseSignerKey) {
            throw new Error("missing x-base-signer-key — can't finalize HL→Base CCTP on unwind");
          }
          const freedMicro = BigInt(Math.floor(shrank * 1_000_000));
          const moduleAddr = ctx.moduleAddress;
          console.log(`[hl] position shrank $${shrank.toFixed(2)} — unwindHlOutbound → module ${moduleAddr}`);
          // Inline-blocking: the /leg/execute response must NOT return before the Base mint is
          // confirmed. Follows the Base→HL settleHlInbound pattern (pull msg → poll Iris → mint).
          // baseSignerKey is TEE-injected per request via `x-base-signer-key` header.
          const r = await unwindHlOutbound(creds.hlPrivateKey!, moduleAddr, freedMicro, creds.baseSignerKey, "");
          console.log(`[hl] CCTP-back complete: burn=${r.burnTxHash} mint=${r.baseReceiveTxHash}`);
        }

        return {
          cycleId: intent.cycleId,
          venue: intent.venue,
          status: resultingNotionalUsd * 1e6 >= Number(intent.targetNotionalUsd) * 0.99 ? ExecStatus.Filled : ExecStatus.PartialFill,
          filledNotionalUsd: BigInt(Math.floor(resultingNotionalUsd * 1e6)),
          filledBaseQty: BigInt(Math.floor(resultingBaseQty * 1e18)),
          avgPriceE18: BigInt(Math.floor(avgPx * 1e18)),
          externalOrderId: pad(toHex(filled.oid ?? 0), { size: 32 }) as Hex,
          externalAccountRef: pad(account.address, { size: 32 }) as Hex,
          terminal: true,
          rawPayloadHash: keccak256(toBytes(JSON.stringify({ resp, resultingNotionalUsd, deltaSz: totalSz }))),
        };
      }

      // Not filled (unusual for IoC — likely rejected or fully cancelled).
      return failReceipt(intent, "hl order placed but no fill");
    } finally {
      sdk.disconnect();
    }
  }

  async getBuffer(creds: VenueCredentials): Promise<LegBufferSnapshot> {
    if (!creds.hlPrivateKey) return { bufferUsd: 0n, timestamp: nowSec() };
    const account = privateKeyToAccount(creds.hlPrivateKey);

    // Self-heal layer 1: CCTP reconciliation. Scan Base CCTP sender events for any stranded
    // HL top-up burns and submit receiveMessage on HyperEVM. Recovers from inline-settle
    // failures (crash, stale code, gateway reject). Zero cost if no pending.
    const cctpSender = process.env.BASE_CCTP_SENDER as Address | undefined;
    if (cctpSender && creds.hlPrivateKey) {
      try {
        const base = defineChain({
          id: 8453, name: "Base",
          nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
          rpcUrls: { default: { http: ["https://mainnet.base.org"] } },
        });
        const hyperevm = defineChain({
          id: 999, name: "HyperEVM",
          nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
          rpcUrls: { default: { http: ["https://rpc.hyperliquid.xyz/evm"] } },
        });
        const basePub = createPublicClient({ chain: base, transport: http() });
        const hlPub = createPublicClient({ chain: hyperevm, transport: http() });
        const hlWallet = createWalletClient({
          chain: hyperevm, transport: http(),
          account: privateKeyToAccount(creds.hlPrivateKey),
        });
        // HL perp + HL spot both route via `dest:hl:perp` / `dest:hl:spot`. Reconcile the one
        // matching this venue; the other's handled by its own adapter instance's getBuffer.
        const destRef: `0x${string}` = this.isPerp()
          ? "0x14ea71fbfd6c1e5a474b882bed919af85a238641811bfb45bb190614cccbcb5d"
          : "0x505c4f0d4540ebe3cf3a696872bd20475324e24a241d00cd1c67a9efa1bff9ff";
        const r = await reconcileCctpForDestRef({
          basePub, baseCctpSender: cctpSender, destRef,
          destPub: hlPub, destWallet: hlWallet, sourceDomain: DOMAIN.BASE,
        });
        if (r.settled > 0 || r.pending > 0) {
          console.log(`[hl] cctp reconcile: scanned=${r.scanned} settled=${r.settled} pending=${r.pending}`);
        }
      } catch (e) {
        console.log(`[hl] cctp reconcile skipped: ${String(e).slice(0, 160)}`);
      }
    }

    // Self-heal layer 2: if any USDC is stranded on HyperEVM at the HL wallet (happens when a
    // prior `/base/execute-command` flow was interrupted between CCTP receive and
    // CoreDepositWallet.deposit — e.g. adapter restart, gateway reject), sweep it to
    // HyperCore on the right dex (perp=0 or spot=type(uint32).max) before reading balance.
    try {
      await this.sweepStrandedHyperEvmToHyperCore(creds.hlPrivateKey, this.isPerp());
    } catch (e) {
      console.log(`[hl] sweep-stranded non-fatal: ${String(e).slice(0, 160)}`);
    }

    if (this.isPerp()) {
      const state = await this.hlInfo({ type: "clearinghouseState", user: account.address });
      // HL unified accounts: perp orders can draw margin from the combined spot+perp balance.
      // Report `accountValue` (or `withdrawable`, whichever is larger) so the controller's buffer
      // check reflects actual available margin, not just the perp-only slice. Legacy isolated
      // accounts return `accountValue == withdrawable` so this is a no-op there.
      const withdrawable = parseFloat(state?.withdrawable ?? "0");
      const accountValue = parseFloat(state?.marginSummary?.accountValue ?? "0");
      let available = Math.max(withdrawable, accountValue);
      // In unified mode, also add the spot USDC slice since it backs perp margin cross-margin.
      try {
        const spotState = await this.hlInfo({ type: "spotClearinghouseState", user: account.address });
        const spotUsdc = (spotState?.balances ?? []).find((b: { coin: string; total: string }) => b.coin === "USDC");
        if (spotUsdc) available += parseFloat(spotUsdc.total ?? "0");
      } catch {
        // spot read optional — if it fails, withdrawable / accountValue still gives us a floor
      }
      return { bufferUsd: BigInt(Math.floor(available * 1e6)), timestamp: nowSec() };
    } else {
      const state = await this.hlInfo({ type: "spotClearinghouseState", user: account.address });
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
    const sdk = new Hyperliquid({ privateKey: creds.hlPrivateKey, enableWs: false, testnet: false });
    await sdk.connect();

    try {
      if (this.isPerp()) {
        // SDK's one-shot close lives on `sdk.custom` (not `sdk.exchange`): 5% slippage tolerance.
        await sdk.custom.closeAllPositions(0.05).catch(() => {});
      } else {
        // Spot: sell all non-USDC balances via individual market sells.
        const state = await this.hlInfo({ type: "spotClearinghouseState", user: account.address });
        const bal = Array.isArray(state?.balances) ? state.balances : [];
        for (const b of bal) {
          if (b.coin === "USDC") continue;
          const size = parseFloat(b.total);
          if (size <= 0) continue;
          const mid = await this.getMidPrice(b.coin);
          if (!mid) continue;
          await sdk.exchange.placeOrder({
            coin: `${b.coin}-SPOT`,
            is_buy: false,
            sz: size,
            limit_px: Number((mid * 0.95).toPrecision(5)),
            order_type: { limit: { tif: "Ioc" } },
            reduce_only: false,
          }).catch(() => {});
        }
      }

      // Withdraw post-close HyperCore balance back to HyperEVM (same address).
      // The adapter's outbound CCTP step (`unwindHlOutbound`) will then bridge HyperEVM→Base.
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
        // SDK convenience: withdraw to self on HyperEVM.
        await (sdk.exchange as any).initiateWithdrawal?.(withdrawable).catch(() => {});
      }
      return BigInt(Math.floor(withdrawable * 1e6));
    } finally {
      sdk.disconnect();
    }
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

// Ritual `block.timestamp` is in MILLISECONDS (non-standard EVM). Buffer + valuation
// timestamps written by the adapter are compared against Ritual's block.timestamp, so they
// must also be ms. The function name is kept for grep continuity — it returns MS.
function nowSec(): bigint {
  return BigInt(Date.now());
}

