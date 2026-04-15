# Strategy Vault Launchpad - Frontend Design & Integration Handoff

## Context

Create a one-click launchpad for deploying strategy vaults. Users select an archetype (Delta-Neutral or PT Loop), configure params, and deploy — all via a single transaction to `StrategyVaultFactory`. The factory uses EIP-1167 minimal proxies (clones) for gas-efficient deployment (~200k gas per clone vs ~2M+ for full deployment).

The existing frontend integration doc (`docs/OVAULT_FRONTEND_INTEGRATION.md`) covers deposit/withdraw flows for spoke chains. This document covers the **deployment** (launchpad) experience.

---

## 1. Architecture Overview

### Contract Surface

| Contract | Address Source | Purpose |
|----------|--------------|---------|
| `StrategyVaultFactory` | Deployed per-chain | Single entry point: `createDeltaNeutralVault()` / `createPTLoopVault()` |
| `VaultV2Factory` | Immutable in factory | Sub-factory for vault clones |
| `UniversalAdapterEscrowFactory` | Immutable in factory | Sub-factory for adapter/sleeve clones |

### EIP-1167 Minimal Proxy (Clone) Architecture

The factory uses **EIP-1167 minimal proxies** for gas-efficient deployment. The factory constructor deploys "dead" implementation contracts (all-zero params that self-disable) and stores their addresses as immutables. At deployment time, `Clones.clone(implementation)` creates a minimal proxy (~45 bytes) that delegates all calls to the implementation, then `initialize()` is called to set up state.

**Implementation contracts stored in factory (immutable, set at factory deploy time):**

| Implementation | Factory Field | Gas Savings |
|----------------|---------------|-------------|
| `DeltaNeutralController` | `deltaNeutralControllerImplementation` | ~2M -> ~200k |
| `PTLoopController` | `ptLoopControllerImplementation` | ~2M -> ~200k |
| `VaultTimeLockWrapper` | `vaultTimeLockWrapperImplementation` | ~1M -> ~200k |
| `WrapperOnlySendAssetsGate` | `wrapperOnlySendAssetsGateImplementation` | ~500k -> ~200k |
| `AsyncWithdrawalQueue` | `asyncWithdrawalQueueImplementation` | ~1.5M -> ~200k |

The `VaultV2Factory` and `UniversalAdapterEscrowFactory` handle their own implementations internally.

**Key implication for frontend:** The frontend does NOT need to worry about implementation addresses — they're baked into the factory at deploy time. The frontend only calls `createDeltaNeutralVault()` or `createPTLoopVault()` with params.

### What Gets Deployed (per vault)

One `createDeltaNeutralVault()` or `createPTLoopVault()` call deploys:
- **VaultV2** - ERC-4626 vault (clone via VaultV2Factory)
- **UniversalAdapterEscrow** ("sleeve") - Strategy execution adapter (clone via AdapterFactory)
- **Controller** - DeltaNeutralController or PTLoopController (clone via Clones.clone)
- **VaultTimeLockWrapper** - Optional 7-day lock wrapper (clone, if `enableTimelock=true`)
- **WrapperOnlySendAssetsGate** - Deposit gate (clone, if timelock enabled)
- **AsyncWithdrawalQueue** - Async redemption queue (clone, DeltaNeutral only)

All wiring (whitelist, caps, roles, adapters) happens atomically in the same tx.

### Chain -> Archetype Mapping

| Archetype | Venue | Deployment Chain(s) | Venue ID |
|-----------|-------|---------------------|----------|
| **Delta-Neutral** | Hyperliquid | HyperEVM (chainId: 999) | `keccak256("HYPERLIQUID")` |
| **PT Loop** | Pendle | Ethereum (1), Arbitrum (42161), Base (8453), BNB (56), Optimism (10), Sonic (146), Mantle (5000), Berachain (80094), Monad (143) | `keccak256("PENDLE")` |

The frontend **must enforce** that users deploy on the correct chain for their chosen archetype.

### Critical Venue & Infrastructure Addresses

**These addresses are passed in `venueConfig` and MUST be correct for the strategy to function. Wrong addresses = bricked vault.**

#### Delta-Neutral (Hyperliquid / HyperEVM)

| Address | VenueConfig Field | What It Is | Why It Matters |
|---------|-------------------|-----------|----------------|
| **CoreWriter** | `venueConfig.venue` | Hyperliquid L1 action proxy on HyperEVM | Factory whitelists `sendRawAction` selector on this address. Wrong address = controller cannot execute spot/perp trades. |
| **L1Read** | `venueConfig.helper` | Hyperliquid L1 state reader on HyperEVM | Controller reads perp positions, margin, and funding via this. Wrong address = controller cannot read state. |
| `keccak256("HYPERLIQUID")` | `venueConfig.venueId` | Venue identifier | Must be exactly `keccak256("HYPERLIQUID")` — hardcode this. |

Also in `automationConfig`:
| Address | Field | What It Is |
|---------|-------|-----------|
| **HyperCore Vault** | `automationConfig.hyperCoreVault` | The HyperCore vault address for margin/collateral operations |

#### PT Loop (Pendle)

| Address | VenueConfig Field | What It Is | Why It Matters |
|---------|-------------------|-----------|----------------|
| **PendleRouter (v4)** | `venueConfig.venue` | Pendle Router for swap execution | Factory whitelists `swapExactTokenForPt` and `swapExactPtForToken` selectors on this address. Wrong address = controller cannot loop PT. |
| **PendleStaticQuoter** | `venueConfig.helper` | Pendle quoter for off-chain price estimation | Controller uses this for slippage checks and position sizing. |
| `keccak256("PENDLE")` | `venueConfig.venueId` | Venue identifier | Must be exactly `keccak256("PENDLE")` — hardcode this. |

Also PT-specific params:
| Address | Field | What It Is |
|---------|-------|-----------|
| **Pendle Market** | `params.market` | The specific Pendle market (PT-asset pair) being traded |
| **PT Token** | `params.ptToken` | The Principal Token contract address for the market |

**The frontend MUST pre-populate venue addresses per chain from a hardcoded registry.** Do not let users manually enter these — incorrect addresses will deploy a non-functional vault. See Section 5 (Chain Configuration Registry) for the full registry structure.

### Asset Constraints

**The vault's deposit `asset` must match the strategy's requirements. Mismatched assets = bricked vault.**

#### Delta-Neutral

- **Only HyperEVM USDC** is supported as the deposit asset
- DN vaults use USDC as collateral on Hyperliquid for margin trading
- The frontend should hardcode the USDC address for HyperEVM and not offer other asset options
- If other assets are supported in the future, a swap module would need to be added

#### PT Loop

- The vault `asset` must be the **underlying token** of the Pendle market being looped
- Example: A PT-KHYPE looper must use KHYPE as the vault asset, NOT USDC or another token
- Example: A PT-USDe looper must use USDe as the vault asset
- The frontend should **auto-populate the asset from the selected Pendle market** — when the user picks a market, resolve the underlying asset and lock it in
- If the user wants to deposit a different token (e.g., USDC into a PT-USDe vault), a swap layer would need to be added separately — the factory does not handle this

**Validation:** The frontend should prevent deployment if the selected asset doesn't match the market's underlying token. The contract won't catch this mismatch — it will deploy successfully but the vault won't function correctly.

---

## 2. User Flow

### Screen 1: Archetype Selection

```
+--------------------------------------------------+
|  STRATEGY VAULT LAUNCHPAD                         |
|                                                   |
|  Select Strategy Type                             |
|                                                   |
|  +---------------------+  +--------------------+ |
|  | DELTA-NEUTRAL       |  | PT LOOP            | |
|  |                     |  |                    | |
|  | Hedge spot exposure  |  | Earn fixed yield   | |
|  | via perp shorts on  |  | by looping Pendle  | |
|  | Hyperliquid         |  | Principal Tokens   | |
|  |                     |  |                    | |
|  | Chain: HyperEVM     |  | Chains: Arb, Base, | |
|  |                     |  | ETH, BNB, Sonic... | |
|  | [Select]            |  | [Select]           | |
|  +---------------------+  +--------------------+ |
+--------------------------------------------------+
```

When an archetype is selected, prompt chain switch if user is on wrong network.

### Screen 2: Vault Identity

```
+--------------------------------------------------+
|  VAULT DETAILS                                    |
|                                                   |
|  Vault Name        [___________________________] |
|  Vault Symbol       [________]                    |
|                                                   |
|  --- Asset Selection (depends on archetype) ---   |
|                                                   |
|  [DN] Deposit Asset: USDC (HyperEVM)              |
|       (hardcoded, read-only — only supported      |
|        asset for delta-neutral on HyperEVM)       |
|                                                   |
|  [PT] Deposit Asset: (set automatically in        |
|       Screen 4b when user picks Pendle market.    |
|       Show "Resolved from market selection" here  |
|       or defer asset display to Screen 4b.)       |
|                                                   |
|  Strategy ID        [auto-generated or custom___] |
|  (used for deterministic deployment addressing)   |
|                                                   |
|  [Next ->]                                        |
+--------------------------------------------------+
```

- **DN asset**: Hardcode to HyperEVM USDC. No dropdown — there's only one supported asset.
- **PT asset**: Auto-resolved from the Pendle market's underlying token in Screen 4b. The asset field on this screen should either be hidden (resolved later) or shown as read-only once the market is selected.
- `strategyIdData`: auto-generate from `abi.encode(name, symbol, owner, timestamp)` or let user provide custom bytes
- `salt`: auto-generate or 0x0 for default

### Screen 3: Governance & Access

```
+--------------------------------------------------+
|  GOVERNANCE                                       |
|                                                   |
|  Owner          [connected wallet______________]  |
|  Vault Manager  [same as owner v] (optional)      |
|  Curator        [same as owner v] (optional)      |
|                                                   |
|  [ ] Enable 7-day Timelock Wrapper                |
|      Users must lock deposits for 7 days.         |
|      Prevents hot-money attacks.                  |
|                                                   |
|  [Next ->]                                        |
+--------------------------------------------------+
```

### Screen 4a: Strategy Config (Delta-Neutral)

```
+--------------------------------------------------+
|  DELTA-NEUTRAL CONFIGURATION                      |
|                                                   |
|  Spot Side Mode                                   |
|  (*) Hold   ( ) Lend   ( ) LP                    |
|  Hold: buy and hold spot asset                    |
|  Lend: lend spot into approved market             |
|  LP: deploy spot into bounded LP                  |
|                                                   |
|  ---- Risk Parameters ----                        |
|  Target Reserve    [====|====] 20%    (BPS: 2000) |
|  Max Delta         [==|======] 2.5%   (BPS: 250)  |
|                                                   |
|  ---- Vault Caps ----                             |
|  Absolute Cap      [1,000,000] USDC               |
|  Relative Cap      [1.0e18__]                     |
|                                                   |
|  [Advanced: Kelly Config v]                       |
|  [Advanced: Automation Config v]                  |
|  [Advanced: Venue Config v]                       |
|                                                   |
|  [Next ->]                                        |
+--------------------------------------------------+
```

### Screen 4b: Strategy Config (PT Loop)

```
+--------------------------------------------------+
|  PT LOOP CONFIGURATION                            |
|                                                   |
|  Chain             [Arbitrum v]                    |
|  Pendle Market     [PT-USDe 31DEC2025 v]           |
|                     (dropdown of known markets)    |
|  PT Token          [0x1234...] (auto-populated,    |
|                     read-only)                     |
|  Vault Asset       [USDe (0x...)] (auto-populated  |
|                     from market underlying,        |
|                     read-only — MUST match market) |
|                                                   |
|  ---- Risk Parameters ----                        |
|  Target Reserve    [====|====] 15%    (BPS: 1500) |
|  Max Unwind Slip.  [===|=====] 6%     (BPS: 600)  |
|  Max Entry Slip.   [===|=====] 6%     (BPS: 600)  |
|                                                   |
|  ---- Vault Caps ----                             |
|  Absolute Cap      [500,000__] USDe               |
|  Relative Cap      [1.0e18__]                     |
|                                                   |
|  [Advanced: Venue Config v]                       |
|  (Pre-populated: PendleRouter + StaticQuoter      |
|   for selected chain. Show as read-only unless    |
|   user wants to override.)                        |
|                                                   |
|  [Next ->]                                        |
+--------------------------------------------------+
```

**Asset selection flow for PT Loop:**
1. User selects chain -> filters available Pendle markets
2. User selects Pendle market -> auto-populates PT token AND vault asset (underlying)
3. Asset is locked/read-only — user cannot change it independently of market
4. The Vault Identity screen (Screen 2) should skip the asset dropdown for PT Loop and instead show the auto-resolved asset

### Screen 5: Review & Deploy

```
+--------------------------------------------------+
|  REVIEW DEPLOYMENT                                |
|                                                   |
|  Strategy: Delta-Neutral (Hold)                   |
|  Chain: HyperEVM                                  |
|  Asset: USDC (0x...)                              |
|  Name: "My DN Vault"  Symbol: "vDN"              |
|  Owner: 0x1234...                                 |
|  Timelock: Enabled (7 days)                       |
|  Reserve: 20%  |  Max Delta: 2.5%                |
|  Absolute Cap: 1,000,000 USDC                    |
|                                                   |
|  ---- Venue Config (auto-resolved) ----           |
|  Venue:  CoreWriter (0xABC...)                    |
|  Helper: L1Read (0xDEF...)                        |
|                                                   |
|  Estimated gas: ~2.5M                             |
|                                                   |
|  [Deploy Vault]                                   |
+--------------------------------------------------+
```

The review screen should display the resolved venue addresses so the deployer can verify them. This is critical — wrong venue addresses result in a non-functional vault.

### Screen 6: Post-Deploy Success

```
+--------------------------------------------------+
|  VAULT DEPLOYED                                   |
|                                                   |
|  Vault:      0xABCD...  [copy] [explorer]         |
|  Sleeve:     0x1234...  [copy] [explorer]         |
|  Controller: 0x5678...  [copy] [explorer]         |
|  Wrapper:    0x9ABC...  [copy] [explorer]         |
|  Queue:      0xDEF0...  [copy] [explorer]         |
|  Strategy ID: 0x...     [copy]                    |
|                                                   |
|  [View Vault Dashboard]  [Deploy Another]         |
+--------------------------------------------------+
```

---

## 3. Contract Integration

### ABI Source

Compiled ABIs are in `/out/` directory:
- `out/StrategyVaultFactory.sol/StrategyVaultFactory.json`
- `out/DeltaNeutralController.sol/DeltaNeutralController.json`
- `out/PTLoopController.sol/PTLoopController.json`
- `out/VaultV2.sol/VaultV2.json`

### TypeScript Type Definitions

```typescript
// ============ ENUMS ============

enum StrategyKind { DeltaNeutral = 0, PTLoop = 1 }
enum SpotSideMode { Hold = 0, Lend = 1, LP = 2 }

// ============ STRUCTS ============

interface VenueConfig {
  venueId: `0x${string}`;   // bytes32: keccak256("HYPERLIQUID") or keccak256("PENDLE")
  venue: `0x${string}`;     // address: CoreWriter (HL) or PendleRouter
  helper: `0x${string}`;    // address: L1Read (HL) or PendleStaticQuoter
}

interface DeltaNeutralKellyConfig {
  spotYieldWad: bigint;               // e.g. 204_000_000_000_000_000n (20.4%)
  marginYieldWad: bigint;             // e.g. 433_000_000_000_000_000n (43.3%)
  baseFundingRateWad: bigint;         // e.g. 105_000_000_000_000_000n (10.5%)
  ethVolatilityWad: bigint;           // REQUIRED != 0, e.g. 600_000_000_000_000_000n (60%)
  liquidationLossWad: bigint;         // REQUIRED < 1e18
  rebalanceThresholdWad: bigint;      // REQUIRED <= 1e18
  minBenefitWad: bigint;              // REQUIRED <= 1e18
  shortTakerFeeWad: bigint;
  entrySlippageWad: bigint;
  exitSlippageWad: bigint;
  shortSlippageWad: bigint;
  bridgeSlippageWad: bigint;
  sizeImpactThresholdAssets: bigint;
  sizeImpactMultiplierWad: bigint;    // REQUIRED >= 1e18
  bridgeFeeAssets: bigint;
  gasSpotActionAssets: bigint;
  gasShortActionAssets: bigint;
  timeHorizonDays: number;            // uint32, REQUIRED != 0
  fundingDivisor: number;             // uint16, REQUIRED != 0
  asymmetricRebalanceThresholdBps: number;  // uint16, REQUIRED <= 10000
}

interface DeltaNeutralAutomationConfig {
  spotAssetIndex: number;             // uint32, Hyperliquid asset index
  perpAssetIndex: number;             // uint32, Hyperliquid perp asset index
  spotPriceIndex: number;             // uint32, price feed index
  perpDexIndex: number;               // uint32, DEX index
  spotToken: bigint;                  // uint64, Hyperliquid token ID
  spotTokenDecimals: number;          // uint8
  encodedTif: number;                 // uint8, time-in-force encoding
  hyperCoreVault: `0x${string}`;      // address
  maxOrderSlippageBps: number;        // uint16, <= 10000
  maxOracleDivergenceBps: number;     // uint16, <= 10000
  maxMarginUsageBps: number;          // uint16, REQUIRED != 0 && <= 10000
}

interface PTLoopAutomationConfig {
  maxEntrySlippageBps: number;        // uint16, <= 10000
}

interface DeltaNeutralDeploymentParams {
  owner: `0x${string}`;
  vaultManager: `0x${string}`;        // 0x0 = defaults to owner
  curator: `0x${string}`;             // 0x0 = defaults to owner
  enableTimelock: boolean;
  asset: `0x${string}`;
  name: string;
  symbol: string;
  strategyIdData: `0x${string}`;      // bytes, hashed to strategyId
  spotSideMode: SpotSideMode;
  targetReserveBps: bigint;           // 0-10000
  maxDeltaBps: bigint;                // 0-10000
  kellyConfig: DeltaNeutralKellyConfig;
  automationConfig: DeltaNeutralAutomationConfig;
  absoluteCap: bigint;                // asset-denominated
  relativeCap: bigint;                // 1e18 = 100%
  salt: `0x${string}`;               // bytes32, 0x0 for default
  venueConfig: VenueConfig;
}

interface PTLoopDeploymentParams {
  owner: `0x${string}`;
  vaultManager: `0x${string}`;
  curator: `0x${string}`;
  enableTimelock: boolean;
  asset: `0x${string}`;
  market: `0x${string}`;             // Pendle market address
  ptToken: `0x${string}`;            // Pendle PT token address
  name: string;
  symbol: string;
  strategyIdData: `0x${string}`;
  targetReserveBps: bigint;
  maxUnwindSlippageBps: bigint;       // 0-10000
  automationConfig: PTLoopAutomationConfig;
  absoluteCap: bigint;
  relativeCap: bigint;
  salt: `0x${string}`;
  venueConfig: VenueConfig;
}

// ============ RETURN TYPE ============

interface Deployment {
  vault: `0x${string}`;
  sleeve: `0x${string}`;
  controller: `0x${string}`;
  wrapper: `0x${string}`;            // 0x0 if timelock disabled
  strategyId: `0x${string}`;
}
```

### Minimal Factory ABI

```typescript
const STRATEGY_VAULT_FACTORY_ABI = [
  {
    name: "createDeltaNeutralVault",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [/* DeltaNeutralDeploymentParams */] }],
    outputs: [{ name: "deployment", type: "tuple", components: [
      { name: "vault", type: "address" },
      { name: "sleeve", type: "address" },
      { name: "controller", type: "address" },
      { name: "wrapper", type: "address" },
      { name: "strategyId", type: "bytes32" }
    ]}]
  },
  {
    name: "createPTLoopVault",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [{ name: "params", type: "tuple", components: [/* PTLoopDeploymentParams */] }],
    outputs: [{ name: "deployment", type: "tuple", components: [
      { name: "vault", type: "address" },
      { name: "sleeve", type: "address" },
      { name: "controller", type: "address" },
      { name: "wrapper", type: "address" },
      { name: "strategyId", type: "bytes32" }
    ]}]
  },
  {
    name: "timeLockWrapperOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [{ type: "address" }]
  },
  {
    name: "withdrawalQueueOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [{ type: "address" }]
  },
  {
    name: "depositGateOf",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "vault", type: "address" }],
    outputs: [{ type: "address" }]
  }
] as const;
```

### Event to Watch

```typescript
// Emitted on successful deployment
event StrategyVaultDeployed(
  StrategyKind indexed kind,
  address indexed owner,
  address indexed vault,
  address controller,
  address sleeve,
  address wrapper,
  bytes32 strategyId,
  bytes32 salt
);

// DeltaNeutral only
event AsyncWithdrawalQueueDeployed(address indexed vault, address indexed queue);
```

### Deploy Transaction

```typescript
// Example: Deploy Delta-Neutral vault
const tx = await factoryContract.write.createDeltaNeutralVault([params]);
const receipt = await publicClient.waitForTransactionReceipt({ hash: tx });

// Parse deployment from return value or event logs
const deployment = decodeEventLog({
  abi: STRATEGY_VAULT_FACTORY_ABI,
  eventName: "StrategyVaultDeployed",
  topics: receipt.logs[/* last log */].topics,
  data: receipt.logs[/* last log */].data,
});
```

---

## 4. Parameter Groups & Validation

### Common Params (both archetypes)

| Param | Type | Validation | UI Element |
|-------|------|------------|------------|
| `owner` | address | Non-zero, connected wallet | Auto-fill |
| `vaultManager` | address | Optional (0x0 = owner) | Optional text input |
| `curator` | address | Optional (0x0 = owner) | Optional text input |
| `enableTimelock` | bool | - | Checkbox |
| `asset` | address | Non-zero, valid ERC20 on chain | Dropdown |
| `name` | string | Non-empty | Text input |
| `symbol` | string | Non-empty, short | Text input |
| `strategyIdData` | bytes | Non-empty | Auto-generated |
| `absoluteCap` | uint256 | > 0 | Numeric input (in asset decimals) |
| `relativeCap` | uint256 | > 0 | Numeric input (WAD, default 1e18) |
| `salt` | bytes32 | Any | Auto-generated (0x0 default) |
| `venueConfig` | struct | venueId + venue + helper | Pre-populated per chain |

### Delta-Neutral Specific

#### Risk Params (user-facing)

| Param | Range | Default | UI Element |
|-------|-------|---------|------------|
| `spotSideMode` | Hold/Lend/LP | Hold | Radio buttons |
| `targetReserveBps` | 0-10000 | 2000 (20%) | Slider (%) |
| `maxDeltaBps` | 0-10000 | 250 (2.5%) | Slider (%) |

#### Kelly Config (advanced, 19 params)

Most users should use presets. Group as:

**Yield & Funding** (5 params):
- `spotYieldWad`, `marginYieldWad`, `baseFundingRateWad`, `timeHorizonDays`, `fundingDivisor`

**Volatility & Liquidation** (3 params):
- `ethVolatilityWad`, `liquidationLossWad`, `rebalanceThresholdWad`

**Costs & Slippage** (8 params):
- `entrySlippageWad`, `exitSlippageWad`, `shortSlippageWad`, `bridgeSlippageWad`
- `shortTakerFeeWad`, `bridgeFeeAssets`, `gasSpotActionAssets`, `gasShortActionAssets`

**Size Impact** (3 params):
- `minBenefitWad`, `sizeImpactThresholdAssets`, `sizeImpactMultiplierWad`, `asymmetricRebalanceThresholdBps`

#### Automation Config (advanced, 11 params)

Hyperliquid-specific. Should be pre-populated per asset pair:

**Asset Indices** (4 params): `spotAssetIndex`, `perpAssetIndex`, `spotPriceIndex`, `perpDexIndex`
**Token Config** (3 params): `spotToken`, `spotTokenDecimals`, `encodedTif`
**Address** (1 param): `hyperCoreVault`
**Slippage** (3 params): `maxOrderSlippageBps`, `maxOracleDivergenceBps`, `maxMarginUsageBps`

### PT Loop Specific

| Param | Range | Default | UI Element |
|-------|-------|---------|------------|
| `market` | address | - | Dropdown (known Pendle markets) |
| `ptToken` | address | - | Auto-populated from market |
| `targetReserveBps` | 0-10000 | 1500 (15%) | Slider (%) |
| `maxUnwindSlippageBps` | 0-10000 | 600 (6%) | Slider (%) |
| `maxEntrySlippageBps` | 0-10000 | 600 (6%) | Slider (%) |

---

## 5. Chain Configuration Registry

```typescript
interface ChainConfig {
  chainId: number;
  name: string;
  rpcUrl: string;
  explorerUrl: string;
  factoryAddress: `0x${string}`;
  supportedArchetypes: StrategyKind[];
  venueConfigs: Record<string, VenueConfig>;
  knownAssets: AssetInfo[];
  knownMarkets?: PendleMarketInfo[];  // PT Loop chains only
}

interface AssetInfo {
  address: `0x${string}`;
  symbol: string;
  decimals: number;
  name: string;
}

interface PendleMarketInfo {
  address: `0x${string}`;
  ptToken: `0x${string}`;
  underlyingAsset: `0x${string}`;  // This MUST be used as the vault's deposit asset
  underlyingSymbol: string;         // e.g. "USDe", "KHYPE"
  underlyingDecimals: number;
  expiry: number;
  name: string;
}

// Example configs
const CHAIN_CONFIGS: Record<number, ChainConfig> = {
  999: {
    chainId: 999,
    name: "HyperEVM",
    rpcUrl: "https://rpc.hyperliquid.xyz/evm",
    explorerUrl: "https://explorer.hyperliquid.xyz",
    factoryAddress: "0x...",  // Deployed factory address
    supportedArchetypes: [StrategyKind.DeltaNeutral],
    venueConfigs: {
      HYPERLIQUID: {
        venueId: keccak256("HYPERLIQUID"),
        venue: "0x...",   // CoreWriter address
        helper: "0x...",  // L1Read address
      }
    },
    knownAssets: [
      { address: "0x...", symbol: "USDC", decimals: 6, name: "USD Coin" }
    ]
  },
  42161: {
    chainId: 42161,
    name: "Arbitrum",
    rpcUrl: "https://arb1.arbitrum.io/rpc",
    explorerUrl: "https://arbiscan.io",
    factoryAddress: "0x...",
    supportedArchetypes: [StrategyKind.PTLoop],
    venueConfigs: {
      PENDLE: {
        venueId: keccak256("PENDLE"),
        venue: "0x...",   // Pendle Router v4
        helper: "0x...",  // Pendle StaticQuoter
      }
    },
    knownAssets: [
      { address: "0x...", symbol: "USDe", decimals: 18, name: "USDe" }
    ],
    knownMarkets: [
      {
        address: "0x...",
        ptToken: "0x...",
        underlyingAsset: "0x...",
        underlyingSymbol: "USDe",
        underlyingDecimals: 18,
        expiry: 1735689600,
        name: "PT-USDe 31DEC2025"
      }
    ]
  }
};
```

### Pendle Supported Chains

| Chain | Chain ID | Pendle Router Address |
|-------|----------|----------------------|
| Ethereum | 1 | See [Pendle deployments](https://docs.pendle.finance/pendle-v2/Developers/Deployments) |
| Arbitrum | 42161 | " |
| Base | 8453 | " |
| BNB Chain | 56 | " |
| Optimism | 10 | " |
| Sonic | 146 | " |
| Mantle | 5000 | " |
| HyperEVM | 999 | " |
| Berachain | 80094 | " |
| Monad | 143 | " |

Router addresses follow pattern: check `deployments/{chainId}-core.json` in [pendle-core-v2-public](https://github.com/pendle-finance/pendle-core-v2-public).

---

## 6. Preset Configurations

### Delta-Neutral Presets

```typescript
const DN_PRESETS = {
  conservative: {
    label: "Conservative",
    description: "Lower risk, wider delta band, higher reserves",
    targetReserveBps: 3000n,
    maxDeltaBps: 500n,
    kellyConfig: {
      spotYieldWad: 100_000_000_000_000_000n,   // 10%
      marginYieldWad: 200_000_000_000_000_000n,  // 20%
      // ... fill sensible defaults
    }
  },
  balanced: {
    label: "Balanced",
    description: "Default risk parameters from test suite",
    targetReserveBps: 2000n,
    maxDeltaBps: 250n,
    kellyConfig: {
      spotYieldWad: 204_000_000_000_000_000n,
      marginYieldWad: 433_000_000_000_000_000n,
      baseFundingRateWad: 105_000_000_000_000_000n,
      ethVolatilityWad: 600_000_000_000_000_000n,
      liquidationLossWad: 300_000_000_000_000_000n,
      rebalanceThresholdWad: 50_000_000_000_000_000n,
      minBenefitWad: 10_000_000_000_000_000n,
      shortTakerFeeWad: 350_000_000_000_000n,
      entrySlippageWad: 3_000_000_000_000_000n,
      exitSlippageWad: 3_000_000_000_000_000n,
      shortSlippageWad: 1_000_000_000_000_000n,
      bridgeSlippageWad: 500_000_000_000_000n,
      sizeImpactThresholdAssets: 100_000_000_000n,
      sizeImpactMultiplierWad: 1_000_000_000_000_000_000n,
      bridgeFeeAssets: 100_000n,
      gasSpotActionAssets: 50_000n,
      gasShortActionAssets: 50_000n,
      timeHorizonDays: 7,
      fundingDivisor: 3,
      asymmetricRebalanceThresholdBps: 100,
    }
  },
  aggressive: {
    label: "Aggressive",
    description: "Higher yield target, tighter delta band, lower reserves",
    targetReserveBps: 1000n,
    maxDeltaBps: 150n,
    // ... fill accordingly
  }
};
```

### Automation Config (per asset pair)

```typescript
const HL_AUTOMATION_PRESETS: Record<string, DeltaNeutralAutomationConfig> = {
  "ETH-USDC": {
    spotAssetIndex: 1,
    perpAssetIndex: 7,
    spotPriceIndex: 3,
    perpDexIndex: 0,
    spotToken: 1n,
    spotTokenDecimals: 6,
    encodedTif: 0,
    hyperCoreVault: "0x...",
    maxOrderSlippageBps: 500,
    maxOracleDivergenceBps: 1000,
    maxMarginUsageBps: 8000,
  },
  "BTC-USDC": {
    spotAssetIndex: 2,
    perpAssetIndex: 0,
    // ... fill for BTC pair
  }
};
```

---

## 7. Client-Side Validation

```typescript
// Shared venue config validation
function validateVenueConfig(config: VenueConfig, label: string): string[] {
  const errors: string[] = [];
  const ZERO = "0x0000000000000000000000000000000000000000";
  if (!config.venue || config.venue === ZERO) errors.push(`${label} venue address required`);
  if (!config.helper || config.helper === ZERO) errors.push(`${label} helper address required`);
  if (!config.venueId || config.venueId === "0x" + "0".repeat(64)) errors.push(`${label} venue ID required`);
  return errors;
}

function validateDeltaNeutralParams(
  params: DeltaNeutralDeploymentParams,
  chainConfig: ChainConfig
): string[] {
  const errors: string[] = [];
  const ZERO = "0x0000000000000000000000000000000000000000";

  // Common
  if (!params.owner || params.owner === ZERO) errors.push("Owner required");
  if (!params.asset || params.asset === ZERO) errors.push("Asset required");
  if (!params.strategyIdData || params.strategyIdData === "0x") errors.push("Strategy ID required");
  if (!params.absoluteCap || params.absoluteCap === 0n) errors.push("Absolute cap required");
  if (!params.relativeCap || params.relativeCap === 0n) errors.push("Relative cap required");
  if (!params.name) errors.push("Vault name required");
  if (!params.symbol) errors.push("Vault symbol required");

  // Asset constraint: DN only supports HyperEVM USDC
  const expectedAsset = chainConfig.knownAssets.find(a => a.symbol === "USDC");
  if (expectedAsset && params.asset.toLowerCase() !== expectedAsset.address.toLowerCase()) {
    errors.push("Delta-Neutral only supports USDC as deposit asset on HyperEVM");
  }

  // Venue config
  errors.push(...validateVenueConfig(params.venueConfig, "DN"));

  // Risk
  if (params.targetReserveBps > 10000n) errors.push("Reserve must be <= 100%");
  if (params.maxDeltaBps > 10000n) errors.push("Max delta must be <= 100%");

  // Kelly (critical constraints from contract)
  const k = params.kellyConfig;
  if (k.fundingDivisor === 0) errors.push("Funding divisor cannot be 0");
  if (k.timeHorizonDays === 0) errors.push("Time horizon cannot be 0");
  if (k.ethVolatilityWad === 0n) errors.push("Volatility cannot be 0");
  if (k.liquidationLossWad >= 1_000_000_000_000_000_000n) errors.push("Liquidation loss must be < 100%");
  if (k.rebalanceThresholdWad > 1_000_000_000_000_000_000n) errors.push("Rebalance threshold must be <= 100%");
  if (k.minBenefitWad > 1_000_000_000_000_000_000n) errors.push("Min benefit must be <= 100%");
  if (k.sizeImpactMultiplierWad < 1_000_000_000_000_000_000n) errors.push("Size impact multiplier must be >= 1x");
  if (k.asymmetricRebalanceThresholdBps > 10000) errors.push("Asymmetric threshold must be <= 10000");

  // Automation
  const a = params.automationConfig;
  if (a.maxOrderSlippageBps > 10000) errors.push("Max order slippage must be <= 10000");
  if (a.maxOracleDivergenceBps > 10000) errors.push("Max oracle divergence must be <= 10000");
  if (a.maxMarginUsageBps === 0 || a.maxMarginUsageBps > 10000) errors.push("Margin usage must be 1-10000");
  if (!a.hyperCoreVault || a.hyperCoreVault === ZERO) errors.push("HyperCore vault address required");

  return errors;
}

function validatePTLoopParams(
  params: PTLoopDeploymentParams,
  selectedMarket: PendleMarketInfo | null
): string[] {
  const errors: string[] = [];
  const ZERO = "0x0000000000000000000000000000000000000000";

  // Common validations
  if (!params.owner || params.owner === ZERO) errors.push("Owner required");
  if (!params.asset || params.asset === ZERO) errors.push("Asset required");
  if (!params.strategyIdData || params.strategyIdData === "0x") errors.push("Strategy ID required");
  if (!params.absoluteCap || params.absoluteCap === 0n) errors.push("Absolute cap required");
  if (!params.relativeCap || params.relativeCap === 0n) errors.push("Relative cap required");
  if (!params.name) errors.push("Vault name required");
  if (!params.symbol) errors.push("Vault symbol required");

  // Asset constraint: PT Loop asset MUST match market underlying
  if (selectedMarket && params.asset.toLowerCase() !== selectedMarket.underlyingAsset.toLowerCase()) {
    errors.push(`Asset must be ${selectedMarket.underlyingSymbol} (${selectedMarket.underlyingAsset}) to match the selected Pendle market`);
  }

  // Venue config
  errors.push(...validateVenueConfig(params.venueConfig, "PT"));

  // PT Loop specific
  if (!params.market || params.market === ZERO) errors.push("Pendle market required");
  if (!params.ptToken || params.ptToken === ZERO) errors.push("PT token required");
  if (params.targetReserveBps > 10000n) errors.push("Reserve must be <= 100%");
  if (params.maxUnwindSlippageBps > 10000n) errors.push("Unwind slippage must be <= 100%");
  if (params.automationConfig.maxEntrySlippageBps > 10000) errors.push("Entry slippage must be <= 10000");

  return errors;
}
```

---

## 8. Post-Deployment Monitoring

After deployment, the dashboard should show:

### Read from deployed contracts

```typescript
// Vault state
const totalAssets = await vault.read.totalAssets();
const totalSupply = await vault.read.totalSupply();
const sharePrice = totalSupply > 0n ? (totalAssets * 10n**18n) / totalSupply : 10n**18n;

// Sleeve state
const idleAssets = await sleeve.read.getIdleAssets();
const [cachedValue, cachedTimestamp, isStale] = await sleeve.read.getCachedValuation();
const activeStrategies = await sleeve.read.getActiveStrategies();
const realAssets = await sleeve.read.realAssets();

// Controller state (DN)
const spec = await controller.read.getStrategySpec();
const kellyConfig = await controller.read.getKellyConfig();

// Queue state (DN)
const totalProtected = await queue.read.totalProtectedAssets();
const totalReserved = await queue.read.totalReservedLocalAssets();
```

---

## 9. File References

| File | Purpose |
|------|---------|
| `src/factories/StrategyVaultFactory.sol` | Main factory contract |
| `src/strategies/StrategyTypes.sol` | All param structs and enums |
| `src/controllers/DeltaNeutralController.sol` | DN controller with validation |
| `src/controllers/PTLoopController.sol` | PT controller with validation |
| `src/VaultTimeLockWrapper.sol` | 7-day lock wrapper |
| `src/queues/AsyncWithdrawalQueue.sol` | Async redemption queue |
| `script/ovault/StrategyLaunchpadScriptBase.s.sol` | Deployment script (env var reference) |
| `docs/OVAULT_FRONTEND_INTEGRATION.md` | Existing deposit/withdraw integration guide |
| `test/strategy/StrategyVaultFactory.t.sol` | Factory tests (example params) |
| `test/strategy/StrategyControllers.t.sol` | E2E strategy tests |

---

## 10. Implementation Checklist

### Critical Path (must-haves)
- [ ] Chain config registry with factory addresses, **venue configs (CoreWriter/L1Read for HL, PendleRouter/StaticQuoter for Pendle)**, and known assets
- [ ] **Venue address pre-population** — users must never manually enter venue addresses
- [ ] **Asset constraint enforcement** — DN locked to HyperEVM USDC, PT auto-resolved from market underlying
- [ ] Archetype selection screen with chain enforcement (prompt wallet chain switch)
- [ ] Vault identity form (name, symbol, asset — with constraints above)
- [ ] Governance form (owner, manager, curator, timelock toggle)
- [ ] DN config form: spotSideMode, reserve/delta sliders, Kelly preset selector, advanced toggle
- [ ] PT config form: chain/market selector, auto-populate PT token + asset from market, slippage sliders
- [ ] Client-side validation matching on-chain constraints (venue, asset, kelly, automation)
- [ ] Review screen with full param summary **including resolved venue addresses**
- [ ] Deploy transaction with receipt parsing
- [ ] Post-deploy success screen with all deployed addresses (vault, sleeve, controller, wrapper, queue)
- [ ] Event listener for `StrategyVaultDeployed` + `AsyncWithdrawalQueueDeployed`
- [ ] Error handling for tx revert (`InvalidAddress`, `InvalidConfig`)

### Nice-to-haves
- [ ] Pendle market registry per chain (fetch from Pendle API or hardcode known markets)
- [ ] Hyperliquid automation config presets per asset pair
- [ ] Gas estimation before deploy
- [ ] Deterministic address preview (predict clone addresses before tx)
