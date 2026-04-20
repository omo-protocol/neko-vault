/// PT loop (chain-agnostic) — CCTP bridge + executor-proxy calls.
///
/// The adapter server is a relayer: it signs all execution txs on the target chain from the
/// vault's strategy-agent EOA (TEE-held PK), while the atomic flash-loan logic lives in the
/// per-vault EIP-1167 clone of `PtLoopExecutor`. Chain is chosen by the controller via
/// `PtIterationIntent.targetChainId`; everything below is chain-neutral.
///
/// Inbound flow (TOPUP_PT_BUFFER):
///   Base USDC → CCTP V2 Fast → {targetChain} USDC at cloneProxy → enterLoop(flash sandwich)
///   → position held by cloneProxy in the lending venue.
///
/// Outbound flow (REFILL_RESERVE / unwind):
///   cloneProxy.exitLoop → residual USDC at strategy-agent EOA → CCTP burn → Base module mint.

import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  type Chain,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  DOMAIN,
  extractMessageFromBurnTx,
  fetchAttestation,
  receiveCctp,
  depositForBurn,
} from "./cctp.js";
import { getPtLoopChain, type PtLoopChainConfig } from "../chains/pt-loop-chains.js";

const base = defineChain({
  id: 8453,
  name: "Base",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.base.org"] } },
});

function chainFor(c: PtLoopChainConfig): Chain {
  return defineChain({
    id: c.chainId,
    name: c.name,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [c.rpcUrl] } },
  });
}

function signingClients(c: PtLoopChainConfig, signerKey: Hex): { pub: PublicClient; wallet: WalletClient } {
  const chain = chainFor(c);
  const pub = createPublicClient({ chain, transport: http(c.rpcUrl) });
  const wallet = createWalletClient({
    chain,
    transport: http(c.rpcUrl),
    account: privateKeyToAccount(signerKey),
  });
  return { pub, wallet };
}

// ─── ABIs ──────────────────────────────────────────────────────────────────

const erc20Abi = [
  { name: "balanceOf", type: "function", stateMutability: "view",
    inputs: [{ name: "a", type: "address" }], outputs: [{ name: "", type: "uint256" }] },
] as const;

const factoryAbi = [
  { name: "predictClone", type: "function", stateMutability: "view",
    inputs: [{ name: "owner", type: "address" }, { name: "agent", type: "address" }],
    outputs: [{ name: "", type: "address" }] },
  { name: "cloneFor", type: "function", stateMutability: "nonpayable",
    inputs: [{ name: "owner", type: "address" }, { name: "agent", type: "address" }],
    outputs: [{ name: "", type: "address" }] },
] as const;

const executorAbi = [
  {
    name: "enterLoop",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{
      name: "p",
      type: "tuple",
      components: [
        { name: "pendleMarket", type: "address" },
        { name: "lendingVenue", type: "address" },
        { name: "baseUsdc", type: "uint256" },
        { name: "flashAmt", type: "uint256" },
        { name: "minPtOut", type: "uint256" },
        { name: "leverageBps", type: "uint16" },
        { name: "pendleRouterCalldata", type: "bytes" },
        { name: "lendingSupplyCalldata", type: "bytes" },
        { name: "lendingBorrowCalldata", type: "bytes" },
      ],
    }],
    outputs: [],
  },
  {
    name: "exitLoop",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{
      name: "p",
      type: "tuple",
      components: [
        { name: "pendleMarket", type: "address" },
        { name: "lendingVenue", type: "address" },
        { name: "debtUsdc", type: "uint256" },
        { name: "minUsdcOut", type: "uint256" },
        { name: "recipient", type: "address" },
        { name: "lendingRepayCalldata", type: "bytes" },
        { name: "lendingWithdrawCalldata", type: "bytes" },
        { name: "pendleRouterCalldata", type: "bytes" },
      ],
    }],
    outputs: [],
  },
] as const;

// ─── Proxy resolution ──────────────────────────────────────────────────────

/// Resolve the per-vault clone proxy on `chain`. Predicts the CREATE2 address via the factory;
/// deploys the clone if it doesn't exist yet.
export async function resolveExecutorClone(
  chain: PtLoopChainConfig,
  signerKey: Hex,
  vaultOwner: Address,
  strategyAgent: Address,
): Promise<Address> {
  const { pub, wallet } = signingClients(chain, signerKey);
  const predicted = (await pub.readContract({
    address: chain.ptLoopFactory,
    abi: factoryAbi,
    functionName: "predictClone",
    args: [vaultOwner, strategyAgent],
  })) as Address;
  const code = await pub.getCode({ address: predicted });
  if (!code || code === "0x") {
    const hash = await wallet.writeContract({
      account: wallet.account!,
      chain: wallet.chain!,
      address: chain.ptLoopFactory,
      abi: factoryAbi,
      functionName: "cloneFor",
      args: [vaultOwner, strategyAgent],
    });
    await pub.waitForTransactionReceipt({ hash });
    console.log(`[pt-loop] deployed executor clone ${predicted} on chain ${chain.chainId}`);
  }
  return predicted;
}

// ─── Inbound (CCTP mint + enterLoop) ───────────────────────────────────────

export interface EnterLoopCallParams {
  pendleMarket: Address;
  lendingVenue: Address;         // adapter resolves from chain registry or controller config
  targetLeverageBps: number;
  minPtOut: bigint;
  /// Pre-built Pendle `swapExactTokenForPt` calldata (built off-chain via Pendle SDK).
  pendleRouterCalldata: Hex;
  lendingSupplyCalldata: Hex;
  lendingBorrowCalldata: Hex;
}

/// Minimal CCTP-only settlement — called directly from /base/execute-command right after a
/// successful Base burn. Just receives the mint on the target chain at the executor's
/// predicted clone address. Enter-loop itself still runs later via /pt/execute.
export async function settlePtLoopCctpOnly(
  arbKey: Hex,
  p: { targetChainId: number; baseBurnTxHash: Hex; amount: bigint },
): Promise<{ receiveHash: Hex }> {
  const chain = getPtLoopChain(p.targetChainId);
  const basePub = createPublicClient({ chain: base, transport: http() });
  const { pub, wallet } = signingClients(chain, arbKey);
  const agent = privateKeyToAccount(arbKey).address as Address;
  // Ensure clone deployed so USDC has a destination we can subsequently enter from.
  const cloneProxy = await resolveExecutorClone(chain, arbKey, agent, agent);

  const preBal = (await pub.readContract({
    address: chain.usdc, abi: erc20Abi, functionName: "balanceOf", args: [cloneProxy],
  })) as bigint;
  if (preBal >= p.amount) {
    console.log(`[pt-loop] cctp-only: ${cloneProxy} already has ${preBal}, skip receive`);
    return { receiveHash: ("0x" + "0".repeat(64)) as Hex };
  }
  const message = await extractMessageFromBurnTx(basePub, p.baseBurnTxHash);
  const att = await fetchAttestation(DOMAIN.BASE, message);
  const receiveHash = await receiveCctp(wallet, pub, att);
  console.log(`[pt-loop] cctp-only: minted on chain ${chain.chainId} at ${cloneProxy} (receive=${receiveHash})`);
  return { receiveHash };
}

export async function settlePtLoopInbound(
  arbKey: Hex, // strategy-agent PK; name kept for back-compat with caller
  p: {
    targetChainId: number;
    baseBurnTxHash: Hex;
    amount: bigint;
    cloneProxy: Address;           // already deployed (use resolveExecutorClone if unknown)
    enter: EnterLoopCallParams;
  },
): Promise<{ receiveHash: Hex; enterHash: Hex }> {
  const chain = getPtLoopChain(p.targetChainId);
  const basePub = createPublicClient({ chain: base, transport: http() });
  const { pub, wallet } = signingClients(chain, arbKey);

  // 1. CCTP receive (if not already landed). The route's mintRecipient = cloneProxy, so USDC
  //    lands directly on the clone's balance.
  const preBal = (await pub.readContract({
    address: chain.usdc, abi: erc20Abi, functionName: "balanceOf", args: [p.cloneProxy],
  })) as bigint;

  let receiveHash: Hex = ("0x" + "0".repeat(64)) as Hex;
  if (preBal < p.amount) {
    const message = await extractMessageFromBurnTx(basePub, p.baseBurnTxHash);
    const att = await fetchAttestation(DOMAIN.BASE, message);
    try {
      receiveHash = await receiveCctp(wallet, pub, att);
    } catch (err) {
      const msg = (err as Error)?.message ?? String(err);
      if (!/already used|NonceAlreadyUsed|already processed/i.test(msg)) throw err;
      console.log(`[pt-loop] CCTP receive reverted (nonce used), continuing: ${msg}`);
    }
  }

  // 2. Compute flash amount = base × (L − 1) / 10_000.
  const L = BigInt(p.enter.targetLeverageBps);
  const flashAmt = L > 10_000n ? (p.amount * (L - 10_000n)) / 10_000n : 0n;

  // 3. Call the clone's enterLoop (atomic flash-loan sandwich).
  const enterHash = await wallet.writeContract({
    account: wallet.account!,
    chain: wallet.chain!,
    address: p.cloneProxy,
    abi: executorAbi,
    functionName: "enterLoop",
    args: [{
      pendleMarket: p.enter.pendleMarket,
      lendingVenue: p.enter.lendingVenue,
      baseUsdc: p.amount,
      flashAmt,
      minPtOut: p.enter.minPtOut,
      leverageBps: p.enter.targetLeverageBps,
      pendleRouterCalldata: p.enter.pendleRouterCalldata,
      lendingSupplyCalldata: p.enter.lendingSupplyCalldata,
      lendingBorrowCalldata: p.enter.lendingBorrowCalldata,
    }],
  });
  await pub.waitForTransactionReceipt({ hash: enterHash });
  return { receiveHash, enterHash };
}

// ─── Outbound (exitLoop + CCTP burn back to Base) ──────────────────────────

export async function unwindPtLoopOutbound(
  arbKey: Hex,
  moduleAddress: Address,
  baseSignerKey: Hex,
  p: {
    targetChainId: number;
    cloneProxy: Address;
    pendleMarket: Address;
    lendingVenue: Address;
    debtUsdc: bigint;
    minUsdcOut: bigint;
    lendingRepayCalldata: Hex;
    lendingWithdrawCalldata: Hex;
    pendleRouterCalldata: Hex;
  },
): Promise<{ exitHash: Hex; cctpBurnHash: Hex; baseReceiveHash: Hex }> {
  const chain = getPtLoopChain(p.targetChainId);
  const basePub = createPublicClient({ chain: base, transport: http() });
  const baseWallet = createWalletClient({
    chain: base, transport: http(), account: privateKeyToAccount(baseSignerKey),
  });
  const { pub, wallet } = signingClients(chain, arbKey);

  // 1. exitLoop sends residual USDC to `recipient`. Relay uses the strategy-agent EOA as
  //    recipient so the same wallet then CCTP-burns back to Base.
  const recipient = wallet.account!.address as Address;
  const preBal = (await pub.readContract({
    address: chain.usdc, abi: erc20Abi, functionName: "balanceOf", args: [recipient],
  })) as bigint;

  const exitHash = await wallet.writeContract({
    account: wallet.account!,
    chain: wallet.chain!,
    address: p.cloneProxy,
    abi: executorAbi,
    functionName: "exitLoop",
    args: [{
      pendleMarket: p.pendleMarket,
      lendingVenue: p.lendingVenue,
      debtUsdc: p.debtUsdc,
      minUsdcOut: p.minUsdcOut,
      recipient,
      lendingRepayCalldata: p.lendingRepayCalldata,
      lendingWithdrawCalldata: p.lendingWithdrawCalldata,
      pendleRouterCalldata: p.pendleRouterCalldata,
    }],
  });
  await pub.waitForTransactionReceipt({ hash: exitHash });

  const postBal = (await pub.readContract({
    address: chain.usdc, abi: erc20Abi, functionName: "balanceOf", args: [recipient],
  })) as bigint;
  const realized = postBal > preBal ? postBal - preBal : 0n;
  if (realized === 0n) throw new Error(`unwindPtLoopOutbound: exitLoop returned 0 USDC`);

  // 2. CCTP V2 Fast burn: target chain → Base module.
  const { hash: cctpBurnHash, message } = await depositForBurn(wallet as any, pub, {
    amount: realized,
    destinationDomain: DOMAIN.BASE,
    mintRecipient: moduleAddress,
    usdc: chain.usdc,
    maxFee: 50_000n,
    minFinalityThreshold: 1000,
  });
  const att = await fetchAttestation(chain.cctpDomain, message);
  const baseReceiveHash = await receiveCctp(baseWallet as any, basePub, att);

  return { exitHash, cctpBurnHash, baseReceiveHash };
}
