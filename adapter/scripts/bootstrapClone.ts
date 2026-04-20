/// Bootstrap a freshly-created MultiLegController (or PtLoopController) clone:
///   1. Pick an executor from TEEServiceRegistry (address + ECIES pubkey).
///   2. ECIES-encrypt the plaintext venue secrets (HL PK, PM PK, Base signer PK) to that pubkey.
///   3. Sign each blob hash with the owner EOA.
///   4. clone.setExecutor(executor)
///   5. clone.setSecrets(blobs, sigs)
///   6. clone.setSecretHeaders(keys, placeholders)
///   7. SecretsAccessControl.grantAccess(clone, secretsHash, expiresAt, emptyPolicy)
///
/// After this runs, the TEE can decrypt per-request and substitute into headers.
///
/// Env:
///   RITUAL_RPC_URL      — https://rpc.ritualfoundation.org
///   PRIVATE_KEY         — owner EOA of the clone (also the secrets owner)
///   CLONE               — clone address (MultiLeg or PtLoop)
///   SECRETS_JSON        — JSON blob with venue keys, e.g. {"HL_PK":"0x...","PM_PK":"0x...","BASE_PK":"0x..."}
///   SECRET_HEADER_MAP   — JSON, e.g. {"x-hl-key":"HL_PK","x-pm-key":"PM_PK","x-base-signer-key":"BASE_PK"}
///   EXPIRES_BLOCKS      — grant duration in blocks (default 246_858 ≈ 24h @ 350ms)

import "dotenv/config";
import {
  createPublicClient,
  createWalletClient,
  http,
  defineChain,
  keccak256,
  toBytes,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { ECIES_CONFIG, encrypt } from "eciesjs";

// Ritual requires 12-byte AES-GCM nonce, not the eciesjs default of 16.
ECIES_CONFIG.symmetricNonceLength = 12;

const TEE_SERVICE_REGISTRY: Address = "0x9644e8562cE0Fe12b4deeC4163c064A8862Bf47F";
const SECRETS_ACCESS_CONTROL: Address = "0xf9BF1BC8A3e79B9EBeD0fa2Db70D0513fecE32FD";
const CAPABILITY_HTTP = 0;

const teeRegistryAbi = [
  {
    name: "getServicesByCapability",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "capability", type: "uint8" },
      { name: "checkValidity", type: "bool" },
    ],
    outputs: [
      {
        name: "",
        type: "tuple[]",
        components: [
          {
            name: "node",
            type: "tuple",
            components: [
              { name: "paymentAddress", type: "address" },
              { name: "teeAddress", type: "address" },
              { name: "teeType", type: "uint8" },
              { name: "publicKey", type: "bytes" },
              { name: "endpoint", type: "string" },
              { name: "certPubKeyHash", type: "bytes32" },
              { name: "capability", type: "uint8" },
            ],
          },
          { name: "isValid", type: "bool" },
          { name: "workloadId", type: "bytes32" },
        ],
      },
    ],
  },
] as const;

const secretsAcAbi = [
  {
    name: "grantAccess",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "delegate", type: "address" },
      { name: "secretsHash", type: "bytes32" },
      { name: "expiresAt", type: "uint256" },
      {
        name: "policy",
        type: "tuple",
        components: [
          { name: "allowedDestinations", type: "string[]" },
          { name: "allowedMethods", type: "string[]" },
          { name: "allowedPaths", type: "string[]" },
          { name: "allowedQueryParams", type: "string[]" },
          { name: "allowedHeaders", type: "string[]" },
          { name: "secretLocation", type: "string" },
          { name: "bodyFormat", type: "string" },
        ],
      },
    ],
    outputs: [],
  },
] as const;

const cloneAbi = [
  {
    name: "setIntegrationRefs",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "e", type: "address" },
      { name: "u", type: "string" },
      { name: "f", type: "address" },
      { name: "k", type: "address" },
    ],
    outputs: [],
  },
  {
    name: "setSecrets",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "blobs", type: "bytes[]" },
      { name: "sigs", type: "bytes[]" },
    ],
    outputs: [],
  },
  {
    name: "setSecretHeaders",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "keys", type: "string[]" },
      { name: "values", type: "string[]" },
    ],
    outputs: [],
  },
] as const;

function envOrThrow(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`missing env ${name}`);
  return v;
}

async function main() {
  const rpc = envOrThrow("RITUAL_RPC_URL");
  const privateKey = envOrThrow("PRIVATE_KEY") as Hex;
  const clone = envOrThrow("CLONE") as Address;
  const secretsJson = envOrThrow("SECRETS_JSON");
  const headerMapJson = envOrThrow("SECRET_HEADER_MAP");
  const expiresBlocks = BigInt(process.env.EXPIRES_BLOCKS ?? "246858");

  JSON.parse(secretsJson); // validate JSON
  const headerMap = JSON.parse(headerMapJson) as Record<string, string>;

  const chain = defineChain({
    id: 1979,
    name: "Ritual",
    nativeCurrency: { name: "RITUAL", symbol: "RITUAL", decimals: 18 },
    rpcUrls: { default: { http: [rpc] } },
  });
  const account = privateKeyToAccount(privateKey);
  const publicClient = createPublicClient({ chain, transport: http(rpc) });
  const walletClient = createWalletClient({ account, chain, transport: http(rpc) });

  console.log("[1/6] fetching executors from TEEServiceRegistry…");
  const services = (await publicClient.readContract({
    address: TEE_SERVICE_REGISTRY,
    abi: teeRegistryAbi,
    functionName: "getServicesByCapability",
    args: [CAPABILITY_HTTP, true],
  })) as readonly {
    node: { teeAddress: Address; publicKey: Hex; endpoint: string };
    isValid: boolean;
  }[];
  if (services.length === 0) throw new Error("no active executors in registry");
  // Select: prefer env-override, else load-balance by pinging each endpoint and picking fastest.
  const override = process.env.EXECUTOR_OVERRIDE as Address | undefined;
  let selected: (typeof services)[number] | undefined;
  if (override) {
    selected = services.find((s) => s.node.teeAddress.toLowerCase() === override.toLowerCase());
    if (!selected) throw new Error(`EXECUTOR_OVERRIDE ${override} not in registry`);
    console.log(`       override   → ${selected.node.teeAddress} @ ${selected.node.endpoint}`);
  } else {
    console.log(`       pinging ${services.length} executors to find fastest…`);
    const probes = await Promise.all(services.map(async (s) => {
      const start = Date.now();
      try {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), 3000);
        await fetch(s.node.endpoint, { signal: ctrl.signal }).catch(() => null);
        clearTimeout(t);
        return { s, ms: Date.now() - start };
      } catch { return { s, ms: 9999 }; }
    }));
    probes.sort((a, b) => a.ms - b.ms);
    const top5 = probes.slice(0, 5);
    console.log(`       top 5 by latency:`);
    for (const p of top5) console.log(`         ${p.s.node.teeAddress} ${p.s.node.endpoint}  ${p.ms}ms`);
    selected = top5[0].s;
  }
  const executor = selected.node.teeAddress;
  const executorPublicKey = selected.node.publicKey;
  console.log(`       executor   = ${executor}`);
  console.log(`       pubkey     = ${executorPublicKey.slice(0, 18)}…`);

  console.log("[2/6] ECIES-encrypting secrets blob…");
  const encryptedBuf = encrypt(executorPublicKey.slice(2), Buffer.from(secretsJson));
  const blob = (`0x${encryptedBuf.toString("hex")}`) as Hex;
  const secretsHash = keccak256(toBytes(blob));
  console.log(`       blob       = ${blob.slice(0, 18)}… (${encryptedBuf.length} bytes)`);
  console.log(`       hash       = ${secretsHash}`);

  console.log("[3/6] signing secretsHash with owner EOA…");
  // Per ritual-dapp-secrets skill: EIP-191 personal_sign over the RAW encrypted blob bytes.
  // Executor recovers signer via `keccak256("\x19Ethereum Signed Message:\n" + len + blob)`.
  // Prior code signed the hash directly — recovered wrong address → silent 402 rejection.
  const sig = await walletClient.signMessage({
    account,
    message: { raw: blob },
  });

  console.log("[4/6] clone.setExecutor + clone.setSecrets + clone.setSecretHeaders");
  const headerKeys = Object.keys(headerMap);
  const headerValues = Object.values(headerMap);

  // setExecutor was merged into setIntegrationRefs(executor, url, funder, kellySigner).
  // Pass zero / empty for fields we don't want to change.
  const txSetExec = await walletClient.writeContract({
    address: clone,
    abi: cloneAbi,
    functionName: "setIntegrationRefs",
    args: [executor, "", "0x0000000000000000000000000000000000000000", "0x0000000000000000000000000000000000000000"],
  });
  await publicClient.waitForTransactionReceipt({ hash: txSetExec });
  console.log(`       setIntegrationRefs tx = ${txSetExec}`);

  const txSetSecrets = await walletClient.writeContract({
    address: clone,
    abi: cloneAbi,
    functionName: "setSecrets",
    args: [[blob], [sig]],
  });
  await publicClient.waitForTransactionReceipt({ hash: txSetSecrets });
  console.log(`       setSecrets tx        = ${txSetSecrets}`);

  const txSetHeaders = await walletClient.writeContract({
    address: clone,
    abi: cloneAbi,
    functionName: "setSecretHeaders",
    args: [headerKeys, headerValues],
  });
  await publicClient.waitForTransactionReceipt({ hash: txSetHeaders });
  console.log(`       setSecretHeaders tx  = ${txSetHeaders}`);

  console.log("[5/6] grantAccess on SecretsAccessControl…");
  const currentBlock = await publicClient.getBlockNumber();
  const expiresAt = currentBlock + expiresBlocks;
  const emptyPolicy = {
    allowedDestinations: [],
    allowedMethods: [],
    allowedPaths: [],
    allowedQueryParams: [],
    allowedHeaders: [],
    secretLocation: "",
    bodyFormat: "",
  };

  const txGrant = await walletClient.writeContract({
    address: SECRETS_ACCESS_CONTROL,
    abi: secretsAcAbi,
    functionName: "grantAccess",
    args: [clone, secretsHash, expiresAt, emptyPolicy],
  });
  await publicClient.waitForTransactionReceipt({ hash: txGrant });
  console.log(`       grantAccess tx       = ${txGrant}`);
  console.log(`       expiresAt block      = ${expiresAt}`);

  console.log("[6/6] done.");
  console.log(`       clone                = ${clone}`);
  console.log(`       executor             = ${executor}`);
  console.log(`       secretsHash          = ${secretsHash}`);
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
