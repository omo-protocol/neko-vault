# Production Deployment Guide — Morpho Vaults v2 + Adapters

*(Compatible with Morpho Market v1 / Morpho Vault v1 and custom adapters like Pendle)*

This is a "full-path production manual" that covers everything from environment setup → deployment → role/timelock/caps configuration → adapter listing → testing (allocate/deallocate/realAssets/forceDeallocate) → security checklist → AI agent integration (Allocator).

---

## Note

Vault v2 is a protocol-agnostic architecture that distributes liquidity via "adapters" and computes yield based on real asset value in each accrueInterest() round (replacing the old VIC approach).
It introduces IDs & Caps, Gates, Timelocks, and forceDeallocate (in-kind redemption) for stronger non-custodial guarantees and finer-grained risk control.

---

## 0) Prerequisites

- **Dev tools:** Foundry (recommended), Node.js (for scripts/agents), Git
- **Keys/wallets:** multisig/EOAs for Owner / Curator / Allocator / Sentinel roles
- **Networks:** supported Morpho/Pendle chain (with RPC + native gas)
- **Key references:**
  - Morpho Vault v2 — Concepts & Contracts, Roles/Gates/Timelocks, Adapter management, Force-Deallocate
  - Morpho Market v1 (Morpho Blue) — supply/withdraw + market parameters
  - Pendle — PendleRouter + PT/LP Oracle (TWAP) integration
  - ERC-4626 security (Inflation Attack), EIP-2612 permit

---

## 1) Project Structure & Compilation

Start with Morpho's official deploy repo:

```bash
git clone https://github.com/morpho-org/vault-v2-deployment
cd vault-v2-deployment
forge install
```

The deploy script workflow: create VaultV2 → set Roles → deploy/list Adapter → set Caps/MaxRate → (optional) configure LiquidityAdapter + Timelocks (with sample .env).
(Note: as of writing, there's no official factory, so this flow deploys directly to instances.)

Alternative: clone morpho-org/vault-v2, compile contracts (including custom adapters like Pendle), then write your own Foundry/Hardhat deploy scripts.

---

## 2) Deploy VaultV2

### 2.1 Roles

- **Owner:** appoint Curator/Sentinels, rename token, transfer ownership
- **Curator:** manage risk config (enable/disable adapters, caps, gates, timelocks, fees) — almost all actions go through timelock
- **Allocator:** execute vault.allocate/deallocate with adapters, set maxRate
- **Sentinel:** reduce caps, emergency liquidity pulls, cancel pending timelocks

Best practice: use multisigs for Owner/Curator.

### 2.2 Setup Steps

1. Deploy VaultV2 (via script or manually)
2. Owner appoints Curator and (optional) Sentinels
3. Curator submits timelock actions for:
   - `setIsAdapter(adapter,true)`
   - `increaseCaps(ids, absoluteCap, relativeCap)`
   - (Optional) `setReceiveAssetsGate/SendAssetsGate/ReceiveSharesGate/SendSharesGate`
4. Curator/Allocator sets maxRate (APR ceiling)
5. (Optional) configure LiquidityAdapter
6. Timelock hardening: set appropriate delays, "abdicate" functions you want permanently disabled (set timelock = uint256.max)

**forceDeallocate:** in-kind redemption mechanism, permissionless, penalty ≤2% in shares. This is the cornerstone of Vault v2's non-custodial guarantee.

---

## 3) Deploy & List Adapters

Adapters = contracts that receive vault.allocate(adapter, data, assets), route to the target protocol, and return (ids, delta) for Vault accounting.

### 3.1 Morpho Market v1 Adapter (official)

- `allocate(data=abi.encode(MarketParams), assets)` → calls `IMorpho.supply`
- `deallocate(...)` → calls `IMorpho.withdraw`
- `ids()` includes adapterId / collateralToken / marketParams-id
- `realAssets()` sums `expectedSupplyAssets()` across markets

### 3.2 Pendle Adapter (custom)

- **allocate/deallocate:** decode data → Router calls (e.g. swapExactTokenForPt, add/remove LP)
- **realAssets():** use Pendle Oracles (TWAP) for PT→asset (or PT→SY→asset), LP→asset
- **ids()** should at least include adapterId / market / pt for fine-grained caps

### 3.3 Listing

1. Curator submits timelock → `setIsAdapter(adapter,true)` → wait → execute
2. Configure absolute/relative caps per adapter `ids()`
3. (Optional) use an Adapter Registry for whitelist enforcement

---

## 4) Pre-Launch Security Setup

- **ERC-4626 inflation attack hardening:** use virtual shares/initial buffer/guard + maxRate (caps APR spikes at ~200% in v2)
- **Timelocks:** per-function, with abdication for irreversible safety
- **Gates:** apply only if needed (KYC, limits) — note this reduces non-custodial purity
- **MaxRate:** choose appropriate ceiling
- **Oracles:** Pendle must use TWAP oracles; SY→asset oracle if needed
- **Morpho Blue markets:** choose only liquid markets with sane IRM/Oracle

---

## 5) Testnet Testing (mandatory)

### 5.1 Vault Functions

- ERC-4626 core (deposit/mint/withdraw/redeem/transfer/permit) + correct events
- `accrueInterest()` works both idle and with adapters

### 5.2 Adapter Tests

- **Morpho:** supply/withdraw, check ids/delta/realAssets vs expectedSupplyAssets
- **Pendle:**
  - allocate asset→PT (or LP add), check balances
  - `realAssets()` vs TWAP oracle & RouterStatic off-chain
  - deallocate PT→asset, idle returned

### 5.3 Robustness

- forceDeallocate works (≤2% penalty)
- Caps enforce correctly
- Gates enforce correctly
- Timelocks (submit, wait, execute, revoke pending)

---

## 6) AI Agent Integration (Allocator Role)

1. Assign AI agent's address as Allocator (via timelock)
2. Agent monitors events/markets, calls:

```solidity
vault.allocate(adapter, abi.encode(PendleCall{...}), assets);
vault.allocate(morphoAdapter, abi.encode(MarketParams{...}), assets);
```

Vault first transfers idle assets → adapter → protocol. Adapter returns (ids, delta) for accounting.

3. Risk boundaries: caps, maxRate, registry
4. Agent must hold gas, handle retries/slippage (Pendle: use RouterStatic/TWAP for minOut)

---

## 7) Example Playbook

1. Deploy Vault v2 via deploy script with .env (Owner/Curator/Allocator/Sentinel, timelock duration)
2. Deploy adapters:
   - **MorphoMarketV1Adapter:** link vault + morpho, approve tokens
   - **PendleAdapter:** link vault + router + oracles, approve tokens
3. List adapters: timelock → enable → caps per market/PT
4. Test allocate/deallocate: Morpho & Pendle calls, check balances + `realAssets()`
5. Mainnet launch: set timelocks, gates, maxRate, test forceDeallocate, monitor markets

---

## 8) Final Security Checklist

- Inflation-attack guard (initial buffer, virtual shares)
- Timelocks per function + abdication plan
- Gates only if necessary
- Risk-bucketed caps tested
- Morpho: liquid markets, IRM/Oracle stable
- Pendle: TWAP oracles, SY→asset oracle if needed, minOut guards

---

## 9) Monitoring & Ops

- Cron/keeper for `accrueInterest()`
- Monitor metrics: totalAssets, `realAssets()`, caps utilization, gates, timelocks
- Emergency playbook: Sentinel can deallocate/reduce caps; anyone can forceDeallocate (with penalty)

---

## Appendix — Key References

- Vault v2 Concepts & Contracts
- Manage Adapters guide
- Vault v2 Deployment repo
- Morpho Market v1 docs
- Pendle Router & Oracle docs
- ERC-4626 security + EIP-2612

---

👉 If you'd like, I can also generate a README.md template + Foundry boilerplate scripts (Vault v2 deploy, Morpho/Pendle adapters listing, caps/timelocks setup, plus TypeScript agent script) ready to run.

---

Would you like me to convert this into a polished README.md file with runnable Foundry/TypeScript examples for your repo?