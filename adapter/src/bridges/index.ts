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
export async function settlePmInbound(
  pmWalletKey: Hex,
  p: SettleParams & { minAllowance: bigint; usdcToken?: Address; exchange?: Address },
): Promise<SettlePmResult> {
  const basePub = createPublicClient({ chain: base, transport: http() });
  const message = await extractMessageFromBurnTx(basePub, p.baseBurnTxHash);
  const att = await fetchAttestation(DOMAIN.BASE, message);

  const { pub: polyPub, wallet: polyWallet } = clients(polygon, pmWalletKey);
  const pmAccount = polyWallet.account!.address as Address;

  const receiveHash = await receiveCctp(polyWallet, polyPub, att);
  await waitForPmUsdcBalance(polyPub, p.usdcToken ?? POLYMARKET.USDC_E, pmAccount, p.amount);

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
  const message = await extractMessageFromBurnTx(basePub, p.baseBurnTxHash);
  const att = await fetchAttestation(DOMAIN.BASE, message);

  const { pub: hlPub, wallet: hlWallet } = clients(hyperevm, hlWalletKey);
  const hlAccount = hlWallet.account!.address as Address;

  const receiveHash = await receiveCctp(hlWallet, hlPub, att);
  await waitHlUsdc(hlPub, hlAccount, p.amount);

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

/// @notice HL wallet (HyperEVM) → Base module. Assumes funds have already been withdrawn from
///         HyperCore back to the HL wallet's HyperEVM balance (done via HL API `usdClassTransfer`
///         or `withdraw3`). Then burns USDC on HyperEVM → mints on Base.
export async function unwindHlOutbound(
  hlWalletKey: Hex,
  moduleAddress: Address,
  amount: bigint,
): Promise<UnwindResult> {
  const { pub: hlPub, wallet: hlWallet } = clients(hyperevm, hlWalletKey);
  const { pub: basePub, wallet: baseRelayer } = clients(base);

  const { hash: burnHash, message } = await depositForBurn(hlWallet, hlPub, {
    amount,
    destinationDomain: DOMAIN.BASE,
    mintRecipient: moduleAddress,
    usdc: HL.USDC,
  });
  const att = await fetchAttestation(DOMAIN.HYPEREVM, message);
  const receiveHash = await receiveCctp(baseRelayer, basePub, att);
  return { burnTxHash: burnHash, baseReceiveTxHash: receiveHash };
}

export { CCTP_V2, DOMAIN, POLYMARKET, HL };
