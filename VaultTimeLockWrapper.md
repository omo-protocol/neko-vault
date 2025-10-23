# VaultTimeLockWrapper: Transferable Time-Locked Vault Positions

## Overview

**VaultTimeLockWrapper** is an ERC20-compliant wrapper contract that enforces time-based lockup periods on VaultV2 deposits while enabling **secondary market trading** through transferable receipt tokens.

### Key Innovation

Traditional lockup mechanisms prevent transfers, making positions illiquid. VaultTimeLockWrapper solves this by:

1. ✅ **Minting transferable ERC20 receipt tokens** (vTokens) representing locked positions
2. ✅ **Preserving original deposit timestamps** across transfers
3. ✅ **Creating secondary market** where locked positions can trade at market-determined discounts

### Example Flow

```
T=0 days:  Alice deposits 1000 USDC → Receives 1000 vTokens (unlock at T=7)
T=3 days:  Alice transfers 500 vTokens to Bob
           Bob now owns 500 vTokens that unlock at T=7 (4 days from his perspective)
T=7 days:  Both Alice and Bob can withdraw (original lockup expired)
```

Bob effectively bought a position that unlocks in 4 days, potentially at a discount from Alice who needed liquidity before the 7-day lockup expired.

---

## Architecture

### Core Components

```solidity
contract VaultTimeLockWrapper {
    // ERC20 receipt tokens
    mapping(address => uint256) public balanceOf;

    // FIFO deposit tracking
    struct DepositBatch {
        uint256 amount;       // vTokens in this batch
        uint256 depositTime;  // Original deposit timestamp
    }
    mapping(address => DepositBatch[]) public userDeposits;

    // Vault integration
    IVaultV2 public immutable vault;
    IERC20 public immutable asset;
    uint256 public constant LOCK_PERIOD = 7 days;
}
```

### Deposit Batch System (FIFO)

Each deposit creates a new batch with its own timestamp. Batches are organized as a **FIFO queue**:

```
Alice's Deposits:
┌─────────────────────────────────────────────────────┐
│ [0] 400 tokens @ T=0   (unlocks T=7)                │
│ [1] 300 tokens @ T=2   (unlocks T=9)                │
│ [2] 300 tokens @ T=5   (unlocks T=12)               │
└─────────────────────────────────────────────────────┘
```

**Operations process oldest batches first:**
- **Withdrawals**: Burn from batch [0] first
- **Transfers**: Move batch [0] first
- **Lockup checks**: Check batch [0] unlock time

---

## Key Features

### 1. Original Depositor Lockup ✅

**Requirement**: Lockup period is based on **when tokens were deposited**, not who currently holds them.

```solidity
// T=0: Alice deposits 1000 tokens
wrapper.deposit(1000e18, alice);
// Creates: DepositBatch(1000, T=0) → unlocks at T=7

// T=3: Alice transfers to Bob
wrapper.transfer(bob, 1000);
// Bob receives: DepositBatch(1000, T=0) → still unlocks at T=7

// T=7: Bob can withdraw (original deposit time = T=0)
wrapper.withdraw(1000e18, bob, bob); // ✅ Success
```

### 2. FIFO Processing ✅

**Oldest deposits are always processed first** (withdrawals, transfers, lockup checks).

**Example: Multiple Deposits**
```solidity
// T=0: Deposit 400
wrapper.deposit(400e18, alice);

// T=2: Deposit 600
vm.warp(block.timestamp + 2 days);
wrapper.deposit(600e18, alice);

// T=7: First batch unlocked, second still locked
vm.warp(block.timestamp + 5 days);
wrapper.unlockedBalanceOf(alice); // Returns 400 (only first batch)

// T=9: Both batches unlocked
vm.warp(block.timestamp + 2 days);
wrapper.unlockedBalanceOf(alice); // Returns 1000 (all batches)
```

**Example: Transfer FIFO**
```solidity
// Alice has:
// [0] 400 @ T=0
// [1] 600 @ T=3

// Alice transfers 700 to Bob
wrapper.transfer(bob, 700);

// Result:
// Alice: [0] 300 @ T=3 (remaining from second batch)
// Bob:   [0] 400 @ T=0 (entire first batch)
//        [1] 300 @ T=3 (partial second batch)
```

### 3. Transferable Receipt Tokens ✅

**Full ERC20 compatibility** enables secondary market trading.

```solidity
// Standard ERC20 functions
function transfer(address to, uint256 amount) external returns (bool);
function transferFrom(address from, address to, uint256 amount) external returns (bool);
function approve(address spender, uint256 amount) external returns (bool);
function balanceOf(address account) external view returns (uint256);
function allowance(address owner, address spender) external view returns (uint256);
```

**Batch preservation on transfer:**
```solidity
function _transferWithBatches(address from, address to, uint256 amount) internal {
    // Standard balance transfer
    balanceOf[from] -= amount;
    balanceOf[to] += amount;

    // Move oldest deposit batches (FIFO)
    while (remaining > 0) {
        DepositBatch storage batch = fromDeposits[0];
        toDeposits.push(DepositBatch({
            amount: ...,
            depositTime: batch.depositTime  // ✅ Preserves original time
        }));
    }
}
```

### 4. Emergency Exit (Bypasses Lockup) ⚠️

Users can always exit via VaultV2's `forceDeallocate` mechanism, but **pay a penalty** (up to 2%).

```solidity
function emergencyWithdraw(
    address adapter,
    bytes memory data,
    uint256 assets
) external returns (uint256 penaltyShares) {
    // Calls vault.forceDeallocate() - bypasses lockup
    // User pays penalty per vault's forceDeallocatePenalty
    penaltyShares = vault.forceDeallocate(adapter, data, assets, address(this));

    // Burns vTokens without lockup check
    _burnEmergency(msg.sender, penaltyShares);
}
```

**This preserves the non-custodial guarantee** from VaultV2_GATE.md documentation.

---

## Function Reference

### Deposit Functions

#### `deposit(uint256 assets, address onBehalf) → uint256 vTokens`
Deposits underlying assets and receives vTokens with 7-day lockup.

```solidity
// Alice deposits 1000 USDC
asset.approve(address(wrapper), 1000e18);
uint256 vTokens = wrapper.deposit(1000e18, alice);
```

#### `mint(uint256 shares, address onBehalf) → uint256 assets`
Mints exact number of vault shares as vTokens.

```solidity
// Alice mints exactly 1000 vTokens
uint256 assetsNeeded = wrapper.previewMint(1000e18);
asset.approve(address(wrapper), assetsNeeded);
wrapper.mint(1000e18, alice);
```

### Withdrawal Functions (Lockup Enforced)

#### `withdraw(uint256 assets, address receiver, address onBehalf) → uint256 vTokensBurned`
Withdraws assets after lockup expires. Burns vTokens from oldest batch.

```solidity
// After 7 days, Alice withdraws 500 USDC
wrapper.withdraw(500e18, alice, alice);
```

**Reverts if oldest deposit still locked:**
```solidity
vm.expectRevert("Oldest deposit still locked");
wrapper.withdraw(amount, user, user);
```

#### `redeem(uint256 vTokens, address receiver, address onBehalf) → uint256 assets`
Burns vTokens for assets after lockup expires.

```solidity
// After 7 days, Alice redeems 500 vTokens
wrapper.redeem(500e18, alice, alice);
```

### Emergency Functions

#### `emergencyWithdraw(address adapter, bytes data, uint256 assets) → uint256 penalty`
Bypasses lockup using vault's forceDeallocate (pays penalty).

```solidity
// Alice needs emergency liquidity before lockup expires
uint256 penalty = wrapper.emergencyWithdraw(
    adapterAddress,
    deallocateCalldata,
    1000e18
);
// Alice receives 1000 USDC but loses ~2% in penalty
```

### View Functions

#### `isUnlocked(address user) → bool`
Checks if user's **oldest** deposit is unlocked.

```solidity
bool canWithdraw = wrapper.isUnlocked(alice);
```

#### `remainingLockTime(address user) → uint256`
Returns seconds until oldest deposit unlocks.

```solidity
uint256 timeLeft = wrapper.remainingLockTime(alice);
// Returns: 345600 (4 days in seconds)
```

#### `unlockedBalanceOf(address user) → uint256`
Returns amount of vTokens currently withdrawable.

```solidity
// Alice has 3 batches:
// [0] 400 @ T=0   (unlocked)
// [1] 300 @ T=2   (unlocked)
// [2] 300 @ T=5   (locked)

uint256 unlocked = wrapper.unlockedBalanceOf(alice);
// Returns: 700 (first two batches)
```

#### `getDepositCount(address user) → uint256`
Returns number of deposit batches for user.

```solidity
uint256 count = wrapper.getDepositCount(alice);
```

#### `getDeposit(address user, uint256 index) → (amount, depositTime, unlockTime, isUnlocked)`
Gets details of specific deposit batch.

```solidity
(
    uint256 amount,
    uint256 depositTime,
    uint256 unlockTime,
    bool isUnlocked
) = wrapper.getDeposit(alice, 0);
```

---

## Security Considerations

### 1. Trust Assumptions ⚠️

**Wrapper holds all vault shares** on behalf of users. Users trust that:
- ✅ Wrapper has no owner/admin functions (immutable)
- ✅ Wrapper has no pause mechanism
- ✅ Wrapper has no upgrade mechanism
- ✅ Lockup rules are hard-coded and cannot change

**Mitigation**: Wrapper is designed as **trustless, immutable contract** with no admin privileges.

### 2. Direct Vault Bypass ⚠️

Users can still interact directly with the vault, bypassing the wrapper:

```solidity
// User deposits directly to vault (no lockup)
vault.deposit(1000e18, alice);

// Alice can withdraw immediately
vault.withdraw(1000e18, alice, alice); // ✅ No lockup enforced
```

**Solutions:**

**Option A: Use receive shares gate**
```solidity
contract WrapperOnlyGate is IReceiveSharesGate {
    address public immutable wrapper;

    function canReceiveShares(address account) external view returns (bool) {
        return account == wrapper ||
               account == feeRecipient ||
               account == address(vault);
    }
}
```

**Option B: Deploy dedicated vault**
```solidity
// Deploy new vault exclusively for wrapper
// Configure vault to only allow wrapper deposits
```

### 3. Force Deallocate Always Available ✅

From VaultV2_GATE.md:
> "Force deallocate allows users to perform in-kind redemptions... provides non-custodial guarantee"

**Users can ALWAYS exit** (even during lockup) by:
1. Calling `emergencyWithdraw()` which uses `vault.forceDeallocate()`
2. Paying the penalty (up to 2%)
3. Receiving their assets

This is **intentional** - preserves DeFi's non-custodial ethos.

### 4. Batch Management Complexity

**FIFO queue operations are gas-intensive** for users with many deposits:

```solidity
// Alice has 50 small deposits
// Withdrawing requires iterating through all batches
wrapper.withdraw(largeAmount, alice, alice);
// Gas cost: O(n) where n = number of batches
```

**Mitigation**: Users can consolidate by:
1. Withdrawing all funds after lockup
2. Redepositing as single batch

---

## Use Cases

### 1. Early-Stage Protocols (Prevent Rug Pools)

**Problem**: New protocols need to prove commitment without locking user funds permanently.

**Solution**:
```solidity
// Protocol founders deposit to wrapper
// Users see:
// - Funds locked for 7 days (can't rug immediately)
// - Founders can still sell position on secondary market if needed (liquidity)
// - After 7 days, natural unlock (not permanent lockup)
```

### 2. Yield Farming with Lock Bonuses

**Problem**: Protocols want to incentivize longer commitments.

**Solution**:
```solidity
// Base APY: 10%
// 7-day lockup: 15% APY (5% bonus)
// User deposits to wrapper, earns extra yield
// Can sell position early on secondary market if needed
```

### 3. Token Sale Vesting

**Problem**: Token sales need vesting but investors want some liquidity.

**Solution**:
```solidity
// Investors receive vTokens that unlock over time
// Can trade vTokens on secondary market at discount
// Buyers get tokens with shorter remaining lockup
```

### 4. DAO Treasury Management

**Problem**: DAOs want to prevent panic withdrawals during volatility.

**Solution**:
```solidity
// DAO treasury uses wrapper
// Withdrawals require 7-day notice period
// Gives DAO time to rebalance before outflows
// Members can sell positions if urgent need
```

---

## Integration Examples

### Depositing with Approval

```solidity
// User workflow
IERC20 asset = IERC20(wrapper.asset());
uint256 depositAmount = 1000e18;

// 1. Approve wrapper
asset.approve(address(wrapper), depositAmount);

// 2. Deposit
uint256 vTokens = wrapper.deposit(depositAmount, msg.sender);

// 3. User now has vTokens, can transfer immediately
wrapper.transfer(otherUser, vTokens / 2);
```

### Checking Unlocked Balance Before Withdrawal

```solidity
// Check how much can be withdrawn
uint256 unlocked = wrapper.unlockedBalanceOf(msg.sender);

if (unlocked >= desiredAmount) {
    wrapper.withdraw(desiredAmount, msg.sender, msg.sender);
} else {
    // Not enough unlocked, check remaining time
    uint256 timeLeft = wrapper.remainingLockTime(msg.sender);
    revert("Wait ${timeLeft} seconds");
}
```

### Trading on Secondary Market (DEX Integration)

```solidity
// vTokens are standard ERC20 - can use any DEX

// 1. Alice lists vTokens on Uniswap
router.addLiquidity(
    address(vToken),
    address(stablecoin),
    vTokenAmount,
    stablecoinAmount,
    ...
);

// 2. Bob buys vTokens at discount
router.swapExactTokensForTokens(
    stablecoinAmount,
    minVTokens,
    [stablecoin, vToken],
    bob,
    deadline
);

// 3. Bob now owns vTokens with inherited unlock times
// Can withdraw after original lockup expires
```

---

## Testing

Comprehensive test suite included in `test/VaultTimeLockWrapper.t.sol`:

```bash
# Run all tests
forge test --match-contract VaultTimeLockWrapperTest

# Run specific test
forge test --match-test test_transfer_preservesOriginalDepositTime

# Run with gas report
forge test --gas-report --match-contract VaultTimeLockWrapperTest

# Run with coverage
forge coverage --match-contract VaultTimeLockWrapperTest
```

### Test Coverage

- ✅ Basic deposit/withdraw flows
- ✅ Transfer preserves original timestamps
- ✅ FIFO withdrawal ordering
- ✅ Multiple deposits with different unlock times
- ✅ Emergency withdraw bypass
- ✅ ERC20 standard compliance
- ✅ Edge cases (zero amounts, insufficient balance, etc.)
- ✅ Complex multi-user scenarios

---

## Comparison: Gate-Based vs Wrapper-Based Lockup

| Feature | Gate-Based (Requires VaultV2 Mod) | Wrapper-Based (This Implementation) |
|---------|-----------------------------------|-------------------------------------|
| **VaultV2 Changes** | ❌ Requires notification hooks | ✅ Zero changes needed |
| **Lockup Enforcement** | ✅ Vault-native | ✅ Wrapper-enforced |
| **Transferable Positions** | ❌ Hard to implement | ✅ Native ERC20 |
| **Secondary Market** | ❌ Requires custom implementation | ✅ Works with any DEX |
| **Emergency Exit** | ✅ forceDeallocate | ✅ forceDeallocate |
| **Trust Model** | Trustless (vault-enforced) | Minimal trust (immutable wrapper) |
| **Gas Overhead** | Low (1 contract) | Medium (2 contracts) |
| **Direct Vault Bypass** | ❌ Can't bypass | ⚠️ Can bypass (mitigated with gate) |

---

## Deployment

```solidity
// 1. Deploy or get existing VaultV2
address vaultAddress = 0x...;

// 2. Deploy wrapper
VaultTimeLockWrapper wrapper = new VaultTimeLockWrapper(vaultAddress);

// 3. (Optional) Deploy wrapper-only gate to prevent direct vault access
WrapperOnlyGate gate = new WrapperOnlyGate(address(wrapper));

// 4. (Optional) Configure vault to use gate
vault.setReceiveSharesGate(address(gate));
```

### Gas Estimates

| Operation | Gas Cost | Notes |
|-----------|----------|-------|
| First deposit | ~150k | Creates first batch |
| Subsequent deposit | ~120k | Adds batch to queue |
| Withdraw (1 batch) | ~80k | Burns oldest batch |
| Withdraw (5 batches) | ~150k | Iterates through batches |
| Transfer (1 batch) | ~100k | Moves batch between users |
| Transfer (5 batches) | ~200k | Moves multiple batches |

---

## Limitations

1. **Cannot prevent direct vault access** (unless vault uses wrapper-only gate)
2. **Gas costs scale with deposit count** (FIFO queue iteration)
3. **Wrapper holds all vault shares** (users must trust immutable code)
4. **7-day lockup is hard-coded** (cannot be changed without redeployment)

---

## Future Enhancements

### 1. Configurable Lockup Periods
```solidity
constructor(address _vault, uint256 _lockPeriod) {
    vault = IVaultV2(_vault);
    LOCK_PERIOD = _lockPeriod;
}
```

### 2. Batch Consolidation Function
```solidity
// Merge multiple old batches into single new batch
function consolidateBatches() external {
    // Requires all batches to be unlocked
    // Reduces gas costs for future operations
}
```

### 3. NFT Receipts Instead of Fungible Tokens
```solidity
// Each deposit = unique NFT with metadata
// Better for tracking individual positions
// Worse for secondary market liquidity
```

### 4. Linear Unlocking (Instead of Cliff)
```solidity
// Instead of: locked → unlocked at T=7
// Implement: 0% → 100% linearly from T=0 to T=7
```

---

## Conclusion

VaultTimeLockWrapper provides a **production-ready solution** for time-based lockups that:

✅ Works with existing VaultV2 (no modifications)
✅ Creates secondary market for locked positions
✅ Preserves original depositor lockup guarantees
✅ Maintains non-custodial principles via forceDeallocate
✅ Fully ERC20 compliant for DEX integration

**Perfect for protocols needing lockup mechanisms while maintaining user liquidity options.**
