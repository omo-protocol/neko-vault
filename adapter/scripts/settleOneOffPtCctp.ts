import "dotenv/config";
import { settlePtLoopCctpOnly } from "../src/bridges/pt-loop.js";
async function main() {
  const r = await settlePtLoopCctpOnly(process.env.PK as `0x${string}`, {
    targetChainId: 42161,
    baseBurnTxHash: process.env.BURN_TX as `0x${string}`,
    amount: BigInt(process.env.AMOUNT!),
  });
  console.log("done", r);
}
main().catch(e => { console.error(e); process.exit(1); });
