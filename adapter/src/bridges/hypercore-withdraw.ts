/// HyperCore → external chain withdrawal helpers.
///
/// Two actions exposed by the Hyperliquid exchange API:
///   - `sendAsset`           — HyperCore → HyperEVM (same address only; USDC token system addr)
///   - `sendToEvmWithData`   — HyperCore → any CCTP-supported EVM chain (Base, Arbitrum, ETH, etc.)
///                              One-step: debits HyperCore → routes through HyperEVM → CCTP burn
///                              → mints on destination. Automatic forwarding if `data="0x"`.
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
