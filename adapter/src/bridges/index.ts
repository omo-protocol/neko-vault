/// High-level funding orchestrators used by the adapter server.
///
/// These compose the minimal venue-specific inbound/outbound steps into one call each:
///   - `settlePmInbound`  (Base USDC.transfer → Polymarket Bridge → pUSD on PM EOA + approval)
///   - `settleHlInbound`  (Base CCTP burn → HyperEVM mint → HyperCore deposit)
///   - `unwindPmOutbound` (pUSD transfer → Polymarket Bridge → USDC on Base module)
///   - `unwindHlOutbound` (HyperCore withdraw → Arbitrum → CCTP → Base)

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
import {
  POLYMARKET,
  ensurePmApproval,
  waitForBalance,
  createDepositAddresses,
  createWithdrawAddresses,
  waitForBridgeCompletion,
} from "./polymarket-bridge.js";

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
  /// Base tx hash (still required for HL CCTP path; unused by PM now).
  baseBurnTxHash: Hex;
  /// Amount in USDC micro-units (6 decimals).
  amount: bigint;
}

/// Base USDC token — src for the Bridge API inbound transfer.
const BASE_USDC: Address = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913";

const erc20BalanceAbi = [{
  name: "balanceOf",
  type: "function",
  stateMutability: "view",
  inputs: [{ name: "account", type: "address" }],
  outputs: [{ name: "", type: "uint256" }],
}] as const;

const erc20TransferAbi = [{
  name: "transfer",
  type: "function",
  stateMutability: "nonpayable",
  inputs: [
    { name: "to", type: "address" },
    { name: "amount", type: "uint256" },
  ],
  outputs: [{ name: "", type: "bool" }],
}] as const;

export interface SettlePmResult {
  bridgeDepositAddress: Address;
  baseTransferTxHash: Hex;
  bridgeTxHash: Hex | null;
  pmApprovalTxHash: Hex | null;
}

/// @notice Inbound Base → PM via Polymarket's Bridge API.
///         1. POST /deposit with the PM EOA to get a one-time EVM deposit address.
///         2. From Base, transfer `amount` USDC to that address (signed by baseSignerKey).
///         3. Poll /status until COMPLETED — Polymarket bridges + wraps to pUSD internally.
///         4. Approve pUSD for CTFExchange V2 so the CLOB can spend it.
///
/// @param pmWalletKey     PM EOA PK — used to derive the PM wallet address and post approval.
/// @param baseSignerKey   Base EOA PK holding USDC — signs the transfer on Base.
/// @param p               amount (micros), minAllowance (pUSD approval floor), optional exchange.
export async function settlePmInbound(
  pmWalletKey: Hex,
  baseSignerKey: Hex,
  p: { amount: bigint; minAllowance: bigint; exchange?: Address },
): Promise<SettlePmResult> {
  const { pub: polyPub, wallet: polyWallet } = clients(polygon, pmWalletKey);
  const { pub: basePub, wallet: baseWallet } = clients(base, baseSignerKey);
  const pmAccount = polyWallet.account!.address as Address;

  // 1. Get a Bridge API deposit address for this PM wallet.
  const addresses = await createDepositAddresses(pmAccount);
  if (!addresses.evm) {
    throw new Error(`bridge /deposit returned no EVM address for ${pmAccount}: ${JSON.stringify(addresses)}`);
  }
  const bridgeAddr = addresses.evm;
  console.log(`[adapter] settlePmInbound: bridge deposit addr=${bridgeAddr} for PM EOA ${pmAccount}`);

  // 2. Transfer `amount` USDC on Base to the bridge address.
  const baseTransferTxHash = await baseWallet.writeContract({
    account: baseWallet.account!,
    chain: baseWallet.chain!,
    address: BASE_USDC,
    abi: erc20TransferAbi,
    functionName: "transfer",
    args: [bridgeAddr, p.amount],
  });
  await basePub.waitForTransactionReceipt({ hash: baseTransferTxHash });
  console.log(`[adapter] settlePmInbound: Base USDC transfer=${baseTransferTxHash}`);

  // 3. Poll /status until Polymarket completes the cross-chain bridge + wrap-to-pUSD.
  const prePusd = (await polyPub.readContract({
    address: POLYMARKET.PUSD,
    abi: erc20BalanceAbi,
    functionName: "balanceOf",
    args: [pmAccount],
  })) as bigint;

  const tx = await waitForBridgeCompletion(bridgeAddr);
  console.log(`[adapter] settlePmInbound: bridge COMPLETED tx=${tx.txHash} (status=${tx.status})`);

  // Safety: confirm pUSD actually landed. Bridge reports COMPLETED before Polygon state is fully
  // queryable on every RPC — a short balance poll closes that race.
  await waitForBalance(polyPub, POLYMARKET.PUSD, pmAccount, prePusd + 1n, 60_000);

  // 4. Approve pUSD for CTFExchange V2.
  const approvalHash = await ensurePmApproval(
    polyWallet,
    polyPub,
    POLYMARKET.PUSD,
    p.exchange ?? POLYMARKET.CTF_EXCHANGE,
    p.minAllowance,
  );

  return {
    bridgeDepositAddress: bridgeAddr,
    baseTransferTxHash,
    bridgeTxHash: tx.txHash ?? null,
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

/// @notice Outbound PM → Base via Polymarket's Bridge API.
///         1. POST /withdraw with (PM EOA, toChainId=Base, toToken=BASE_USDC, recipient=module).
///            Returns a one-time Polygon address to send pUSD to.
///         2. PM EOA transfers `amount` pUSD to that Polygon address.
///         3. Poll /status until COMPLETED — Polymarket unwraps + CCTP-bridges + delivers USDC
///            to the Base module.
///
/// @param pmWalletKey     PM EOA PK — signs pUSD transfer on Polygon.
/// @param moduleAddress   BaseStrategyModule recipient on Base.
/// @param amount          pUSD micro-amount to unwind (6 decimals).
/// @param _baseSignerKey  Unused in Bridge API path; kept for call-site compatibility.
export async function unwindPmOutbound(
  pmWalletKey: Hex,
  moduleAddress: Address,
  amount: bigint,
  _baseSignerKey?: Hex,
): Promise<UnwindResult> {
  const { pub: polyPub, wallet: polyWallet } = clients(polygon, pmWalletKey);
  const pmAccount = polyWallet.account!.address as Address;

  // 1. Request Bridge API withdraw address for (Base, USDC, module).
  const addresses = await createWithdrawAddresses({
    pmWalletAddress: pmAccount,
    toChainId: 8453, // Base
    toTokenAddress: BASE_USDC,
    recipientAddr: moduleAddress,
  });
  if (!addresses.evm) {
    throw new Error(`bridge /withdraw returned no EVM address: ${JSON.stringify(addresses)}`);
  }
  const bridgeAddr = addresses.evm;
  console.log(`[adapter] unwindPmOutbound: bridge withdraw addr=${bridgeAddr} for module ${moduleAddress}`);

  // 2. PM EOA transfers pUSD to the bridge address.
  const burnTxHash = await polyWallet.writeContract({
    account: polyWallet.account!,
    chain: polyWallet.chain!,
    address: POLYMARKET.PUSD,
    abi: erc20TransferAbi,
    functionName: "transfer",
    args: [bridgeAddr, amount],
  });
  await polyPub.waitForTransactionReceipt({ hash: burnTxHash });
  console.log(`[adapter] unwindPmOutbound: pUSD transfer=${burnTxHash}`);

  // 3. Poll /status until COMPLETED — Bridge API handles unwrap + swap + CCTP + Base delivery.
  const tx = await waitForBridgeCompletion(bridgeAddr);
  console.log(`[adapter] unwindPmOutbound: bridge COMPLETED tx=${tx.txHash} (status=${tx.status})`);

  return {
    burnTxHash,
    baseReceiveTxHash: (tx.txHash ?? `0x${"0".repeat(64)}`) as Hex,
  };
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
