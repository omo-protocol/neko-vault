import {
  createPublicClient,
  http,
  keccak256,
  toBytes,
  toHex,
  pad,
  defineChain,
  encodeFunctionData,
  type Address,
  type Hex,
  type PublicClient,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import type {
  ExecutionIntent,
  NormalizedExecutionReceipt,
  VenueCredentials,
  LegBufferSnapshot,
  PtIterationIntent,
} from "../types.js";
import { ExecStatus } from "../types.js";
import type { VenueAdapter, VenueExecContext } from "./types.js";
import { getPtLoopChain, type PtLoopChainConfig } from "../chains/pt-loop-chains.js";
import { resolveExecutorClone, settlePtLoopInbound, unwindPtLoopOutbound } from "../bridges/pt-loop.js";
import { reconcileCctpForDestRef } from "../bridges/cctpReconcile.js";
import { createWalletClient } from "viem";
import { DOMAIN } from "../bridges/cctp.js";

export const V_PENDLE = keccak256(toBytes("PENDLE"));

/// Pendle market reference convention: `marketRef = bytes32(uint160(pendleMarket))`.
/// Both the Pendle market address AND the Morpho market id come from the controller's
/// `PtLoopConfig` (user-supplied at clone creation) — no adapter-side registry needed.
function ptMarketRefToAddress(marketRef: Hex): Address {
  return ("0x" + marketRef.slice(-40)) as Address;
}

// ─── ABIs ──────────────────────────────────────────────────────────────────

const erc20BalAbi = [
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "a", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
] as const;

const pendleMarketAbi = [
  { name: "readTokens", type: "function", stateMutability: "view",
    inputs: [], outputs: [
      { name: "sy", type: "address" }, { name: "pt", type: "address" }, { name: "yt", type: "address" },
    ] },
  { name: "isExpired", type: "function", stateMutability: "view",
    inputs: [], outputs: [{ name: "", type: "bool" }] },
] as const;

/// Morpho Blue ABI surface used for validation + calldata construction.
/// See: github.com/morpho-org/morpho-blue (src/interfaces/IMorpho.sol)
const morphoAbi = [
  {
    name: "idToMarketParams",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "loanToken", type: "address" },
      { name: "collateralToken", type: "address" },
      { name: "oracle", type: "address" },
      { name: "irm", type: "address" },
      { name: "lltv", type: "uint256" },
    ],
  },
  {
    name: "market",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "id", type: "bytes32" }],
    outputs: [
      { name: "totalSupplyAssets", type: "uint128" },
      { name: "totalSupplyShares", type: "uint128" },
      { name: "totalBorrowAssets", type: "uint128" },
      { name: "totalBorrowShares", type: "uint128" },
      { name: "lastUpdate", type: "uint128" },
      { name: "fee", type: "uint128" },
    ],
  },
  {
    name: "position",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "id", type: "bytes32" },
      { name: "user", type: "address" },
    ],
    outputs: [
      { name: "supplyShares", type: "uint256" },
      { name: "borrowShares", type: "uint128" },
      { name: "collateral", type: "uint128" },
    ],
  },
  {
    name: "supplyCollateral",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "marketParams",
        type: "tuple",
        components: [
          { name: "loanToken", type: "address" },
          { name: "collateralToken", type: "address" },
          { name: "oracle", type: "address" },
          { name: "irm", type: "address" },
          { name: "lltv", type: "uint256" },
        ],
      },
      { name: "assets", type: "uint256" },
      { name: "onBehalf", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [],
  },
  {
    name: "borrow",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "marketParams",
        type: "tuple",
        components: [
          { name: "loanToken", type: "address" },
          { name: "collateralToken", type: "address" },
          { name: "oracle", type: "address" },
          { name: "irm", type: "address" },
          { name: "lltv", type: "uint256" },
        ],
      },
      { name: "assets", type: "uint256" },
      { name: "shares", type: "uint256" },
      { name: "onBehalf", type: "address" },
      { name: "receiver", type: "address" },
    ],
    outputs: [
      { name: "", type: "uint256" },
      { name: "", type: "uint256" },
    ],
  },
  {
    name: "repay",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "marketParams",
        type: "tuple",
        components: [
          { name: "loanToken", type: "address" },
          { name: "collateralToken", type: "address" },
          { name: "oracle", type: "address" },
          { name: "irm", type: "address" },
          { name: "lltv", type: "uint256" },
        ],
      },
      { name: "assets", type: "uint256" },
      { name: "shares", type: "uint256" },
      { name: "onBehalf", type: "address" },
      { name: "data", type: "bytes" },
    ],
    outputs: [
      { name: "", type: "uint256" },
      { name: "", type: "uint256" },
    ],
  },
  {
    name: "withdrawCollateral",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "marketParams",
        type: "tuple",
        components: [
          { name: "loanToken", type: "address" },
          { name: "collateralToken", type: "address" },
          { name: "oracle", type: "address" },
          { name: "irm", type: "address" },
          { name: "lltv", type: "uint256" },
        ],
      },
      { name: "assets", type: "uint256" },
      { name: "onBehalf", type: "address" },
      { name: "receiver", type: "address" },
    ],
    outputs: [],
  },
] as const;

// ─── Chain + client plumbing ───────────────────────────────────────────────

function chainFor(c: PtLoopChainConfig): Chain {
  return defineChain({
    id: c.chainId,
    name: c.name,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [c.rpcUrl] } },
  });
}

function publicClientFor(c: PtLoopChainConfig): PublicClient {
  return createPublicClient({ chain: chainFor(c), transport: http(c.rpcUrl) });
}

// ─── Pendle SDK calldata builder ───────────────────────────────────────────

async function buildPendleSwapCalldata(p: {
  chainId: number;
  receiver: Address;
  pendleMarket: Address;
  tokenIn: Address;
  amountIn: bigint;
  slippageBps: number;
  direction: "toPt" | "fromPt";
}): Promise<{ calldata: Hex; minOut: bigint }> {
  const base = process.env.PENDLE_SDK_URL ?? "https://api-v2.pendle.finance";
  const qs = new URLSearchParams({
    chainId: String(p.chainId),
    receiver: p.receiver,
    slippage: (p.slippageBps / 10_000).toString(),
    enableAggregator: "true",
  });
  const endpoint =
    p.direction === "toPt"
      ? `${base}/core/v1/sdk/${p.chainId}/markets/${p.pendleMarket}/swap?${qs}&tokenIn=${p.tokenIn}&amountIn=${p.amountIn}`
      : `${base}/core/v1/sdk/${p.chainId}/markets/${p.pendleMarket}/swap?${qs}&tokenOut=${p.tokenIn}&amountPtIn=${p.amountIn}`;
  const res = await fetch(endpoint);
  if (!res.ok) throw new Error(`pendle SDK ${res.status}: ${await res.text()}`);
  const j = (await res.json()) as { tx?: { data?: string }; data?: { amountOut?: string } };
  const data = j.tx?.data as Hex | undefined;
  const amountOut = BigInt(j.data?.amountOut ?? "0");
  if (!data || amountOut === 0n) throw new Error(`pendle SDK returned no tx data`);
  const minOut = (amountOut * BigInt(10_000 - p.slippageBps)) / 10_000n;
  return { calldata: data, minOut };
}

// ─── Live validation (runs pre-enterLoop + at clone creation) ──────────────

export interface MorphoMarketParams {
  loanToken: Address;
  collateralToken: Address;
  oracle: Address;
  irm: Address;
  lltv: bigint;
}

export interface PtLiveValidation {
  pt: Address;
  params: MorphoMarketParams;
  liqLtvBps: bigint;
  usdcBorrowable: bigint;
  maxSafeLeverageBps: bigint;
  hfAtLeverageBps: bigint;
}

/// Live validation. Four checks, runs both at clone creation (FE) and at every /pt/execute.
///   1. Pendle market exists and is not expired.
///   2. Morpho market exists (lltv > 0 means `idToMarketParams` returned a real market).
///   3. collateralToken matches the Pendle market's PT + loanToken is USDC.
///   4. LLTV supports target leverage; HF at target L ≥ hfMinBps.
///   5. Morpho USDC borrow liquidity covers the flash amount we're about to draw.
export async function validatePtLive(
  pub: PublicClient,
  chain: PtLoopChainConfig,
  pendleMarket: Address,
  morphoMarketId: Hex,
  targetLeverageBps: number,
  hfMinBps: number,
  flashAmountUsdc: bigint,
): Promise<PtLiveValidation> {
  // 1. Pendle sanity.
  const tokens = (await pub.readContract({
    address: pendleMarket, abi: pendleMarketAbi, functionName: "readTokens",
  })) as readonly [Address, Address, Address];
  const pt = tokens[1];
  const expired = (await pub.readContract({
    address: pendleMarket, abi: pendleMarketAbi, functionName: "isExpired",
  })) as boolean;
  if (expired) throw new Error(`pendle market ${pendleMarket} is expired`);

  // 2. Morpho market params.
  const paramsRaw = (await pub.readContract({
    address: chain.morpho.blue, abi: morphoAbi, functionName: "idToMarketParams", args: [morphoMarketId],
  })) as readonly [Address, Address, Address, Address, bigint];
  const params: MorphoMarketParams = {
    loanToken: paramsRaw[0],
    collateralToken: paramsRaw[1],
    oracle: paramsRaw[2],
    irm: paramsRaw[3],
    lltv: paramsRaw[4],
  };
  if (params.lltv === 0n) {
    throw new Error(`Morpho market ${morphoMarketId} not found on ${chain.morpho.blue}`);
  }

  // 3. Token pairing matches expectation.
  if (params.collateralToken.toLowerCase() !== pt.toLowerCase()) {
    throw new Error(
      `Morpho market collateral ${params.collateralToken} != Pendle PT ${pt}`,
    );
  }
  if (params.loanToken.toLowerCase() !== chain.usdc.toLowerCase()) {
    throw new Error(
      `Morpho market loanToken ${params.loanToken} != chain USDC ${chain.usdc}`,
    );
  }

  // 4. Leverage + HF. LLTV is 1e18-scaled in Morpho; convert to bps.
  const liqLtvBps = params.lltv / 10n ** 14n;
  if (liqLtvBps === 0n) throw new Error(`Morpho market has zero LLTV`);
  const maxSafeLeverageBps = (10_000n * 10_000n) / (10_000n - liqLtvBps);
  if (BigInt(targetLeverageBps) > maxSafeLeverageBps) {
    throw new Error(
      `leverage ${targetLeverageBps} bps exceeds Morpho max ${maxSafeLeverageBps} bps (LLTV ${liqLtvBps}bps)`,
    );
  }
  const L = BigInt(targetLeverageBps);
  const hfAtLeverageBps = L > 10_000n ? (L * liqLtvBps) / (L - 10_000n) : 10n ** 18n;
  if (hfAtLeverageBps < BigInt(hfMinBps)) {
    throw new Error(`HF ${hfAtLeverageBps} at L=${L} below min ${hfMinBps}`);
  }

  // 5. USDC borrow liquidity = totalSupplyAssets − totalBorrowAssets.
  const m = (await pub.readContract({
    address: chain.morpho.blue, abi: morphoAbi, functionName: "market", args: [morphoMarketId],
  })) as readonly [bigint, bigint, bigint, bigint, bigint, bigint];
  const supply = m[0];
  const borrowed = m[2];
  const usdcBorrowable = supply > borrowed ? supply - borrowed : 0n;
  if (usdcBorrowable < flashAmountUsdc) {
    throw new Error(
      `Morpho USDC liquidity ${usdcBorrowable} < required flash ${flashAmountUsdc}`,
    );
  }

  return { pt, params, liqLtvBps, usdcBorrowable, maxSafeLeverageBps, hfAtLeverageBps };
}

// ─── Live position read (for shrink / unwind routing) ─────────────────────

export interface LivePosition {
  collateralPt: bigint;   // PT token amount held by the clone as collateral
  borrowShares: bigint;   // raw Morpho borrow shares
  debtUsdc: bigint;       // converted to USDC assets via live market state
}

async function readLivePosition(
  pub: PublicClient,
  chain: PtLoopChainConfig,
  morphoMarketId: Hex,
  holder: Address,
): Promise<LivePosition> {
  const pos = (await pub.readContract({
    address: chain.morpho.blue, abi: morphoAbi, functionName: "position",
    args: [morphoMarketId, holder],
  })) as readonly [bigint, bigint, bigint];
  const borrowShares = pos[1];
  const collateralPt = pos[2];
  if (borrowShares === 0n) {
    return { collateralPt, borrowShares, debtUsdc: 0n };
  }
  // Convert shares → assets using live totals. Morpho uses virtual-shares (+1 asset, +1e6
  // shares) to resist manipulation; match on-chain math exactly.
  const m = (await pub.readContract({
    address: chain.morpho.blue, abi: morphoAbi, functionName: "market", args: [morphoMarketId],
  })) as readonly [bigint, bigint, bigint, bigint, bigint, bigint];
  const totalBorrowAssets = m[2];
  const totalBorrowShares = m[3];
  const VIRTUAL_SHARES = 1_000_000n;
  const VIRTUAL_ASSETS = 1n;
  const debtUsdc =
    (borrowShares * (totalBorrowAssets + VIRTUAL_ASSETS)) /
    (totalBorrowShares + VIRTUAL_SHARES) + 1n;
  return { collateralPt, borrowShares, debtUsdc };
}

// ─── Morpho calldata builders ───────────────────────────────────────────────

function buildMorphoSupplyCollateral(params: MorphoMarketParams, amount: bigint, onBehalf: Address): Hex {
  return encodeFunctionData({
    abi: morphoAbi,
    functionName: "supplyCollateral",
    args: [params, amount, onBehalf, "0x"],
  });
}

function buildMorphoBorrow(params: MorphoMarketParams, amount: bigint, onBehalf: Address, receiver: Address): Hex {
  return encodeFunctionData({
    abi: morphoAbi,
    functionName: "borrow",
    args: [params, amount, 0n, onBehalf, receiver],
  });
}

export function buildMorphoRepay(params: MorphoMarketParams, amount: bigint, onBehalf: Address): Hex {
  return encodeFunctionData({
    abi: morphoAbi,
    functionName: "repay",
    args: [params, amount, 0n, onBehalf, "0x"],
  });
}

export function buildMorphoWithdrawCollateral(
  params: MorphoMarketParams,
  amount: bigint,
  onBehalf: Address,
  receiver: Address,
): Hex {
  return encodeFunctionData({
    abi: morphoAbi,
    functionName: "withdrawCollateral",
    args: [params, amount, onBehalf, receiver],
  });
}

// ─── Venue adapter ─────────────────────────────────────────────────────────

export class PendleLoopAdapter implements VenueAdapter {
  readonly venueId = V_PENDLE;

  async execute(
    intent: ExecutionIntent,
    creds: VenueCredentials,
    ctx?: VenueExecContext,
    ptIntent?: PtIterationIntent,
  ): Promise<NormalizedExecutionReceipt> {
    if (!creds.arbPrivateKey) {
      console.log("[pt-loop] no x-arb-key");
      return fail(intent);
    }
    if (!ptIntent) {
      console.log("[pt-loop] missing PtIterationIntent wrapper");
      return fail(intent);
    }
    const { targetLeverageBps: leverageBps, hfMinBps, targetChainId, morphoMarketId, isUnwind } = ptIntent;
    const chain = getPtLoopChain(targetChainId);
    const pendleMarket = ptMarketRefToAddress(intent.marketRef);

    const pub = publicClientFor(chain);
    const agent = privateKeyToAccount(creds.arbPrivateKey).address as Address;
    const cloneProxy = await resolveExecutorClone(chain, creds.arbPrivateKey, agent, agent);

    // Controller tells us the direction explicitly via `isUnwind` — no heuristics.
    // OPEN  = enterLoop (initial deposit OR incremental deposit; Morpho supply/borrow add to
    //         any existing position naturally).
    // UNWIND = exitLoop (partial or full close, driven by requestPartialUnwind or auto-unwind).
    if (isUnwind) {
      const pos = await readLivePosition(pub, chain, morphoMarketId, cloneProxy);
      if (pos.collateralPt === 0n || pos.borrowShares === 0n) {
        console.log("[pt-loop] unwind called with no open position; no-op");
        return fail(intent);
      }
      return this._executeShrink(intent, creds, {
        chain, pendleMarket, morphoMarketId, cloneProxy, pos,
        arbKey: creds.arbPrivateKey,
        moduleAddress: (ctx as any)?.moduleAddress as Address | undefined,
        baseSignerKey: creds.baseSignerKey,
      });
    }

    return this._executeOpen(intent, {
      chain, pendleMarket, morphoMarketId, cloneProxy, ctx,
      leverageBps, hfMinBps,
      arbKey: creds.arbPrivateKey,
    });
  }

  /// Open path: CCTP mint → flash-loan USDC → swap to PT → supply → borrow → repay flash.
  private async _executeOpen(
    intent: ExecutionIntent,
    a: {
      chain: PtLoopChainConfig;
      pendleMarket: Address;
      morphoMarketId: Hex;
      cloneProxy: Address;
      ctx: VenueExecContext | undefined;
      leverageBps: number;
      hfMinBps: number;
      arbKey: Hex;
    },
  ): Promise<NormalizedExecutionReceipt> {
    const pub = publicClientFor(a.chain);
    const L = BigInt(a.leverageBps);
    const flashAmt = L > 10_000n ? (intent.targetNotionalUsd * (L - 10_000n)) / 10_000n : 0n;

    let v: PtLiveValidation;
    try {
      v = await validatePtLive(
        pub, a.chain, a.pendleMarket, a.morphoMarketId, a.leverageBps, a.hfMinBps, flashAmt,
      );
    } catch (err) {
      console.log(`[pt-loop] open validation failed: ${String(err).slice(0, 250)}`);
      return fail(intent);
    }

    const { calldata: pendleCall, minOut } = await buildPendleSwapCalldata({
      chainId: a.chain.chainId,
      receiver: a.cloneProxy,
      pendleMarket: a.pendleMarket,
      tokenIn: a.chain.usdc,
      amountIn: intent.targetNotionalUsd,
      slippageBps: intent.maxSlippageBps,
      direction: "toPt",
    });

    const lendingSupplyCalldata = buildMorphoSupplyCollateral(v.params, minOut, a.cloneProxy);
    const lendingBorrowCalldata = buildMorphoBorrow(v.params, flashAmt, a.cloneProxy, a.cloneProxy);

    const baseBurnTxHash = (a.ctx as any)?.baseBurnTxHash as Hex | undefined;
    if (!baseBurnTxHash) {
      console.log("[pt-loop] open: missing baseBurnTxHash in ctx");
      return fail(intent);
    }

    try {
      const r = await settlePtLoopInbound(a.arbKey, {
        targetChainId: a.chain.chainId,
        baseBurnTxHash,
        amount: intent.targetNotionalUsd,
        cloneProxy: a.cloneProxy,
        enter: {
          pendleMarket: a.pendleMarket,
          lendingVenue: a.chain.morpho.blue,
          targetLeverageBps: a.leverageBps,
          minPtOut: minOut,
          pendleRouterCalldata: pendleCall,
          lendingSupplyCalldata,
          lendingBorrowCalldata,
        },
      });
      return {
        cycleId: intent.cycleId,
        venue: this.venueId,
        status: ExecStatus.Filled,
        filledNotionalUsd: (intent.targetNotionalUsd * BigInt(a.leverageBps)) / 10_000n,
        filledBaseQty: minOut,
        avgPriceE18: 0n,
        externalOrderId: r.enterHash,
        externalAccountRef: pad(a.cloneProxy, { size: 32 }) as Hex,
        terminal: true,
        rawPayloadHash: keccak256(toBytes(`pt-enter:${r.enterHash}`)),
      };
    } catch (err) {
      console.log(`[pt-loop] enterLoop failed: ${String(err).slice(0, 300)}`);
      return fail(intent);
    }
  }

  /// Shrink path: drawn when the controller wants to reduce the position to a new target
  /// below the currently-held PT collateral. Full close = target=0. Implemented via the
  /// executor's `exitLoop` flash-sandwich: flash-borrow USDC to repay debt → withdraw PT →
  /// swap PT → USDC → repay flash → forward residual to Base module.
  ///
  /// MVP: only handles full close (target=0 → unwind entire position). Partial-shrink
  /// (reduce-by-r) needs a proportional exit which would require building smaller repay +
  /// withdraw amounts — follow-up.
  private async _executeShrink(
    intent: ExecutionIntent,
    _creds: VenueCredentials,
    a: {
      chain: PtLoopChainConfig;
      pendleMarket: Address;
      morphoMarketId: Hex;
      cloneProxy: Address;
      pos: LivePosition;
      arbKey: Hex;
      moduleAddress: Address | undefined;
      baseSignerKey: Hex | undefined;
    },
  ): Promise<NormalizedExecutionReceipt> {
    const moduleAddress = a.moduleAddress ?? (process.env.MODULE as Address | undefined);
    if (!moduleAddress) {
      console.log("[pt-loop] shrink: missing moduleAddress (need ctx.moduleAddress or MODULE env)");
      return fail(intent);
    }
    if (!a.baseSignerKey) {
      console.log("[pt-loop] shrink: missing baseSignerKey for CCTP burn back to Base");
      return fail(intent);
    }

    // Only full-close MVP. If target > 0 we'd need to compute the proportional repay/withdraw
    // sizes; skipping until the core flow is battle-tested.
    if (intent.targetNotionalUsd > 0n) {
      console.log(`[pt-loop] shrink: partial-shrink target=${intent.targetNotionalUsd} not yet supported`);
      return fail(intent);
    }

    const pub = publicClientFor(a.chain);
    const paramsRaw = (await pub.readContract({
      address: a.chain.morpho.blue, abi: morphoAbi, functionName: "idToMarketParams",
      args: [a.morphoMarketId],
    })) as readonly [Address, Address, Address, Address, bigint];
    const params: MorphoMarketParams = {
      loanToken: paramsRaw[0], collateralToken: paramsRaw[1],
      oracle: paramsRaw[2], irm: paramsRaw[3], lltv: paramsRaw[4],
    };

    // Full repay: pass shares=borrowShares, assets=0 so Morpho uses exact share balance.
    // Here we pass assets explicitly for the flash-loan size (shares path would leave dust).
    const debtUsdc = a.pos.debtUsdc;
    const ptHeld = a.pos.collateralPt;

    // PT → USDC swap via Pendle (full collateral).
    const { calldata: pendleCall, minOut } = await buildPendleSwapCalldata({
      chainId: a.chain.chainId,
      receiver: a.cloneProxy,
      pendleMarket: a.pendleMarket,
      tokenIn: a.chain.usdc,
      amountIn: ptHeld,
      slippageBps: intent.maxSlippageBps > 0 ? intent.maxSlippageBps : 100,
      direction: "fromPt",
    });

    const repayCalldata = buildMorphoRepay(params, debtUsdc, a.cloneProxy);
    const withdrawCalldata = buildMorphoWithdrawCollateral(params, ptHeld, a.cloneProxy, a.cloneProxy);

    try {
      const r = await unwindPtLoopOutbound(a.arbKey, moduleAddress, a.baseSignerKey, {
        targetChainId: a.chain.chainId,
        cloneProxy: a.cloneProxy,
        pendleMarket: a.pendleMarket,
        lendingVenue: a.chain.morpho.blue,
        debtUsdc,
        minUsdcOut: minOut,
        lendingRepayCalldata: repayCalldata,
        lendingWithdrawCalldata: withdrawCalldata,
        pendleRouterCalldata: pendleCall,
      });
      console.log(`[pt-loop] shrink-to-zero ok: exit=${r.exitHash} base=${r.baseReceiveHash}`);
      return {
        cycleId: intent.cycleId,
        venue: this.venueId,
        status: ExecStatus.Filled,
        filledNotionalUsd: minOut > debtUsdc ? minOut - debtUsdc : 0n, // residual returned
        filledBaseQty: 0n,
        avgPriceE18: 0n,
        externalOrderId: r.exitHash,
        externalAccountRef: pad(a.cloneProxy, { size: 32 }) as Hex,
        terminal: true,
        rawPayloadHash: keccak256(toBytes(`pt-exit:${r.exitHash}`)),
      };
    } catch (err) {
      console.log(`[pt-loop] shrink failed: ${String(err).slice(0, 300)}`);
      return fail(intent);
    }
  }

  /// Buffer = native USDC held by the vault's clone proxy pre-enterLoop.
  ///
  /// Self-healing: before returning balance, scan Base CCTP sender events for any stranded
  /// burns to this clone and submit `receiveMessage` on the dest chain. Recovers from inline-
  /// settle failures (stale code, adapter crash, etc.) automatically. Zero cost if no pending.
  /// Requires `BASE_CCTP_SENDER` env for the scan origin.
  async getBuffer(creds: VenueCredentials): Promise<LegBufferSnapshot> {
    if (!creds.arbPrivateKey) return zero();
    try {
      const chain = getPtLoopChain(42161);
      const agent = privateKeyToAccount(creds.arbPrivateKey).address as Address;
      const cloneProxy = await resolveExecutorClone(chain, creds.arbPrivateKey, agent, agent);
      const pub = publicClientFor(chain);

      const cctpSender = process.env.BASE_CCTP_SENDER as Address | undefined;
      if (cctpSender && creds.baseSignerKey) {
        try {
          const base = defineChain({
            id: 8453, name: "Base",
            nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
            rpcUrls: { default: { http: ["https://mainnet.base.org"] } },
          });
          const basePub = createPublicClient({ chain: base, transport: http() });
          const destWallet = createWalletClient({
            chain: chainFor(chain), transport: http(chain.rpcUrl),
            account: privateKeyToAccount(creds.arbPrivateKey),
          });
          const r = await reconcileCctpForDestRef({
            basePub, baseCctpSender: cctpSender,
            destRef: "0xed455b9eef2ae29d317f4124dd21e4eb631b05ccc0d3885f2091c08849c1b2c6" as Hex,
            destPub: pub, destWallet,
            sourceDomain: DOMAIN.BASE,
          });
          if (r.settled > 0 || r.pending > 0) {
            console.log(`[pt-loop] reconcile: scanned=${r.scanned} settled=${r.settled} pending=${r.pending}`);
          }
        } catch (e) {
          console.log(`[pt-loop] reconcile skipped: ${String(e).slice(0, 150)}`);
        }
      }

      const bal = (await pub.readContract({
        address: chain.usdc, abi: erc20BalAbi, functionName: "balanceOf", args: [cloneProxy],
      })) as bigint;
      return { bufferUsd: bal, timestamp: BigInt(Date.now()) };
    } catch {
      return zero();
    }
  }

  /// Mark value is computed by the controller via strategy-specific pathway — valuer pushes the
  /// NAV to Base using `/valuation` output. For PT loops this venue adapter isn't invoked for
  /// mark reads (per-leg `getPositionMarkValue` is a multi-leg controller primitive); returning
  /// 0 here is safe and matches the "controller does mark via valuer" architecture.
  async getPositionMarkValue(_creds: VenueCredentials, _strategyId: Hex): Promise<bigint> {
    return 0n;
  }

  /// Emergency full-unwind path. Reads the clone's live Morpho position (no registry needed —
  /// position is on-chain) and fires `exitLoop` via the flash-sandwich to close everything,
  /// then CCTP-bridges residual USDC back to the Base module. Requires:
  ///   - creds.arbPrivateKey (strategy agent)
  ///   - creds.baseSignerKey (signs CCTP receiveMessage on Base)
  ///   - MODULE env set to BaseStrategyModule address (CCTP mintRecipient)
  ///   - PT_UNWIND_MARKET env — "pendleMarket:morphoMarketId" pair the clone has a position in
  ///     (we don't scan on-chain for all possible markets; operator points at the one).
  async closeAllAndWithdraw(creds: VenueCredentials, _strategyId: Hex): Promise<bigint> {
    if (!creds.arbPrivateKey) return 0n;
    if (!creds.baseSignerKey) {
      console.log("[pt-loop] closeAll: missing baseSignerKey");
      return 0n;
    }
    const moduleAddress = process.env.MODULE as Address | undefined;
    if (!moduleAddress) {
      console.log("[pt-loop] closeAll: missing MODULE env");
      return 0n;
    }
    const unwindMarket = process.env.PT_UNWIND_MARKET;
    if (!unwindMarket || !unwindMarket.includes(":")) {
      console.log("[pt-loop] closeAll: set PT_UNWIND_MARKET=<pendleMarket>:<morphoMarketId>");
      return 0n;
    }
    const [pmRaw, mmIdRaw] = unwindMarket.split(":");
    const pendleMarket = pmRaw as Address;
    const morphoMarketId = mmIdRaw as Hex;

    const chain = getPtLoopChain(42161);
    const pub = publicClientFor(chain);
    const agent = privateKeyToAccount(creds.arbPrivateKey).address as Address;
    const cloneProxy = await resolveExecutorClone(chain, creds.arbPrivateKey, agent, agent);

    const pos = await readLivePosition(pub, chain, morphoMarketId, cloneProxy);
    if (pos.collateralPt === 0n) {
      console.log("[pt-loop] closeAll: no open position");
      return 0n;
    }

    const paramsRaw = (await pub.readContract({
      address: chain.morpho.blue, abi: morphoAbi, functionName: "idToMarketParams", args: [morphoMarketId],
    })) as readonly [Address, Address, Address, Address, bigint];
    const params: MorphoMarketParams = {
      loanToken: paramsRaw[0], collateralToken: paramsRaw[1],
      oracle: paramsRaw[2], irm: paramsRaw[3], lltv: paramsRaw[4],
    };

    const { calldata: pendleCall, minOut } = await buildPendleSwapCalldata({
      chainId: chain.chainId,
      receiver: cloneProxy,
      pendleMarket,
      tokenIn: chain.usdc,
      amountIn: pos.collateralPt,
      slippageBps: 100,
      direction: "fromPt",
    });
    const repayCalldata = buildMorphoRepay(params, pos.debtUsdc, cloneProxy);
    const withdrawCalldata = buildMorphoWithdrawCollateral(params, pos.collateralPt, cloneProxy, cloneProxy);

    try {
      const r = await unwindPtLoopOutbound(creds.arbPrivateKey, moduleAddress, creds.baseSignerKey, {
        targetChainId: chain.chainId,
        cloneProxy,
        pendleMarket,
        lendingVenue: chain.morpho.blue,
        debtUsdc: pos.debtUsdc,
        minUsdcOut: minOut,
        lendingRepayCalldata: repayCalldata,
        lendingWithdrawCalldata: withdrawCalldata,
        pendleRouterCalldata: pendleCall,
      });
      console.log(`[pt-loop] closeAll ok: exit=${r.exitHash} base=${r.baseReceiveHash}`);
      return minOut > pos.debtUsdc ? minOut - pos.debtUsdc : 0n;
    } catch (err) {
      console.log(`[pt-loop] closeAll failed: ${String(err).slice(0, 300)}`);
      return 0n;
    }
  }
}

function zero(): LegBufferSnapshot {
  return { bufferUsd: 0n, timestamp: BigInt(Date.now()) };
}

function fail(intent: ExecutionIntent): NormalizedExecutionReceipt {
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
    rawPayloadHash: keccak256(toBytes("pt-fail")),
  };
}
