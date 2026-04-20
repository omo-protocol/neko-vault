/// PT loop chain + lending-venue registry.
///
/// Day-1 scope: Arbitrum + Morpho Blue only. The architecture (Base vault custody + Ritual
/// control-plane + chain-agnostic adapter relayer) is already multi-chain-capable — this file
/// just pins the one execution chain + lender we ship on first. Adding other chains later is
/// a config change here + a deploy of `PtLoopExecutor` + `PtLoopFactory` on that chain.

import type { Address } from "viem";

export interface PtLoopChainConfig {
  chainId: number;
  name: string;
  rpcUrl: string;
  usdc: Address;
  /// Pendle Router V4. Same address `0x888…8946` on every Pendle-supported chain.
  pendleRouter: Address;
  /// Flash-loan provider. Balancer V2 is ubiquitous and fee-free on most chains.
  flashVault: Address;
  /// PtLoopFactory deployed via `script/DeployPtLoopExecutor.s.sol`. Must match chain constants.
  ptLoopFactory: Address;
  /// CCTP source domain for this chain (for outbound burns back to Base).
  cctpDomain: number;
  /// Morpho Blue on this chain. Used for live-state validation:
  ///   - market params (LLTV, oracle, irm) via `idToMarketParams(id)`
  ///   - USDC borrow liquidity via `market(id)`
  morpho: {
    blue: Address;
  };
}

/// Arbitrum One — all constants verified on-chain 2026-04-20.
///
///   USDC (native, CCTP):  0xaf88d065e77c8cC2239327C5EDb3A432268e5831
///   Pendle Router V4:     0x888888888889758F76e7103c6CbF23ABbF58F946 (cross-chain)
///   Balancer V2 Vault:    0xBA12222222228d8Ba445958a75a0704d566BF2C8 (0-fee flash loans)
///   Morpho Blue:          0x6c247b1F6182318877311737BaC0844bAa518F5e
///
/// Factory comes from env `PT_LOOP_FACTORY_ARB` — set after running
/// `script/DeployPtLoopExecutor.s.sol` on Arbitrum. Chain is unregistered until set.
function buildArbConfig(): PtLoopChainConfig | undefined {
  const factory = process.env.PT_LOOP_FACTORY_ARB as Address | undefined;
  if (!factory) return undefined;
  return {
    chainId: 42161,
    name: "Arbitrum",
    rpcUrl: process.env.ARBITRUM_RPC_URL ?? "https://arb1.arbitrum.io/rpc",
    usdc: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831",
    pendleRouter: "0x888888888889758F76e7103c6CbF23ABbF58F946",
    flashVault: "0xBA12222222228d8Ba445958a75a0704d566BF2C8",
    ptLoopFactory: factory,
    cctpDomain: 3,
    morpho: {
      blue: "0x6c247b1F6182318877311737BaC0844bAa518F5e",
    },
  };
}

function buildRegistry(): Record<number, PtLoopChainConfig> {
  const out: Record<number, PtLoopChainConfig> = {};
  const arb = buildArbConfig();
  if (arb) out[42161] = arb;
  return out;
}

export const PT_LOOP_CHAINS: Record<number, PtLoopChainConfig> = buildRegistry();

export function getPtLoopChain(chainId: number): PtLoopChainConfig {
  const c = PT_LOOP_CHAINS[chainId];
  if (!c) {
    throw new Error(
      `PT loop: chain ${chainId} not registered. Deploy executor/factory via ` +
        `script/DeployPtLoopExecutor.s.sol, then set env PT_LOOP_FACTORY_ARB and restart.`,
    );
  }
  return c;
}
