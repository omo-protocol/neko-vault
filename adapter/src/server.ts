import Fastify, { type FastifyRequest } from "fastify";
import { keccak256, toBytes, pad, toHex, type Hex, type Address } from "viem";
import {
  decodeExecutionIntent,
  decodeCommandEnvelope,
  encodeExecutionReceipt,
  encodeBufferSnapshots,
  encodeValuationResponse,
  encodeUnwindResult,
} from "./codec.js";
import { BaseClient } from "./base-client.js";
import { HyperliquidAdapter, V_HL_PERP as HL_PERP, V_HL_SPOT as HL_SPOT, type HlMarketRegistry } from "./venues/hyperliquid.js";
import { PolymarketAdapter, V_POLYMARKET as PM_VENUE, type PmMarketRegistry } from "./venues/polymarket.js";
import type { VenueAdapter } from "./venues/types.js";
import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
} from "./types.js";
import { ExecStatus } from "./types.js";
import {
  settlePmInbound,
  settleHlInbound,
  unwindPmOutbound,
  unwindHlOutbound,
} from "./bridges/index.js";

/// Matches CrossVenueCommandLib.CommandType in Solidity.
enum CommandType {
  TOPUP_PM_BUFFER = 0,
  TOPUP_HL_BUFFER = 1,
  REFILL_RESERVE = 2,
  PAUSE = 3,
}

/// Venue ID constants (keccak256 of canonical names, must match Solidity).
const V_HL_PERP = HL_PERP;
const V_HL_SPOT = HL_SPOT;
const V_POLYMARKET = PM_VENUE;

export interface AdapterServerOptions {
  /** Pre-built venue map (test injection). Defaults to real HL + PM adapters if registries provided,
   *  else falls back to mocks. */
  venues?: Map<Hex, VenueAdapter>;
  /** Per-venue market registries — map `marketRef` bytes32 to venue-specific asset identifiers. */
  hlMarkets?: HlMarketRegistry;
  pmMarkets?: PmMarketRegistry;
  /** Base-chain client for /base/execute-command + /valuation push. */
  baseClient: BaseClient;
  /** BaseExecutionGateway address. */
  gateway: Address;
  /** Gateway EIP-712 domain. */
  gatewayName: string;
  gatewayVersion: string;
  /** UniversalValuerOffchain address. */
  valuer: Address;
  /** USDC address on Base. */
  baseAsset: Address;
  /** Vault address for reserve reads. */
  vault: Address;
  /** BaseStrategyModule address — used as `mintRecipient` for inbound-unwind CCTP bursts. */
  module: Address;
}

export function buildServer(opts: AdapterServerOptions) {
  const app = Fastify({ logger: true });

  if (!opts.hlMarkets) {
    throw new Error("Adapter requires HL market registry — auto-load from API failed and no override provided.");
  }
  const venues: Map<Hex, VenueAdapter> =
    opts.venues ??
    new Map<Hex, VenueAdapter>([
      [V_HL_PERP, new HyperliquidAdapter(V_HL_PERP, opts.hlMarkets)],
      [V_HL_SPOT, new HyperliquidAdapter(V_HL_SPOT, opts.hlMarkets)],
      [V_POLYMARKET, new PolymarketAdapter(opts.pmMarkets ?? {})],
    ]);

  // TEE executors send mismatched Content-Length headers — strip them to avoid Fastify 400s.
  app.addHook("onRequest", (req, _reply, done) => { delete req.headers["content-length"]; done(); });
  // Catch-all body parser — accept any content-type as raw buffer.
  app.addContentTypeParser("*", { parseAs: "buffer" }, (_req, body, done) => done(null, body));
  // Raw-body parser — Ritual's HTTP precompile sends ABI-encoded bytes.
  app.addContentTypeParser(
    "application/json",
    { parseAs: "string" },
    (_req, body, done) => done(null, body)
  );
  app.addContentTypeParser(
    "application/octet-stream",
    { parseAs: "buffer" },
    (_req, body, done) => done(null, body)
  );

  // Result cache for the long-running HTTP pattern: POST returns a task_id; TEE then polls
  // `<url>/status/<task_id>` which looks up the cached result.
  const resultCache = new Map<string, { result: string; ts: number }>();
  function cacheResult(result: string): string {
    const taskId = Math.random().toString(36).slice(2, 10) + Date.now().toString(36);
    resultCache.set(taskId, { result, ts: Date.now() });
    const cutoff = Date.now() - 5 * 60_000;
    for (const [k, v] of resultCache) if (v.ts < cutoff) resultCache.delete(k);
    return taskId;
  }

  // Idempotency is handled two ways without any adapter-side state:
  //   1. Controller (`MultiLegController.onLegResult`): silent no-op if `tradingState` drifted
  //      or `pendingLegJobId` is already cleared → AsyncDelivery won't retry the precompile,
  //      which means no duplicate /leg/execute POSTs from that path.
  //   2. Adapter venue methods: delta-based rebalance — read current venue position, place
  //      only the net delta (target − current). Second call with same intent finds position
  //      already at target → returns a synthetic Filled receipt without placing a new order.
  // Result: stateless adapter, no dedup cache needed.

  function credentialsFromHeaders(headers: Record<string, string | string[] | undefined>): VenueCredentials {
    const h = (k: string) => {
      const v = headers[k];
      return typeof v === "string" && v.length > 0 ? v : undefined;
    };
    return {
      hlPrivateKey: h("x-hl-key") as Hex | undefined,
      pmPrivateKey: h("x-pm-key") as Hex | undefined,
      pmApiKey: h("x-pm-api-key"),
      pmApiSecret: h("x-pm-api-secret"),
      pmApiPassphrase: h("x-pm-passphrase"),
      baseSignerKey: h("x-base-signer-key") as Hex | undefined,
      valuerSignerKey: h("x-valuer-signer-key") as Hex | undefined,
    };
  }

  function rawBodyToHex(req: FastifyRequest): Hex {
    const raw = req.body as string | Buffer;
    const str = typeof raw === "string" ? raw.trim() : raw.toString("utf-8").trim();
    if (str.startsWith("0x")) return str as Hex;
    return ("0x" + Buffer.from(raw as Buffer).toString("hex")) as Hex;
  }

  // ─── POST /leg/execute ─── submit a trade intent for a single leg
  app.post("/leg/execute", async (req, reply) => {
    try {
      const hex = rawBodyToHex(req);
      req.log.info({ bodyLen: hex.length, first64: hex.slice(0, 66), last64: hex.slice(-64) }, "leg-execute body");
      const intent = decodeExecutionIntent(hex);
      const creds = credentialsFromHeaders(req.headers);
      const adapter = venues.get(intent.venue);
      const result: NormalizedExecutionReceipt =
        adapter == null
          ? failReceipt(intent)
          : await adapter.execute(intent, creds, { moduleAddress: opts.module });
      return reply
        .type("application/json")
        .send((() => { const __r = encodeExecutionReceipt(result); const __id = cacheResult(__r); return { task_id: __id, status: "completed", result: __r }; })());
    } catch (err) {
      req.log.error({ err: String(err), stack: (err as Error)?.stack }, "leg-execute failed");
      return reply.status(400).send({ error: String(err) });
    }
  });

  // ─── POST /buffers ─── return buffer snapshots for all configured legs
  app.post("/buffers", async (req, reply) => {
    try {
      const creds = credentialsFromHeaders(req.headers);
      const ordered = [V_POLYMARKET, V_HL_PERP, V_HL_SPOT];
      const snaps: LegBufferSnapshot[] = [];
      for (const v of ordered) {
        const a = venues.get(v);
        if (a == null) {
          snaps.push({ bufferUsd: 0n, timestamp: BigInt(Math.floor(Date.now() / 1000)) });
          continue;
        }
        snaps.push(await a.getBuffer(creds));
      }
      return reply
        .type("application/json")
        .send((() => { const __r = encodeBufferSnapshots(snaps); const __id = cacheResult(__r); return { task_id: __id, status: "completed", result: __r }; })());
    } catch (err) {
      return reply.status(400).send({ error: String(err) });
    }
  });

  // ─── POST /base/execute-command ─── TEE signs + submits envelope on Base
  app.post("/base/execute-command", async (req, reply) => {
    try {
      const hex = rawBodyToHex(req);
      req.log.info({ bodyLen: hex.length, first64: hex.slice(0, 66), last64: hex.slice(-64) }, "base-cmd body");
      const env = decodeCommandEnvelope(hex);
      const creds = credentialsFromHeaders(req.headers);
      if (creds.baseSignerKey == null) {
        return reply.status(401).send({ error: "missing x-base-signer-key" });
      }
      const baseClient = new BaseClient(
        opts.baseClient.rpcUrl,
        opts.baseClient.walletClient.chain!.id,
        creds.baseSignerKey
      );
      const baseRes = await baseClient.submitCommandEnvelope(
        opts.gateway,
        env,
        opts.gatewayName,
        opts.gatewayVersion
      );
      const { txHash, success } = baseRes;
      if (!success) {
        req.log.error({ txHash, errorMessage: baseRes.errorMessage, env }, "executeCommand failed");
      }

      // After a successful top-up command, drive the inbound CCTP settlement INLINE.
      //   Base burn (just happened) → Circle attestation → venue-chain receive
      //   → (HL only) CoreDepositWallet.deposit to credit HyperCore
      //   → (PM only) ensure CTF Exchange allowance
      // With CCTP V2 Fast Transfer (maxFee ≥ 10000, finalityThreshold = 1000), end-to-end
      // is typically 60–90 s — inside Ritual's HTTP precompile TTL (30 blocks ≈ 150 s).
      // Blocking here lets the controller's `onBaseCommandSubmitted` callback encode
      // "base success == funding confirmed", so fundingState can flip TOPUP_PENDING → OK
      // without a separate off-chain receipt hop.
      if (success) {
        const cmdType = Number((env as any).commandType) as CommandType;
        const amount = BigInt((env as any).amount);
        try {
          if (cmdType === CommandType.TOPUP_PM_BUFFER && creds.pmPrivateKey != null && amount > 0n) {
            if (creds.baseSignerKey == null) {
              throw new Error("settlePmInbound requires x-base-signer-key for Base USDC transfer to PM Bridge");
            }
            await settlePmInbound(creds.pmPrivateKey, creds.baseSignerKey, {
              amount,
              minAllowance: amount,
            });
          } else if (cmdType === CommandType.TOPUP_HL_BUFFER && creds.hlPrivateKey != null && amount > 0n) {
            // Route to HyperCore dex based on destinationRef. Dedicated refs
            // `keccak("dest:hl:spot")` → SPOT dex, `keccak("dest:hl:perp")` → PERP. Fallback
            // (legacy `keccak("dest:hl")` or unknown) → PERP. Lets a multi-leg clone mix HL
            // spot + HL perp in the same strategy without ambiguity.
            const destRef = String((env as any).destinationRef ?? "").toLowerCase();
            const HL_SPOT_REF = "0x505c4f0d4540ebe3cf3a696872bd20475324e24a241d00cd1c67a9efa1bff9ff"; // keccak("dest:hl:spot")
            const HL_PERP_REF = "0x14ea71fbfd6c1e5a474b882bed919af85a238641811bfb45bb190614cccbcb5d"; // keccak("dest:hl:perp")
            let destDex: number | undefined;
            if (destRef === HL_SPOT_REF) destDex = 4294967295;
            else if (destRef === HL_PERP_REF) destDex = 0;
            await settleHlInbound(creds.hlPrivateKey, {
              baseBurnTxHash: txHash,
              amount,
              destinationDex: destDex,
            });
          }
        } catch (settleErr) {
          // Settlement failed (attestation slow, RPC glitch, etc). We still return success for
          // the Base tx — the burn landed — but surface the failure so the controller's callback
          // sees it. The controller should stay in TOPUP_PENDING until operator retries.
          req.log.error({ err: String(settleErr) }, "CCTP inbound settlement failed");
          const failBody = encodeBaseSubmitResult(txHash, false);
          return reply
            .type("application/json")
            .send((() => { const __r = failBody; const __id = cacheResult(__r); return { task_id: __id, status: "completed", result: __r }; })());
        }
      }

      // Body: abi.encode(bytes32 baseTxHash, bool success, string errorMsg)
      const body = encodeBaseSubmitResult(txHash, success);
      return reply
        .type("application/json")
        .send((() => { const __r = body; const __id = cacheResult(__r); return { task_id: __id, status: "completed", result: __r }; })());
    } catch (err) {
      req.log.error({ err: String(err), stack: (err as Error)?.stack, baseKey: String(req.headers["x-base-signer-key"] ?? "").slice(0, 12) }, "base/execute-command failed");
      return reply.status(500).send({ error: String(err) });
    }
  });

  // ─── POST /valuation ─── compute NAV across venues, push to Base valuer, read Base reserve
  app.post("/valuation", async (req, reply) => {
    try {
      const creds = credentialsFromHeaders(req.headers);
      const strategyId = rawBodyToHex(req).slice(0, 66) as Hex; // first bytes32 of body

      let totalMarkUsd = 0n;
      for (const adapter of venues.values()) {
        totalMarkUsd += await adapter.getPositionMarkValue(creds, strategyId);
      }

      // Read Base USDC reserve (vault's own USDC balance).
      const baseReserveUsd = await opts.baseClient.balanceOf(
        opts.baseAsset,
        opts.vault
      );

      // Push NAV to Base valuer.
      let baseTxHash: Hex = pad(toHex(0), { size: 32 }) as Hex;
      let baseSuccess = false;
      if (creds.baseSignerKey != null && creds.valuerSignerKey != null) {
        const baseClient = new BaseClient(
          opts.baseClient.rpcUrl,
          opts.baseClient.walletClient.chain!.id,
          creds.baseSignerKey
        );
        const nonce = BigInt(Math.floor(Date.now() / 1000));
        const res = await baseClient.pushNav(
          opts.valuer,
          creds.valuerSignerKey,
          strategyId,
          totalMarkUsd,
          90n,
          nonce,
          600n // 10-minute expiry
        );
        baseTxHash = res.txHash;
        baseSuccess = res.success;
      }

      req.log.info({ totalMarkUsd: totalMarkUsd.toString(), baseReserveUsd: baseReserveUsd.toString(), baseTxHash, baseSuccess }, "valuation ok");
      const body = encodeValuationResponse({
        navUsd: totalMarkUsd,
        baseReserveUsd,
        baseTxHash,
        baseSuccess,
      });
      return reply
        .type("application/json")
        .send((() => { const __r = body; const __id = cacheResult(__r); return { task_id: __id, status: "completed", result: __r }; })());
    } catch (err) {
      req.log.error({ err: String(err), stack: (err as Error)?.stack }, "valuation failed");
      return reply.status(500).send({ error: String(err) });
    }
  });

  // ─── POST /unwind ─── close all venue positions, return realized USDC
  app.post("/unwind", async (req, reply) => {
    try {
      const creds = credentialsFromHeaders(req.headers);
      // Body: abi.encode(bytes32 cycleId, uint256 targetAssetsUsd) — we only use strategyId-style addressing.
      const strategyId = rawBodyToHex(req).slice(0, 66) as Hex;

      // Phase 1: close positions on each venue and withdraw to the venue-chain EOA's USDC balance.
      // `closeAllAndWithdraw` is responsible for: PM → sell all + withdraw from CTF Exchange;
      // HL → close all perps/spot + `withdraw3` to HyperEVM USDC balance.
      let realized = 0n;
      const hlRealized: bigint = (venues.has(V_HL_PERP) || venues.has(V_HL_SPOT)) && creds.hlPrivateKey != null
        ? await (venues.get(V_HL_PERP) ?? venues.get(V_HL_SPOT)!).closeAllAndWithdraw(creds, strategyId)
        : 0n;
      const pmRealized: bigint = venues.has(V_POLYMARKET) && creds.pmPrivateKey != null
        ? await venues.get(V_POLYMARKET)!.closeAllAndWithdraw(creds, strategyId)
        : 0n;
      realized = hlRealized + pmRealized;

      // Phase 2: CCTP-burn the venue-chain USDC back to the Base module, wait for Circle
      // attestation, post receiveMessage on Base. Both legs run in parallel; we block until
      // both mints settle before returning so MultiLegController.onUnwindResult →
      // REFILL_RESERVE has an accurate realized figure.
      if (creds.baseSignerKey == null) {
        return reply.status(401).send({ error: "missing x-base-signer-key — unwind finalize needs Base EOA" });
      }
      const baseKey = creds.baseSignerKey;
      const unwindJobs: Promise<void>[] = [];
      if (hlRealized > 0n && creds.hlPrivateKey != null) {
        unwindJobs.push(
          unwindHlOutbound(creds.hlPrivateKey, opts.module, hlRealized, baseKey, "")
            .then(() => {})
            .catch((err) => console.error(`[adapter] HL unwind CCTP failed: ${err}`))
        );
      }
      if (pmRealized > 0n && creds.pmPrivateKey != null) {
        unwindJobs.push(
          unwindPmOutbound(creds.pmPrivateKey, opts.module, pmRealized, baseKey)
            .then(() => {})
            .catch((err) => console.error(`[adapter] PM unwind CCTP failed: ${err}`))
        );
      }
      if (unwindJobs.length > 0) {
        await Promise.all(unwindJobs);
      }

      const body = encodeUnwindResult(realized);
      return reply
        .type("application/json")
        .send((() => { const __r = body; const __id = cacheResult(__r); return { task_id: __id, status: "completed", result: __r }; })());
    } catch (err) {
      return reply.status(500).send({ error: String(err) });
    }
  });

  // ─── POST /settle/:kind ─── manually (re-)trigger a CCTP inbound settlement for a past Base
  //     burn (recovery path — idempotent). Body: { baseBurnTxHash: "0x...", amount: "5000000" }.
  //     Credentials via the usual venue headers.
  app.post<{ Params: { kind: string } }>("/settle/:kind", async (req, reply) => {
    const kindParam = req.params.kind;
    if (kindParam !== "pm" && kindParam !== "hl") {
      return reply.status(400).send({ error: "kind must be 'pm' or 'hl'" });
    }
    const body = (req.body ?? {}) as { baseBurnTxHash?: string; amount?: string };
    const baseBurnTxHash = body.baseBurnTxHash as Hex | undefined;
    const amountStr = body.amount;
    if (!baseBurnTxHash || !amountStr) {
      return reply.status(400).send({ error: "need baseBurnTxHash and amount" });
    }
    const creds = credentialsFromHeaders(req.headers);
    try {
      if (kindParam === "pm") {
        if (creds.pmPrivateKey == null) return reply.status(401).send({ error: "missing x-pm-key" });
        if (creds.baseSignerKey == null) return reply.status(401).send({ error: "missing x-base-signer-key (required for PM Bridge API inbound)" });
        const res = await settlePmInbound(creds.pmPrivateKey, creds.baseSignerKey, {
          amount: BigInt(amountStr),
          minAllowance: BigInt(amountStr),
        });
        return reply.send({ ok: true, ...res });
      } else {
        if (creds.hlPrivateKey == null) return reply.status(401).send({ error: "missing x-hl-key" });
        const res = await settleHlInbound(creds.hlPrivateKey, {
          baseBurnTxHash,
          amount: BigInt(amountStr),
        });
        return reply.send({ ok: true, ...res });
      }
    } catch (err) {
      return reply.status(500).send({ error: String(err) });
    }
  });

  // statusCatchAll — long-running HTTP precompile polls <url>/status/<taskId>; we always
  // return status=completed since our endpoints reply immediately in wrapAsTask form.
  app.all("/*", async (req, reply) => {
    // TEE polls <endpoint>/status/<task_id>; return the cached result for that task_id.
    const statusMatch = req.url.match(/\/status\/([a-zA-Z0-9]+)/);
    if (statusMatch) {
      const cached = resultCache.get(statusMatch[1]);
      return reply.type("application/json").send({
        status: "completed",
        result: cached?.result ?? "0x",
      });
    }
    return reply.status(404).send({ error: "not found" });
  });

  // ─── Health ─────────────────────────────────────────────────────────────
  app.get("/health", async () => ({
    status: "ok",
    venues: [...venues.keys()],
    baseSigner: opts.baseClient.signerAddress(),
  }));

  return app;
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
    rawPayloadHash: keccak256(toBytes("fail")),
  };
}

function encodeBaseSubmitResult(txHash: Hex, success: boolean): Hex {
  // abi.encode(bytes32, bool, string) — adapter's response body.
  const strEmpty = "0000000000000000000000000000000000000000000000000000000000000000";
  const txHashHex = txHash.slice(2).padStart(64, "0");
  const successHex = success
    ? "0000000000000000000000000000000000000000000000000000000000000001"
    : "0000000000000000000000000000000000000000000000000000000000000000";
  const stringOffset = "0000000000000000000000000000000000000000000000000000000000000060";
  return `0x${txHashHex}${successHex}${stringOffset}${strEmpty}` as Hex;
}
