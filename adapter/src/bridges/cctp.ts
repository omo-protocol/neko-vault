/// CCTP V2 bridge settlement helper.
///
/// Three responsibilities:
///   1. Poll Circle's attestation API for a given source tx until `status === "complete"`.
///   2. Post `MessageTransmitter.receiveMessage(message, attestation)` on the destination chain.
///   3. Trigger an outbound `TokenMessenger.depositForBurn` from a signer that holds funds on a venue chain
///      (used for unwinds: HL wallet on HyperEVM, PM wallet on Polygon → Base module).
///
/// Circle domain IDs (mainnet): Ethereum=0, Avalanche=1, OP=2, Arbitrum=3, Base=6, Polygon=7, HyperEVM=19.
/// MessageTransmitter V2 and TokenMessenger V2 are at the same address across every EVM chain
/// (deterministic CREATE2).

import {
  parseEventLogs,
  type Hex,
  type Address,
  type WalletClient,
  type PublicClient,
} from "viem";

export const CCTP_V2 = {
  TOKEN_MESSENGER: "0x28b5a0e9C621a5BadaA536219b3a228C8168cf5d" as Address,
  MESSAGE_TRANSMITTER: "0x81D40F21F12A8F0E3252Bccb954D722d4c464B64" as Address,
} as const;

export const DOMAIN = {
  ETHEREUM: 0,
  AVALANCHE: 1,
  OP: 2,
  ARBITRUM: 3,
  BASE: 6,
  POLYGON: 7,
  HYPEREVM: 19,
} as const;

const CIRCLE_ATTESTATION_API = "https://iris-api.circle.com";

// ─── ABIs ──────────────────────────────────────────────────────────────────

const messageTransmitterAbi = [
  {
    name: "receiveMessage",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "message", type: "bytes" },
      { name: "attestation", type: "bytes" },
    ],
    outputs: [{ name: "success", type: "bool" }],
  },
  {
    name: "usedNonces",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "hash", type: "bytes32" }],
    outputs: [{ name: "used", type: "uint256" }],
  },
  {
    name: "MessageSent",
    type: "event",
    inputs: [{ name: "message", type: "bytes", indexed: false }],
  },
] as const;

const tokenMessengerAbi = [
  {
    name: "depositForBurn",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amount", type: "uint256" },
      { name: "destinationDomain", type: "uint32" },
      { name: "mintRecipient", type: "bytes32" },
      { name: "burnToken", type: "address" },
      { name: "destinationCaller", type: "bytes32" },
      { name: "maxFee", type: "uint256" },
      { name: "minFinalityThreshold", type: "uint32" },
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

// ─── Attestation polling ───────────────────────────────────────────────────

export interface CctpAttestation {
  message: Hex;
  attestation: Hex;
}

/// @notice Pulls the message bytes from a Base `MessageSent` log in a given tx receipt.
export async function extractMessageFromBurnTx(
  publicClient: PublicClient,
  burnTxHash: Hex,
): Promise<Hex> {
  const receipt = await publicClient.waitForTransactionReceipt({ hash: burnTxHash });
  const events = parseEventLogs({
    abi: messageTransmitterAbi,
    logs: receipt.logs,
    eventName: "MessageSent",
  });
  if (events.length === 0) throw new Error(`no MessageSent event in tx ${burnTxHash}`);
  return (events[0] as any).args.message as Hex;
}

/// @notice Poll Circle's attestation API until the attestation signature is available.
///         Standard transfers: ~13 min on Ethereum, ~20 min on L2s. Fast transfers: <1 min.
///         Polls indefinitely — a burn on-chain is permanent, so the matching attestation will
///         always eventually publish. Caller decides when to give up (via AbortSignal).
export async function fetchAttestation(
  sourceDomain: number,
  message: Hex,
  opts?: { intervalMs?: number; signal?: AbortSignal },
): Promise<CctpAttestation> {
  const interval = opts?.intervalMs ?? 15_000;
  const signal = opts?.signal;
  const { keccak256 } = await import("viem");
  const messageHash = keccak256(message);
  const url = `${CIRCLE_ATTESTATION_API}/v2/messages/${sourceDomain}?transactionHash=${messageHash}`;
  while (true) {
    if (signal?.aborted) throw new Error(`fetchAttestation aborted for msg ${messageHash}`);
    try {
      const res = await fetch(url);
      if (res.ok) {
        const data: any = await res.json();
        const msgs: any[] = data?.messages ?? [];
        const m = msgs.find((x) => x.message === message);
        if (m && m.status === "complete" && m.attestation && m.attestation !== "PENDING") {
          return { message, attestation: m.attestation as Hex };
        }
      }
    } catch {
      // swallow, retry
    }
    await new Promise((r) => setTimeout(r, interval));
  }
}

// ─── Receive (mint on destination) ──────────────────────────────────────────

/// @notice Post a CCTP attestation on the destination chain. Anyone can call this — permissionless.
///         After success, USDC is minted to the `mintRecipient` that the source burn specified.
export async function receiveCctp(
  walletClient: WalletClient,
  publicClient: PublicClient,
  att: CctpAttestation,
): Promise<Hex> {
  const hash = await walletClient.writeContract({
    account: walletClient.account!,
    chain: walletClient.chain!,
    address: CCTP_V2.MESSAGE_TRANSMITTER,
    abi: messageTransmitterAbi,
    functionName: "receiveMessage",
    args: [att.message, att.attestation],
  });
  await publicClient.waitForTransactionReceipt({ hash });
  return hash;
}

// ─── Outbound burn (for unwind — venue chain → Base) ────────────────────────

export interface BurnParams {
  amount: bigint;
  destinationDomain: number;
  mintRecipient: Address;
  usdc: Address;
  maxFee?: bigint;
  minFinalityThreshold?: number;
}

/// @notice Sign + submit `TokenMessenger.depositForBurn` from an existing wallet client.
///         Used during unwinds: HL/PM wallet burns their USDC on the venue chain, recipient =
///         Base module. Returns the tx hash + extracted message bytes for downstream attestation.
export async function depositForBurn(
  walletClient: WalletClient,
  publicClient: PublicClient,
  p: BurnParams,
): Promise<{ hash: Hex; message: Hex }> {
  // Approve first
  const approveHash = await walletClient.writeContract({
    account: walletClient.account!,
    chain: walletClient.chain!,
    address: p.usdc,
    abi: erc20Abi,
    functionName: "approve",
    args: [CCTP_V2.TOKEN_MESSENGER, p.amount],
  });
  await publicClient.waitForTransactionReceipt({ hash: approveHash });

  const paddedRecipient = `0x${"0".repeat(24)}${p.mintRecipient.slice(2)}` as Hex;
  const burnHash = await walletClient.writeContract({
    account: walletClient.account!,
    chain: walletClient.chain!,
    address: CCTP_V2.TOKEN_MESSENGER,
    abi: tokenMessengerAbi,
    functionName: "depositForBurn",
    args: [
      p.amount,
      p.destinationDomain,
      paddedRecipient,
      p.usdc,
      `0x${"0".repeat(64)}` as Hex,
      // CCTP V2 Fast Transfer defaults: non-zero maxFee + finalityThreshold 1000 → ~60-90s
      // end-to-end vs 13-20min standard. maxFee=50000 = 5¢ (Circle's fast-lane relayers take it).
      p.maxFee ?? 50_000n,
      p.minFinalityThreshold ?? 1000,
    ],
  });
  const message = await extractMessageFromBurnTx(publicClient, burnHash);
  return { hash: burnHash, message };
}
