/// One-shot HL withdraw3 helper. Issues a signed withdraw to send USDC from HL Core spot to the
/// signer's address on Arbitrum.
///
/// Env:
///   HL_PK     — the HL trading wallet PK (hex, with 0x)
///   HL_AMOUNT — USDC amount as a decimal string, e.g. "19"

import { privateKeyToAccount } from "viem/accounts";
import { keccak256, concat, toBytes, pad, toHex, type Hex, type Address } from "viem";
import { encode as msgpackEncode } from "@msgpack/msgpack";

const HL_API = "https://api.hyperliquid.xyz";

function hashAction(action: unknown, nonce: number, vault?: Address): Hex {
  const actionBytes = msgpackEncode(action);
  const nonceBytes = toBytes(pad(toHex(BigInt(nonce)), { size: 8 }));
  const vaultBytes = vault
    ? concat([toBytes("0x01"), toBytes(vault)])
    : toBytes("0x00");
  return keccak256(concat([new Uint8Array(actionBytes), nonceBytes, vaultBytes]));
}

async function main() {
  const pk = process.env.HL_PK as Hex;
  if (!pk || !pk.startsWith("0x")) throw new Error("HL_PK missing");
  const amount = process.env.HL_AMOUNT ?? "19";

  const account = privateKeyToAccount(pk);
  console.log(`[hlWithdraw] signer: ${account.address}, amount: ${amount} USDC`);

  const nonce = Date.now();
  const action = {
    type: "withdraw3",
    hyperliquidChain: "Mainnet",
    signatureChainId: "0xa4b1",
    amount,
    time: nonce,
    destination: account.address.toLowerCase(),
  };

  // HL withdraw3 uses EIP-712 typed-data signing (per HL API docs)
  const domain = {
    name: "HyperliquidSignTransaction",
    version: "1",
    chainId: 42161, // Arbitrum
    verifyingContract: "0x0000000000000000000000000000000000000000" as Address,
  };
  const types = {
    "HyperliquidTransaction:Withdraw": [
      { name: "hyperliquidChain", type: "string" },
      { name: "destination", type: "string" },
      { name: "amount", type: "string" },
      { name: "time", type: "uint64" },
    ],
  };
  const message = {
    hyperliquidChain: "Mainnet",
    destination: action.destination,
    amount: action.amount,
    time: BigInt(nonce),
  };

  const sig = await account.signTypedData({
    domain,
    types,
    primaryType: "HyperliquidTransaction:Withdraw",
    message,
  });
  const r = sig.slice(0, 66);
  const s = ("0x" + sig.slice(66, 130)) as Hex;
  const v = parseInt(sig.slice(130, 132), 16);

  const body = JSON.stringify({
    action,
    nonce,
    signature: { r, s, v },
  });
  console.log(`[hlWithdraw] POST ${HL_API}/exchange`);
  const res = await fetch(`${HL_API}/exchange`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body,
  });
  const result = await res.text();
  console.log(`[hlWithdraw] HTTP ${res.status}: ${result}`);
  if (!res.ok) process.exit(1);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
