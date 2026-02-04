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
  mpcWalletAddress?: string;  // MPC wallet holding external assets
  usdt0Address?: string;      // USDT0 token address for premium tracking
  isOptionsVault: boolean;    // True for monthly options strategies (shows monthly return)
  originalDeposit?: string;   // Manual override for original deposit amount (in wei)
  vaultAgeDays?: number;      // Actual vault age in days (for accurate APR/APY calculation)
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
  mpcWalletAddress: "0x2F10b3FF99F507f438A0e338A8dE31af1E0cdCd7",  // MPC wallet holding WHYPE
  usdt0Address: "0x94e8396e0869C9F2200760aB075A3e6A48E4F050",      // USDT0 token for premium tracking
  isOptionsVault: true,  // Monthly options strategy from Rysk Finance
  originalDeposit: "184233000000000000000",  // 184.233 WHYPE (from Allocate events)
  vaultAgeDays: 30,  // Vault has been running for ~30 days (1 month)
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
  "event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares)",
  "event Withdraw(address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares)",
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

interface MPCWalletInfo {
  address: string;
  whypeBalance: string;
  usdt0Balance: string;
  usdt0AsWhype: string;  // Converted at estimated rate
}

interface DepositWithdrawSummary {
  totalDeposits: string;
  totalWithdrawals: string;
  netDeposits: string;
  depositCount: number;
  withdrawalCount: number;
  firstDepositTimestamp: number | null;
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
  // Deposit-based metrics
  originalDeposit: string;         // Total net deposits
  currentAUM: string;              // Current total AUM
  totalReturnPercent: number;      // (currentAUM - deposit) / deposit * 100
  totalReturnAmount: string;       // currentAUM - deposit
  isAnnualizedReliable: boolean;   // true if period > 7 days
  // Options vault metrics (monthly strategy)
  isOptionsVault: boolean;         // true for monthly options strategies
  monthlyReturnPercent: number;    // Return normalized to 30-day period
  apr: number;                     // Annual Percentage Rate (simple)
  apy: number;                     // Annual Percentage Yield (compounded monthly)
}

interface VaultPerformance {
  timestamp: number;
  vault: VaultInfo | null;
  asset: AssetInfo | null;
  escrow: EscrowInfo | null;
  strategy: StrategyInfo;
  escrowTotal: EscrowTotalInfo | null;  // ESCROW_TOTAL is the actual AUM source
  mpcWallet: MPCWalletInfo | null;      // MPC wallet holdings
  depositSummary: DepositWithdrawSummary | null;  // Deposit/withdrawal history
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
      case "--mpc-wallet":
        parsed.mpcWalletAddress = next;
        i++;
        break;
      case "--usdt0":
        parsed.usdt0Address = next;
        i++;
        break;
      case "--options-vault":
        parsed.isOptionsVault = true;
        break;
      case "--no-options-vault":
        parsed.isOptionsVault = false;
        break;
      case "--original-deposit":
        parsed.originalDeposit = next;
        i++;
        break;
      case "--vault-age":
        parsed.vaultAgeDays = parseFloat(next);
        i++;
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
  --strategy-id <id>    Strategy identifier (default: "whype-stack-vault")
  --period-days <n>     Performance calculation period in days (default: 30)
  --from-block <n>      Starting block for event query (auto-calculated if not provided)
  --valuer-only         Only fetch valuer data (skip vault/escrow calls)
  --mpc-wallet <addr>   MPC wallet address holding external assets
  --usdt0 <address>     USDT0 token address for premium tracking
  --options-vault       Treat as monthly options vault (shows monthly return, APR, APY)
  --no-options-vault    Disable options vault mode
  --original-deposit <wei>  Override original deposit amount (in wei)
  --vault-age <days>    Actual vault age in days (for accurate APR/APY)
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

// Fetch MPC wallet holdings
async function fetchMPCWalletInfo(
  provider: JsonRpcProvider,
  mpcWalletAddress: string,
  whypeAddress: string,
  usdt0Address: string | undefined,
  _whypeDecimals: number  // Reserved for future use
): Promise<MPCWalletInfo> {
  const whype = new Contract(whypeAddress, ERC20_ABI, provider);
  const whypeBalance = await safeCall(() => whype.balanceOf(mpcWalletAddress), 0n);

  let usdt0Balance = 0n;
  let usdt0AsWhype = "0";

  if (usdt0Address) {
    const usdt0 = new Contract(usdt0Address, ERC20_ABI, provider);
    usdt0Balance = await safeCall(() => usdt0.balanceOf(mpcWalletAddress), 0n);

    // USDT0 has 6 decimals, WHYPE has 18 decimals
    // Assume ~33.3 USDT0 per WHYPE (based on user feedback: 1375 USDT0 ≈ 41.3 WHYPE)
    // This is an approximation - in production, use an oracle
    const USDT0_PER_WHYPE = 33.3;
    const usdt0Value = Number(formatUnits(usdt0Balance, 6));
    const whypeEquivalent = usdt0Value / USDT0_PER_WHYPE;
    // Convert to 18 decimals
    usdt0AsWhype = (BigInt(Math.floor(whypeEquivalent * 1e18))).toString();
  }

  return {
    address: mpcWalletAddress,
    whypeBalance: whypeBalance.toString(),
    usdt0Balance: usdt0Balance.toString(),
    usdt0AsWhype,
  };
}

// Fetch deposit/withdrawal history from vault events
async function fetchDepositWithdrawSummary(
  vault: Contract,
  fromBlock: number,
  toBlock: number
): Promise<DepositWithdrawSummary> {
  let totalDeposits = 0n;
  let totalWithdrawals = 0n;
  let depositCount = 0;
  let withdrawalCount = 0;
  let firstDepositTimestamp: number | null = null;

  try {
    // Fetch Deposit events
    const depositFilter = vault.filters.Deposit();
    const depositEvents = await fetchEventsChunked(vault, depositFilter, fromBlock, toBlock, 1000);

    for (const event of depositEvents) {
      const eventLog = event as EventLog;
      const decoded = vault.interface.decodeEventLog("Deposit", eventLog.data, eventLog.topics);
      totalDeposits += BigInt(decoded.assets);
      depositCount++;

      if (firstDepositTimestamp === null) {
        const block = await event.getBlock();
        firstDepositTimestamp = block.timestamp;
      }
    }

    // Fetch Withdraw events
    const withdrawFilter = vault.filters.Withdraw();
    const withdrawEvents = await fetchEventsChunked(vault, withdrawFilter, fromBlock, toBlock, 1000);

    for (const event of withdrawEvents) {
      const eventLog = event as EventLog;
      const decoded = vault.interface.decodeEventLog("Withdraw", eventLog.data, eventLog.topics);
      totalWithdrawals += BigInt(decoded.assets);
      withdrawalCount++;
    }
  } catch (e) {
    console.error(`  Warning: Error fetching deposit/withdraw events: ${e}`);
  }

  const netDeposits = totalDeposits - totalWithdrawals;

  return {
    totalDeposits: totalDeposits.toString(),
    totalWithdrawals: totalWithdrawals.toString(),
    netDeposits: netDeposits.toString(),
    depositCount,
    withdrawalCount,
    firstDepositTimestamp,
  };
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

  // Fetch MPC wallet info if address is provided
  let mpcWalletInfo: MPCWalletInfo | null = null;
  if (config.mpcWalletAddress && assetInfo && !config.valuerOnly) {
    console.error(`  Fetching MPC wallet holdings...`);
    mpcWalletInfo = await fetchMPCWalletInfo(
      provider,
      config.mpcWalletAddress,
      assetInfo.address,
      config.usdt0Address,
      assetInfo.decimals
    );
    console.error(`    WHYPE: ${formatUnits(mpcWalletInfo.whypeBalance, assetInfo.decimals)}`);
    if (config.usdt0Address) {
      console.error(`    USDT0: ${formatUnits(mpcWalletInfo.usdt0Balance, 6)}`);
      console.error(`    USDT0 as WHYPE: ${formatUnits(mpcWalletInfo.usdt0AsWhype, assetInfo.decimals)}`);
    }
  }

  // Fetch deposit/withdrawal summary
  // Search deposit history - use a reasonable window to avoid RPC timeouts
  let depositSummary: DepositWithdrawSummary | null = null;
  if (vaultInfo && !config.valuerOnly) {
    console.error(`  Fetching deposit/withdrawal history...`);
    const vault = new Contract(vaultInfo.address, VAULT_ABI, provider);
    // Search from ~60 days ago for deposits (balance between coverage and speed)
    // For truly accurate deposit tracking, consider using an indexer service
    const depositFromBlock = Math.max(0, currentBlock - blocksPerDay * 60); // 60 days
    depositSummary = await fetchDepositWithdrawSummary(vault, depositFromBlock, currentBlock);
    console.error(`    Deposits: ${depositSummary.depositCount} totaling ${formatUnits(depositSummary.totalDeposits, assetInfo?.decimals ?? 18)} ${assetInfo?.symbol ?? ""}`);
    console.error(`    Withdrawals: ${depositSummary.withdrawalCount} totaling ${formatUnits(depositSummary.totalWithdrawals, assetInfo?.decimals ?? 18)} ${assetInfo?.symbol ?? ""}`);
    console.error(`    Net Deposits: ${formatUnits(depositSummary.netDeposits, assetInfo?.decimals ?? 18)} ${assetInfo?.symbol ?? ""}`);
  }

  // Calculate performance metrics using DEPOSIT-BASED returns (fixed formula)
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

    let valueChangePercent = 0;
    if (startValue > 0n) {
      valueChangePercent = Number((valueChange * 10000n) / startValue) / 100;
    }

    // ========== FIXED PERFORMANCE CALCULATION ==========
    // Use net deposits as the baseline (original deposit amount)
    // This is the KEY FIX: compare current AUM to what was deposited, not short-term fluctuations

    // Determine original deposit amount with fallbacks:
    // 1. Use manual override from config (most reliable if known)
    // 2. Use net deposits from vault events
    // 3. Fallback to earliest recorded value in value history
    // 4. Fallback to start value of the query period
    let originalDeposit: bigint;
    if (config.originalDeposit) {
      originalDeposit = BigInt(config.originalDeposit);
      console.error(`  Using configured original deposit: ${formatUnits(originalDeposit.toString(), 18)}`);
    } else if (depositSummary && BigInt(depositSummary.netDeposits) > 0n) {
      originalDeposit = BigInt(depositSummary.netDeposits);
    } else if (valueHistory.length > 0) {
      // Use the earliest recorded value as proxy for original deposit
      originalDeposit = BigInt(valueHistory[0].value);
      console.error(`  Note: Using earliest recorded value (${formatUnits(originalDeposit.toString(), 18)}) as deposit baseline`);
    } else {
      originalDeposit = startValue;
    }

    const currentAUM = endValue;
    const totalReturnAmount = currentAUM - originalDeposit;

    // Calculate TRUE total return based on deposits
    let totalReturnPercent = 0;
    if (originalDeposit > 0n) {
      totalReturnPercent = Number((totalReturnAmount * 10000n) / originalDeposit) / 100;
    }

    // Only calculate annualized yield for periods > 7 days
    // For short periods, annualization produces unrealistic numbers
    const MIN_DAYS_FOR_ANNUALIZATION = 7;
    const isAnnualizedReliable = actualPeriodDays >= MIN_DAYS_FOR_ANNUALIZATION;

    let annualizedYieldPercent = 0;
    if (isAnnualizedReliable && actualPeriodDays > 0) {
      // Annualize the total return based on actual period
      annualizedYieldPercent = totalReturnPercent * (365 / actualPeriodDays);
    } else if (actualPeriodDays > 0) {
      // For short periods, still calculate but mark as unreliable
      annualizedYieldPercent = totalReturnPercent * (365 / actualPeriodDays);
      console.error(`  Warning: Period (${actualPeriodDays.toFixed(1)} days) < ${MIN_DAYS_FOR_ANNUALIZATION} days, annualized yield may be unreliable`);
    }

    // ========== OPTIONS VAULT METRICS (Monthly Strategy) ==========
    // Normalize return to 30-day period for monthly options strategies
    let monthlyReturnPercent = 0;
    let apr = 0;
    let apy = 0;

    // Use vault age if configured, otherwise use actual period from data
    const effectivePeriodDays = config.vaultAgeDays ?? actualPeriodDays;

    if (effectivePeriodDays > 0 && totalReturnPercent !== 0) {
      // Monthly return: normalize to 30 days
      monthlyReturnPercent = totalReturnPercent * (30 / effectivePeriodDays);

      // APR: Simple annual rate (monthly return × 12)
      apr = monthlyReturnPercent * 12;

      // APY: Compounded annual yield ((1 + monthly_return)^12 - 1)
      const monthlyReturnDecimal = monthlyReturnPercent / 100;
      apy = (Math.pow(1 + monthlyReturnDecimal, 12) - 1) * 100;
    }

    if (config.vaultAgeDays) {
      console.error(`  Using configured vault age: ${config.vaultAgeDays} days`);
    }
    // ========== END FIXED CALCULATION ==========

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
      // Deposit-based metrics
      originalDeposit: originalDeposit.toString(),
      currentAUM: currentAUM.toString(),
      totalReturnPercent,
      totalReturnAmount: totalReturnAmount.toString(),
      isAnnualizedReliable,
      // Options vault metrics
      isOptionsVault: config.isOptionsVault,
      monthlyReturnPercent,
      apr,
      apy,
    };
  }

  return {
    timestamp: Math.floor(Date.now() / 1000),
    vault: vaultInfo,
    asset: assetInfo,
    escrow: escrowInfo,
    strategy,
    escrowTotal: escrowTotalInfo,
    mpcWallet: mpcWalletInfo,
    depositSummary,
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
    if (config.mpcWalletAddress) {
      console.error(`  MPC Wallet: ${config.mpcWalletAddress}`);
    }
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

    // MPC Wallet holdings
    if (result.mpcWallet) {
      console.error("");
      console.error(`MPC Wallet (${result.mpcWallet.address}):`);
      console.error(`  WHYPE Balance: ${formatUnits(result.mpcWallet.whypeBalance, result.asset?.decimals ?? 18)} ${result.asset?.symbol ?? ""}`);
      if (result.mpcWallet.usdt0Balance !== "0") {
        console.error(`  USDT0 Balance: ${formatUnits(result.mpcWallet.usdt0Balance, 6)} USDT0`);
        console.error(`  USDT0 as WHYPE: ~${formatUnits(result.mpcWallet.usdt0AsWhype, result.asset?.decimals ?? 18)} ${result.asset?.symbol ?? ""}`);
      }
    }

    // Deposit/Withdrawal Summary
    if (result.depositSummary) {
      console.error("");
      console.error(`Deposit Summary:`);
      console.error(`  Total Deposits: ${formatUnits(result.depositSummary.totalDeposits, result.asset?.decimals ?? 18)} ${result.asset?.symbol ?? ""} (${result.depositSummary.depositCount} txs)`);
      console.error(`  Total Withdrawals: ${formatUnits(result.depositSummary.totalWithdrawals, result.asset?.decimals ?? 18)} ${result.asset?.symbol ?? ""} (${result.depositSummary.withdrawalCount} txs)`);
      console.error(`  Net Deposits: ${formatUnits(result.depositSummary.netDeposits, result.asset?.decimals ?? 18)} ${result.asset?.symbol ?? ""}`);
      if (result.depositSummary.firstDepositTimestamp) {
        console.error(`  First Deposit: ${new Date(result.depositSummary.firstDepositTimestamp * 1000).toISOString()}`);
      }
    }

    if (result.performance) {
      const decimals = result.asset?.decimals ?? 18;
      const symbol = result.asset?.symbol ?? "";

      console.error("");
      console.error(`=== Performance Summary ===`);
      console.error(`Original Deposit: ${formatUnits(result.performance.originalDeposit, decimals)} ${symbol}`);
      console.error(`Current AUM: ${formatUnits(result.performance.currentAUM, decimals)} ${symbol}`);

      const returnSign = BigInt(result.performance.totalReturnAmount) >= 0n ? "+" : "";
      console.error(`Total Return: ${returnSign}${formatUnits(result.performance.totalReturnAmount, decimals)} ${symbol} (${returnSign}${result.performance.totalReturnPercent.toFixed(2)}%)`);
      console.error(`Period: ${result.performance.periodDays.toFixed(1)} days`);

      // Options Vault: Show Monthly Return, APR, APY as primary metrics
      if (result.performance.isOptionsVault) {
        console.error("");
        console.error(`=== Monthly Options Strategy Metrics ===`);
        const monthlySign = result.performance.monthlyReturnPercent >= 0 ? "+" : "";
        console.error(`Monthly Return (30d): ${monthlySign}${result.performance.monthlyReturnPercent.toFixed(2)}%`);
        console.error(`APR (simple annual): ${result.performance.apr.toFixed(2)}%`);
        console.error(`APY (compounded):    ${result.performance.apy.toFixed(2)}%`);
        console.error("");
        console.error(`Note: Monthly options returns are variable. Past performance`);
        console.error(`      does not guarantee future results.`);
      } else {
        // Non-options vault: show annualized yield
        if (result.performance.isAnnualizedReliable) {
          console.error(`Annualized Yield: ${result.performance.annualizedYieldPercent.toFixed(2)}%`);
        } else {
          console.error(`Annualized Yield: ${result.performance.annualizedYieldPercent.toFixed(2)}% (unreliable - period < 7 days)`);
        }
      }

      console.error("");
      console.error(`Raw Performance Data (${result.performance.periodDays.toFixed(1)} days):`);
      console.error(`  Start Value: ${formatUnits(result.performance.startValue, decimals)} ${symbol}`);
      console.error(`  End Value: ${formatUnits(result.performance.endValue, decimals)} ${symbol}`);
      console.error(`  Value Change: ${formatUnits(result.performance.valueChange, decimals)} ${symbol} (${result.performance.valueChangePercent.toFixed(2)}%)`);
      console.error(`  Average AUM: ${formatUnits(result.performance.averageAUM, decimals)} ${symbol}`);
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
