/**
 * Check WHYPE allocations to/from escrow via Allocate events
 */
import { Contract, JsonRpcProvider, formatUnits } from "ethers";

const WHYPE = "0x5555555555555555555555555555555555555555";
const VAULT = "0xd7bFebcbfA0f703a10054C8ffc9Dc53a389DCF83";
const ESCROW = "0xAb6021ffBc44546F22E61E5F03F0F017B0b40182";
const MPC = "0x2F10b3FF99F507f438A0e338A8dE31af1E0cdCd7";
const RPC = "https://hyperliquid-mainnet.g.alchemy.com/v2/J7ZwqHgyu3YAGvtCwOVGH";

const VAULT_ABI = [
  "event Allocate(address indexed sender, address indexed adapter, uint256 assets, bytes32[] ids, int256 change)"
];

const ERC20_ABI = [
  "event Transfer(address indexed from, address indexed to, uint256 value)",
  "function balanceOf(address) view returns (uint256)"
];

async function fetchEventsChunked(
  contract: Contract,
  filter: ReturnType<typeof contract.filters.Transfer>,
  fromBlock: number,
  toBlock: number,
  chunkSize = 1000
) {
  const events: any[] = [];
  let current = fromBlock;

  while (current <= toBlock) {
    const to = Math.min(current + chunkSize - 1, toBlock);
    try {
      const chunk = await contract.queryFilter(filter, current, to);
      events.push(...chunk);
      if ((to - fromBlock) % 10000 < chunkSize) {
        const progress = ((to - fromBlock) / (toBlock - fromBlock) * 100).toFixed(1);
        console.error(`Progress: ${progress}%`);
      }
    } catch (e) {
      console.error(`Error at block ${current}: ${e}`);
    }
    current = to + 1;
  }
  return events;
}

async function main() {
  const provider = new JsonRpcProvider(RPC);
  const vault = new Contract(VAULT, VAULT_ABI, provider);
  const whype = new Contract(WHYPE, ERC20_ABI, provider);

  const currentBlock = await provider.getBlockNumber();
  const blocksPerDay = 43200; // ~2s blocks
  const fromBlock = Math.max(0, currentBlock - blocksPerDay * 90); // 90 days

  console.log(`Querying blocks ${fromBlock} to ${currentBlock}...`);

  // Query Allocate events from Vault to Escrow
  console.log("\n=== Allocate events from Vault ===");
  const allocateFilter = vault.filters.Allocate(null, ESCROW);
  const allocateEvents = await fetchEventsChunked(vault, allocateFilter, fromBlock, currentBlock);

  let totalAllocated = 0n;
  let totalDeallocated = 0n;

  for (const e of allocateEvents) {
    const sender = e.args[0];
    const assets: bigint = e.args[2];
    const change: bigint = e.args[4]; // int256

    console.log(`Allocate: assets=${formatUnits(assets, 18)} WHYPE, change=${formatUnits(change, 18)} WHYPE`);
    console.log(`  sender: ${sender}`);

    if (change > 0n) {
      totalAllocated += change;
    } else {
      totalDeallocated += -change;
    }
  }

  console.log(`\nTotal Allocated:   ${formatUnits(totalAllocated, 18)} WHYPE`);
  console.log(`Total Deallocated: ${formatUnits(totalDeallocated, 18)} WHYPE`);
  console.log(`Net Allocation:    ${formatUnits(totalAllocated - totalDeallocated, 18)} WHYPE`);

  // Also check Transfer events for comparison
  console.log("\n=== WHYPE Transfer events (for comparison) ===");

  // Query transfers TO escrow (deposits in)
  const filterIn = whype.filters.Transfer(null, ESCROW);
  const eventsIn = await fetchEventsChunked(whype, filterIn, fromBlock, currentBlock);

  let totalIn = 0n;
  for (const e of eventsIn) {
    const from = e.args[0];
    const value = e.args[2];
    totalIn += value;
    console.log(`IN: ${formatUnits(value, 18)} WHYPE from ${from}`);
  }
  console.log(`Total IN: ${formatUnits(totalIn, 18)} WHYPE`);

  // Query transfers FROM escrow (allocations out)
  const filterOut = whype.filters.Transfer(ESCROW, null);
  const eventsOut = await fetchEventsChunked(whype, filterOut, fromBlock, currentBlock);

  let totalOut = 0n;
  for (const e of eventsOut) {
    const to = e.args[1];
    const value = e.args[2];
    totalOut += value;
    console.log(`OUT: ${formatUnits(value, 18)} WHYPE to ${to}`);
  }
  console.log(`Total OUT: ${formatUnits(totalOut, 18)} WHYPE`);

  // Summary
  console.log("\n=== SUMMARY ===");
  console.log(`From Allocate events:`);
  console.log(`  Total Allocated:   ${formatUnits(totalAllocated, 18)} WHYPE`);
  console.log(`  Total Deallocated: ${formatUnits(totalDeallocated, 18)} WHYPE`);
  console.log(`  Net:               ${formatUnits(totalAllocated - totalDeallocated, 18)} WHYPE`);
  console.log(`\nFrom Transfer events:`);
  console.log(`  Total IN:  ${formatUnits(totalIn, 18)} WHYPE`);
  console.log(`  Total OUT: ${formatUnits(totalOut, 18)} WHYPE`);
  console.log(`  Net:       ${formatUnits(totalIn - totalOut, 18)} WHYPE`);

  // Current balance
  const balance = await whype.balanceOf(ESCROW);
  console.log(`\nCurrent escrow balance: ${formatUnits(balance, 18)} WHYPE`);
}

main().catch(console.error);
