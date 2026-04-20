/// Polymarket Bridge API client + Polygon-side PM constants and helpers.
///
/// Two flows:
///   - Deposit: POST /deposit → get EVM deposit address → sender transfers USDC → poll /status.
///     Polymarket handles cross-chain bridge + swap + wrap-to-pUSD internally.
///   - Withdraw: POST /withdraw → get Polygon deposit address → PM EOA transfers pUSD → poll
///     /status. Polymarket handles unwrap + swap + CCTP to the destination chain.
///
/// Status progression (terminal = COMPLETED | FAILED):
///   DEPOSIT_DETECTED → PROCESSING → ORIGIN_TX_CONFIRMED → SUBMITTED → COMPLETED

import type { Address, Hex, PublicClient, WalletClient } from "viem";

const BRIDGE_API = process.env.POLYMARKET_BRIDGE_URL ?? "https://bridge.polymarket.com";

export const POLYMARKET = {
  /// Polygon mainnet native USDC.
  USDC: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359" as Address,
  /// Bridged USDC.e (legacy; not used directly by the Bridge API path).
  USDC_E: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174" as Address,
  /// pUSD — Polymarket's collateral token. ERC-20 wrapper around USDC.e.
  PUSD: "0xC011a7E12a19f7B1f670d46F03B03f3342E82DFB" as Address,
  /// CTF Exchange V2 (binary markets).
  CTF_EXCHANGE: "0xE111180000d2663C0091e4f400237545B87B996B" as Address,
  /// Neg Risk CTF Exchange V2 (multi-outcome markets).
  NEGRISK_CTF_EXCHANGE: "0xe2222d279d744050d28e00520010520000310F59" as Address,
} as const;

const erc20Abi = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "allowance",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

// ─── Bridge API types + HTTP helpers ────────────────────────────────────────

export interface DepositAddresses {
  evm?: Address;
  svm?: string;
  btc?: string;
  tvm?: string;
}

export interface BridgeTxStatus {
  fromChainId: string;
  fromTokenAddress: string;
  fromAmountBaseUnit: string;
  toChainId: string;
  toTokenAddress: string;
  status:
    | "DEPOSIT_DETECTED"
    | "PROCESSING"
    | "ORIGIN_TX_CONFIRMED"
    | "SUBMITTED"
    | "COMPLETED"
    | "FAILED";
  txHash?: Hex;
  createdTimeMs?: number;
}

/// @notice POST /deposit — returns deposit addresses linked to the PM wallet.
///         Funds sent to `evm` from any supported EVM chain are bridged + wrapped to pUSD.
export async function createDepositAddresses(pmWalletAddress: Address): Promise<DepositAddresses> {
  const res = await fetch(`${BRIDGE_API}/deposit`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ address: pmWalletAddress }),
  });
  if (!res.ok) throw new Error(`bridge /deposit failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as DepositAddresses;
}

/// @notice POST /withdraw — returns a Polygon address where the PM wallet sends pUSD to have it
///         bridged + swapped + delivered as `toTokenAddress` on `toChainId` to `recipientAddr`.
///         Addresses are destination-specific — do NOT pre-generate.
export async function createWithdrawAddresses(p: {
  pmWalletAddress: Address;
  toChainId: number;
  toTokenAddress: Address;
  recipientAddr: Address;
}): Promise<DepositAddresses> {
  const res = await fetch(`${BRIDGE_API}/withdraw`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      address: p.pmWalletAddress,
      toChainId: String(p.toChainId),
      toTokenAddress: p.toTokenAddress,
      recipientAddr: p.recipientAddr,
    }),
  });
  if (!res.ok) throw new Error(`bridge /withdraw failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as DepositAddresses;
}

/// @notice Poll /status/{depositAddress} until the latest tx reaches a terminal state.
///         Returns the matching tx once COMPLETED. Throws on FAILED or timeout.
export async function waitForBridgeCompletion(
  depositAddress: string,
  opts?: { intervalMs?: number; timeoutMs?: number; matchFromTxHash?: Hex },
): Promise<BridgeTxStatus> {
  const interval = opts?.intervalMs ?? 10_000;
  const timeout = opts?.timeoutMs ?? 15 * 60_000; // 15 min default — docs quote "a few minutes"
  const started = Date.now();
  while (Date.now() - started < timeout) {
    try {
      const res = await fetch(`${BRIDGE_API}/status/${depositAddress}`);
      if (res.ok) {
        const data = (await res.json()) as { transactions: BridgeTxStatus[] };
        const txs = data.transactions ?? [];
        const match = txs.find((t) => !opts?.matchFromTxHash || t.txHash === opts.matchFromTxHash)
          ?? txs.sort((a, b) => (b.createdTimeMs ?? 0) - (a.createdTimeMs ?? 0))[0];
        if (match) {
          if (match.status === "COMPLETED") return match;
          if (match.status === "FAILED") {
            throw new Error(`bridge transaction failed: ${JSON.stringify(match)}`);
          }
        }
      }
    } catch (err) {
      const msg = (err as Error)?.message ?? String(err);
      if (/bridge transaction failed/.test(msg)) throw err;
    }
    await new Promise((r) => setTimeout(r, interval));
  }
  throw new Error(`waitForBridgeCompletion timed out after ${timeout}ms for ${depositAddress}`);
}

// ─── Polygon-side helpers (approval + balance poll) ─────────────────────────

/// @notice Ensure the PM trading wallet has approved the CTF Exchange to spend its collateral
///         (pUSD). Idempotent; returns null when allowance already covers `minAllowance`.
export async function ensurePmApproval(
  walletClient: WalletClient,
  publicClient: PublicClient,
  collateralToken: Address,
  exchange: Address,
  minAllowance: bigint,
): Promise<Hex | null> {
  const owner = walletClient.account!.address;
  const current = (await publicClient.readContract({
    address: collateralToken,
    abi: erc20Abi,
    functionName: "allowance",
    args: [owner, exchange],
  })) as bigint;
  if (current >= minAllowance) return null;

  const hash = await walletClient.writeContract({
    account: walletClient.account!,
    chain: walletClient.chain!,
    address: collateralToken,
    abi: erc20Abi,
    functionName: "approve",
    args: [exchange, (1n << 256n) - 1n],
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;
}

/// @notice Poll until `token` balance on `account` reaches `minAmount`. Short races close after
///         Bridge API reports COMPLETED but before the destination RPC fully caught up.
export async function waitForBalance(
  publicClient: PublicClient,
  token: Address,
  account: Address,
  minAmount: bigint,
  timeoutMs = 60_000,
): Promise<bigint> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const bal = (await publicClient.readContract({
      address: token,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    })) as bigint;
    if (bal >= minAmount) return bal;
    await new Promise((r) => setTimeout(r, 2_000));
  }
  throw new Error(`timeout waiting for ${token} balance ≥ ${minAmount} on ${account}`);
}
