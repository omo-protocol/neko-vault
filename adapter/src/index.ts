import "dotenv/config";
import { readFileSync } from "fs";
import { buildServer } from "./server.js";
import { BaseClient } from "./base-client.js";
import { loadHlMarketsFromApi, type HlMarketRegistry } from "./venues/hyperliquid.js";
import type { PmMarketRegistry } from "./venues/polymarket.js";
import type { Address, Hex } from "viem";

/// Entry point. Env vars:
///   PORT — default 3000
///   BASE_RPC_URL, BASE_CHAIN_ID
///   BASE_SIGNER_KEY — fallback; per-request `x-base-signer-key` is preferred
///   GATEWAY, GATEWAY_NAME, GATEWAY_VERSION
///   VALUER, BASE_ASSET, VAULT
///   HL_MARKETS_PATH — optional JSON path with HlMarketRegistry (marketRef → {assetIndex, szDecimals, tickerSymbol})
///   PM_MARKETS_PATH — optional JSON path with PmMarketRegistry (marketRef → {tokenId, tickSize, minOrderSize})
///   HL_API_URL — override HL REST base (default: mainnet)
///   PM_API_URL — override PM CLOB base (default: clob.polymarket.com)
function req(n: string): string {
  const v = process.env[n];
  if (!v) throw new Error(`missing env ${n}`);
  return v;
}

function loadOptionalRegistry<T>(path: string | undefined): T | undefined {
  if (!path) return undefined;
  try {
    return JSON.parse(readFileSync(path, "utf-8")) as T;
  } catch (err) {
    console.warn(`[adapter] failed to load registry ${path}:`, err);
    return undefined;
  }
}

async function main() {
  const port = parseInt(process.env.PORT ?? "3000", 10);
  const baseClient = new BaseClient(
    req("BASE_RPC_URL"),
    Number(req("BASE_CHAIN_ID")),
    req("BASE_SIGNER_KEY") as Hex
  );

  // Markets: by default, auto-populate HL from the HL /info meta endpoint (no JSON file needed —
  // operator just sets leg.marketRef = keccak256("ETH") / keccak256("BTC") / etc. on the Ritual
  // controller). PM marketRef decodes directly as uint256(tokenId); JSON registry only used as
  // override/pin. Set HL_MARKETS_PATH / PM_MARKETS_PATH only if you want to override.
  let hlMarkets = loadOptionalRegistry<HlMarketRegistry>(process.env.HL_MARKETS_PATH);
  if (!hlMarkets) {
    try {
      hlMarkets = await loadHlMarketsFromApi();
      console.log(`[adapter] auto-loaded ${Object.keys(hlMarkets).length} HL markets from API`);
    } catch (err) {
      console.warn(`[adapter] HL auto-load failed:`, err);
    }
  }
  const pmMarkets = loadOptionalRegistry<PmMarketRegistry>(process.env.PM_MARKETS_PATH);

  const app = buildServer({
    baseClient,
    hlMarkets,
    pmMarkets,
    gateway: req("GATEWAY") as Address,
    gatewayName: process.env.GATEWAY_NAME ?? "NekoBaseGateway",
    gatewayVersion: process.env.GATEWAY_VERSION ?? "1",
    valuer: req("VALUER") as Address,
    baseAsset: req("BASE_ASSET") as Address,
    vault: req("VAULT") as Address,
    module: req("MODULE") as Address,
  });

  await app.listen({ port, host: "0.0.0.0" });
  console.log(`[adapter] listening on :${port}`);
  console.log(`  baseSigner = ${baseClient.signerAddress()}`);
  console.log(`  HL markets loaded: ${hlMarkets ? Object.keys(hlMarkets).length : 0}`);
  console.log(`  PM markets loaded: ${pmMarkets ? Object.keys(pmMarkets).length : 0}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
