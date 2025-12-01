# UniversalAdapterEscrow - Technical Specification

> Multi-strategy adapter with escrow functionality for VaultV2
> Location: `src/adapters/UniversalAdapterEscrow.sol`

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [State Variables](#state-variables)
- [Functions](#functions)
- [Security Mechanisms](#security-mechanisms)
- [Integration Points](#integration-points)
- [Events](#events)
- [Invariants & Assumptions](#invariants--assumptions)
- [Configuration Guide](#configuration-guide)

---

## Overview

UniversalAdapterEscrow is a unified contract that merges adapter and strategy escrow functionality into a single contract. It manages fund allocations to multiple DeFi strategies while maintaining accurate accounting, security controls, and valuation tracking.

### Key Features

- **Multi-Strategy Management**: Supports multiple concurrent strategies with independent allocation tracking
- **Valuer Integration**: Integrates with off-chain valuation system for accurate NAV calculation
- **Emergency Mode**: Fallback mechanisms when valuation system is unavailable
- **Circuit Breaker**: Automatic protection against excessive balance losses (10% max)
- **Whitelisted Execution**: Only pre-approved functions can be called on external protocols

### Architecture Pattern

```
VaultV2 (Parent)
    │
    ├─── allocate(data, assets) ──────────────┐
    │                                          │
    ├─── deallocate(data, assets) ────────────┤
    │                                          ▼
    └─── realAssets() ◄───────────── UniversalAdapterEscrow
                                              │
                                              ├── Strategy 1 (PT-kHYPE Loop)
                                              │   └── Agent: 0x...
                                              │
                                              ├── Strategy 2 (Felix Lending)
                                              │   └── Agent: 0x...
                                              │
                                              └── [Whitelisted External Protocols]
                                                  ├── Pendle Router
                                                  ├── Felix Protocol
                                                  └── ...
```

---

## State Variables

### Immutable State

```solidity
address public immutable parentVault;    // VaultV2 that owns this adapter
address public immutable asset;          // Primary ERC20 asset (e.g., kHYPE)
address public immutable valuer;         // UniversalValuerOffchain address
```

### Strategy Tracking

```solidity
mapping(bytes32 => StrategyConfig) public strategies;       // Config per strategy
mapping(bytes32 => uint256) public allocations;             // Allocated amount per strategy
EnumerableSet.Bytes32Set private activeStrategies;          // Set of active strategy IDs
uint256 public totalAllocations;                            // Sum of all allocations

struct StrategyConfig {
    address agent;              // Authorized executor for this strategy
    bytes preConfiguredData;    // Optional pre-configured calldata
    uint256 dailyLimit;         // Daily spending limit (currently unused)
    uint256 lastResetTime;      // Last daily limit reset
    uint256 dailyUsed;          // Amount used today (currently unused)
    bool active;                // Is strategy active
}
```

### External Protocol Tracking

```solidity
mapping(bytes32 => uint256) public externalDeposits;    // Amount in external protocols per strategy
uint256 public totalExternalDeposits;                   // Sum of all external deposits
```

### Valuation Caching

```solidity
uint256 private cachedValuation;              // Last known total valuation
uint256 private cachedValuationTimestamp;     // When cache was updated
uint256 constant MAX_CACHED_VALUATION_AGE = 4 hours;
```

### Access Control & State

```solidity
mapping(address => mapping(bytes4 => WhitelistConfig)) public functionWhitelist;
bool public paused;
address public owner;
bool public emergencyMode;
uint256 public emergencyModeActivatedAt;
uint256 public constant EMERGENCY_HAIRCUT = 500;  // 5% in basis points

struct WhitelistConfig {
    bool allowed;       // Function allowed for execution
    uint256 limit;      // Per-call limit (0 for unlimited)
}
```

### Constants

```solidity
uint256 private constant MAX_BALANCE_LOSS_BPS = 1000;       // 10% max loss per execution
uint256 private constant VALUER_GAS_STIPEND = 200000;       // Gas limit for valuer calls
bytes4 private constant DEALLOCATE_SELECTOR = 0x4b219d16;
bytes4 private constant FORCE_DEALLOCATE_SELECTOR = 0xe4d38cd8;
```

---

## Functions

### Core Adapter Functions (IAdapter)

#### `allocate`

```solidity
function allocate(
    bytes memory data,
    uint256 assets,
    bytes4,
    address
) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change)
```

**Purpose**: Allocate vault assets to a strategy.

**Parameters**:
- `data`: ABI-encoded `bytes32 strategyId`
- `assets`: Amount of assets to allocate
- Returns: `ids` array with single strategyId, `change` as positive int256

**Flow**:
1. Decode strategyId from data
2. Verify strategy is active
3. Update `allocations[strategyId] += assets`
4. Update `totalAllocations += assets`
5. Add strategy to activeStrategies set (if not already)
6. Emit `AllocationUpdated` event

#### `deallocate`

```solidity
function deallocate(
    bytes memory data,
    uint256 assets,
    bytes4 caller,
    address
) external override onlyVault notPaused returns (bytes32[] memory ids, int256 change)
```

**Purpose**: Deallocate funds from a strategy.

**Scenarios**:
1. **Sufficient adapter balance**: Direct deallocation
2. **Partial balance**: Return what's available, emit `PartialDeallocate`
3. **Force deallocate**: Withdraw from external protocols first

**Flow**:
1. Decode strategyId from data
2. Check adapter balance vs requested assets
3. If insufficient, check if force deallocate
4. Update allocations (decrease by actual amount)
5. Transfer assets back to vault
6. Remove strategy from activeStrategies if allocation reaches 0

#### `realAssets`

```solidity
function realAssets() external view override returns (uint256 assets)
```

**Purpose**: Calculate total real assets value for NAV calculation.

**Formula**:
```
valuerValue = valuer.getValue(ESCROW_TOTAL)
allocatedInAdapter = max(0, totalAllocations - totalExternalDeposits)
idle = max(0, balance - allocatedInAdapter)
excessIdle = max(0, idle - allocatedInAdapter)
assets = max(0, valuerValue - excessIdle) + idle
```

**Fallback Logic**:
1. Try valuer with gas stipend (200k gas)
2. If fails and cache exists and not stale (< 4 hours): use cache
3. If emergency mode: apply 5% haircut
4. If all fail: revert

### Strategy Management

#### `setStrategy`

```solidity
function setStrategy(
    bytes32 strategyId,
    address agent,
    bytes calldata preConfiguredData,
    uint256 dailyLimit
) external onlyOwner
```

**Purpose**: Create or update strategy configuration.

#### `removeStrategy`

```solidity
function removeStrategy(bytes32 strategyId) external onlyOwner
```

**Requirements**:
- `allocations[strategyId] == 0`
- `externalDeposits[strategyId] == 0`

### Strategy Execution

#### `executeStrategy`

```solidity
function executeStrategy(
    bytes32 strategyId,
    Call[] calldata calls
) external onlyStrategyAgentOrOwner(strategyId) notPaused
```

**Purpose**: Execute arbitrary multicalls for a strategy.

**Security**:
- Validates each call against whitelist
- Circuit breaker: reverts if balance loss > 10%
- Cannot transfer assets INTO adapter (prevents manipulation)

#### `executeStrategyWithSlippage`

```solidity
function executeStrategyWithSlippage(
    bytes32 strategyId,
    Call[] calldata calls,
    uint256 minBalanceIncrease
) external onlyStrategyAgentOrOwner(strategyId) notPaused
```

**Purpose**: Execute multicalls with slippage protection.

**Behavior**:
- Requires `balanceAfter >= balanceBefore + minBalanceIncrease`
- Automatically syncs externalDeposits when balance increases

#### `executeStrategyBypassCircuitBreaker`

```solidity
function executeStrategyBypassCircuitBreaker(
    bytes32 strategyId,
    Call[] calldata calls
) external onlyStrategyAgentOrOwner(strategyId) notPaused
```

**Warning**: USE WITH EXTREME CAUTION. Bypasses 10% loss protection.

#### `withdrawFromStrategy`

```solidity
function withdrawFromStrategy(
    bytes32 strategyId,
    Call[] calldata withdrawCalls,
    uint256 minBalanceIncrease
) external onlyStrategyAgentOrOwner(strategyId) notPaused
```

**Purpose**: Withdraw assets from external protocols back to adapter.

### Whitelist Management

#### `updateWhitelist`

```solidity
function updateWhitelist(
    address target,
    bytes4 selector,
    bool allowed,
    uint256 limit
) external onlyOwner
```

**Special Cases**:
- `selector = 0x00000000`: Whitelist ALL functions on target
- `limit = 0`: No per-call limit

### Valuation & Sync Functions

#### `refreshCachedValuation`

```solidity
function refreshCachedValuation() external
```

**Purpose**: Anyone can refresh the cached valuation from current valuer state.

#### `syncStrategyWithValuer`

```solidity
function syncStrategyWithValuer(bytes32 strategyId) external onlyOwner
```

**Purpose**: Manually sync strategy's externalDeposits with valuer value.

**Use Case**: After claiming yield, sync to recognize gains.

#### `syncExternalDepositsPerStrategy`

```solidity
function syncExternalDepositsPerStrategy(
    bytes32[] calldata strategyIds,
    uint256[] calldata newValues
) external onlyOwner
```

**Purpose**: Batch sync with validation against valuer.

#### `reduceExternalDeposits`

```solidity
function reduceExternalDeposits(
    bytes32 strategyId,
    uint256 newPerStrategy
) external onlyOwner
```

**Purpose**: Reduce externalDeposits for loss recognition.

### Emergency Mode

#### `enableEmergencyMode`

```solidity
function enableEmergencyMode() external onlyOwner
```

**Effect**:
- Applies 5% haircut to all valuations
- Allows use of stale cached valuations
- Emits `EmergencyModeEnabled`

#### `disableEmergencyMode`

```solidity
function disableEmergencyMode() external onlyOwner
```

**Requirement**: Valuer must be working before disabling.

---

## Security Mechanisms

### Access Control

| Modifier | Restricts To |
|----------|--------------|
| `onlyVault` | Parent vault only |
| `onlyOwner` | Owner address only |
| `onlyStrategyAgentOrOwner(strategyId)` | Strategy agent or owner |
| `notPaused` | When not paused |

### Circuit Breaker

```solidity
uint256 lossBps = (loss * 10000) / balanceBefore;
if (lossBps > MAX_BALANCE_LOSS_BPS) {  // 10%
    revert ExcessiveBalanceLoss();
}
```

### Whitelist Enforcement

Every multicall checks:
1. Function selector whitelisted on target
2. OR target-level whitelist exists (selector = 0x00000000)
3. Reverts if no whitelist entry found

### Balance Validation

- In allocate: Calls array must be empty (no execution)
- In deallocate: Three-scenario logic handles insufficient balance
- Force deallocate: Validates slack covers requested assets

### Valuation Safety

- Valuer calls limited to 200k gas (prevents DoS)
- Timeout handling via staticcall with success check
- Fallback to cached valuation (4-hour TTL)
- Emergency mode applies 5% haircut

---

## Integration Points

### With VaultV2

```
VaultV2.allocate(adapter, data, assets)
    → adapter.allocate(data, assets, selector, sender)
    → Returns (ids[], change)

VaultV2.accrueInterest()
    → adapter.realAssets()
    → Returns total value for NAV calculation
```

### With UniversalValuerOffchain

```solidity
// Query total value
valuer.staticcall{gas: 200000}(
    abi.encodeWithSignature("getValue(bytes32)", keccak256("ESCROW_TOTAL", address(this)))
)

// Query per-strategy value
valuer.staticcall{gas: 200000}(
    abi.encodeWithSignature("getValue(bytes32)", strategyId)
)
```

### With External Protocols

Strategy agents execute whitelisted calls:
```solidity
Call[] memory calls = new Call[](2);
calls[0] = Call({
    target: pendleRouter,
    data: abi.encodeWithSelector(IRouter.swapExactTokensForTokens.selector, ...),
    value: 0
});
executeStrategy(strategyId, calls);
```

---

## Events

### Allocation Events

```solidity
event AllocationUpdated(bytes32 indexed strategyId, uint256 newAmount, int256 change);
event PartialDeallocate(bytes32 indexed strategyId, uint256 requested, uint256 actual);
```

### Strategy Events

```solidity
event StrategySet(bytes32 indexed strategyId, address indexed agent, uint256 dailyLimit);
event StrategyRemoved(bytes32 indexed strategyId);
event StrategyExecuted(bytes32 indexed strategyId, address indexed executor);
event StrategyWithdrawn(bytes32 indexed strategyId, uint256 amount, address indexed executor);
```

### Valuation Events

```solidity
event CachedValuationRefreshed(uint256 newValue, uint256 timestamp);
event ExternalDepositsReduced(bytes32 indexed strategyId, uint256 oldValue, uint256 newValue, uint256 delta);
event YieldAccrued(bytes32 indexed strategyId, uint256 yieldAmount);
```

### Admin Events

```solidity
event WhitelistUpdated(address indexed target, bytes4 indexed selector, bool allowed, uint256 limit);
event PauseStatusChanged(bool paused);
event EmergencyModeEnabled(uint256 timestamp, string reason);
event EmergencyModeDisabled(uint256 timestamp, uint256 duration);
```

---

## Invariants & Assumptions

### Critical Invariants

1. **Allocation Consistency**:
   ```
   sum(allocations[strategyId]) == totalAllocations
   ```

2. **External Deposits Consistency**:
   ```
   sum(externalDeposits[strategyId]) == totalExternalDeposits
   ```

3. **Strategy Removal**:
   ```
   Can only remove if: allocations[strategyId] == 0 AND externalDeposits[strategyId] == 0
   ```

4. **Real Assets Calculation**:
   ```
   realAssets ≥ 0 (never negative)
   realAssets = valuerValue - excessIdle + idle (simplified)
   ```

### Key Assumptions

1. **Valuer Behavior**: Returns uint256, may fail/timeout, requires fallback
2. **Vault Behavior**: Only vault calls allocate/deallocate, respects realAssets()
3. **Asset Properties**: Standard ERC20, no fee-on-transfer, safe transfers
4. **Agent Behavior**: Executes within whitelist, maintains position health
5. **Owner Trustworthiness**: Controls pause, emergency mode, whitelist, sync

---

## Configuration Guide

### Setting Up a New Strategy

```solidity
// 1. Create strategy
bytes32 strategyId = keccak256("MY_STRATEGY");
adapter.setStrategy(strategyId, agentAddress, "", 0);

// 2. Whitelist target protocol
adapter.updateWhitelist(protocolAddress, SWAP_SELECTOR, true, 0);
adapter.updateWhitelist(protocolAddress, DEPOSIT_SELECTOR, true, 0);

// 3. Configure valuer (off-chain)
// Add strategy to keeper_config.json
```

### Emergency Recovery

```solidity
// 1. Enable emergency mode
adapter.enableEmergencyMode();

// 2. Reduce external deposits if needed
adapter.reduceExternalDeposits(strategyId, 0);

// 3. Remove stuck strategy
adapter.removeStrategy(strategyId);

// 4. Disable emergency mode when recovered
adapter.disableEmergencyMode();
```

### Monitoring Checklist

- [ ] Watch for `ExcessiveBalanceLoss` reverts
- [ ] Monitor `CachedValuationRefreshed` timestamps
- [ ] Alert on `EmergencyModeEnabled`
- [ ] Track `YieldAccrued` for performance metrics
- [ ] Verify `totalExternalDeposits` aligns with valuer
