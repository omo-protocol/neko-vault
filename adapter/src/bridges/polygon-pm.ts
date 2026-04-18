/// Polygon-side PM setup helper.
///
/// After CCTP mints USDC to the PM trading wallet on Polygon, we only need to ensure the wallet
/// has approved the Polymarket CTF Exchange to spend USDC. This is one-time per wallet.

import {
  type Hex,
  type Address,
  type WalletClient,
  type PublicClient,
} from "viem";

export const POLYMARKET = {
  /// Polygon mainnet USDC.e (the Polymarket-accepted variant).
  USDC_E: "0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174" as Address,
  /// Native USDC on Polygon (post-migration). PM may accept either depending on market.
  USDC: "0x3c499c542cEF5E3811e1192ce70d8cC03d5c3359" as Address,
  /// Polymarket CTF Exchange (canonical, binary markets).
  CTF_EXCHANGE: "0x4bFb41d5B3570DeFd03C39a9A4D8dE6Bd8B8982E" as Address,
  /// NegRisk CTF Exchange (multi-outcome markets).
  NEGRISK_CTF_EXCHANGE: "0xC5d563A36AE78145C45a50134d48A1215220f80a" as Address,
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

/// @notice Ensure the PM trading wallet has approved the CTF Exchange to spend USDC. Idempotent.
///         Pass `usdcToken` = POLYMARKET.USDC_E (typical) or POLYMARKET.USDC depending on the market.
export async function ensurePmApproval(
  walletClient: WalletClient,
  publicClient: PublicClient,
  usdcToken: Address,
  exchange: Address,
  minAllowance: bigint,
): Promise<Hex | null> {
  const owner = walletClient.account!.address;
  const current = (await publicClient.readContract({
    address: usdcToken,
    abi: erc20Abi,
    functionName: "allowance",
    args: [owner, exchange],
  })) as bigint;
  if (current >= minAllowance) return null;

  const hash = await walletClient.writeContract({
    account: walletClient.account!,
    chain: walletClient.chain!,
    address: usdcToken,
    abi: erc20Abi,
    functionName: "approve",
    args: [exchange, (1n << 256n) - 1n],
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;
}

/// @notice Wait until USDC balance on `account` reaches `minAmount` (poll-based, used after CCTP
///         receive on Polygon).
export async function waitForPmUsdcBalance(
  publicClient: PublicClient,
  usdcToken: Address,
  account: Address,
  minAmount: bigint,
  timeoutMs = 60_000,
): Promise<bigint> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const bal = (await publicClient.readContract({
      address: usdcToken,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    })) as bigint;
    if (bal >= minAmount) return bal;
    await new Promise((r) => setTimeout(r, 2_000));
  }
  throw new Error(`timeout waiting for USDC balance ≥ ${minAmount} on ${account}`);
}
