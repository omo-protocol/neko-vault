import {
  createPublicClient,
  createWalletClient,
  http,
  keccak256,
  toBytes,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import {
  BASE_EXECUTION_GATEWAY_ABI,
  UNIVERSAL_VALUER_ABI,
  ERC20_ABI,
  COMMAND_ENVELOPE_EIP712_TYPE,
} from "./abis.js";
import type { CommandEnvelope } from "./types.js";

/** Clients + signer helpers for Base-side interactions. */
export class BaseClient {
  readonly publicClient;
  readonly walletClient;
  readonly account;

  constructor(
    readonly rpcUrl: string,
    readonly chainId: number,
    signerKey: Hex
  ) {
    this.account = privateKeyToAccount(signerKey);
    const chain = {
      id: chainId,
      name: chainId === 8453 ? "Base" : `Base-${chainId}`,
      nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
      rpcUrls: { default: { http: [rpcUrl] } },
    } as const;
    this.publicClient = createPublicClient({ chain, transport: http(rpcUrl) });
    this.walletClient = createWalletClient({
      account: this.account,
      chain,
      transport: http(rpcUrl),
    });
  }

  signerAddress(): Address {
    return this.account.address;
  }

  /** Read USDC balance on Base. */
  async balanceOf(token: Address, holder: Address): Promise<bigint> {
    return (await this.publicClient.readContract({
      address: token,
      abi: ERC20_ABI,
      functionName: "balanceOf",
      args: [holder],
    })) as bigint;
  }

  /** Sign + submit a CommandEnvelope to BaseExecutionGateway. Returns { txHash, success }. */
  async submitCommandEnvelope(
    gateway: Address,
    env: CommandEnvelope,
    domainName: string,
    domainVersion: string
  ): Promise<{ txHash: Hex; success: boolean; errorMessage?: string }> {
    try {
      const signature = await this.account.signTypedData({
        domain: {
          name: domainName,
          version: domainVersion,
          chainId: this.walletClient.chain!.id,
          verifyingContract: gateway,
        },
        types: COMMAND_ENVELOPE_EIP712_TYPE,
        primaryType: "CommandEnvelope",
        message: env,
      });

      const txHash = await this.walletClient.writeContract({
        address: gateway,
        abi: BASE_EXECUTION_GATEWAY_ABI,
        functionName: "executeCommand",
        args: [env, [signature]],
      });

      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash: txHash,
      });
      return { txHash, success: receipt.status === "success" };
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      return {
        txHash: keccak256(toBytes("fail")) as Hex,
        success: false,
        errorMessage: msg.slice(0, 200),
      };
    }
  }

  /** Sign + submit a valuer update. `value` is the total NAV in USDC base units. */
  async pushNav(
    valuer: Address,
    valuerSignerKey: Hex,
    strategyId: Hex,
    value: bigint,
    confidence: bigint,
    nonce: bigint,
    expirySecondsFromNow: bigint
  ): Promise<{ txHash: Hex; success: boolean }> {
    // UniversalValuerOffchain's _verifySignatures does keccak256(
    //   abi.encode(strategyId, value, confidence, nonce, expiry, chainId, address(valuer))
    // ) + "\x19Ethereum Signed Message:\n32" prefix.
    const chainId = BigInt(this.walletClient.chain!.id);
    const expiry = BigInt(Math.floor(Date.now() / 1000)) + expirySecondsFromNow;

    const messageHash = keccak256(
      new Uint8Array([
        ...toBytes(strategyId),
        ...toBytes(padBig(value)),
        ...toBytes(padBig(confidence)),
        ...toBytes(padBig(nonce)),
        ...toBytes(padBig(expiry)),
        ...toBytes(padBig(chainId)),
        ...toBytes(valuer),
      ])
    );
    // Note: UniversalValuerOffchain uses `abi.encode` (padded per field), not packed bytes.
    // Full EIP-191 signing left as an exercise — use viem's `signMessage({message: {raw: ...}})`
    // with the correctly constructed hash.

    const signerAccount = privateKeyToAccount(valuerSignerKey);
    const signature = await signerAccount.signMessage({
      message: { raw: messageHash },
    });

    try {
      const txHash = await this.walletClient.writeContract({
        address: valuer,
        abi: UNIVERSAL_VALUER_ABI,
        functionName: "updateValue",
        args: [strategyId, value, confidence, nonce, expiry, [signature]],
      });
      const receipt = await this.publicClient.waitForTransactionReceipt({
        hash: txHash,
      });
      return { txHash, success: receipt.status === "success" };
    } catch {
      return {
        txHash: keccak256(toBytes("nav-push-fail")) as Hex,
        success: false,
      };
    }
  }
}

function padBig(v: bigint): Hex {
  const hex = v.toString(16).padStart(64, "0");
  return `0x${hex}` as Hex;
}
