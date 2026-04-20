/// CCTP burn → mint reconciliation. Self-healing layer on top of the inline settlement in
/// `/base/execute-command`. Runs every time a buffer is read on the destination chain.
///
/// Why: the inline path only fires CCTP-receive when the current `executeCommand` simulation
/// succeeds. Any failure (adapter crash mid-flight, network flake, stale-code-at-burn-time,
/// subsequent-cycle-blocked-by-empty-sleeve) strands the burn forever. Circle has the
/// attestation; nobody's pulling it.
///
/// Design: scan the Base CCTP sender's `CctpBridged` events for `destinationRef` matches,
/// then for each event check `MessageTransmitter.usedNonces` on the destination chain — if
/// unused + attestation complete, submit `receiveMessage`. Idempotent; `usedNonces` check is
/// a no-op if already settled.
///
/// Scope is O(events-in-window) per call. With ~30 min window × 1 cycle/min = ~30 events max,
/// most already-settled (fast early-exit on usedNonces). Cheap.

import {
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  parseAbiItem,
  keccak256,
} from "viem";
import { CCTP_V2, extractMessageFromBurnTx, fetchAttestation, receiveCctp } from "./cctp.js";

const messageTransmitterAbi = [
  {
    name: "usedNonces",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "hash", type: "bytes32" }],
    outputs: [{ name: "used", type: "uint256" }],
  },
] as const;

const CCTP_BRIDGED_EVENT = parseAbiItem(
  "event CctpBridged(bytes32 indexed cycleId, bytes32 indexed destinationRef, uint256 amount)"
);

export interface ReconcileParams {
  basePub: PublicClient;
  baseCctpSender: Address;
  destRef: Hex;
  destPub: PublicClient;
  destWallet: WalletClient;
  sourceDomain: number; // DOMAIN.BASE for base-origin burns
  blockWindow?: bigint; // how far back to scan; default 5000 blocks (~3 hours on Base)
}

/// Scan Base CCTP sender events for recent burns to `destRef`, settle any not-yet-received
/// on the destination chain. Safe to call every tick.
export async function reconcileCctpForDestRef(p: ReconcileParams): Promise<{
  scanned: number;
  settled: number;
  pending: number;
}> {
  const window = p.blockWindow ?? 5000n;
  const latest = await p.basePub.getBlockNumber();
  const fromBlock = latest > window ? latest - window : 0n;

  const logs = await p.basePub.getLogs({
    address: p.baseCctpSender,
    fromBlock,
    toBlock: latest,
    event: CCTP_BRIDGED_EVENT,
    args: { destinationRef: p.destRef },
  });

  let settled = 0;
  let pending = 0;
  for (const log of logs) {
    const burnTxHash = log.transactionHash as Hex;
    if (!burnTxHash) continue;
    try {
      const message = await extractMessageFromBurnTx(p.basePub, burnTxHash);
      const messageHash = keccak256(message);
      const used = (await p.destPub.readContract({
        address: CCTP_V2.MESSAGE_TRANSMITTER,
        abi: messageTransmitterAbi,
        functionName: "usedNonces",
        args: [messageHash],
      })) as bigint;
      if (used > 0n) continue; // already settled

      // Try to fetch attestation. If not yet complete, skip silently — next call retries.
      const att = await fetchAttestation(p.sourceDomain, message, {
        intervalMs: 1_000,
        signal: AbortSignal.timeout(3_000), // bounded; don't block buffer reads
      }).catch(() => null);
      if (!att) {
        pending += 1;
        continue;
      }
      await receiveCctp(p.destWallet, p.destPub, att);
      settled += 1;
      console.log(`[cctp-reconcile] settled burn ${burnTxHash} → ${p.destRef}`);
    } catch (err) {
      const msg = (err as Error)?.message ?? String(err);
      if (/already used|NonceAlreadyUsed|already processed/i.test(msg)) continue;
      console.log(`[cctp-reconcile] skip ${burnTxHash}: ${msg.slice(0, 120)}`);
    }
  }
  return { scanned: logs.length, settled, pending };
}
