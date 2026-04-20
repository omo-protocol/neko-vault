/// HyperCore → external chain withdrawal helpers.
///
/// Three actions exposed by the Hyperliquid exchange API:
///   - `sendAsset`           — HyperCore → HyperEVM (same address only; USDC token system addr)
///   - `withdraw3`           — HyperCore → Arbitrum (HL-native fast path, no CCTP). Lands in ~1min.
///   - `sendToEvmWithData`   — HyperCore → any CCTP-supported EVM chain (Base, Arbitrum, ETH, etc.)
///                              One-step: debits HyperCore → routes through HyperEVM → CCTP burn
///                              → mints on destination. Automatic forwarding is Arbitrum-only;
///                              for Base/others HL's batched outbound queue can add 30+min delay.
///                              Use `withdraw3` + a separate CCTP burn from Arbitrum instead.
///
/// Docs:
///   https://developers.circle.com/cctp/howtos/withdraw-usdc-from-hypercore-to-evm
///   https://developers.circle.com/cctp/howtos/withdraw-usdc-from-hypercore-to-hyperevm

import type { Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

const HL_API_URL = process.env.HL_API_URL ?? "https://api.hyperliquid.xyz";

/// @notice One-step HyperCore → any EVM chain via CCTP. Ideal for our unwind path (HL → Base).
/// @param hlKey           HL wallet PK (same address credited on HyperCore).
/// @param amount          USDC amount as human-readable string (e.g. "10" for 10 USDC).
/// @param destinationRecipient  EOA/contract on destination chain to receive minted USDC.
/// @param destinationChainId    CCTP domain id — 0=ETH, 3=Arbitrum, 6=Base, 7=Polygon, …
/// @param sourceDex       "" for perp balance, "spot" for spot. Default "" (perp).
/// @param signatureChainId Hex EVM chain id of destination for EIP-712 replay protection.
///                          Our unwind target is Base so defaults to 0x2105 (8453).
export async function sendHyperCoreToEvm(
  hlKey: Hex,
  params: {
    amount: string;
    destinationRecipient: `0x${string}`;
    destinationChainId: number;
    sourceDex?: "" | "spot";
    gasLimit?: number;
    signatureChainId?: string; // hex; defaults to Base
  },
): Promise<any> {
  const account = privateKeyToAccount(hlKey);
  const sourceDex = params.sourceDex ?? "";
  const signatureChainId = params.signatureChainId ?? "0x2105"; // Base (8453)
  const chainId = parseInt(signatureChainId, 16);
  const gasLimit = params.gasLimit ?? 200_000;
  const nonce = Date.now();

  const domain = {
    name: "HyperliquidSignTransaction",
    version: "1",
    chainId,
    verifyingContract: "0x0000000000000000000000000000000000000000" as `0x${string}`,
  };

  const types = {
    "HyperliquidTransaction:SendToEvmWithData": [
      { name: "hyperliquidChain", type: "string" },
      { name: "token", type: "string" },
      { name: "amount", type: "string" },
      { name: "sourceDex", type: "string" },
      { name: "destinationRecipient", type: "string" },
      { name: "addressEncoding", type: "string" },
      { name: "destinationChainId", type: "uint32" },
      { name: "gasLimit", type: "uint64" },
      { name: "data", type: "bytes" },
      { name: "nonce", type: "uint64" },
    ],
  } as const;

  const message = {
    hyperliquidChain: "Mainnet" as const,
    token: "USDC",
    amount: params.amount,
    sourceDex,
    destinationRecipient: params.destinationRecipient,
    addressEncoding: "hex",
    destinationChainId: params.destinationChainId,
    gasLimit: BigInt(gasLimit),
    data: "0x" as Hex, // automatic forwarding
    nonce: BigInt(nonce),
  };

  const sigHex = await account.signTypedData({ domain, types, primaryType: "HyperliquidTransaction:SendToEvmWithData", message });
  const r = ("0x" + sigHex.slice(2, 66)) as Hex;
  const s = ("0x" + sigHex.slice(66, 130)) as Hex;
  const v = parseInt(sigHex.slice(130, 132), 16);

  const action = {
    type: "sendToEvmWithData",
    hyperliquidChain: "Mainnet",
    signatureChainId,
    token: "USDC",
    amount: params.amount,
    sourceDex,
    destinationRecipient: params.destinationRecipient,
    addressEncoding: "hex",
    destinationChainId: params.destinationChainId,
    gasLimit,
    data: "0x",
    nonce,
  };

  const res = await fetch(`${HL_API_URL}/exchange`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action, nonce, signature: { r, s, v } }),
  });
  const json = await res.json();
  if (!res.ok || json.status !== "ok") {
    throw new Error(`sendToEvmWithData failed: ${JSON.stringify(json)}`);
  }
  return json;
}

/// @notice HL `withdraw3` action: HyperCore → Arbitrum (native HL bridge, no CCTP).
///         Funds land at `account(hlKey).address` on Arbitrum in ~1min. Returns when HL
///         accepts the action (HL's internal settlement is usually 30-60s after).
export async function hlWithdrawToArbitrum(
  hlKey: Hex,
  amount: string, // human-readable USDC, e.g. "24.5"
): Promise<{ txId: string }> {
  const account = privateKeyToAccount(hlKey);
  const nonce = Date.now();

  const domain = {
    name: "HyperliquidSignTransaction",
    version: "1",
    chainId: 42161, // Arbitrum
    verifyingContract: "0x0000000000000000000000000000000000000000" as `0x${string}`,
  };
  const types = {
    "HyperliquidTransaction:Withdraw": [
      { name: "hyperliquidChain", type: "string" },
      { name: "destination", type: "string" },
      { name: "amount", type: "string" },
      { name: "time", type: "uint64" },
    ],
  } as const;
  const message = {
    hyperliquidChain: "Mainnet" as const,
    destination: account.address.toLowerCase(),
    amount,
    time: BigInt(nonce),
  };
  const sigHex = await account.signTypedData({ domain, types, primaryType: "HyperliquidTransaction:Withdraw", message });
  const r = ("0x" + sigHex.slice(2, 66)) as Hex;
  const s = ("0x" + sigHex.slice(66, 130)) as Hex;
  const v = parseInt(sigHex.slice(130, 132), 16);

  const action = {
    type: "withdraw3",
    hyperliquidChain: "Mainnet",
    signatureChainId: "0xa4b1",
    amount,
    time: nonce,
    destination: account.address.toLowerCase(),
  };
  const res = await fetch(`${HL_API_URL}/exchange`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ action, nonce, signature: { r, s, v } }),
  });
  const json = await res.json();
  if (!res.ok || json.status !== "ok") throw new Error(`withdraw3 failed: ${JSON.stringify(json)}`);
  return { txId: String(json.response?.data?.type ?? "default") };
}
