/// Withdraw HL spot USDC → Arbitrum (withdraw3), then CCTP Fast Arb→Base.
/// Env: HL_PK, AMOUNT (decimal), BASE_DEST, BASE_SIGNER_KEY

import { createPublicClient, createWalletClient, http, defineChain, type Hex, type Address } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { base } from "viem/chains";
import { hlWithdrawToArbitrum } from "../src/bridges/hypercore-withdraw.js";
import { depositForBurn, fetchAttestation, receiveCctp, DOMAIN } from "../src/bridges/cctp.js";

const ARB_USDC: Address = "0xaf88d065e77c8cC2239327C5EDb3A432268e5831";
const arb = defineChain({ id: 42161, name: "Arbitrum", nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: ["https://arb1.arbitrum.io/rpc"] } } });

async function main() {
  const hlKey = process.env.HL_PK as Hex;
  const amt = process.env.AMOUNT ?? "28";
  const baseDest = process.env.BASE_DEST as Address;
  const baseKey = process.env.BASE_SIGNER_KEY as Hex;
  if (!hlKey || !baseDest || !baseKey) throw new Error("HL_PK + BASE_DEST + BASE_SIGNER_KEY required");

  const hlAccount = privateKeyToAccount(hlKey);
  const arbPub = createPublicClient({ chain: arb, transport: http() });
  const arbWallet = createWalletClient({ chain: arb, transport: http(), account: hlAccount });
  const balAbi = [{ name: "balanceOf", type: "function", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] }] as const;
  const pre = (await arbPub.readContract({ address: ARB_USDC, abi: balAbi, functionName: "balanceOf", args: [hlAccount.address] })) as bigint;
  console.log(`[recover] pre-Arb: ${Number(pre) / 1e6}; withdraw3 ${amt} USDC HL→Arb…`);
  await hlWithdrawToArbitrum(hlKey, amt);

  const started = Date.now();
  let arrived = 0n;
  while (Date.now() - started < 300_000) {
    const bal = (await arbPub.readContract({ address: ARB_USDC, abi: balAbi, functionName: "balanceOf", args: [hlAccount.address] })) as bigint;
    if (bal > pre) { arrived = bal - pre; console.log(`[recover] landed Arb: +${Number(arrived) / 1e6}`); break; }
    await new Promise((r) => setTimeout(r, 10_000));
  }
  if (arrived === 0n) throw new Error("withdraw3 didn't land on Arb within 5min");

  console.log(`[recover] Arb→Base CCTP Fast burn ${Number(arrived) / 1e6}…`);
  const { hash: burnTxHash, message } = await depositForBurn(arbWallet as any, arbPub as any, {
    amount: arrived, destinationDomain: DOMAIN.BASE, mintRecipient: baseDest, usdc: ARB_USDC,
    maxFee: 50_000n, minFinalityThreshold: 1000,
  });
  console.log(`[recover] burn tx: ${burnTxHash}`);
  const att = await fetchAttestation(DOMAIN.ARBITRUM, message);
  const baseWallet = createWalletClient({ chain: base, transport: http(), account: privateKeyToAccount(baseKey) });
  const basePub = createPublicClient({ chain: base, transport: http() });
  const mintTx = await receiveCctp(baseWallet, basePub, att);
  console.log(`[recover] Base mint: ${mintTx}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
