/// High-level funding orchestrators used by the adapter server.
///
/// These compose CCTP + venue-specific post-receive steps into one call each:
///   - `settlePmInbound`  (Base burn → Polygon mint + PM approval check)
///   - `settleHlInbound`  (Base burn → HyperEVM mint + HyperCore deposit)
///   - `unwindPmOutbound` (Polygon burn → Base mint)
///   - `unwindHlOutbound` (HyperCore withdraw → HyperEVM burn → Base mint)

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
import { CCTP_V2, DOMAIN, extractMessageFromBurnTx, fetchAttestation, receiveCctp, depositForBurn } from "./cctp.js";
import { HL, forwardToHyperCore, waitForUsdcBalance as waitHlUsdc } from "./hyperevm-forward.js";
import { POLYMARKET, ensurePmApproval, waitForPmUsdcBalance } from "./polygon-pm.js";

const base = defineChain({
  id: 8453,
  name: "Base",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: ["https://mainnet.base.org"] } },
});
const polygon = defineChain({
  id: 137,
  name: "Polygon",
  nativeCurrency: { name: "POL", symbol: "POL", decimals: 18 },
  rpcUrls: { default: { http: ["https://polygon-bor-rpc.publicnode.com"] } },
});
const hyperevm = defineChain({
  id: 999,
  name: "HyperEVM",
  nativeCurrency: { name: "HYPE", symbol: "HYPE", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.hyperliquid.xyz/evm"] } },
});

function clients(chain: Chain, signerKey?: Hex): { pub: PublicClient; wallet: WalletClient } {
  const pub = createPublicClient({ chain, transport: http() });
  const wallet = signerKey
    ? createWalletClient({ chain, transport: http(), account: privateKeyToAccount(signerKey) })
    : (createWalletClient({ chain, transport: http() }) as WalletClient);
  return { pub, wallet };
}

export interface SettleParams {
  /// Base tx hash where BaseCctpSender.bridge was called (emits MessageSent).
  baseBurnTxHash: Hex;
  /// Amount burned (for balance polling after receive).
  amount: bigint;
}

export interface SettlePmResult {
  attestationMessageHash: Hex;
  polygonReceiveTxHash: Hex;
  pmApprovalTxHash: Hex | null;
}

/// @notice After Base burned USDC for PM, wait for attestation, mint on Polygon, and ensure the PM
///         wallet's CTF Exchange allowance covers `minAllowance`.
///         Idempotent: if the mint already landed externally (e.g. prior attempt, manual receive),
///         we skip the receive step and still ensure allowance. Useful when replaying failed
///         settlements from the persistent queue.
export async function settlePmInbound(
  pmWalletKey: Hex,
  p: SettleParams & { minAllowance: bigint; usdcToken?: Address; exchange?: Address },
): Promise<SettlePmResult> {
  const basePub = createPublicClient({ chain: base, transport: http() });
  const { pub: polyPub, wallet: polyWallet } = clients(polygon, pmWalletKey);
  const pmAccount = polyWallet.account!.address as Address;
  const usdc = p.usdcToken ?? POLYMARKET.USDC_E;

  const preBal = (await polyPub.readContract({
    address: usdc,
    abi: [{ name: "balanceOf", type: "function", stateMutability: "view",
      inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] }],
    functionName: "balanceOf",
    args: [pmAccount],
  })) as bigint;

  let receiveHash: Hex = ("0x" + "0".repeat(64)) as Hex;
  let message: Hex = ("0x" + "0".repeat(64)) as Hex;
  if (preBal >= p.amount) {
    // Mint already landed — skip attestation fetch + receive to keep replay idempotent.
    console.log(`[adapter] settlePmInbound: mint already on ${pmAccount} (bal=${preBal}), skipping receive`);
  } else {
    message = await extractMessageFromBurnTx(basePub, p.baseBurnTxHash);
    const att = await fetchAttestation(DOMAIN.BASE, message);
    try {
      receiveHash = await receiveCctp(polyWallet, polyPub, att);
    } catch (err) {
      // If the nonce was already used (externally-receive'd), fall through to balance check.
      const msg = (err as Error)?.message ?? String(err);
      if (!/already used|NonceAlreadyUsed|already processed/i.test(msg)) throw err;
      console.log(`[adapter] settlePmInbound: receive reverted (nonce used), continuing: ${msg}`);
    }
    await waitForPmUsdcBalance(polyPub, usdc, pmAccount, p.amount);
  }

  const approvalHash = await ensurePmApproval(
    polyWallet,
    polyPub,
    p.usdcToken ?? POLYMARKET.USDC_E,
    p.exchange ?? POLYMARKET.CTF_EXCHANGE,
    p.minAllowance,
  );
  return {
    attestationMessageHash: message,
    polygonReceiveTxHash: receiveHash,
    pmApprovalTxHash: approvalHash,
  };
}

export interface SettleHlResult {
  attestationMessageHash: Hex;
  hyperEvmReceiveTxHash: Hex;
  approveHash?: Hex;
  depositHash: Hex;
}

/// @notice After Base burned USDC for HL, wait for attestation, mint on HyperEVM, then
///         `CoreDepositWallet.deposit(amount, 0)` to credit HL wallet's HyperCore perps balance.
///         `amount` must be > 1e6 on first deposit (HL creates account, burns 1 USDC as fee).
export async function settleHlInbound(
  hlWalletKey: Hex,
  p: SettleParams & { destinationDex?: number },
): Promise<SettleHlResult> {
  const basePub = createPublicClient({ chain: base, transport: http() });
  const { pub: hlPub, wallet: hlWallet } = clients(hyperevm, hlWalletKey);
  const hlAccount = hlWallet.account!.address as Address;

  const preBal = (await hlPub.readContract({
    address: HL.USDC,
    abi: [{ name: "balanceOf", type: "function", stateMutability: "view",
      inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] }],
    functionName: "balanceOf",
    args: [hlAccount],
  })) as bigint;

  let receiveHash: Hex = ("0x" + "0".repeat(64)) as Hex;
  let message: Hex = ("0x" + "0".repeat(64)) as Hex;
  if (preBal >= p.amount) {
    console.log(`[adapter] settleHlInbound: mint already on ${hlAccount} (bal=${preBal}), skipping receive`);
  } else {
    message = await extractMessageFromBurnTx(basePub, p.baseBurnTxHash);
    const att = await fetchAttestation(DOMAIN.BASE, message);
    try {
      receiveHash = await receiveCctp(hlWallet, hlPub, att);
    } catch (err) {
      const msg = (err as Error)?.message ?? String(err);
      if (!/already used|NonceAlreadyUsed|already processed/i.test(msg)) throw err;
      console.log(`[adapter] settleHlInbound: receive reverted (nonce used), continuing: ${msg}`);
    }
    await waitHlUsdc(hlPub, hlAccount, p.amount);
  }

  const { approveHash, depositHash } = await forwardToHyperCore(hlWallet, hlPub, {
    amount: p.amount,
    destinationDex: p.destinationDex ?? HL.DEST_PERPS,
  });
  return {
    attestationMessageHash: message,
    hyperEvmReceiveTxHash: receiveHash,
    approveHash,
    depositHash,
  };
}

export interface UnwindResult {
  burnTxHash: Hex;
  baseReceiveTxHash: Hex;
}

/// @notice PM wallet (Polygon) → Base module. Burns USDC on Polygon, waits for attestation, and
///         THE ADAPTER mints on Base. Blocks until the Base mint confirms so the caller knows
///         `moduleAddress` holds the returned USDC before this returns. Fast Transfer by default.
///
/// @param pmWalletKey     PM wallet PK — signs the burn + pays Polygon gas.
/// @param moduleAddress   BaseStrategyModule that will hold returned USDC.
/// @param amount          USDC micro-amount.
/// @param baseSignerKey   Base EOA PK — submits `receiveMessage` on Base.
export async function unwindPmOutbound(
  pmWalletKey: Hex,
  moduleAddress: Address,
  amount: bigint,
  baseSignerKey: Hex,
): Promise<UnwindResult> {
  const { pub: polyPub, wallet: polyWallet } = clients(polygon, pmWalletKey);
  const { pub: basePub, wallet: baseWallet } = clients(base, baseSignerKey);

  const { hash: burnHash, message } = await depositForBurn(polyWallet, polyPub, {
    amount,
    destinationDomain: DOMAIN.BASE,
    mintRecipient: moduleAddress,
    usdc: POLYMARKET.USDC_E,
  });
  const att = await fetchAttestation(DOMAIN.POLYGON, message);
  const receiveHash = await receiveCctp(baseWallet, basePub, att);
  return { burnTxHash: burnHash, baseReceiveTxHash: receiveHash };
}

/// @notice HL → Base unwind via `withdraw3 → Arbitrum → CCTP Fast → Base`. This is more
///         reliable than HL's `sendToEvmWithData` for Base because:
///           - Auto-forwarder is Arbitrum-only (per Circle docs); for Base the HL-side flow
///             falls into a batched queue that can add 30+ min delay — breaks the ~10s HTTP TTL.
///           - Arbitrum Fast Transfers have NO fee per Circle.
///         Total: ~1-2 min — HL→Arb settlement (1min) + Arb→Base Fast CCTP (~60s) + mint (~5s).
///
///         Blocks until the Base mint confirms so the caller knows `moduleAddress` holds the
///         returned USDC before this returns — matches the Base→HL settleHlInbound pattern.
///
/// @param hlWalletKey      HL wallet PK — signs withdraw3 (also the Arbitrum recipient + depositForBurn signer).
/// @param moduleAddress    BaseStrategyModule mintRecipient on Base.
/// @param amount           USDC micro-amount (6 decimals).
/// @param baseSignerKey    Base EOA PK — pays Base gas for receiveMessage.
export async function unwindHlOutbound(
  hlWalletKey: Hex,
  moduleAddress: Address,
  amount: bigint,
  baseSignerKey: Hex,
  _sourceDex: "" | "spot" = "",
): Promise<UnwindResult> {
  const { hlWithdrawToArbitrum } = await import("./hypercore-withdraw.js");
  const humanAmount = (Number(amount) / 1_000_000).toString();

  // 1. withdraw3 HyperCore → Arbitrum (HL native, free, ~1min).
  const hlAccount = privateKeyToAccount(hlWalletKey);
  const arb = defineChain({
    id: 42161,
    name: "Arbitrum",
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [process.env.ARBITRUM_RPC_URL ?? "https://arb1.arbitrum.io/rpc"] } },
  });
  const arbPub = createPublicClient({ chain: arb, transport: http() });
  const arbWallet = createWalletClient({ chain: arb, transport: http(), account: hlAccount });
  const ARB_USDC: Address = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";

  const preArbBal = (await arbPub.readContract({
    address: ARB_USDC,
    abi: [{ name: "balanceOf", type: "function", stateMutability: "view",
      inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] }],
    functionName: "balanceOf",
    args: [hlAccount.address],
  })) as bigint;

  await hlWithdrawToArbitrum(hlWalletKey, humanAmount);

  // 2. Poll Arb until USDC lands (~30-90s, HL's arb settlement). Timeout 3min.
  const targetArbBal = preArbBal + amount - 1_000_000n; // HL takes $1 withdrawal fee
  const started = Date.now();
  while (Date.now() - started < 180_000) {
    const bal = (await arbPub.readContract({
      address: ARB_USDC,
      abi: [{ name: "balanceOf", type: "function", stateMutability: "view",
        inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] }],
      functionName: "balanceOf",
      args: [hlAccount.address],
    })) as bigint;
    if (bal >= targetArbBal) break;
    await new Promise((r) => setTimeout(r, 5_000));
  }
  const arbBal = (await arbPub.readContract({
    address: ARB_USDC,
    abi: [{ name: "balanceOf", type: "function", stateMutability: "view",
      inputs: [{ name: "", type: "address" }], outputs: [{ name: "", type: "uint256" }] }],
    functionName: "balanceOf",
    args: [hlAccount.address],
  })) as bigint;
  const freshlyArrived = arbBal > preArbBal ? arbBal - preArbBal : 0n;
  if (freshlyArrived === 0n) throw new Error(`unwindHlOutbound: withdraw3 didn't land on Arbitrum within 3min`);

  // 3. CCTP Fast burn Arbitrum → Base (maxFee=50k, finality=1000; Arbitrum→Base fast-fee is 0 per Circle).
  const { hash: burnTxHash, message } = await depositForBurn(arbWallet as any, arbPub, {
    amount: freshlyArrived,
    destinationDomain: DOMAIN.BASE,
    mintRecipient: moduleAddress,
    usdc: ARB_USDC,
    maxFee: 50_000n,
    minFinalityThreshold: 1000,
  });
  const att = await fetchAttestation(DOMAIN.ARBITRUM, message);
  const { pub: basePub, wallet: baseWallet } = clients(base, baseSignerKey);
  const baseReceiveTxHash = await receiveCctp(baseWallet, basePub, att);
  return { burnTxHash, baseReceiveTxHash };
}

export { CCTP_V2, DOMAIN, POLYMARKET, HL };
