/// List all currently-valid executors (HTTP_CALL capability) from TEEServiceRegistry.

import { createPublicClient, http, defineChain, type Address, type Hex } from "viem";

const REGISTRY: Address = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F";
const ritualChain = defineChain({
  id: 1979,
  name: "Ritual",
  nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
  rpcUrls: { default: { http: [process.env.RITUAL_RPC_URL ?? "https://rpc.ritualfoundation.org"] } },
});

const abi = [{
  name: "getServicesByCapability",
  type: "function",
  stateMutability: "view",
  inputs: [{ name: "capability", type: "uint8" }, { name: "checkValidity", type: "bool" }],
  outputs: [{
    name: "", type: "tuple[]",
    components: [
      { name: "node", type: "tuple", components: [
        { name: "paymentAddress", type: "address" },
        { name: "teeAddress", type: "address" },
        { name: "teeType", type: "uint8" },
        { name: "publicKey", type: "bytes" },
        { name: "endpoint", type: "string" },
        { name: "certPubKeyHash", type: "bytes32" },
        { name: "capability", type: "uint8" },
      ]},
      { name: "isValid", type: "bool" },
      { name: "workloadId", type: "bytes32" },
    ],
  }],
}] as const;

async function main() {
  const pub = createPublicClient({ chain: ritualChain, transport: http() });
  const services = (await pub.readContract({
    address: REGISTRY,
    abi,
    functionName: "getServicesByCapability",
    args: [0, true],
  })) as any[];
  console.log(`valid HTTP executors: ${services.length}`);
  for (const s of services) {
    console.log(`  teeAddress=${s.node.teeAddress}  endpoint=${s.node.endpoint}  isValid=${s.isValid}  workloadId=${s.workloadId}`);
  }
}
main().catch(e => { console.error(e); process.exit(1); });
