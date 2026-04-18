/// HyperEVM → HyperCore forwarding helper.
///
/// After CCTP mints USDC to the HL trading wallet on HyperEVM, this module approves + deposits
/// the USDC into Circle's `CoreDepositWallet`, which credits the HL wallet's HyperCore balance
/// (perps by default, spot if destinationDex = 0xFFFFFFFF).
///
/// First deposit to a new HyperCore account burns 1 USDC as an account-creation fee — make sure
/// the amount exceeds 1_000_000 base units on first use.

import {
  type Hex,
  type Address,
  type WalletClient,
  type PublicClient,
} from "viem";

export const HL = {
  /// HyperEVM mainnet CoreDepositWallet — confirm against Circle/HL docs before prod.
  CORE_DEPOSIT_WALLET: "0x0B80659a4076E9E93C7DbE0f10675A16a3e5C206" as Address,
  USDC: "0xb88339CB7199b77E23DB6E890353E22632Ba630f" as Address,
  DEST_PERPS: 0,
  DEST_SPOT: 4294967295,
} as const;

const coreDepositAbi = [
  {
    name: "deposit",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amount", type: "uint256" },
      { name: "destinationDex", type: "uint32" },
    ],
    outputs: [],
  },
  {
    name: "depositFor",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "recipient", type: "address" },
      { name: "amount", type: "uint256" },
      { name: "destinationId", type: "uint32" },
    ],
    outputs: [],
  },
] as const;

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
    name: "balanceOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "account", type: "address" }],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

export interface ForwardParams {
  amount: bigint;
  destinationDex?: number; // default: perps (0)
}

/// @notice Approve + deposit USDC on the HL wallet's behalf. `msg.sender` on HyperEVM must be the
///         wallet client account, and that same address is credited on HyperCore.
///         If the wallet had ≥ `amount` allowance already, skip the approve.
export async function forwardToHyperCore(
  walletClient: WalletClient,
  publicClient: PublicClient,
  p: ForwardParams,
): Promise<{ approveHash?: Hex; depositHash: Hex }> {
  const dex = p.destinationDex ?? HL.DEST_PERPS;

  const approveHash = await walletClient.writeContract({
    account: walletClient.account!,
    chain: walletClient.chain!,
    address: HL.USDC,
    abi: erc20Abi,
    functionName: "approve",
    args: [HL.CORE_DEPOSIT_WALLET, p.amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const depositHash = await walletClient.writeContract({
    account: walletClient.account!,
    chain: walletClient.chain!,
    address: HL.CORE_DEPOSIT_WALLET,
    abi: coreDepositAbi,
    functionName: "deposit",
    args: [p.amount, dex],
  });
  await publicClient.waitForTransactionReceipt({ hash: depositHash });
  return { approveHash, depositHash };
}

/// @notice Wait for USDC balance on this wallet to reach `minAmount` (used after CCTP receive).
export async function waitForUsdcBalance(
  publicClient: PublicClient,
  account: Address,
  minAmount: bigint,
  timeoutMs = 60_000,
): Promise<bigint> {
  const started = Date.now();
  while (Date.now() - started < timeoutMs) {
    const bal = (await publicClient.readContract({
      address: HL.USDC,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account],
    })) as bigint;
    if (bal >= minAmount) return bal;
    await new Promise((r) => setTimeout(r, 2_000));
  }
  throw new Error(`timeout waiting for USDC balance ≥ ${minAmount} on ${account}`);
}
