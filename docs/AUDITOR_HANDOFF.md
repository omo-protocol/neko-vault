# Auditor Handoff

## Purpose

This document is the shortest reliable path for an auditor or new reviewer to understand the current codebase.

The repo has recently been consolidated around the factory-driven launchpad flow. Legacy offchain keeper code, emergency monitor/gate systems, wrapper experiments, and manual deployment surfaces were removed. The current source of truth is the Solidity code under `src/`, the rollout scripts under `script/ovault/`, and the retained tests under `test/`.

## Important orientation

- Current launchpad entrypoint: `src/factories/StrategyVaultFactory.sol`
- Supported strategy kinds:
  - `DeltaNeutral`
  - `PTLoop`
- Same-chain valuation is now controller-driven and onchain-first
- Cross-chain valuation is async and snapshot-based
- Offchain valuer support still exists, but it is optional and no longer required for same-chain strategies
- Optional timelock wrapper still exists:
  - `src/VaultTimeLockWrapper.sol`
  - `src/gates/WrapperOnlySendAssetsGate.sol`

## Source-of-truth guidance

Please treat the following as authoritative, in this order:

1. Solidity contracts in `src/`
2. Launchpad scripts in `script/ovault/`
3. Retained tests in `test/`

Several older docs in `docs/` still describe removed flows such as the Python keeper / emergency monitoring system. They are useful for historical context only and should not override the code.

## High-level architecture

The system is a strategy-vault launchpad built from four main layers:

1. **Vault core**
   - `src/VaultV2.sol`
   - ERC-4626 style vault with owner / curator / allocator roles, caps, fees, gates, and liquidity adapter hooks

2. **Sleeve / execution adapter**
   - `src/adapters/UniversalAdapterEscrow.sol`
   - Holds strategy funds, tracks allocations and external deposits, executes whitelisted external calls, and reports `realAssets()`

3. **Strategy controller**
   - `src/controllers/DeltaNeutralController.sol`
   - `src/controllers/PTLoopController.sol`
   - Each controller owns strategy-specific logic for reserve policy, automatic allocation / unwind quoting, and onchain valuation

4. **Launchpad / deployment / async infra**
   - `src/factories/StrategyVaultFactory.sol`
   - `src/queues/AsyncWithdrawalQueue.sol`
   - `src/ovault/RemotePpsSnapshotStore.sol`
   - `src/ovault/RemotePpsSnapshotSender.sol`
   - optional omnichain infra in `src/ovault/`

## Directory map

### Core vault

- `src/VaultV2.sol`
- `src/VaultV2Factory.sol`
- `src/interfaces/`
- `src/libraries/`

### Strategy launchpad

- `src/factories/StrategyVaultFactory.sol`
- `src/strategies/StrategyTypes.sol`

### Sleeve / adapter layer

- `src/adapters/UniversalAdapterEscrow.sol`
- `src/adapters/UniversalAdapterEscrowFactory.sol`
- `src/adapters/interfaces/`

### Controllers

- `src/controllers/StrategyControllerInterfaces.sol`
- `src/controllers/DeltaNeutralController.sol`
- `src/controllers/PTLoopController.sol`
- `src/controllers/venue_specific/hyperliquid/*`
- `src/controllers/venue_specific/pendle/*`

### Async / omnichain / remote PPS

- `src/queues/AsyncWithdrawalQueue.sol`
- `src/ovault/AsyncWithdrawalSettlementComposer.sol`
- `src/ovault/RemotePpsSnapshotStore.sol`
- `src/ovault/RemotePpsSnapshotSender.sol`
- `src/ovault/ShareOFTAdapter.sol`
- `src/ovault/VaultComposerSync.sol`
- `src/ovault/{AssetOFT,ShareOFT}.sol`

### Optional valuation fallback

- `src/valuers/UniversalValuerOffchain.sol`

## Canonical deployment flow

The canonical deployment surface is:

- `script/ovault/RunStrategyTestnetRollout.s.sol`
- `script/ovault/StrategyLaunchpadScriptBase.s.sol`

`RunStrategyTestnetRollout` supports four actions:

1. deploy strategy vault
2. deploy spoke OFTs
3. configure omnichain peers / options
4. deploy remote PPS reporter

The factory is the key deployment contract:

- `StrategyVaultFactory.createDeltaNeutralVault(...)`
- `StrategyVaultFactory.createPTLoopVault(...)`

During deployment the factory:

1. creates the `VaultV2`
2. deploys the sleeve via `UniversalAdapterEscrowFactory`
3. deploys the controller
4. optionally deploys:
   - `VaultTimeLockWrapper`
   - `WrapperOnlySendAssetsGate`
   - `AsyncWithdrawalQueue`
   - `AsyncWithdrawalSettlementComposer`
   - `ShareOFTAdapter`
   - `VaultComposerSync`
   - `RemotePpsSnapshotStore`
5. configures caps, whitelists, liquidity adapter, queue hook, and roles
6. transfers sleeve ownership and final vault ownership / curation to the requested addresses

## Strategy model

The launchpad currently assumes one controller-managed strategy per sleeve.

Relevant types live in:

- `src/strategies/StrategyTypes.sol`

Important structs:

- `DeltaNeutralDeploymentParams`
- `PTLoopDeploymentParams`
- `ChainManifest`
- `VenueConfig`
- `Deployment`
- unwind / rebalance quote structs

`ChainManifest` is the cross-chain manifest that ties together:

- chain id
- LayerZero eid
- sleeve
- asset OFT
- share OFT
- home-chain marker

## Runtime flow: deposits and allocation

### Core path

1. User deposits into `VaultV2`
2. Vault can forward funds to its configured liquidity adapter
3. For launchpad vaults, the configured liquidity adapter is normally the sleeve
4. Controller-specific `liquidityData()` tells the sleeve which strategy id is being targeted

Key files:

- `src/VaultV2.sol`
- `src/adapters/UniversalAdapterEscrow.sol`
- `src/controllers/{DeltaNeutralController,PTLoopController}.sol`

### Important security note

Deposit-triggered venue entry was intentionally removed.

In `UniversalAdapterEscrow.allocate(...)`, automatic allocation only runs when:

- the caller path is `IVaultV2.allocate.selector`
- automation flags enable it

This means ordinary user deposits do not automatically push capital into strategy execution, which avoids the previous deposit-triggered MEV surface.

## Runtime flow: sleeve accounting

The sleeve tracks two distinct quantities:

- `allocations[strategyId]`
- `externalDeposits[strategyId]`

Conceptually:

- `allocations` = assets that the vault has allocated into the sleeve for the strategy
- `externalDeposits` = assets the sleeve has pushed out into external venues and is still tracking there

Important sleeve fields / methods:

- `totalAllocations`
- `totalExternalDeposits`
- `allocate(...)`
- `deallocate(...)`
- `executeStrategy(...)`
- `withdrawFromStrategy(...)`
- `recordSettlement(...)`
- `realAssets()`
- `refreshCachedValuation()`
- `_executeMulticall(...)`
- `_resolveCurrentValuation()`

`_executeMulticall(...)` enforces per-target / per-selector whitelist checks and tracks balance deltas. A balance drop is treated as funds moving out to external venues and increments `externalDeposits`.

## Runtime flow: valuation

### Current valuation model

`UniversalAdapterEscrow.realAssets()` is onchain-first.

Valuation resolution order:

1. try controller onchain valuation via `IOnchainStrategyValuer.quoteCurrentAssets()`
2. if unavailable and an external valuer exists, fall back to offchain valuer paths
3. if stale or emergency conditions apply, apply conservative handling / haircut

Key implementation:

- `src/adapters/UniversalAdapterEscrow.sol`
  - `_resolveCurrentValuation()`
  - `_aggregateOnchainStrategyValue()`

### Delta-neutral valuation

`DeltaNeutralController.quoteCurrentAssets()` includes:

- idle sleeve balance
- spot inventory
- Hyperliquid margin account equity
- remote snapshot assets, if configured

Key file:

- `src/controllers/DeltaNeutralController.sol`

### PT-loop valuation

`PTLoopController.quoteCurrentAssets()` includes:

- idle sleeve balance
- PT position quoted via Pendle static quoter
- remote snapshot assets, if configured

Key file:

- `src/controllers/PTLoopController.sol`

### Offchain valuer status

`src/valuers/UniversalValuerOffchain.sol` still exists, but it is no longer the required path for same-chain strategies. It should be reviewed as an optional fallback / legacy-compatible surface, not as the primary pricing path for launchpad strategies.

## Runtime flow: sync and manager actions

Each controller now separates:

- `sync()` -> strategy maintenance / rebalance execution
- `syncPPS()` -> refresh cached valuation used for PPS updates

These are restricted to `vaultManager`.

This separation is important because:

- rebalancing and valuation refresh are no longer coupled
- cron-style PPS refresh can happen without strategy repositioning

## Runtime flow: withdrawals

There are two withdrawal modes:

### 1. Local liquidity path

If enough local liquidity exists in vault + sleeve balances, withdrawals can complete directly.

### 2. Async path

Async withdrawals are handled by:

- `src/queues/AsyncWithdrawalQueue.sol`

Important functions:

- `requestRedeem(...)`
- `requestWithdraw(...)`
- `creditSettlement(...)`
- `claim(...)`
- `refreshRequest(...)`

Behavior:

1. user escrows shares into the queue
2. queue reserves currently available local liquidity
3. if not enough liquidity exists, queue asks the controller to initiate an async unwind
4. settlement funds are credited later
5. once claimable, the queue redeems escrowed shares through the vault

The queue’s solvency / fairness depends on:

- live `previewRedeem(...)`
- reserved local liquidity tracking
- request ordering in `_isClaimableByCurrentLiquidity(...)`
- duplicate-settlement protection via `processedGuids`

## Cross-chain PPS and remote settlement

### Remote PPS snapshots

Remote valuation is async.

Home chain:

- `src/ovault/RemotePpsSnapshotStore.sol`

Remote / spoke chain:

- `src/ovault/RemotePpsSnapshotSender.sol`

Flow:

1. remote manager calls `pushSnapshot(...)`
2. sender reads `IAdapter(sleeve).realAssets()`
3. LayerZero message is sent to home chain
4. `RemotePpsSnapshotStore.lzReceive(...)` stores snapshot by source eid
5. controllers include `quoteRemoteAssets()` in `quoteCurrentAssets()`

Audit notes:

- peer wiring is critical
- staleness is enforced via `MAX_SNAPSHOT_AGE`
- health degrades when snapshots are missing or stale

### Cross-chain async withdrawal settlement

If LayerZero async settlement is enabled, the factory can deploy:

- `src/ovault/AsyncWithdrawalSettlementComposer.sol`

It:

- receives composed OFT settlement messages
- forwards assets to the sleeve
- credits the async withdrawal queue
- stores recoverable pending settlements if processing fails

## Strategy-specific surfaces

### DeltaNeutralController

Primary file:

- `src/controllers/DeltaNeutralController.sol`

Auxiliary files:

- `src/controllers/libraries/DeltaNeutralKellyLib.sol`
- `src/controllers/venue_specific/hyperliquid/CoreWriter.sol`
- `src/controllers/venue_specific/hyperliquid/L1Read.sol`
- `src/controllers/venue_specific/hyperliquid/HyperliquidLib.sol`

What it does:

- manages target reserve vs deployed risk
- computes Kelly-based target sizing
- quotes automatic allocation / automatic withdrawal
- performs manager-triggered `sync()`
- supports async unwind initiation for same-chain setups

Areas to inspect carefully:

- `_liveState()`
- `_quoteTargetCalls(...)`
- `_quoteUnwindExecution(...)`
- `_buildUnwindCalls(...)`
- delta-band and risk-degraded logic
- assumptions around margin equity, spot balances, and remote assets

### PTLoopController

Primary file:

- `src/controllers/PTLoopController.sol`

Auxiliary file:

- `src/controllers/venue_specific/pendle/PendleLib.sol`

What it does:

- manages local reserve vs PT deployment
- quotes PT entry and unwind
- prices PT using Pendle static quoter
- includes remote snapshot assets when configured

Areas to inspect carefully:

- `_quoteAutomaticAllocation()`
- `quoteUnloopForAssets(...)`
- `_quoteExactPtInForAssets(...)`
- slippage assumptions
- binary search / quoter dependence

### PendleLib

`src/controllers/venue_specific/pendle/PendleLib.sol` is a call-builder / interface library.

It does not hold state. It packages:

- Pendle router interfaces
- static quoter interfaces
- helper constructors for `TokenInput`, `TokenOutput`, and default approximation params
- helper builders for approve / swap / open-loop / close-loop call bundles

For auditors, this file is mainly about call correctness and ABI/data packing rather than stateful accounting.

## Roles and trust boundaries

### Vault roles

Defined in `VaultV2`:

- owner
- curator
- allocators
- sentinels

### Launchpad ownership model

During deployment:

- the factory temporarily owns / curates the vault

After deployment:

- vault owner is the final `owner`
- curator is final `curator` or owner fallback
- controller is an allocator
- sleeve owner is transferred to the final owner
- `vaultManager` is a separate operational role for `sync()` / `syncPPS()` if configured

### Trust boundaries to focus on

1. `VaultV2` trusts adapter `realAssets()` and adapter accounting
2. `UniversalAdapterEscrow` trusts controller quotes when onchain valuation succeeds
3. if configured, sleeve also trusts `UniversalValuerOffchain`
4. `RemotePpsSnapshotStore` trusts configured LayerZero endpoint + peers
5. `AsyncWithdrawalQueue` trusts controller async initiation and settlement hook credits
6. whitelisted external calls in the sleeve are still powerful despite whitelist gating

## What was removed and should not distract the auditor

The current launchpad architecture no longer depends on:

- Python offchain keeper infrastructure
- security monitor contracts
- emergency gate system
- legacy top-level deployment scripts
- older wrapper experiments such as `UniversalTokenWrapper`

The remaining wrapper/gate pieces that still matter are only:

- `src/VaultTimeLockWrapper.sol`
- `src/gates/WrapperOnlySendAssetsGate.sol`

## Likely high-risk areas

If audit time is limited, prioritize these:

1. `src/VaultV2.sol`
   - adapter accounting
   - total asset calculation
   - deallocate / forceDeallocate
   - fee accrual

2. `src/adapters/UniversalAdapterEscrow.sol`
   - allocation vs external deposit accounting
   - whitelisted multicall execution
   - cached valuation / emergency mode behavior
   - settlement recording
   - onchain vs offchain valuation selection

3. `src/factories/StrategyVaultFactory.sol`
   - temporary ownership model
   - deployment / wiring correctness
   - chain manifest validation
   - whitelist configuration

4. Controllers
   - rebalance / unwind sizing
   - manager-only sync surfaces
   - venue-specific call construction
   - pricing assumptions

5. `src/queues/AsyncWithdrawalQueue.sol`
   - reservation logic
   - claimability ordering
   - duplicate GUID protection
   - interaction with changing PPS

6. Cross-chain components
   - peer config
   - stale snapshot handling
   - compose-based settlement recovery

## Recommended audit reading order

1. `src/strategies/StrategyTypes.sol`
2. `src/controllers/StrategyControllerInterfaces.sol`
3. `src/factories/StrategyVaultFactory.sol`
4. `src/VaultV2Factory.sol`
5. `src/VaultV2.sol`
6. `src/adapters/UniversalAdapterEscrow.sol`
7. `src/controllers/DeltaNeutralController.sol`
8. `src/controllers/PTLoopController.sol`
9. `src/controllers/venue_specific/pendle/PendleLib.sol`
10. `src/controllers/venue_specific/hyperliquid/*`
11. `src/queues/AsyncWithdrawalQueue.sol`
12. `src/ovault/RemotePpsSnapshotStore.sol`
13. `src/ovault/RemotePpsSnapshotSender.sol`
14. `src/ovault/AsyncWithdrawalSettlementComposer.sol`
15. `src/VaultTimeLockWrapper.sol`
16. `src/valuers/UniversalValuerOffchain.sol`

## Test files worth using as executable documentation

### Launchpad / strategy flow

- `test/strategy/StrategyVaultFactory.t.sol`
- `test/strategy/StrategyControllers.t.sol`
- `test/script/StrategyLaunchpadScripts.t.sol`

### Core vault behavior

- `test/MainFunctionsTest.sol`
- `test/SettersTest.sol`
- `test/AllocateTest.sol`
- `test/AccrueInterestTest.sol`
- `test/ExchangeRateTest.sol`
- `test/ForceDeallocateTest.sol`

### Sleeve / security / async coverage

- `test/adapters/CachePoisoningSecurityFix.t.sol`
- `test/adapters/EmergencyModeSecurityFix.t.sol`
- `test/adapters/YieldAccountingTest.t.sol`
- `test/unit/UniversalAdapterEscrow*.t.sol`
- `test/VaultTimeLockWrapper.t.sol`

## Suggested audit questions

1. Does `VaultV2.totalAssets()` remain correct across all adapter and queue states?
2. Can sleeve accounting drift between `allocations`, `externalDeposits`, balance, and valuation?
3. Are whitelist constraints sufficient for the venue call surfaces actually used by controllers?
4. Can async withdrawals become unfair or insolvent under changing PPS / liquidity conditions?
5. Can stale or malicious remote snapshots distort home-chain valuation?
6. Are controller sizing / unwind assumptions robust under adversarial or broken venue data?
7. Is the factory handoff sequence safe under partial configuration or misconfigured manifests?

## Fast walkthrough for a live review with auditors

If you are screensharing the codebase, the fastest verbal walkthrough is:

1. open `StrategyTypes.sol` to define the system vocabulary
2. open `StrategyVaultFactory.sol` to show what gets deployed and how roles are handed off
3. open `VaultV2.sol` to show the base vault and adapter model
4. open `UniversalAdapterEscrow.sol` to explain sleeve accounting and valuation
5. open the relevant controller (`DeltaNeutralController` or `PTLoopController`)
6. open `AsyncWithdrawalQueue.sol` for non-instant exits
7. open `RemotePpsSnapshotStore.sol` / `RemotePpsSnapshotSender.sol` for cross-chain valuation
8. finish with the matching strategy tests

That sequence gives an auditor the system in the same order the code executes.
