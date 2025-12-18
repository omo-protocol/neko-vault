# Price Per Share (PPS) Calculation

## Overview

**Price Per Share (PPS)** determines how much each vault share is worth in terms of the underlying deposit asset. This is the core metric that users rely on to understand their position value and calculate deposit/withdrawal amounts.

```
PPS = totalAssets / totalSupply
```

Where:
- `totalAssets`: Total value of all assets managed by the vault (in deposit asset units)
- `totalSupply`: Total number of vault shares issued

---

## Calculation Flow

```
┌─────────────────────────────────────────────────────────────┐
│ User Interaction                                            │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ VaultV2.sol                                                 │
│                                                             │
│  deposit(assets) or withdraw(assets)                        │
│    │                                                        │
│    ├─> totalAssets = adapter.realAssets()  ◄───┐          │
│    │                                             │          │
│    ├─> totalSupply = ERC20.totalSupply()        │          │
│    │                                             │          │
│    └─> PPS = totalAssets / totalSupply          │          │
│                                                  │          │
└──────────────────────────────────────────────────┼──────────┘
                                                   │
                                                   │
┌──────────────────────────────────────────────────┼──────────┐
│ UniversalAdapterEscrow.sol                       │          │
│                                                  │          │
│  realAssets()                                    │          │
│    │                                             │          │
│    ├─> balance = asset.balanceOf(this)          │          │
│    │                                             │          │
│    ├─> allocatedInAdapter =                     │          │
│    │    totalAllocations - totalExternalDeposits│          │
│    │                                             │          │
│    ├─> totalId = ESCROW_TOTAL_ID                │          │
│    │                                             │          │
│    └─> totalValue = valuer.getValue(totalId) ───┘          │
│                                                             │
│    return totalValue (or with haircut if stale/emergency)  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ UniversalValuerOffchain.sol                                 │
│                                                             │
│  getValue(ESCROW_TOTAL_ID)                                  │
│    │                                                        │
│    └─> returns latestReports[totalId].value                │
│         (sum of all strategy values in wrapper shares)     │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│ OffchainValuationKeeper.py                                  │
│                                                             │
│  For each strategy:                                         │
│    1. Read on-chain positions                               │
│    2. Convert all assets back to deposit asset              │
│    3. Sum strategy value                                    │
│    4. Sign and push to valuer                               │
└─────────────────────────────────────────────────────────────┘
```

---

## Asset Valuation: Converting Back to Deposit Asset

The key challenge is **converting complex positions back to the deposit asset** to calculate total value.

### General Principle

For any strategy holding various assets (tokens, LP positions, lending positions), we must:

1. **Identify all held assets** (collateral, debt, idle balances)
2. **Price each asset** in terms of deposit asset
3. **Apply formula**: `Net Value = Assets - Liabilities + Idle`
4. **Convert to wrapper shares** (if using wrapped deposit asset)

---

## Example: PT-kHYPE Looper Strategy

### Strategy Overview

**Deposit Asset**: kHYPE

**Strategy Actions**:
1. User deposits kHYPE to vault
2. Vault allocates kHYPE to adapter (escrow)
3. Agent transfers kHYPE to Looper contract
4. Looper executes loop:
   - Swap kHYPE → PT-kHYPE
   - Supply PT-kHYPE to HyperLend (receives **a-token** collateral)
   - Borrow wHYPE (incurs **debt token** liability)
   - Repeat loop 3-4 times for leverage

**Final Position** (Looper contract):
- **a-token (aPT-kHYPE)**: Collateral representing PT-kHYPE supplied to HyperLend
- **debt token (variable debt wHYPE)**: Debt owed to HyperLend
- **Idle kHYPE**: Any undeployed kHYPE sitting in looper

**Reference**: [AAVE V3 a-token and debt token explained](https://updraft.cyfrin.io/courses/aave-v3/foundation/a-token-and-debt-token)

### Asset Valuation Breakdown

```python
# === 1. READ HELD ASSETS ===

# A. Escrow idle kHYPE (donation-protected)
escrow_idle_khype = allocations[strategyId] - externalDeposits[strategyId]
# Example: 1000 - 1000 = 0 kHYPE (all sent to looper)

# B. Looper idle kHYPE (donation-protected, bounded)
looper_idle_khype = kHYPE.balanceOf(looper)
# Bounded to prevent donation attacks
# Example: 50 kHYPE

# C. Looper collateral (a-token = aPT-kHYPE)
looper_collateral_pt_khype = aPT_kHYPE.balanceOf(looper)
# Or read via HyperLend pool.getReserveData()
# Example: 2500 PT-kHYPE

# D. Looper debt (debt token = variable debt wHYPE)
looper_debt_whype = variableDebtWHYPE.balanceOf(looper)
# Or read via HyperLend pool.getUserAccountData()
# Example: 1800 wHYPE


# === 2. CONVERT TO DEPOSIT ASSET (kHYPE) ===

# A. Escrow idle: Already in kHYPE
escrow_value = escrow_idle_khype
# Example: 0 kHYPE

# B. Looper idle: Already in kHYPE
looper_idle_value = looper_idle_khype
# Example: 50 kHYPE

# C. Collateral: PT-kHYPE → kHYPE
# Method: Linear discount rate (or Pendle oracle)
#
# Linear Discount Formula:
#   PT price = 1.0 - ((maturity_date - current_date) / total_duration) * discount_factor
#
# Example: 90 days to maturity, discount_factor = 0.05
#   PT price = 1.0 - (90 / 365) * 0.05 = 0.9877 ≈ 0.95 (conservative)
#
pt_price = 0.95  # kHYPE per PT-kHYPE
looper_collateral_value = looper_collateral_pt_khype * pt_price
# Example: 2500 * 0.95 = 2375 kHYPE

# D. Debt: wHYPE → kHYPE
# Method: Chainlink oracle via USD conversion
#
# wHYPE is 1:1 wrapped HYPE, so conceptually:
#   1 wHYPE = 1 HYPE = 1 kHYPE (staked HYPE)
#
# But to be precise, use oracle:
#   wHYPE → USD (via Chainlink)
#   USD → kHYPE (via Chainlink)
#
# Example (simplified): 1 wHYPE = 1 kHYPE
looper_debt_value = looper_debt_whype * 1.0
# Example: 1800 * 1.0 = 1800 kHYPE


# === 3. CALCULATE NET VALUE ===

looper_net_value = looper_idle_value + looper_collateral_value - looper_debt_value
# Example: 50 + 2375 - 1800 = 625 kHYPE

total_strategy_value = escrow_value + looper_net_value
# Example: 0 + 625 = 625 kHYPE


# === 4. CONVERT TO WRAPPER SHARES ===

# If deposit asset is wrapped (e.g., PT-kHYPE wrapper)
wrapper_shares = wrapper.convertToShares(total_strategy_value)
# Example: 625 kHYPE → 625 PT-kHYPE shares (assuming 1:1 at this point)
```

### Valuation Summary Table

| Component | Raw Value | Conversion | kHYPE Value |
|-----------|-----------|------------|-------------|
| **ASSETS** | | | |
| Escrow idle kHYPE | 0 kHYPE | 1:1 | 0 |
| Looper idle kHYPE | 50 kHYPE | 1:1 | 50 |
| Looper collateral (aPT-kHYPE) | 2500 PT-kHYPE | × 0.95 (linear discount) | 2375 |
| **LIABILITIES** | | | |
| Looper debt (wHYPE) | 1800 wHYPE | × 1.0 (oracle) | -1800 |
| **NET VALUE** | | | **625 kHYPE** |

---

## Complete PPS Calculation Example

### Scenario Setup

```
Vault State:
├─ Total supply: 1000 shares
├─ Strategy allocation: 1000 kHYPE
└─ After looping valuation: 625 kHYPE
```

### Step-by-Step Calculation

#### 1. Keeper Computes Strategy Value (Off-chain)

```python
# Keeper runs every 60 seconds
strategy_value = calculate_pt_khype_looper_value()
# Returns: 625 kHYPE (in wrapper shares)

# Sign and push to valuer
valuer.updateValue(strategyId, 625e18, confidence=95, ...)
valuer.updateValue(ESCROW_TOTAL_ID, 625e18, confidence=95, ...)

# Refresh adapter cache
adapter.refreshCachedValuation()
```

#### 2. User Requests Deposit (On-chain)

```solidity
// User wants to deposit 100 kHYPE
user_deposit_amount = 100 kHYPE

// Vault calculates current PPS
function deposit(uint256 assets, address receiver) public returns (uint256 shares) {
    // Get current total assets
    uint256 currentAssets = adapter.realAssets();
    // currentAssets = 625 kHYPE (from valuer)

    uint256 currentSupply = totalSupply();
    // currentSupply = 1000 shares

    // Calculate shares to mint
    if (currentSupply == 0) {
        shares = assets;  // First depositor: 1:1
    } else {
        shares = (assets * currentSupply) / currentAssets;
        // shares = (100 * 1000) / 625 = 160 shares
    }

    // Current PPS = 625 / 1000 = 0.625 kHYPE per share
    // User deposits 100 kHYPE → receives 160 shares
    // Verification: 160 shares * 0.625 = 100 kHYPE ✓

    _mint(receiver, shares);
}
```

**Result**:
```
Before deposit:
├─ Total assets: 625 kHYPE
├─ Total supply: 1000 shares
└─ PPS: 0.625 kHYPE/share

After deposit:
├─ Total assets: 725 kHYPE (625 + 100 deposit)
├─ Total supply: 1160 shares (1000 + 160 minted)
└─ PPS: 0.625 kHYPE/share (unchanged)
```

#### 3. User Requests Withdrawal (On-chain)

```solidity
// User wants to withdraw 200 kHYPE
user_withdraw_amount = 200 kHYPE

function withdraw(uint256 assets, address receiver, address owner) public returns (uint256 shares) {
    // Get current state (after previous deposit)
    uint256 currentAssets = adapter.realAssets();
    // currentAssets = 725 kHYPE

    uint256 currentSupply = totalSupply();
    // currentSupply = 1160 shares

    // Calculate shares to burn
    shares = (assets * currentSupply) / currentAssets;
    // shares = (200 * 1160) / 725 = 320 shares

    // Current PPS = 725 / 1160 = 0.625 kHYPE per share
    // User withdraws 200 kHYPE → burns 320 shares
    // Verification: 320 shares * 0.625 = 200 kHYPE ✓

    _burn(owner, shares);
    adapter.deallocate(..., assets);  // Get assets from strategy
    asset.transfer(receiver, assets);
}
```

**Result**:
```
After withdrawal:
├─ Total assets: 525 kHYPE (725 - 200 withdrawal)
├─ Total supply: 840 shares (1160 - 320 burned)
└─ PPS: 0.625 kHYPE/share (still unchanged)
```

---

## PPS Changes: When and Why

PPS **increases** when:
- Strategy generates **positive yield** (PT price appreciation, lending yield)
- Strategy **compounds gains** (reinvests yield)

PPS **decreases** when:
- Strategy experiences **losses** (liquidation, bad debt)
- Strategy has **negative yield** (borrow rate > supply rate)
- **Slippage** during asset conversions

PPS **stays constant** during:
- User deposits (assets and shares increase proportionally)
- User withdrawals (assets and shares decrease proportionally)

### Example: PPS Increase from Yield

```
Time T0 (initial):
├─ Total assets: 625 kHYPE
├─ Total supply: 1000 shares
└─ PPS: 0.625 kHYPE/share

Time T1 (30 days later):
├─ PT price: 0.95 → 0.98 (+3.16% appreciation)
├─ Strategy value: 625 → 700 kHYPE (+75 kHYPE yield)
├─ Total assets: 700 kHYPE
├─ Total supply: 1000 shares (no deposits/withdrawals)
└─ PPS: 0.700 kHYPE/share (+12% increase)

User A (held 100 shares):
├─ Value at T0: 100 × 0.625 = 62.5 kHYPE
├─ Value at T1: 100 × 0.700 = 70.0 kHYPE
└─ Profit: +7.5 kHYPE (+12%)
```

---

## Pricing Methods by Asset Type

### 1. Same as Deposit Asset
**Method**: Direct value (1:1)

**Example**: Idle kHYPE when deposit asset is kHYPE
```python
value = balance
```

### 2. Principal Tokens (PT)
**Method A**: Linear discount rate
```python
# Discount PT to underlying based on time to maturity
time_to_maturity = maturity_timestamp - current_timestamp
total_duration = maturity_timestamp - issue_timestamp
discount_rate = 0.05  # 5% discount at issue

pt_price = 1.0 - (time_to_maturity / total_duration) * discount_rate
value = pt_balance * pt_price
```

**Method B**: Pendle oracle
```python
# Read from Pendle oracle contract
pt_price = pendle_oracle.getPtToAssetRate(market, duration)
value = pt_balance * pt_price / 1e18
```

### 3. Wrapped Assets (wHYPE, wETH)
**Method**: Chainlink oracle via USD
```python
# Get price in USD for both assets
whype_usd_price = chainlink_oracle.latestAnswer(WHYPE_USD_FEED)
khype_usd_price = chainlink_oracle.latestAnswer(KHYPE_USD_FEED)

# Convert
whype_to_khype_rate = whype_usd_price / khype_usd_price
value = whype_balance * whype_to_khype_rate
```

### 4. Lending Protocol Tokens (a-tokens, debt tokens)

**A. Collateral (a-tokens)**:
```python
# a-tokens are 1:1 with underlying (with accrued interest)
underlying_balance = atoken_balance  # Interest-bearing, grows over time
value = convert_to_deposit_asset(underlying_balance)
```

**B. Debt (debt tokens)**:
```python
# Debt tokens represent borrowed amount (with accrued interest)
debt_balance = debt_token_balance  # Grows over time due to interest
value = -convert_to_deposit_asset(debt_balance)  # Negative (liability)
```

### 5. LP Positions (Uniswap V3)
**Method**: Calculate token amounts from liquidity
```python
# Read position data
position = position_manager.positions(token_id)
liquidity = position.liquidity
tick_lower = position.tickLower
tick_upper = position.tickUpper
current_tick = pool.slot0().tick

# Calculate amounts
amount0, amount1 = calculate_amounts_from_liquidity(
    liquidity, current_tick, tick_lower, tick_upper
)

# Convert both tokens to deposit asset
value0 = convert_to_deposit_asset(amount0, token0)
value1 = convert_to_deposit_asset(amount1, token1)

value = value0 + value1
```

---

## Staleness and Haircuts

### Stale Data Haircut (5%)

If valuation data is stale or unhealthy, escrow applies a 5% haircut for safety:

```solidity
function realAssets() external view returns (uint256) {
    bytes32 totalId = keccak256(abi.encodePacked("ESCROW_TOTAL", address(this)));

    // Check if data is fresh
    bool hasStaleData = !valuer.isValuationHealthy(address(this));

    uint256 totalValue = valuer.getValue(totalId);

    if (hasStaleData || emergencyMode) {
        // Apply 5% haircut
        return totalValue * 9500 / 10000;
    }

    return totalValue;
}
```

**Impact on PPS**:
```
Normal state:
├─ Strategy value: 700 kHYPE
├─ PPS: 0.700 kHYPE/share

Stale data (keeper offline for 30+ minutes):
├─ Strategy value: 700 × 0.95 = 665 kHYPE (with haircut)
├─ PPS: 0.665 kHYPE/share (-5%)
└─ User deposits/withdrawals still work, but at reduced price (protection mechanism)
```

---

## Common Issues and Debugging

### Issue 1: PPS Decreasing Unexpectedly

**Symptoms**: PPS drops without obvious losses

**Possible Causes**:
1. PT price decrease (check market rates)
2. Debt interest accruing faster than yield
3. Keeper using stale oracle prices
4. Emergency mode activated (5% haircut)

**Debug Steps**:
```bash
# Check strategy value
cast call $VALUER "getReport(bytes32)" $STRATEGY_ID --rpc-url $RPC

# Check valuation health
cast call $VALUER "isValuationHealthy(address)" $ESCROW --rpc-url $RPC

# Check emergency mode
cast call $ESCROW "emergencyMode()" --rpc-url $RPC

# Check keeper logs
journalctl -u valuation-keeper -n 100
```

### Issue 2: PPS Not Updating

**Symptoms**: PPS frozen, no yield accumulation

**Possible Causes**:
1. Keeper offline
2. Signature expired
3. Price bounds exceeded
4. Nonce conflict

**Debug Steps**:
```bash
# Check last update time
cast call $VALUER "getReport(bytes32)" $STRATEGY_ID --rpc-url $RPC | \
  awk '{print "Last update:", strftime("%Y-%m-%d %H:%M:%S", $2)}'

# Check keeper status
systemctl status valuation-keeper

# Check recent keeper transactions
cast logs --address $VALUER --event "ValueUpdated(bytes32,uint256,uint256,uint256,bool)" -n 10
```

### Issue 3: Large PPS Discrepancy Between Expected and Actual

**Symptoms**: PPS is 20%+ different from expected

**Possible Causes**:
1. Donation attack partially succeeded (unlikely with bounds)
2. Accounting drift (externalDeposits out of sync)
3. Oracle manipulation
4. Keeper bug

**Emergency Response**:
```bash
# 1. Enable emergency mode to prevent further deposits/withdrawals
cast send $ESCROW "enableEmergencyMode()" --private-key $OWNER_KEY --rpc-url $RPC

# 2. Check accounting invariants
balance=$(cast call $ASSET "balanceOf(address)" $ESCROW --rpc-url $RPC)
allocations=$(cast call $ESCROW "totalAllocations()" --rpc-url $RPC)
external=$(cast call $ESCROW "totalExternalDeposits()" --rpc-url $RPC)

echo "Balance: $balance"
echo "Allocations: $allocations"
echo "External: $external"
echo "Expected realAssets: balance + external ≈ valuer total"

# 3. Investigate keeper logs for anomalies
grep -E "DONATION|ERROR|WARNING" keeper.log | tail -n 50

# 4. Manually sync accounting if needed
cast send $ESCROW "syncExternalDepositsPerStrategy(bytes32[],uint256[])" \
  "[$STRATEGY_ID]" "[$CORRECTED_VALUE]" \
  --private-key $OWNER_KEY --rpc-url $RPC
```

---

## Summary

### Key Formula
```
PPS = totalAssets / totalSupply
    = adapter.realAssets() / totalSupply
    = valuer.getValue(ESCROW_TOTAL_ID) / totalSupply
    = sum(all strategy values in deposit asset) / totalSupply
```

### Value Calculation Flow
```
1. Identify all held assets (collateral, debt, idle)
2. Convert each to deposit asset:
   - PT tokens: linear discount or oracle
   - Wrapped tokens: oracle (via USD)
   - a-tokens: 1:1 with underlying
   - debt tokens: 1:1 with borrowed (negative)
3. Sum: net_value = assets - liabilities + idle
4. Push to valuer → escrow reads → vault calculates PPS
```

### Critical Dependencies
- **Keeper uptime**: Must run continuously for fresh valuations
- **Oracle accuracy**: PT pricing, debt valuation depend on oracles
- **Accounting integrity**: allocations, externalDeposits must stay in sync
- **Price bounds**: Prevent manipulation but can block legitimate large moves

### Protection Mechanisms
- Donation attack protection (bounded balances)
- Price change circuit breakers (50% max by default)
- Staleness detection + 5% haircut
- Emergency mode fallbacks

---

*For implementation details, see [OFFCHAIN_VALUATION_SYSTEM.md](./OFFCHAIN_VALUATION_SYSTEM.md)*
