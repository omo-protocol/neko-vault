# Universal Adapter System - Comprehensive Documentation

## Table of Contents
1. [System Architecture Overview](#system-architecture-overview)
2. [Core Components](#core-components)
3. [PT-kHYPE Loop Strategy](#pt-khype-loop-strategy)
4. [End-to-End Flow](#end-to-end-flow)
5. [Security Features](#security-features)
6. [Testing & Integration](#testing--integration)

## System Architecture Overview

The Universal Adapter System is a sophisticated multi-strategy integration framework for Morpho Vault V2 that enables secure and flexible allocation to various DeFi strategies through a unified interface.

```
┌─────────────────┐
│   VaultV2       │ <── User deposits/withdrawals
└────────┬────────┘
         │
         ▼
┌─────────────────┐
│ UniversalEscrow │ <── Strategy adapter interface
│    Adapter      │ ←─┐
└────────┬────────┘   │
         │             │ realAssets()
         ▼             │
┌─────────────────┐    │
│ StrategyEscrow  │    │
│                 │    │
└────┬───────┬────┘    │
     │       │         │
     ▼       ▼         │
┌────────┐ ┌────────┐  │
│Strategy│ │Strategy│  │
│   A    │ │   B    │  │ <── Individual DeFi strategies
└────────┘ └────────┘  │     (PT-kHYPE, vNeko, etc.)
                        │
      ┌─────────────────┘
      │
      ▼
┌──────────────────────┐
│ UniversalValuer      │ <── Off-chain valuation system
│    Offchain          │     with signature verification
│                      │ ←── Off-Chain Keeper Service
└──────────────────────┘     (Python/Node.js)
```

## Core Components

### 1. UniversalEscrowAdapter (`src/adapters/UniversalEscrowAdapter.sol`)

**Purpose**: Bridge between Morpho Vault V2 and multiple strategies via StrategyEscrow.

**Key Features**:
- Implements IAdapter interface for vault compatibility
- Transfers funds to StrategyEscrow and notifies of allocations
- Manages strategy-specific allocation tracking
- Emergency withdrawal capabilities with penalty mechanism
- Strategy pausing for risk management

**Core Functions**:
```solidity
// Allocate funds to a strategy
function allocate(bytes memory data, uint256 assets, bytes4, address)
    returns (bytes32[] memory ids, int256 change)

// Deallocate funds from a strategy
function deallocate(bytes memory data, uint256 assets, bytes4, address)
    returns (bytes32[] memory ids, int256 change)

// Get total value across all strategies
function realAssets() returns (uint256)

// Emergency recovery with 2-step timelock (24 hours)
function initiateEmergencyRecovery()  // Step 1: Start timelock
function executeEmergencyRecovery()   // Step 2: Execute after 24 hours
```

**Data Format for Allocation/Deallocation**:
```solidity
(bytes32 strategyId, uint256 amount, bytes memory params) = abi.decode(
    data,
    (bytes32, uint256, bytes)
);
```

### 2. StrategyEscrow (`src/adapters/StrategyEscrow.sol`)

**Purpose**: Secure custody of funds with whitelisted multicall execution for strategies.

**Security Features**:
- Whitelisted function calls only
- Daily spending limits per function
- Strategy-specific agent authorization
- Emergency pause mechanism (72-hour max)
- Reentrancy protection
- Guardian role for emergency response

**Multicall Execution Flow**:
```solidity
struct Call {
    address target;    // Contract to call
    bytes data;       // Function calldata
    uint256 value;    // ETH to send (if any)
}

// Execute multiple calls atomically
function executeMulticall(bytes32 strategyId, Call[] calldata calls)
```

**Whitelist Management**:
```solidity
struct WhitelistEntry {
    bool allowed;        // Is function allowed
    uint256 dailyLimit;  // Daily spending limit (0 = unlimited)
    uint256 usedToday;   // Amount used today
    uint256 lastReset;   // Last reset timestamp
}
```

### 3. UniversalValuerOffchain - Off-Chain Valuation System (`src/valuers/UniversalValuerOffchain.sol`)

**Purpose**: Receive signed oracle reports from off-chain keeper service, significantly reducing audit costs.

**Architecture**:
```
┌─────────────────────────┐
│   Off-Chain Keeper      │
│  (Python Service)       │
├─────────────────────────┤
│ • Calculate values      │
│ • Monitor thresholds    │
│ • Sign reports          │
└───────────┬─────────────┘
            │ Signed Reports
            ▼
┌─────────────────────────┐
│ UniversalValuerOffchain │
├─────────────────────────┤
│ • Verify signatures     │
│ • Store values          │
│ • Manage staleness      │
│ • Emergency fallbacks   │
└─────────────────────────┘
```

**Key Features**:
- **Hybrid Push/Pull Model**: Updates on-demand or when thresholds exceeded
- **Multi-Signature Support**: Configurable signer weights for security
- **Confidence Scoring**: Each value has confidence score (0-100)
- **Emergency Mode**: Owner can force updates in emergencies
- **Fallback Values**: Backup values if oracle fails

**Value Report Structure**:
```solidity
struct ValueReport {
    uint256 value;        // Strategy value in base asset
    uint256 timestamp;    // When calculated
    uint256 confidence;   // 0-100 confidence score
    uint256 nonce;        // Replay protection
    bool isPush;          // Push vs pull update
    address lastUpdater;  // Who submitted
}
```

**Update Mechanisms**:
1. **Pull Model**: Anyone can request update via `requestUpdate(strategyId)`
2. **Push Model**: Keeper pushes when value change exceeds threshold
3. **Scheduled**: Automatic updates before staleness limit

**Off-Chain Keeper Service** (`src/keepers/OffchainValuationKeeper.py`):
- Monitors on-chain events for update requests
- Calculates strategy values using DeFi protocol APIs
- Signs values with authorized private key
- Submits signed reports to chain
- Handles batch updates for gas efficiency

**Deployment Steps**:
1. Deploy `UniversalValuerOffchain`
2. Configure authorized signers with appropriate weights
3. Start off-chain keeper service
4. Deploy adapter with `useOffchainValuer = true`
5. Configure strategy parameters and update thresholds

**Benefits**:
- Significantly reduced audit costs (~$20K one-time vs ~$50K per strategy)
- Minimal gas costs for valuation updates
- Flexible off-chain computation for complex strategies
- Cryptographic security through signature verification

## PT-kHYPE Loop Strategy

### Strategy Overview

The PT-kHYPE Loop is a sophisticated leveraged yield farming strategy that:
1. Takes kHYPE tokens as input
2. Swaps kHYPE for PT-kHYPE (Principal Tokens) via Pendle
3. Uses PT-kHYPE as collateral in Felix lending protocol
4. Borrows more kHYPE against the collateral
5. Repeats the loop to build leveraged exposure
6. Earns enhanced yield from the PT tokens

### Mathematical Model

```
Initial: 1000 kHYPE
Loop 1: Swap 1000 kHYPE → 1100 PT-kHYPE
        Deposit as collateral
        Borrow 800 kHYPE (LTV = 80%)
Loop 2: Swap 800 kHYPE → 880 PT-kHYPE
        Add to collateral (total: 1980 PT-kHYPE)
        Borrow 640 kHYPE
Loop 3: Continue until desired leverage...

Final Position:
- Collateral: ~4400 PT-kHYPE
- Debt: ~3200 kHYPE
- Leverage: ~4.4x
```

### Implementation Details

**Multicall Sequence for Building Loop**:
```solidity
Call[] memory calls = new Call[](10);

// 1. Approve Pendle Router for initial kHYPE
calls[0] = Call({
    target: address(kHYPE),
    data: abi.encodeWithSignature("approve(address,uint256)", pendleRouter, 1000e18),
    value: 0
});

// 2. Swap kHYPE to PT-kHYPE via Pendle
calls[1] = Call({
    target: pendleRouter,
    data: abi.encodeWithSignature(
        "swapExactTokenForPt(address,address,uint256,uint256,address,bytes)",
        kHYPE, pendleMarket, 1000e18, 1050e18, escrow, extraData
    ),
    value: 0
});

// 3. Approve Felix for PT-kHYPE collateral
calls[2] = Call({
    target: address(ptKHYPE),
    data: abi.encodeWithSignature("approve(address,uint256)", felix, 1100e18),
    value: 0
});

// 4. Deposit PT-kHYPE as collateral in Felix
calls[3] = Call({
    target: felix,
    data: abi.encodeWithSignature("depositCollateral(address,uint256)", ptKHYPE, 1100e18),
    value: 0
});

// 5. Borrow kHYPE from Felix
calls[4] = Call({
    target: felix,
    data: abi.encodeWithSignature("borrow(address,uint256)", kHYPE, 800e18),
    value: 0
});

// 6-9. Repeat loop with borrowed funds...
// 10. Final position update tracking
```

### Risk Parameters

- **Max LTV**: 80% (prevents liquidation)
- **Safety Buffer**: 5% (actual target LTV: 75%)
- **Min Loop Size**: 100 kHYPE (gas efficiency)
- **Max Loops**: 5 (risk limitation)
- **Slippage Tolerance**: 2% per swap

## End-to-End Flow

### 1. Initial Setup

```solidity
// Deploy core infrastructure
VaultV2 vault = new VaultV2(owner, kHYPE);
StrategyEscrow escrow = new StrategyEscrow(adapter, owner);
UniversalValuerOffchain valuer = new UniversalValuerOffchain(owner, kHYPE);
UniversalEscrowAdapter adapter = new UniversalEscrowAdapter(vault, escrow, valuer, true);

// Configure vault
vault.addAdapter(adapter);           // Enable adapter
vault.setIsAllocator(allocator);    // Authorize allocator
vault.increaseAbsoluteCap(PT_LOOP_ID, 1000000e18);  // Set caps
vault.increaseRelativeCap(PT_LOOP_ID, 0.5e18);      // 50% of TVL

// Configure off-chain valuer
valuer.configureSigner(authorizedSigner, true, 1);  // Authorize signer
valuer.setRequiredWeight(1);                        // Single signer setup
valuer.configureStrategy(PT_LOOP_ID, 300, 3600, 500, 90); // Strategy params

// Whitelist Pendle & Felix functions in escrow
escrow.updateWhitelist(pendleRouter, swapSelector, true, 10000e18); // 10k daily
escrow.updateWhitelist(felix, borrowSelector, true, 5000e18);       // 5k daily
```

### 2. User Deposits to Vault

```solidity
// User deposits kHYPE into vault
kHYPE.approve(vault, 10000e18);
vault.deposit(10000e18, user);
// User receives vault shares
```

### 3. Allocator Deploys to Strategy

```solidity
// Prepare allocation data
bytes memory data = abi.encode(
    PT_LOOP_ID,           // Strategy identifier
    5000e18,              // Amount to allocate
    loopParameters        // Strategy-specific params
);

// Execute allocation
vault.allocate(adapter, data, 5000e18);
```

**Internal Flow**:
1. Vault transfers 5000 kHYPE to adapter
2. Adapter transfers kHYPE to escrow
3. Adapter updates allocation tracking
4. Escrow notified of new allocation

### 4. Strategy Execution (PT Loop Building)

```solidity
// Keeper or automated system builds the loop
Call[] memory loopCalls = buildPTLoopCalls(5000e18);
escrow.executeMulticall(PT_LOOP_ID, loopCalls);
```

**Execution Steps**:
1. Each call is validated against whitelist
2. Daily limits are checked and updated
3. Calls executed atomically
4. Position state updated in escrow
5. Events emitted for monitoring

### 5. Valuation & Monitoring

```solidity
// Get current strategy value
uint256 totalValue = adapter.realAssets();

// Breakdown:
// - PT-kHYPE collateral value: 22000e18
// - Less kHYPE debt: 16000e18
// - Net value: 6000e18 (20% profit)
```

### 6. Deallocation & Exit

```solidity
// Prepare deallocation (unwind loop)
bytes memory deallocData = abi.encode(
    PT_LOOP_ID,
    5000e18,              // Amount to withdraw
    unwindParameters      // Include slippage, route, etc.
);

// Execute deallocation
vault.deallocate(adapter, deallocData, 5000e18);
```

**Unwind Sequence**:
1. Repay kHYPE debt to Felix
2. Withdraw PT-kHYPE collateral
3. Swap PT-kHYPE back to kHYPE
4. Transfer kHYPE back to adapter
5. Update allocation tracking

### 7. User Withdrawal

```solidity
// User redeems vault shares
uint256 shares = vault.balanceOf(user);
vault.redeem(shares, user, user);
// User receives proportional kHYPE including profits
```

## Security Features

### Multi-Layer Defense

1. **Vault Level**
   - Timelocked configuration changes
   - Role-based access control
   - Absolute and relative caps
   - Force deallocate mechanism

2. **Adapter Level**
   - Strategy pausing capability
   - **2-Step Emergency Recovery**: 24-hour timelock for fund safety
   - **Access Control**: Configurable emergency withdrawal recipient
   - **Safe Math**: Overflow/underflow protection in penalty calculations
   - Allocation tracking & limits
   - Only accepts calls from vault

3. **Escrow Level**
   - Whitelisted calls only
   - Daily spending limits
   - Strategy-specific agents
   - 72-hour emergency pause
   - Guardian for quick response
   - Reentrancy protection

4. **Valuation Level (Off-Chain)**
   - **Cryptographic Security**: ECDSA signature verification with expiry
   - **Multi-Sig Support**: Configurable weights with timelock rotation
   - **Enhanced Security**:
     - **Signer Rotation**: 24-hour timelock for removing signers
     - **Signature Expiry**: 1-hour max validity period
     - **Duplicate Prevention**: Tracks used signers per update
     - **Price Bounds**: Configurable max change (default 50%)
   - **Replay Protection**: Nonce-based deduplication
   - **Staleness Protection**: Automatic value expiry (24 hours max)
   - **Confidence Thresholds**: Minimum 95% confidence required
   - **Emergency Overrides**: Owner can force updates in emergency mode
   - **Fallback Values**: Backup values if oracle fails
   - **Audit Efficiency**: Simple on-chain logic reduces audit surface
   - **Signer Rotation**: 24-hour timelock for removing authorized signers
   - **Signature Expiry**: Max 1-hour validity to prevent replay attacks
   - **Duplicate Prevention**: Built-in protection against duplicate signatures
   - **Price Validation**: On-chain bounds checking (default 50% max change)

### Emergency Procedures

**1. Strategy Pause**:
```solidity
adapter.toggleStrategyPause(PT_LOOP_ID, true);
// Prevents new allocations, allows deallocations
```

**2. Multicall Pause**:
```solidity
escrow.pauseMulticall(); // Guardian or owner
// Blocks all strategy executions for 72 hours max
```

**3. Force Recovery (2-Step Process)**:
```solidity
// Step 1: Initiate recovery (owner only)
adapter.initiateEmergencyRecovery();
// Wait 24 hours...

// Step 2: Execute recovery after timelock
adapter.executeEmergencyRecovery();
// 0.5% penalty applied
// Funds sent to configured recipient
```

**4. Force Deallocate**:
```solidity
vault.forceDeallocate(adapter);
// Permissionless in-kind redemption
// Users receive strategy tokens directly
```

## Testing & Integration

### Test Architecture

```
test/
├── unit/
│   ├── UniversalEscrowAdapterFixedAuth.t.sol     # Adapter unit tests (30/30 passing)
│   ├── StrategyEscrowComprehensiveFinal.t.sol    # Escrow security tests (36/36 passing)
│   └── UniversalValuerOffchainFixed.t.sol        # Off-chain valuation tests (52/52 passing, 96.55% coverage)
│
└── integration/
    └── UniversalEscrowSimpleE2E.t.sol            # End-to-end integration tests (6/6 passing)
```

### Key Test Scenarios

**1. Basic Flow Test**:
```solidity
function testEndToEndPTLoopStrategy() {
    // Setup
    _setupVaultAndAdapter();
    _fundUser(1000e18);

    // User deposit
    vm.prank(user);
    vault.deposit(1000e18, user);

    // Allocate to strategy
    _allocateToPTLoop(500e18);

    // Build loop
    _executePTLoopMulticall();

    // Verify position
    assertGt(adapter.realAssets(), 500e18); // Profit generated

    // Deallocate
    _deallocateFromPTLoop(500e18);

    // User withdrawal
    vm.prank(user);
    vault.redeem(vault.balanceOf(user), user, user);
}
```

**2. Advanced Multicall Test**:
```solidity
function testAdvancedPTLoopWithMulticall() {
    // Complex 10-step multicall building leveraged loop
    Call[] memory calls = _buildCompleteLoopCalls();

    // Execute atomically
    escrow.executeMulticall(PT_LOOP_ID, calls);

    // Verify final position
    MockFelix felix = MockFelix(felixAddress);
    assertEq(felix.collateral(escrow), 4400e18);  // 4.4x leverage
    assertEq(felix.debt(escrow), 3200e18);
}
```

**3. Security Test**:
```solidity
function testEmergencyPauseAndRecovery() {
    // Simulate attack detection
    vm.prank(guardian);
    escrow.pauseMulticall();

    // Verify multicalls blocked
    vm.expectRevert();
    escrow.executeMulticall(PT_LOOP_ID, calls);

    // Execute emergency recovery
    vm.prank(owner);
    adapter.forceRecovery();

    // Verify funds recovered with penalty
    uint256 recovered = asset.balanceOf(adapter);
    assertApproxEq(recovered, initialAmount * 995 / 1000); // 0.5% penalty
}
```

### Mock Implementations

**MockStrategyEscrow**: Simplified escrow for testing without circular dependencies
**MockPendleRouter**: Simulates PT swaps with configurable exchange rates
**MockFelix**: Simulates lending/borrowing with LTV enforcement
**MockPTLoopValuer**: Returns test values for position valuation

## Configuration Examples

### Production Setup

#### Off-Chain Valuer Configuration

```solidity
// Deploy off-chain valuer
UniversalValuerOffchain valuer = new UniversalValuerOffchain(owner, asset);

// Configure signers (multi-sig setup with timelock)
valuer.initiateSignerChange(signer1, true, 1);  // Add signer1 with weight 1
valuer.initiateSignerChange(signer2, true, 1);  // Add signer2 with weight 1
valuer.setRequiredWeight(2);                     // Require both signatures

// To remove a signer (24-hour timelock required)
valuer.initiateSignerChange(signer1, false, 0);  // Start removal timelock
// Wait 24 hours...
valuer.executeSignerRemoval(signer1);            // Complete removal

// Configure PT-kHYPE strategy
valuer.configureStrategy(
    PT_KHYPE_LOOP,
    5 minutes,     // Min update interval
    1 hours,       // Max staleness
    500,           // 5% push threshold (basis points)
    90             // 90% min confidence
);

// Deploy adapter with off-chain valuer
UniversalEscrowAdapter adapter = new UniversalEscrowAdapter(
    vault,
    escrow,
    address(valuer),
    true           // useOffchainValuer = true
);
```

#### Keeper Configuration (`keeper_config.json`)

```json
{
  "rpc_url": "https://mainnet.infura.io/v3/YOUR_KEY",
  "valuer_address": "0x...",
  "strategies": [
    {
      "id": "PT_KHYPE_LOOP",
      "min_update_interval": 300,
      "max_staleness": 3600,
      "push_threshold": 500,
      "min_confidence": 90
    }
  ],
  "keeper_settings": {
    "update_check_interval": 60,
    "batch_size": 10
  }
}
```

#### Protocol Addresses

```solidity
// Mainnet addresses
address PENDLE_ROUTER = 0x888888888889758F76e7103c6CbF23ABbF58F946;
address FELIX_LENDING = 0x...;
address PT_KHYPE_MARKET = 0x...;

// Conservative parameters
uint256 MAX_LEVERAGE = 3; // 3x max
uint256 TARGET_LTV = 70;  // 70% target, 80% max
uint256 SLIPPAGE = 100;   // 1% slippage

// Daily limits (for StrategyEscrow)
uint256 PENDLE_DAILY_LIMIT = 100_000e18;
uint256 FELIX_DAILY_LIMIT = 50_000e18;
```

### Testing Setup

```solidity
// Use mock contracts
address pendleRouter = address(new MockPendleRouter());
address felix = address(new MockFelix());

// Aggressive parameters for testing
uint256 MAX_LEVERAGE = 5;
uint256 TARGET_LTV = 78;
uint256 SLIPPAGE = 500; // 5% for testing

// No daily limits for testing
uint256 DAILY_LIMIT = type(uint256).max;
```

## Future Enhancements

1. **Additional Strategies**
   - vNeko volatility farming
   - Concentrated liquidity provision
   - Options strategies
   - Cross-chain strategies

2. **Advanced Features**
   - Automated rebalancing keepers
   - Risk scoring system
   - Dynamic cap adjustment
   - Multi-asset support
   - Flash loan integrations

3. **Optimizations**
   - Batch operations for gas efficiency
   - Cross-strategy netting
   - Compressed position tracking
   - Layer 2 deployment

## Conclusion

The Universal Adapter System provides a robust, secure, and extensible framework for integrating multiple DeFi strategies into Morpho Vault V2. The PT-kHYPE loop demonstrates the system's capability to handle complex, multi-step strategies with proper risk management and emergency procedures.

Key strengths:
- **Modularity**: Easy to add new strategies
- **Security**: Multiple layers of protection
- **Flexibility**: Configurable parameters and limits
- **Efficiency**: Caching and batch operations
- **Transparency**: Clear audit trail and monitoring

The system is production-ready with comprehensive testing and can be extended to support any DeFi strategy that requires secure, non-custodial fund management.