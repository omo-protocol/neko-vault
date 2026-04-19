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

/// @notice PM wallet (Polygon) → Base module. Burns USDC on Polygon, waits for attestation, mints
///         on Base. `moduleAddress` is the BaseStrategyModule that will hold the returned funds.
export async function unwindPmOutbound(
  pmWalletKey: Hex,
  moduleAddress: Address,
  amount: bigint,
): Promise<UnwindResult> {
  const { pub: polyPub, wallet: polyWallet } = clients(polygon, pmWalletKey);
  const { pub: basePub, wallet: baseRelayer } = clients(base);

  const { hash: burnHash, message } = await depositForBurn(polyWallet, polyPub, {
    amount,
    destinationDomain: DOMAIN.BASE,
    mintRecipient: moduleAddress,
    usdc: POLYMARKET.USDC_E,
  });
  const att = await fetchAttestation(DOMAIN.POLYGON, message);
  // Any signer can post the attestation on Base — use the relayer if we have one, else
  // pm wallet can do it directly if it also has Base gas.
  const receiveHash = await receiveCctp(baseRelayer, basePub, att);
  return { burnTxHash: burnHash, baseReceiveTxHash: receiveHash };
}

/// @notice HL → Base unwind, one-step via HyperCore's `sendToEvmWithData` action. Debits
///         HyperCore perp (or spot) balance, routes through HyperEVM, burns via CCTP with
///         automatic forwarding, mints on Base to `moduleAddress`. No separate `withdraw3` +
///         CCTP burn steps required.
export async function unwindHlOutbound(
  hlWalletKey: Hex,
  moduleAddress: Address,
  amount: bigint,
): Promise<UnwindResult> {
  const { sendHyperCoreToEvm } = await import("./hypercore-withdraw.js");
  // amount is micro-USDC (6 decimals); sendToEvmWithData expects a human-readable string.
  const humanAmount = (Number(amount) / 1_000_000).toString();
  await sendHyperCoreToEvm(hlWalletKey, {
    amount: humanAmount,
    destinationRecipient: moduleAddress,
    destinationChainId: DOMAIN.BASE, // CCTP domain 6 = Base
    sourceDex: "", // perp balance (default)
  });
  // Automatic forwarding delivers the mint without us needing to call receiveMessage.
  // Circle's forwarder will mint to moduleAddress on Base once attestation finalizes.
  const zero32: Hex = ("0x" + "0".repeat(64)) as Hex;
  return { burnTxHash: zero32, baseReceiveTxHash: zero32 };
}

export { CCTP_V2, DOMAIN, POLYMARKET, HL };
