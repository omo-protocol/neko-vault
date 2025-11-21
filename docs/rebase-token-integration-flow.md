# How VaultV2, Adapters, and Escrow Use Rebase Tokens

## Architecture Overview

The key insight is that **VaultV2, adapters, and escrows NEVER directly touch the rebase token**. They only interact with the wrapper, which presents a stable ERC4626 interface.

```
┌──────────────┐     ┌──────────────┐     ┌──────────────┐     ┌──────────────┐
│ Rebase Token │────►│   Wrapper    │────►│   VaultV2    │────►│   Adapter    │
│   (stETH)    │     │  (wstETH)    │     │              │     │              │
└──────────────┘     └──────────────┘     └──────────────┘     └──────────────┘
   Dynamic            Stable ERC4626        Standard            Standard
   Balance            Interface             Operations          Operations
                                                │
                                                ▼
                                        ┌──────────────┐
                                        │    Escrow    │
                                        │              │
                                        └──────────────┘
                                            Holds wrapped
                                            tokens only
```

## Detailed Flow

### 1. Initial Setup

```solidity
// Step 1: Deploy wrapper for rebase token (e.g., stETH)
address stETH = 0x...; // Rebasing token
UniversalTokenWrapper wstETH = factory.deployWrapper(
    stETH,
    "Wrapped stETH",
    "wstETH"
);

// Step 2: Create VaultV2 using WRAPPER as asset (NOT the rebase token)
VaultV2 vault = new VaultV2(
    address(wstETH),  // ← Uses wrapper, not stETH
    "stETH Vault",
    "vstETH",
    owner,
    curator
);

// Step 3: Adapters are configured to work with wrapper tokens
UniversalEscrowAdapter adapter = new UniversalEscrowAdapter(
    address(vault),
    address(escrow),
    address(valuer),
    address(wstETH)  // ← Adapter handles wrapper tokens
);
```

### 2. User Deposit Flow

```solidity
// User has 1000 stETH (rebasing token)

// Option A: Direct wrapping then vault deposit
stETH.approve(wstETH, 1000e18);
uint256 wstETHShares = wstETH.deposit(1000e18, user);  // Get wrapper shares
wstETH.approve(vault, wstETHShares);
uint256 vaultShares = vault.deposit(wstETHShares, user);  // Deposit wrapper shares to vault

// Option B: Using integration helper (automatic)
stETH.approve(integration, 1000e18);
uint256 vaultShares = integration.depositNonStandardToken(
    vault,
    stETH,
    1000e18,
    user
);
```

**What happens internally:**

1. **Wrapper receives stETH**:
   - Measures actual balance before/after transfer
   - Mints wrapper shares based on actual received amount
   - Records current balance for rebase tracking

2. **Vault receives wrapper shares**:
   - Treats wrapper shares as standard ERC20
   - No special logic needed for rebasing
   - Standard ERC4626 operations

3. **Vault allocates to adapter**:
   - Transfers wrapper shares to adapter/escrow
   - Adapter sees stable wrapper tokens, not rebasing tokens

### 3. During Rebases

```solidity
// Example: stETH rebases up 10% (all holders get 10% more tokens)

// Before rebase:
// - User deposited: 1000 stETH
// - Wrapper holds: 1000 stETH
// - User has: 950 wrapper shares (example)
// - Vault has: 950 wrapper shares from user

// stETH rebases (happens automatically)
// - Wrapper now holds: 1100 stETH (10% increase)
// - Wrapper shares: UNCHANGED at 950
// - Share value: Each share now worth 1.1579 stETH instead of 1.0526

// When anyone interacts with wrapper:
wrapper.sync();  // Updates internal accounting

// Wrapper's totalAssets() now returns 1100 stETH
// User's 950 shares still exist but are worth more stETH
```

### 4. Vault Operations with Wrapped Tokens

```solidity
contract VaultV2 {
    address public asset;  // This is wstETH (wrapper), NOT stETH

    function totalAssets() public view returns (uint256) {
        // Returns total wrapper shares held
        uint256 wrapperShares = IERC20(asset).balanceOf(address(this));

        // Add allocated wrapper shares from adapters
        for (uint256 i; i < adapters.length; i++) {
            wrapperShares += adapters[i].realAssets();
        }

        return wrapperShares;
        // Note: This is wrapper shares, not underlying stETH
        // The wrapper handles conversion to actual stETH value
    }

    function deposit(uint256 assets, address receiver)
        external returns (uint256 shares)
    {
        // 'assets' here is wrapper shares, not stETH
        // Vault doesn't know or care about rebasing
        require(assets != 0, "ZERO_ASSETS");

        accrueInterest();

        // Standard ERC4626 share calculation
        shares = convertToShares(assets);

        // Transfer wrapper shares from user
        SafeERC20.safeTransferFrom(IERC20(asset), msg.sender, address(this), assets);

        // Mint vault shares
        _mint(receiver, shares);

        // Allocate to liquidity adapter if configured
        if (liquidityAdapter != address(0)) {
            _allocateToLiquidityAdapter(assets);
        }
    }
}
```

### 5. Adapter Handling

```solidity
contract UniversalEscrowAdapter {
    address public asset;  // wstETH (wrapper)
    address public escrow;

    function allocate(bytes memory data, uint256 assets, bytes4, address)
        external returns (bytes32[] memory ids, int256 change)
    {
        // 'assets' is wrapper shares, not rebasing tokens

        // Transfer wrapper shares to escrow
        SafeERC20.safeTransferFrom(asset, parentVault, escrow, assets);

        // Escrow now holds wrapper shares
        // It can use them in DeFi protocols that accept wstETH

        if (data.length > 0) {
            IStrategyEscrow(escrow).executeStrategy(data);
        }

        return (ids, int256(assets));
    }

    function realAssets() external view returns (uint256) {
        // Returns wrapper shares in escrow
        // NOT the underlying rebasing token amount
        return IERC20(asset).balanceOf(escrow);
    }
}
```

### 6. Escrow Strategy Execution

```solidity
contract StrategyEscrow {
    // Escrow holds wrapper tokens (wstETH), not rebasing tokens (stETH)

    function executeStrategy(bytes[] calldata calls) external onlyAgent {
        // Example: Deploy wstETH to Pendle
        // Pendle accepts wstETH (non-rebasing) not stETH (rebasing)

        // calls[0]: Approve Pendle to spend wstETH
        // target: wstETH, selector: approve
        _executeCall(calls[0]);

        // calls[1]: Swap wstETH for PT-wstETH on Pendle
        // target: PendleRouter, selector: swapExactTokenForPt
        _executeCall(calls[1]);

        // Throughout this process, escrow only handles stable wrapper tokens
    }
}
```

### 7. Valuation

```solidity
contract ScalableValuer {
    function getTotalValue() external view returns (uint256) {
        // Value wrapper tokens in escrow
        uint256 wstETHBalance = IERC20(wstETH).balanceOf(escrow);

        // Get wrapper's share price (accounts for rebasing)
        uint256 stETHPerShare = IWrapper(wstETH).convertToAssets(1e18);

        // Total value in underlying terms
        uint256 totalStETHValue = wstETHBalance * stETHPerShare / 1e18;

        // Convert to USD or base currency
        uint256 stETHPrice = oracle.getPrice(stETH);
        return totalStETHValue * stETHPrice / 1e18;
    }
}
```

## Complete Example: stETH → Vault → Pendle PT

```solidity
// 1. User deposits stETH (rebasing) to get vault shares
function userDepositFlow() external {
    uint256 stETHAmount = 1000e18;

    // Wrap stETH → wstETH
    stETH.approve(wstETH, stETHAmount);
    uint256 wstETHShares = wstETH.deposit(stETHAmount, address(this));
    // wstETHShares = 871.23e18 (example, depends on exchange rate)

    // Deposit wstETH to vault
    wstETH.approve(vault, wstETHShares);
    uint256 vaultShares = vault.deposit(wstETHShares, address(this));
    // vaultShares = 871.23e18 (1:1 initially if vault is empty)
}

// 2. Vault allocates to Pendle adapter
function vaultAllocationFlow() external {
    // Vault has 871.23e18 wstETH from user

    // Allocate to Pendle adapter
    bytes memory pendleData = abi.encode("PT-wstETH-Dec2024");
    adapter.allocate(pendleData, 871.23e18, bytes4(0), address(vault));

    // Now escrow holds 871.23e18 wstETH
}

// 3. Escrow executes Pendle strategy
function escrowStrategyFlow() external {
    bytes[] memory calls = new bytes[](2);

    // Approve Pendle
    calls[0] = abi.encodeCall(
        IERC20.approve,
        (PENDLE_ROUTER, 871.23e18)
    );

    // Swap wstETH for PT-wstETH
    calls[1] = abi.encodeCall(
        IPendleRouter.swapExactTokenForPt,
        (escrow, PT_MARKET, 871.23e18, minPtOut, approxParams, tokenInput, limitOrder)
    );

    escrow.executeStrategy(calls);

    // Escrow now holds PT-wstETH instead of wstETH
}

// 4. During stETH rebase
function rebaseEffect() external view {
    // stETH rebases +2% daily
    // This does NOT affect:
    // - Vault share count
    // - wstETH token count
    // - PT-wstETH count

    // This DOES affect:
    // - Value of wstETH when unwrapped to stETH
    // - Final redemption value for users

    // Example after 30 days of 2% daily rebases:
    // - User's vault shares: still 871.23e18
    // - Vault's wstETH: still 871.23e18
    // - wstETH value in stETH: 1000e18 * 1.02^30 = 1811.36e18
    // - User redeems and gets 1811.36 stETH for same shares
}

// 5. User withdrawal
function userWithdrawFlow() external {
    // User redeems vault shares
    uint256 vaultShares = 871.23e18;

    // Vault returns wstETH shares
    uint256 wstETHReceived = vault.redeem(vaultShares, address(this), address(this));

    // Unwrap wstETH → stETH
    uint256 stETHReceived = wstETH.redeem(wstETHReceived, address(this), address(this));

    // stETHReceived = 1811.36e18 (includes all rebases)
}
```

## Key Points

### What Each Component Sees:

1. **VaultV2**:
   - Only sees stable wrapper tokens (wstETH)
   - No rebase logic needed
   - Standard ERC4626 operations

2. **Adapters**:
   - Transfer wrapper tokens between vault and escrow
   - Report wrapper token balances
   - No special rebase handling

3. **Escrow**:
   - Holds wrapper tokens
   - Executes strategies with wrapper tokens
   - DeFi protocols prefer wrapped versions anyway

4. **Wrapper**:
   - ONLY component that touches rebasing tokens
   - Handles all rebase complexity
   - Presents stable interface to everything else

### Why This Works:

1. **Separation of Concerns**: Rebase complexity isolated in wrapper
2. **No Code Changes**: Vault/adapters/escrow unchanged
3. **DeFi Compatible**: Most protocols already prefer wrapped versions (wstETH over stETH)
4. **Value Preservation**: Users get full rebase benefits when unwrapping

### Common Rebasing Tokens and Their Wrappers:

| Rebasing Token | Wrapper Token | Used By |
|----------------|---------------|---------|
| stETH | wstETH | Most DeFi protocols |
| AMPL | wAMPL | Not widely adopted |
| OHM | gOHM | Olympus ecosystem |
| UST (historical) | aUST | Anchor protocol |

The wrapper approach is already battle-tested in production with wstETH, which is exactly what our `UniversalTokenWrapper` generalizes for any rebasing or fee-on-transfer token.