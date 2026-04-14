# Auditor Handoff

## Purpose

This document is the shortest accurate orientation for the current `simplified-demo-factory-vaults` branch.

It is intentionally branch-specific. The important point for auditors is that this branch is now a **same-chain-only** launchpad. Older omnichain / LayerZero descriptions are not relevant here.

## Scope and current branch assumptions

- Launchpad entrypoint: `src/factories/StrategyVaultFactory.sol`
- Supported strategy kinds:
  - `DeltaNeutral`
  - `PTLoop`
- Deployment model: factory-deployed **EIP-1167 clones**
- Same-chain only:
  - no LayerZero
  - no OFTs
  - no remote PPS store/sender
  - `src/ovault/` is intentionally empty on this branch
- Sleeve valuation is purely agent-based: each strategy's agent must implement `quoteCurrentAssets()` (see `IOnchainStrategyValuer`)
- `UniversalValuerOffchain` still exists as an independent contract but the sleeve no longer reads from it directly
- Optional timelock surfaces still exist:
  - `src/VaultTimeLockWrapper.sol`
  - `src/gates/WrapperOnlySendAssetsGate.sol`

## Source of truth

Please treat these as authoritative, in order:

1. Solidity in `src/`
2. Tests in `test/`
3. Scripts in `script/`

Older docs in `docs/` may still describe removed omnichain flows and should not override the code.

## High-level architecture

The live system is four layers:

1. **Vault core**
   - `src/VaultV2.sol`
   - ERC-4626-style vault with owner / curator / allocator roles, caps, fees, gates, and adapter hooks

2. **Sleeve / execution adapter**
   - `src/adapters/UniversalAdapterEscrow.sol`
   - Holds strategy capital, executes whitelisted venue calls, tracks external exposure, and reports `realAssets()`

3. **Strategy controller**
   - `src/controllers/DeltaNeutralController.sol`
   - `src/controllers/PTLoopController.sol`
   - Owns reserve policy, automatic allocation / unwind quoting, and onchain valuation

4. **Exit / wrapper layer**
   - `src/queues/AsyncWithdrawalQueue.sol` (DeltaNeutral only on this branch)
   - `src/VaultTimeLockWrapper.sol` (optional)
   - `src/gates/WrapperOnlySendAssetsGate.sol` (optional)

## What the factory deploys

The factory is the canonical deployment surface:

- `StrategyVaultFactory.createDeltaNeutralVault(...)`
- `StrategyVaultFactory.createPTLoopVault(...)`

For each vault it creates:

1. a `VaultV2` clone
2. a `UniversalAdapterEscrow` clone
3. the relevant controller clone
4. optional timelock wrapper + wrapper gate
5. for DeltaNeutral only, an `AsyncWithdrawalQueue` clone

Then it:

1. whitelists the strategy venue calls on the sleeve
2. registers the controller as a vault allocator
3. sets the sleeve as liquidity adapter with controller `liquidityData()`
4. transfers sleeve ownership and final vault ownership / curation to requested addresses

## Key files

### Core

- `src/VaultV2.sol`
- `src/VaultV2Admin.sol`
- `src/VaultV2Factory.sol`

### Launchpad

- `src/factories/StrategyVaultFactory.sol`
- `src/strategies/StrategyTypes.sol`

### Sleeve

- `src/adapters/UniversalAdapterEscrow.sol`
- `src/adapters/UniversalAdapterEscrowStorage.sol`
- `src/adapters/UniversalAdapterEscrowInternals.sol`
- `src/adapters/UniversalAdapterEscrowValuation.sol`
- `src/adapters/libraries/AdapterAccountingLib.sol`
- `src/adapters/libraries/ContractCodeCheckerLib.sol`

### Controllers

- `src/controllers/DeltaNeutralController.sol`
- `src/controllers/DeltaNeutralControllerBase.sol`
- `src/controllers/PTLoopController.sol`
- `src/controllers/libraries/ControllerLiquidityLib.sol`
- `src/controllers/libraries/DeltaNeutralKellyLib.sol`
- `src/controllers/venue_specific/hyperliquid/*`
- `src/controllers/venue_specific/pendle/*`

### Exit / wrapper

- `src/queues/AsyncWithdrawalQueue.sol`
- `src/VaultTimeLockWrapper.sol`
- `src/gates/WrapperOnlySendAssetsGate.sol`

### Independent offchain valuer (not read by sleeve)

- `src/valuers/UniversalValuerOffchain.sol`

## Deposit and allocation flow

### User deposits

The important behavioral change is:

- **ordinary user deposits do not automatically open venue positions**

Users deposit into `VaultV2`, receive vault shares, and increase local liquidity. Capital only enters the strategy when an allocator/controller path explicitly calls `vault.allocate(...)` or when the manager calls controller `sync()`.

This was kept specifically to avoid deposit-triggered MEV / entry manipulation.

### Controller liquidity data

Each controller returns `liquidityData()` as:

- `abi.encode(strategyId, automationFlags, emptyCalls)`

Current automation flags:

- `DeltaNeutral`: `1`
  - auto-allocation enabled
  - direct user exits do **not** auto-unwind
- `PTLoop`: `3`
  - auto-allocation enabled
  - allocator-driven deallocation paths may use auto-withdraw logic

### Reserve policy

Reserve logic is centralized in `ControllerLiquidityLib`.

The key concept is:

- `requiredLocalLiquidity = max(targetReserve(totalAssets), queue.totalProtectedAssets())`

That means controller allocation decisions preserve both:

1. the configured reserve floor
2. already-promised async withdrawal liquidity

Important behavior:

- if queue lookup fails, `protectedWithdrawalLiquidity()` fail-closes to `type(uint256).max`
- this drives `availableToAllocate(...)` to zero
- so reserve accounting fails closed instead of allocating too much

### Sleeve allocation

`UniversalAdapterEscrow.allocate(...)`:

1. decodes `strategyId` + automation flags
2. increments `allocations[strategyId]` and `totalAllocations`
3. if automation is enabled on a vault allocator path, asks the controller for `quoteAutomaticAllocation(...)`
4. executes those whitelisted calls via `_executeMulticall(...)`

The sleeve explicitly rejects non-empty liquidity-call payloads for the generic vault allocation path. Strategy execution comes from controller quotes, not user-supplied calldata.

## Sleeve accounting model

The sleeve tracks:

- `allocations[strategyId]`
- `externalDeposits[strategyId]`
- `settlementSurplusAssets`
- `totalAllocations`
- `totalExternalDeposits`

Interpretation:

- `allocations` = vault capital assigned to the strategy
- `externalDeposits` = capital the sleeve has pushed to the venue and still tracks externally
- `settlementSurplusAssets` = returned assets beyond tracked external exposure

Important accounting paths:

### Funds moving out to venue

`_recordMulticallBalanceChange(...)` treats a sleeve balance decrease as venue deployment:

1. consumes `settlementSurplusAssets` first
2. then increments `externalDeposits[strategyId]`
3. increments `totalExternalDeposits`
4. marks valuation dirty

### Funds returning from venue

`_recordWithdrawnAssets(...)`:

1. reduces `externalDeposits[strategyId]`
2. reduces `totalExternalDeposits`
3. any excess return becomes `settlementSurplusAssets`
4. marks valuation dirty

### Async settlement credits

`recordSettlement(...)` is queue-only:

1. reduces tracked external exposure when settlement assets come back
2. forwards full assets to the vault if the strategy allocation is already zero
3. otherwise books any excess as `settlementSurplusAssets`
4. marks valuation dirty

## Valuation model

### How `realAssets()` is resolved

`UniversalAdapterEscrow.realAssets()` is driven by `UniversalAdapterEscrowValuation`.

The sleeve exclusively uses **agent-based onchain valuation**. Each strategy's agent must implement `IOnchainStrategyValuer.quoteCurrentAssets()`, which returns `(uint256 assets, bool healthy)`. The sleeve aggregates across all active strategies via `_aggregateOnchainStrategySnapshot()`.

Resolution order:

1. aggregate per-strategy agent quotes via `quoteCurrentAssets()` on each active strategy's agent
2. if any agent reports `healthy=false`, the aggregate is marked as stale data
3. if the aggregate has stale data or emergency mode is enabled, apply the emergency haircut (5%)
4. if no valuation exists and `totalAllocations == 0`, return only tracked surplus
5. if no valuation exists and there are live allocations:
   - revert `ValuationUnavailable` unless emergency mode is enabled
   - in emergency mode, use conservative tracked-asset fallback with haircut

If any single agent call fails (reverts or returns malformed data), the entire aggregation fails, which triggers path 5.

### Agent validation

`setStrategy(...)` requires each agent to implement `quoteCurrentAssets()`. The check (`_supportsOnchainValuationAgent`) verifies the agent has code and can either successfully call `quoteCurrentAssets()` or contains the pushed selector in its bytecode (including behind a minimal proxy).

### Important valuation details

- `EMERGENCY_HAIRCUT = 500` (5% in basis points)
- accounting-changing events (`_markValuationDirty()`) clear `cachedValuationTimestamp` to invalidate stale cache
- `refreshCachedValuation()` is explicit; nothing auto-refreshes the cache on allocation / deallocation
- `refreshCachedValuation()` accepts any value returned by the agent aggregation (no sanity bounds)
- the offchain valuer (`UniversalValuerOffchain`) still exists as an independent contract but the sleeve does **not** read from it; it may be used by external monitoring or keeper infrastructure

### `quoteSnapshotState()` semantics

`quoteSnapshotState()` reports:

- `(value, 0, healthy)` where `healthy = !hasStaleData && !emergencyMode && valuationTimestamp != 0`

Since agent-based valuations always return `snapshotTimestamp = 0`, `quoteSnapshotState()` always reports `healthy=false`. This is deliberate: onchain controller quotes are usable for `realAssets()`, but they are not timestamped oracle snapshots.

## DeltaNeutral valuation and flow

Primary files:

- `src/controllers/DeltaNeutralController.sol`
- `src/controllers/DeltaNeutralControllerBase.sol`

### What valuation includes

`quoteCurrentAssets()` returns:

- idle sleeve asset balance
- spot inventory
- **positive Hyperliquid margin account equity**

It does **not** rely on a remote snapshot on this branch.

### Health behavior

DeltaNeutral returns `healthy=false` when risk is degraded, specifically when:

- oracle price and mark price diverge beyond `maxOracleDivergenceBps`
- or margin usage exceeds `maxMarginUsageBps`
- or account value is non-positive

### Sync / maintenance

`sync()` is `vaultManager`-only and:

1. reads full Hyperliquid live state
2. computes Kelly / rebalance target
3. builds venue calls
4. executes them through the sleeve

`syncPPS()` is separate and only refreshes cached valuation.

### DeltaNeutral withdrawals

This branch deploys an `AsyncWithdrawalQueue` for DeltaNeutral vaults.

Flow:

1. user calls `requestRedeem(...)` or `requestWithdraw(...)`
2. queue escrows shares
3. queue reserves currently available local liquidity
4. if short, queue calls `controller.initiateAsyncWithdrawal(shortfallAssets)`
5. controller builds Hyperliquid unwind calls and executes them through the sleeve
6. settlement is later credited with `creditSettlement(...)`
7. `claim(...)` redeems escrowed shares when request becomes claimable

The queue tracks:

- `totalReservedLocalAssets`
- `totalProtectedAssets`

and uses `_isClaimableByCurrentLiquidity(...)` to maintain ordering under changing `previewRedeem(...)`.

## PTLoop valuation and flow

Primary file:

- `src/controllers/PTLoopController.sol`

### What valuation includes

`quoteCurrentAssets()` returns:

- idle sleeve asset balance
- PT balance marked using `IPendleStaticQuoter.getPtToAssetRate(market)`

If the PT rate is zero, the quote is unhealthy.

The PT valuation intentionally uses the **spot PT-to-asset rate**, not a conservative redeem quote.

### Sync / allocation

`sync()` is `vaultManager`-only and:

1. reads idle assets and PT balance
2. estimates total assets using current PT spot rate
3. computes `availableToAllocate(...)` after reserve protection
4. builds Pendle open-loop calls
5. executes them through the sleeve

`_quoteExactPtInForAssets(...)` seeds its search using the current PT spot rate, then refines with the static quoter.

### PTLoop withdrawals

PTLoop does **not** deploy an async withdrawal queue on this branch.

Behavior is:

- local liquidity can satisfy normal user exits
- direct user `withdraw` / `redeem` does **not** trigger a strategy unwind
- if reserve is insufficient, the user exit reverts
- owner-managed liquidity preparation is done with `prepareWithdrawal(...)`

`prepareWithdrawal(...)` can:

1. call `sleeve.withdrawFromStrategy(...)`
2. call `vault.deallocate(...)`
3. leave liquid assets locally available for user withdrawals

`quoteAutomaticWithdrawal(...)` still exists, but it is for controller/allocator-driven deallocation paths, not for letting arbitrary users force a live venue unwind from `withdraw()` / `redeem()`.

## Timelock wrapper flow

If timelock is enabled, deposits route through:

- `VaultTimeLockWrapper`

Key behaviors:

- wrapped balances preserve FIFO batch timing
- `unwrap(...)` converts unlocked wrapper shares into vault shares
- `unwrapToApproval(...)` allows pull-based integrations to take vault shares

For wrapped DeltaNeutral vaults, `AsyncWithdrawalQueue.requestRedeemFrom(...)` exists so the queue can pull approved vault shares directly from the wrapper flow.

## Roles and trust boundaries

### Vault roles

Defined in `VaultV2`:

- owner
- curator
- allocators
- sentinels

### Launchpad handoff model

During deployment the factory temporarily configures the vault and sleeve.

After deployment:

- vault owner = final `owner`
- curator = final `curator` or owner fallback
- controller = allocator
- sleeve owner = final owner
- `vaultManager` = operational role for `sync()` / `syncPPS()`

### Core trust boundaries

1. `VaultV2` trusts sleeve `realAssets()` and adapter accounting
2. `UniversalAdapterEscrow` trusts whitelisted venue calls and agent `quoteCurrentAssets()` responses
3. each strategy agent is the sole valuation source for its strategy; a compromised agent can misreport value
4. DeltaNeutral queue trusts controller async unwind initiation plus settlement credits
5. wrapper flows trust FIFO batch accounting and lock enforcement

## What was removed on this branch

These should **not** distract the audit for this branch:

- LayerZero peers / manifests
- remote PPS store / sender
- OFT settlement paths
- async compose settlement plumbing
- older keeper / monitor / emergency infra outside the current contracts

## Highest-value audit targets

If time is limited, prioritize:

1. `src/VaultV2.sol`
   - total asset calculation
   - adapter interactions
   - deallocate / forceDeallocate
   - fee accrual

2. `src/adapters/UniversalAdapterEscrow*.sol`
   - allocation vs external deposit accounting
   - agent-based valuation aggregation and health flag handling
   - cache invalidation (`_markValuationDirty`) and explicit refresh
   - emergency mode fallback vs normal-mode revert on agent failure
   - whitelist enforcement and codehash pinning
   - async settlement handling

3. `src/controllers/libraries/ControllerLiquidityLib.sol`
   - reserve preservation
   - queue-protected-liquidity integration
   - fail-closed behavior

4. `src/controllers/DeltaNeutralController*.sol`
   - live-state reads
   - Kelly sizing
   - unwind execution sizing
   - risk degradation behavior

5. `src/controllers/PTLoopController.sol`
   - PT pricing assumptions
   - open/close loop construction
   - unwind sizing and slippage handling

6. `src/queues/AsyncWithdrawalQueue.sol`
   - reservation logic
   - fairness ordering
   - changing PPS interaction
   - duplicate GUID protection

7. `src/VaultTimeLockWrapper.sol`
   - FIFO batch preservation
   - lock enforcement
   - unwrap / unwrapToApproval share flows

## Recommended reading order

1. `src/strategies/StrategyTypes.sol`
2. `src/controllers/StrategyControllerInterfaces.sol`
3. `src/factories/StrategyVaultFactory.sol`
4. `src/VaultV2Factory.sol`
5. `src/VaultV2.sol`
6. `src/adapters/UniversalAdapterEscrow.sol`
7. `src/adapters/UniversalAdapterEscrowInternals.sol`
8. `src/adapters/UniversalAdapterEscrowValuation.sol`
9. `src/controllers/libraries/ControllerLiquidityLib.sol`
10. `src/controllers/DeltaNeutralControllerBase.sol`
11. `src/controllers/DeltaNeutralController.sol`
12. `src/controllers/PTLoopController.sol`
13. `src/queues/AsyncWithdrawalQueue.sol`
14. `src/VaultTimeLockWrapper.sol`
15. `src/valuers/UniversalValuerOffchain.sol` (independent of sleeve; used by external monitoring only)

## Tests that act as executable documentation

### Launchpad and strategy behavior

- `test/strategy/StrategyVaultFactory.t.sol`
- `test/strategy/StrategyControllers.t.sol`

### Sleeve / valuation / exit security

- `test/unit/UniversalAdapterEscrowSecurityFixes.t.sol`
- `test/unit/UniversalAdapterEscrowValuerTrust.t.sol`
- `test/unit/UniversalAdapterEscrowDonationAttack.t.sol`
- `test/unit/UniversalAdapterEscrowLazyDeallocation.t.sol`
- `test/adapters/EmergencyModeSecurityFix.t.sol`
- `test/adapters/CachePoisoningSecurityFix.t.sol`
- `test/adapters/YieldAccountingTest.t.sol`
- `test/VaultTimeLockWrapper.t.sol`

### Core vault behavior

- `test/MainFunctionsTest.sol`
- `test/SettersTest.sol`
- `test/AllocateTest.sol`
- `test/AccrueInterestTest.sol`
- `test/ExchangeRateTest.sol`
- `test/ForceDeallocateTest.sol`

## Suggested audit questions

1. Does `VaultV2.totalAssets()` remain correct across idle, allocated, external, surplus, and queued-withdrawal states?
2. Can sleeve accounting drift between `allocations`, `externalDeposits`, `settlementSurplusAssets`, and actual balances?
3. Can a malicious or malfunctioning agent's `quoteCurrentAssets()` cause value extraction or share mispricing?
4. Is the emergency mode fallback (tracked-asset haircut) conservative enough when all agents fail?
5. Are controller reserve calculations always conservative when queue state changes or queue reads fail?
6. Can DeltaNeutral async withdrawals become unfair or insolvent under changing `previewRedeem(...)`?
7. Are PTLoop unwind and pricing assumptions robust under bad quoter output or low-liquidity markets?
8. Are whitelist and codehash checks sufficient for the venue call surfaces actually used?

## Fast walkthrough for a live review

For a quick auditor screenshare walkthrough:

1. open `StrategyTypes.sol`
2. open `StrategyVaultFactory.sol`
3. open `VaultV2.sol`
4. open `UniversalAdapterEscrow.sol`
5. open `UniversalAdapterEscrowValuation.sol`
6. open `ControllerLiquidityLib.sol`
7. open the relevant controller:
   - `DeltaNeutralControllerBase.sol` / `DeltaNeutralController.sol`
   - or `PTLoopController.sol`
8. open `AsyncWithdrawalQueue.sol` for DeltaNeutral exits
9. open `VaultTimeLockWrapper.sol` if timelock is enabled
10. finish with `StrategyControllers.t.sol`

That follows the same order the system executes at runtime.
