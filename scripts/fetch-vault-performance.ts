/**
 * Fetch Options Vault Performance Metrics
 *
 * This script retrieves and calculates performance metrics for an options vault:
 * - Strategy value from UniversalValuerOffchain (via getReport() and ValueUpdated events)
 * - Price per share from VaultV2 (via convertToAssets(1e18))
 * - Annualized yield: (value_change / average_AUM) * (365 / days_in_period) * 100
 *
 * IMPORTANT: Uses realAssets from valuer, not totalAssets() which is capped by maxRate.
 *
 * Usage:
 *   npx ts-node scripts/fetch-vault-performance.ts --period-days 30
 *   npx ts-node scripts/fetch-vault-performance.ts --strategy-id "rysk-options-vault" --period-days 7
 *   npx ts-node scripts/fetch-vault-performance.ts --valuer-only  # Only fetch valuer data
 */

import { keccak256, toUtf8Bytes, formatUnits, Contract, JsonRpcProvider, EventLog } from "ethers";

// ==================== Configuration ====================

interface Config {
  rpcUrl: string;
  chainId: number;
  valuerAddress: string;
  vaultAddress: string;
  escrowAddress: string;
  strategyId: string;
  periodDays: number;
  fromBlock?: number;
  valuerOnly: boolean;
}

// HyperEVM Mainnet defaults from keeper_config_options_vault.json
const DEFAULT_CONFIG: Config = {
  rpcUrl: "https://hyperliquid-mainnet.g.alchemy.com/v2/J7ZwqHgyu3YAGvtCwOVGH",
  chainId: 999,
  valuerAddress: "0x23Da1E622376e6186bB1B16b38910C9155deC8ca",
  vaultAddress: "0xd7bFebcbfA0f703a10054C8ffc9Dc53a389DCF83", // Will be fetched from escrow.parentVault() if available
  escrowAddress: "0xAb6021ffBc44546F22E61E5F03F0F017B0b40182",
  strategyId: "whype-stack-vault",
  periodDays: 30,
  valuerOnly: false,
};

// ==================== ABIs ====================

const VALUER_ABI = [
  "function getReport(bytes32 strategyId) view returns (tuple(uint256 value, uint256 timestamp, uint256 confidence, uint256 nonce, bool isPush, address lastUpdater))",
  "function getValue(bytes32 strategyId) view returns (uint256)",
  "function owner() view returns (address)",
  "function asset() view returns (address)",
  "event ValueUpdated(bytes32 indexed strategyId, uint256 value, uint256 confidence, uint256 timestamp, bool isPush)",
];

const VAULT_ABI = [
  "function totalAssets() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function convertToAssets(uint256 shares) view returns (uint256)",
  "function convertToShares(uint256 assets) view returns (uint256)",
  "function decimals() view returns (uint8)",
  "function name() view returns (string)",
  "function symbol() view returns (string)",
  "function asset() view returns (address)",
  "function maxRate() view returns (uint64)",
];

const ESCROW_ABI = [
  "function realAssets() view returns (uint256)",
  "function parentVault() view returns (address)",
  "function asset() view returns (address)",
  "function valuer() view returns (address)",
  "function getActiveStrategies() view returns (bytes32[])",
  "function getAllocation(bytes32 strategyId) view returns (uint256)",
  "function getCachedValuation() view returns (uint256 value, uint256 timestamp, bool isStale)",
  "function emergencyMode() view returns (bool)",
];

const ERC20_ABI = [
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function balanceOf(address account) view returns (uint256)",
];

// ==================== Types ====================

interface ValueReport {
  value: bigint;
  timestamp: bigint;
  confidence: bigint;
  nonce: bigint;
  isPush: boolean;
  lastUpdater: string;
}

interface ValueHistoryEntry {
  value: string;
  timestamp: number;
  blockNumber: number;
  confidence: number;
  isPush: boolean;
}

interface VaultInfo {
  address: string;
  name: string;
  symbol: string;
  totalAssets: string;
  totalSupply: string;
  pricePerShare: string;
  pricePerShareFormatted: string;
  decimals: number;
  maxRate: string;
}

interface AssetInfo {
  address: string;
  symbol: string;
  decimals: number;
}

interface EscrowInfo {
  address: string;
  realAssets: string | null;
  cachedValuation: string | null;
  cachedTimestamp: number | null;
  isCachedStale: boolean | null;
  emergencyMode: boolean | null;
}

interface StrategyInfo {
  id: string;
  idHex: string;
  currentValue: string;
  lastUpdate: number;
  confidence: number;
  nonce: number;
  lastUpdater: string;
  isPush: boolean;
}

interface EscrowTotalInfo {
  idHex: string;
  currentValue: string;
  lastUpdate: number;
  confidence: number;
  nonce: number;
  lastUpdater: string;
  isPush: boolean;
}

interface PerformanceMetrics {
  periodStartTimestamp: number;
  periodEndTimestamp: number;
  periodDays: number;
  startValue: string;
  endValue: string;
  valueChange: string;
  valueChangePercent: number;
  averageAUM: string;
  annualizedYieldPercent: number;
  eventsCount: number;
}

interface VaultPerformance {
  timestamp: number;
  vault: VaultInfo | null;
  asset: AssetInfo | null;
  escrow: EscrowInfo | null;
  strategy: StrategyInfo;
  escrowTotal: EscrowTotalInfo | null;  // ESCROW_TOTAL is the actual AUM source
  valueHistory: ValueHistoryEntry[];
  performance: PerformanceMetrics | null;
}

// ==================== Helper Functions ====================

function parseArgs(): Partial<Config> {
  const args = process.argv.slice(2);
  const parsed: Partial<Config> = {};

  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    const next = args[i + 1];

    switch (arg) {
      case "--rpc":
      case "--rpc-url":
        parsed.rpcUrl = next;
        i++;
        break;
      case "--valuer":
        parsed.valuerAddress = next;
        i++;
        break;
      case "--vault":
        parsed.vaultAddress = next;
        i++;
        break;
      case "--escrow":
        parsed.escrowAddress = next;
        i++;
        break;
      case "--strategy-id":
        parsed.strategyId = next;
        i++;
        break;
      case "--period-days":
        parsed.periodDays = parseInt(next, 10);
        i++;
        break;
      case "--from-block":
        parsed.fromBlock = parseInt(next, 10);
        i++;
        break;
      case "--valuer-only":
        parsed.valuerOnly = true;
        break;
      case "--help":
      case "-h":
        printHelp();
        process.exit(0);
    }
  }

  return parsed;
}

function printHelp(): void {
  console.log(`
Options Vault Performance Metrics Script

Usage:
  npx ts-node scripts/fetch-vault-performance.ts [options]

Options:
  --rpc <url>           RPC endpoint (default: https://rpc.hyperliquid.xyz/evm)
  --valuer <address>    UniversalValuerOffchain address
  --vault <address>     VaultV2 address (auto-detected from escrow if not provided)
  --escrow <address>    UniversalAdapterEscrow address
  --strategy-id <id>    Strategy identifier (default: "rysk-options-vault")
  --period-days <n>     Performance calculation period in days (default: 30)
  --from-block <n>      Starting block for event query (auto-calculated if not provided)
  --valuer-only         Only fetch valuer data (skip vault/escrow calls)
  --help, -h            Show this help message

Examples:
  npx ts-node scripts/fetch-vault-performance.ts --period-days 30
  npx ts-node scripts/fetch-vault-performance.ts --strategy-id "rysk-options-vault" --period-days 7
  npx ts-node scripts/fetch-vault-performance.ts --valuer-only --period-days 7
  `);
}

function strategyIdToBytes32(strategyId: string): string {
  return keccak256(toUtf8Bytes(strategyId));
}

function escrowTotalIdToBytes32(escrowAddress: string): string {
  // Match Solidity: keccak256(abi.encodePacked("ESCROW_TOTAL", escrow_address))
  // "ESCROW_TOTAL" in hex = 0x455343524f575f544f54414c
  const prefix = "0x455343524f575f544f54414c";
  const addressWithout0x = escrowAddress.toLowerCase().replace("0x", "");
  return keccak256(prefix + addressWithout0x);
}

function calculateTWAP(values: { value: bigint; timestamp: number }[]): bigint {
  if (values.length === 0) return 0n;
  if (values.length === 1) return values[0].value;

  // Sort by timestamp
  const sorted = [...values].sort((a, b) => a.timestamp - b.timestamp);

  let weightedSum = 0n;
  let totalDuration = 0n;

  for (let i = 0; i < sorted.length - 1; i++) {
    const duration = BigInt(sorted[i + 1].timestamp - sorted[i].timestamp);
    weightedSum += sorted[i].value * duration;
    totalDuration += duration;
  }

  // Add the last value's contribution up to now
  const now = Math.floor(Date.now() / 1000);
  const lastDuration = BigInt(now - sorted[sorted.length - 1].timestamp);
  weightedSum += sorted[sorted.length - 1].value * lastDuration;
  totalDuration += lastDuration;

  if (totalDuration === 0n) return sorted[sorted.length - 1].value;

  return weightedSum / totalDuration;
}

async function safeCall<T>(fn: () => Promise<T>, defaultValue: T): Promise<T> {
  try {
    return await fn();
  } catch {
    return defaultValue;
  }
}

// Chunked event fetching to handle RPC block range limits
// Returns events and whether fetching was successful
async function fetchEventsChunked(
  contract: Contract,
  filter: ReturnType<Contract["filters"][string]>,
  fromBlock: number,
  toBlock: number,
  chunkSize: number = 500,
  maxRetries: number = 3
): Promise<Array<EventLog>> {
  const events: Array<EventLog> = [];
  let currentFrom = fromBlock;
  let consecutiveFailures = 0;
  const maxConsecutiveFailures = 10;

  while (currentFrom <= toBlock) {
    const currentTo = Math.min(currentFrom + chunkSize - 1, toBlock);

    let success = false;
    for (let retry = 0; retry < maxRetries && !success; retry++) {
      try {
        const chunk = await contract.queryFilter(filter, currentFrom, currentTo);
        events.push(...(chunk as EventLog[]));
        success = true;
        consecutiveFailures = 0;

        // Progress indicator every 10000 blocks
        if ((currentTo - fromBlock) % 10000 < chunkSize) {
          const progress = ((currentTo - fromBlock) / (toBlock - fromBlock) * 100).toFixed(1);
          console.error(`  Progress: ${progress}% (block ${currentTo})`);
        }
      } catch (e: unknown) {
        const error = e as Error;
        if (error.message?.includes("max block range") && chunkSize > 100) {
          // Reduce chunk size and retry
          chunkSize = Math.floor(chunkSize / 2);
          console.error(`  Reducing chunk size to ${chunkSize}`);
          retry--; // Don't count this as a retry
        } else if (retry < maxRetries - 1) {
          // Wait before retrying
          await new Promise(resolve => setTimeout(resolve, 1000 * (retry + 1)));
        }
      }
    }

    if (!success) {
      consecutiveFailures++;
      if (consecutiveFailures >= maxConsecutiveFailures) {
        console.error(`  Warning: Too many consecutive failures, stopping event fetch at block ${currentFrom}`);
        break;
      }
    }

    currentFrom = currentTo + 1;
  }

  return events;
}

// ==================== Main Logic ====================

async function fetchVaultPerformance(config: Config): Promise<VaultPerformance> {
  const provider = new JsonRpcProvider(config.rpcUrl);
  const valuer = new Contract(config.valuerAddress, VALUER_ABI, provider);

  // Get strategy report from valuer (this is the primary data source)
  const strategyIdHex = strategyIdToBytes32(config.strategyId);
  console.error(`  Strategy ID (bytes32): ${strategyIdHex}`);

  const report: ValueReport = await valuer.getReport(strategyIdHex);

  // Fetch historical ValueUpdated events
  const currentBlock = await provider.getBlockNumber();
  const blocksPerDay = Math.floor(86400 / 2); // Assuming ~2s block time for HyperEVM
  const fromBlock = config.fromBlock ?? Math.max(0, currentBlock - blocksPerDay * config.periodDays);

  // Use ESCROW_TOTAL for performance calculation (actual AUM source)
  const escrowTotalIdHex = config.escrowAddress ? escrowTotalIdToBytes32(config.escrowAddress) : strategyIdHex;
  const performanceIdHex = config.escrowAddress ? escrowTotalIdHex : strategyIdHex;

  console.error(`  Querying ESCROW_TOTAL events from block ${fromBlock} to ${currentBlock}...`);

  const filter = valuer.filters.ValueUpdated(performanceIdHex);
  const events = await fetchEventsChunked(valuer, filter, fromBlock, currentBlock, 1000);

  console.error(`  Found ${events.length} ESCROW_TOTAL ValueUpdated events`);

  // Parse events into value history
  const valueHistory: ValueHistoryEntry[] = [];
  for (const event of events) {
    try {
      const block = await event.getBlock();
      const eventLog = event as EventLog;
      const decoded = valuer.interface.decodeEventLog("ValueUpdated", eventLog.data, eventLog.topics);
      valueHistory.push({
        value: decoded.value.toString(),
        timestamp: block.timestamp,
        blockNumber: event.blockNumber,
        confidence: Number(decoded.confidence),
        isPush: decoded.isPush,
      });
    } catch (e) {
      console.error(`  Warning: Failed to parse event at block ${event.blockNumber}`);
    }
  }

  // Sort by timestamp
  valueHistory.sort((a, b) => a.timestamp - b.timestamp);

  // Strategy info
  const strategy: StrategyInfo = {
    id: config.strategyId,
    idHex: strategyIdHex,
    currentValue: report.value.toString(),
    lastUpdate: Number(report.timestamp),
    confidence: Number(report.confidence),
    nonce: Number(report.nonce),
    lastUpdater: report.lastUpdater,
    isPush: report.isPush,
  };

  // ESCROW_TOTAL info - this is the ACTUAL AUM source used by realAssets()
  let escrowTotalInfo: EscrowTotalInfo | null = null;
  if (config.escrowAddress) {
    const escrowTotalIdHex = escrowTotalIdToBytes32(config.escrowAddress);
    console.error(`  ESCROW_TOTAL ID: ${escrowTotalIdHex}`);
    try {
      const escrowTotalReport: ValueReport = await valuer.getReport(escrowTotalIdHex);
      escrowTotalInfo = {
        idHex: escrowTotalIdHex,
        currentValue: escrowTotalReport.value.toString(),
        lastUpdate: Number(escrowTotalReport.timestamp),
        confidence: Number(escrowTotalReport.confidence),
        nonce: Number(escrowTotalReport.nonce),
        lastUpdater: escrowTotalReport.lastUpdater,
        isPush: escrowTotalReport.isPush,
      };
    } catch (e) {
      console.error(`  Warning: Could not fetch ESCROW_TOTAL report: ${e}`);
    }
  }

  // Initialize result
  let vaultInfo: VaultInfo | null = null;
  let assetInfo: AssetInfo | null = null;
  let escrowInfo: EscrowInfo | null = null;

  // Try to get vault and escrow info if not valuer-only mode
  if (!config.valuerOnly) {
    const escrow = new Contract(config.escrowAddress, ESCROW_ABI, provider);

    // Try to get vault address
    let vaultAddress = config.vaultAddress;
    if (!vaultAddress) {
      vaultAddress = await safeCall(() => escrow.parentVault(), "");
    }

    if (vaultAddress) {
      const vault = new Contract(vaultAddress, VAULT_ABI, provider);

      // Get asset address from vault
      const assetAddress = await safeCall(() => vault.asset(), "");

      if (assetAddress) {
        const asset = new Contract(assetAddress, ERC20_ABI, provider);

        // Fetch vault and asset info
        const [
          vaultName,
          vaultSymbol,
          vaultDecimals,
          totalAssets,
          totalSupply,
          maxRate,
          assetSymbol,
          assetDecimals,
        ] = await Promise.all([
          safeCall(() => vault.name(), ""),
          safeCall(() => vault.symbol(), ""),
          safeCall(() => vault.decimals(), 18n),
          safeCall(() => vault.totalAssets(), 0n),
          safeCall(() => vault.totalSupply(), 0n),
          safeCall(() => vault.maxRate(), 0n),
          safeCall(() => asset.symbol(), "UNKNOWN"),
          safeCall(() => asset.decimals(), 18n),
        ]);

        // Calculate price per share
        const oneShare = 10n ** BigInt(vaultDecimals);
        const pricePerShare = await safeCall(() => vault.convertToAssets(oneShare), oneShare);

        vaultInfo = {
          address: vaultAddress,
          name: vaultName,
          symbol: vaultSymbol,
          totalAssets: totalAssets.toString(),
          totalSupply: totalSupply.toString(),
          pricePerShare: pricePerShare.toString(),
          pricePerShareFormatted: formatUnits(pricePerShare, Number(assetDecimals)),
          decimals: Number(vaultDecimals),
          maxRate: maxRate.toString(),
        };

        assetInfo = {
          address: assetAddress,
          symbol: assetSymbol,
          decimals: Number(assetDecimals),
        };
      }
    }

    // Try to get escrow info
    const [realAssets, cachedValuation, emergencyMode] = await Promise.all([
      safeCall(() => escrow.realAssets(), null),
      safeCall(() => escrow.getCachedValuation(), null),
      safeCall(() => escrow.emergencyMode(), null),
    ]);

    escrowInfo = {
      address: config.escrowAddress,
      realAssets: realAssets?.toString() ?? null,
      cachedValuation: cachedValuation ? cachedValuation[0].toString() : null,
      cachedTimestamp: cachedValuation ? Number(cachedValuation[1]) : null,
      isCachedStale: cachedValuation ? cachedValuation[2] : null,
      emergencyMode: emergencyMode,
    };
  }

  // Calculate performance metrics using ESCROW_TOTAL (actual AUM)
  let performance: PerformanceMetrics | null = null;

  if (valueHistory.length > 0) {
    const periodEndTimestamp = Math.floor(Date.now() / 1000);
    const periodStartTimestamp = periodEndTimestamp - config.periodDays * 86400;

    // Find start value (first value in period or earliest available)
    const startEntry = valueHistory.find((e) => e.timestamp >= periodStartTimestamp) ?? valueHistory[0];
    const startValue = BigInt(startEntry.value);
    // Use ESCROW_TOTAL value for end value (actual AUM source)
    const endValue = escrowTotalInfo ? BigInt(escrowTotalInfo.currentValue) : report.value;

    // Calculate TWAP for average AUM
    const valuesForTWAP = valueHistory
      .filter((e) => e.timestamp >= periodStartTimestamp)
      .map((e) => ({ value: BigInt(e.value), timestamp: e.timestamp }));

    // Add current value for TWAP calculation
    valuesForTWAP.push({ value: endValue, timestamp: periodEndTimestamp });

    const averageAUM = calculateTWAP(valuesForTWAP);

    // Calculate yield
    const valueChange = endValue - startValue;
    const actualPeriodDays =
      (periodEndTimestamp - Math.max(startEntry.timestamp, periodStartTimestamp)) / 86400;

    let annualizedYieldPercent = 0;
    let valueChangePercent = 0;

    if (averageAUM > 0n && actualPeriodDays > 0) {
      // valueChangePercent = (valueChange / startValue) * 100
      if (startValue > 0n) {
        valueChangePercent = Number((valueChange * 10000n) / startValue) / 100;
      }

      // annualizedYield = (valueChange / averageAUM) * (365 / days) * 100
      // Use floating point for final calculation to handle sub-day periods correctly
      const returnRate = Number(valueChange * 10000n / averageAUM) / 10000; // decimal return
      annualizedYieldPercent = (returnRate * 365 / actualPeriodDays) * 100;
    }

    performance = {
      periodStartTimestamp: Math.max(startEntry.timestamp, periodStartTimestamp),
      periodEndTimestamp,
      periodDays: actualPeriodDays,
      startValue: startValue.toString(),
      endValue: endValue.toString(),
      valueChange: valueChange.toString(),
      valueChangePercent,
      averageAUM: averageAUM.toString(),
      annualizedYieldPercent,
      eventsCount: valueHistory.length,
    };
  }

  return {
    timestamp: Math.floor(Date.now() / 1000),
    vault: vaultInfo,
    asset: assetInfo,
    escrow: escrowInfo,
    strategy,
    escrowTotal: escrowTotalInfo,
    valueHistory,
    performance,
  };
}

// ==================== Entry Point ====================

async function main(): Promise<void> {
  const argsConfig = parseArgs();
  const config: Config = { ...DEFAULT_CONFIG, ...argsConfig };

  console.error(`Fetching vault performance metrics...`);
  console.error(`  Strategy: ${config.strategyId}`);
  console.error(`  Period: ${config.periodDays} days`);
  console.error(`  RPC: ${config.rpcUrl}`);
  console.error(`  Valuer: ${config.valuerAddress}`);
  if (!config.valuerOnly) {
    console.error(`  Escrow: ${config.escrowAddress}`);
  }
  console.error("");

  try {
    const result = await fetchVaultPerformance(config);

    // Output JSON to stdout
    console.log(JSON.stringify(result, null, 2));

    // Log summary to stderr
    console.error("");
    console.error("=== Summary ===");

    if (result.vault && result.asset) {
      console.error(`Vault: ${result.vault.name} (${result.vault.symbol})`);
      console.error(`Price per Share: ${result.vault.pricePerShareFormatted} ${result.asset.symbol}`);
      console.error(`Total Assets: ${formatUnits(result.vault.totalAssets, result.asset.decimals)} ${result.asset.symbol}`);
    }

    if (result.escrow?.realAssets) {
      console.error(`Escrow Real Assets: ${formatUnits(result.escrow.realAssets, result.asset?.decimals ?? 18)} ${result.asset?.symbol ?? ""}`);
    }

    console.error("");
    console.error(`Strategy: ${result.strategy.id}`);
    console.error(`  Current Value: ${result.strategy.currentValue} (raw)`);
    if (result.asset) {
      console.error(`  Current Value: ${formatUnits(result.strategy.currentValue, result.asset.decimals)} ${result.asset.symbol}`);
    }
    console.error(`  Last Update: ${new Date(result.strategy.lastUpdate * 1000).toISOString()}`);
    console.error(`  Confidence: ${result.strategy.confidence}%`);
    console.error(`  Nonce: ${result.strategy.nonce}`);
    console.error(`  Last Updater: ${result.strategy.lastUpdater}`);

    // ESCROW_TOTAL is the ACTUAL AUM source used by realAssets()
    if (result.escrowTotal) {
      console.error("");
      console.error(`ESCROW_TOTAL (actual AUM source):`);
      if (result.asset) {
        console.error(`  Current Value: ${formatUnits(result.escrowTotal.currentValue, result.asset.decimals)} ${result.asset.symbol}`);
      } else {
        console.error(`  Current Value: ${result.escrowTotal.currentValue} (raw)`);
      }
      console.error(`  Last Update: ${new Date(result.escrowTotal.lastUpdate * 1000).toISOString()}`);
      console.error(`  Confidence: ${result.escrowTotal.confidence}%`);
      console.error(`  Nonce: ${result.escrowTotal.nonce}`);
      console.error(`  Last Updater: ${result.escrowTotal.lastUpdater}`);

      // Highlight discrepancy between strategy value and ESCROW_TOTAL
      const strategyValue = BigInt(result.strategy.currentValue);
      const escrowTotalValue = BigInt(result.escrowTotal.currentValue);
      if (strategyValue !== escrowTotalValue) {
        const ratio = Number(strategyValue * 100n / escrowTotalValue) / 100;
        console.error("");
        console.error(`  ⚠️  DISCREPANCY: Strategy value (${formatUnits(result.strategy.currentValue, result.asset?.decimals ?? 18)}) != ESCROW_TOTAL (${formatUnits(result.escrowTotal.currentValue, result.asset?.decimals ?? 18)})`);
        console.error(`  ⚠️  Ratio: ${ratio.toFixed(2)}x`);
      }
    }

    if (result.performance) {
      console.error("");
      console.error(`Performance (${result.performance.periodDays.toFixed(1)} days):`);
      console.error(`  Start Value: ${result.performance.startValue} (raw)`);
      console.error(`  End Value: ${result.performance.endValue} (raw)`);
      console.error(`  Value Change: ${result.performance.valueChange} (${result.performance.valueChangePercent.toFixed(2)}%)`);
      console.error(`  Average AUM: ${result.performance.averageAUM} (raw)`);
      console.error(`  Annualized Yield: ${result.performance.annualizedYieldPercent.toFixed(2)}%`);
      console.error(`  Events in Period: ${result.performance.eventsCount}`);
    } else {
      console.error("");
      console.error("No historical data available for performance calculation.");
    }
  } catch (error) {
    console.error("Error fetching vault performance:", error);
    process.exit(1);
  }
}

main();
