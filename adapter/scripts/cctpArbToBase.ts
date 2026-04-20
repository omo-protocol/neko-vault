import { createPublicClient, createWalletClient, http, defineChain, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { depositForBurn, fetchAttestation, receiveCctp, DOMAIN } from "../src/bridges/cctp.js";
async function main() {
const pk = process.env.PK as Hex;
const arb = defineChain({ id:42161, name:"Arbitrum", nativeCurrency:{name:"ETH",symbol:"ETH",decimals:18}, rpcUrls:{default:{http:["https://arb1.arbitrum.io/rpc"]}} });
const base = defineChain({ id:8453, name:"Base", nativeCurrency:{name:"ETH",symbol:"ETH",decimals:18}, rpcUrls:{default:{http:["https://mainnet.base.org"]}} });
const arbPub = createPublicClient({ chain:arb, transport:http() });
const basePub = createPublicClient({ chain:base, transport:http() });
const acct = privateKeyToAccount(pk);
const arbW = createWalletClient({ chain:arb, transport:http(), account:acct });
const baseW = createWalletClient({ chain:base, transport:http(), account:acct });
const bal = await arbPub.readContract({ address:"0xaf88d065e77c8cC2239327C5EDb3A432268e5831", abi:[{name:"balanceOf",type:"function",stateMutability:"view",inputs:[{name:"a",type:"address"}],outputs:[{name:"",type:"uint256"}]}] as const, functionName:"balanceOf", args:[acct.address] }) as bigint;
console.log("Arb USDC to burn:", Number(bal)/1e6);
const { hash, message } = await depositForBurn(arbW as any, arbPub, { amount:bal, destinationDomain:DOMAIN.BASE, mintRecipient:"0xb19e2b26b6777929b2E83360fB65cC7341a3418C" as any, usdc:"0xaf88d065e77c8cC2239327C5EDb3A432268e5831", maxFee:50_000n, minFinalityThreshold:1000 });
console.log("burn tx:", hash);
const att = await fetchAttestation(DOMAIN.ARBITRUM, message);
console.log("attestation received");
const rcv = await receiveCctp(baseW as any, basePub, att);
console.log("base mint tx:", rcv);
}
main().catch(e => { console.error(e); process.exit(1); });
