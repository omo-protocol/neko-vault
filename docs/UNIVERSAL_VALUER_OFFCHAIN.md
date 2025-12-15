# UniversalValuerOffchain - Technical Specification

> Off-chain oracle with signed reports for strategy valuations
> Location: `src/valuers/UniversalValuerOffchain.sol`

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [State Variables](#state-variables)
- [Functions](#functions)
- [Security Mechanisms](#security-mechanisms)
- [Signature Validation](#signature-validation)
- [Events](#events)
- [Invariants & Assumptions](#invariants--assumptions)
- [Keeper Integration](#keeper-integration)

---

## Overview

UniversalValuerOffchain is an on-chain oracle system that accepts signed valuation reports from off-chain keepers. It implements a hybrid push/pull model with multi-signature support, replay protection, and multiple fallback mechanisms.

### Key Features

- **Signed Reports**: EIP-191 ECDSA signatures from authorized keepers
- **Multi-Sig Support**: Weighted voting with configurable thresholds
- **Replay Protection**: Nonce-based with expiry windows
- **Atomic Batches**: All-or-nothing batch updates
- **Fallback Layers**: Fresh → Stale → Cached → Fallback → Emergency

### Data Flow

```
Off-Chain Keeper (Python)
    │
    ├─── Calculate strategy value
    ├─── Sign with ECDSA (EIP-191)
    │
    ▼
UniversalValuerOffchain.updateValue()
    │
    ├─── Verify signature(s)
    ├─── Validate bounds & staleness
    ├─── Store ValueReport
    │
    ▼
UniversalAdapterEscrow.realAssets()
    │
    └─── Queries getValue(ESCROW_TOTAL_ID) + isValuationHealthy()
```

---

## Architecture

### ValueReport Structure

```solidity
struct ValueReport {
    uint256 value;          // Strategy value in asset units
    uint256 timestamp;      // When report was submitted
    uint256 confidence;     // Confidence level (0-100)
    uint256 nonce;          // Monotonically increasing nonce
    bool isPush;            // true = keeper push, false = emergency
    address lastUpdater;    // Address that submitted the update
}
```

### UpdateConfig Structure

```solidity
struct UpdateConfig {
    uint256 minUpdateInterval;  // Minimum seconds between updates
    uint256 maxStaleness;       // Maximum age before stale
    uint256 pushThreshold;      // Min price change for off-schedule update
    uint256 minConfidence;      // Minimum confidence required
}
```

### SignerConfig Structure

```solidity
struct SignerConfig {
    bool authorized;    // Is signer active
    uint256 weight;     // Voting weight for multi-sig
}
```

---

## State Variables

### Core State

```solidity
address public owner;                                      // Contract owner
address public asset;                                      // Base asset token
mapping(bytes32 => ValueReport) public latestReports;     // Latest report per strategy
mapping(address => SignerConfig) public signers;          // Authorized signers
mapping(bytes32 => UpdateConfig) public updateConfigs;    // Per-strategy config
```

### Multi-Sig Parameters

```solidity
uint256 public requiredWeight;              // Min signature weight needed
uint256 public defaultConfidenceThreshold;  // Default confidence (90%)
```

### Fallback & Emergency

```solidity
mapping(bytes32 => uint256) public fallbackValues;  // Emergency backup values
bool public emergencyMode;                          // Enable emergency operations
```

### Signer Management

```solidity
mapping(address => uint256) public signerChangeTimestamp;   // Timelock expiry
mapping(address => bool) public pendingSignerRemoval;       // Pending removals
```

### Validation Bounds

```solidity
mapping(bytes32 => uint256) public maxPriceChangeBps;   // Max change per strategy
mapping(bytes32 => uint256) public maxInitialValue;     // First report limit
```

### Constants

```solidity
uint256 constant MAX_STALENESS = 24 hours;
uint256 constant MIN_UPDATE_INTERVAL = 5 minutes;
uint256 constant BASIS_POINTS = 10000;
uint256 constant SIGNER_TIMELOCK = 24 hours;
uint256 constant MAX_SIGNATURE_AGE = 1 hour;
uint256 constant MAX_PRICE_CHANGE_BPS = 5000;       // 50%
uint256 constant MAX_NONCE_GAP = 1000;
uint256 constant ABSOLUTE_MAX_STALENESS = 48 hours;
```

---

## Functions

### Core Valuation Functions

#### `updateValue`

```solidity
function updateValue(
    bytes32 strategyId,
    uint256 value,
    uint256 confidence,
    uint256 nonce,
    uint256 expiry,
    bytes[] calldata signatures
) external
```

**Purpose**: Submit single strategy valuation with signed reports.

**Validation Steps**:
1. `nonce > lastReport.nonce` (strictly increasing)
2. `nonce <= lastReport.nonce + MAX_NONCE_GAP` (prevents overflow)
3. `expiry >= block.timestamp` (not expired)
4. `expiry <= block.timestamp + MAX_SIGNATURE_AGE` (not too far future)
5. `confidence >= config.minConfidence`
6. Price change within bounds (or first report within maxInitialValue)
7. Update interval respected (unless significant change)
8. Total signature weight >= requiredWeight

**Message Hash**:
```solidity
keccak256(abi.encode(
    strategyId,
    value,
    confidence,
    nonce,
    expiry,
    block.chainid,    // Cross-chain replay protection
    address(this)     // Cross-instance replay protection
))
```

#### `batchUpdateValues`

```solidity
function batchUpdateValues(
    bytes32[] calldata strategyIds,
    uint256[] calldata values,
    uint256[] calldata confidences,
    uint256 nonce,
    uint256 expiry,
    bytes[] calldata signatures
) external
```

**Purpose**: Atomically update multiple strategies.

**Critical Feature**: **ATOMIC VALIDATION**
- Phase 1: Validate ALL strategies (if any fails, entire batch reverts)
- Phase 2: Update ALL strategies (only if Phase 1 passed)

**Attack Prevented**: Partial state corruption from value manipulation.

#### `getValue`

```solidity
function getValue(bytes32 strategyId) external view returns (uint256)
```

**Purpose**: Get latest value with staleness/confidence validation.

**Fallback Priority**:
1. Fresh report (within maxStaleness, confidence >= minConfidence)
2. Fallback value (if no report exists)
3. Revert `ValueTooStale` or `LowConfidence`

#### `isValuationHealthy`

```solidity
function isValuationHealthy(address escrow) external view returns (bool healthy)
```

**Purpose**: Check if all strategies for an escrow have fresh valuation data.

**Returns**:
- `true` if all strategies have fresh values (within maxStaleness, confidence >= minConfidence)
- `false` if any strategy has stale data or uses fallback values

**Note**: The adapter uses `getValue(ESCROW_TOTAL_ID)` to get the pre-computed total value pushed by the keeper. This function is used by the adapter to determine if a haircut should be applied.

### Admin Functions

#### Signer Management

```solidity
// Start signer change (immediate for adds, timelocked for removes)
function initiateSignerChange(address signer, bool authorized, uint256 weight) external onlyOwner

// Complete pending removal after 24h
function executeSignerRemoval(address signer) external onlyOwner

// Cancel pending removal
function cancelSignerRemoval(address signer) external onlyOwner
```

**Timelock Behavior**:
- Adding signer: Immediate
- Removing signer: 24-hour delay before executeSignerRemoval

#### Strategy Configuration

```solidity
function configureStrategy(
    bytes32 strategyId,
    uint256 minUpdateInterval,
    uint256 maxStaleness,
    uint256 pushThreshold,
    uint256 minConfidence
) external onlyOwner
```

**Validation**:
- `minUpdateInterval >= MIN_UPDATE_INTERVAL` (5 min)
- `maxStaleness <= MAX_STALENESS` (24 hours)
- `pushThreshold <= MAX_PRICE_CHANGE_BPS` (50%)
- `minUpdateInterval < maxStaleness` (prevents stuck state)
- `pushThreshold <= maxPriceChangeBps[strategyId]`

#### Bounds Configuration

```solidity
// Set max price change per update
function setPriceChangeBounds(bytes32 strategyId, uint256 maxChangeBps) external onlyOwner

// Set max initial value (decimal mismatch protection)
function setMaxInitialValue(bytes32 strategyId, uint256 maxValue) external onlyOwner

// Set emergency fallback value
function setFallbackValue(bytes32 strategyId, uint256 value) external onlyOwner
```

#### Emergency Operations

```solidity
// Toggle emergency mode
function setEmergencyMode(bool enabled) external onlyOwner

// Force set value (bypasses all validation)
function emergencyUpdate(bytes32 strategyId, uint256 value) external onlyOwner
```

**Emergency Update**:
- Requires `emergencyMode == true`
- Sets confidence = 100
- Sets isPush = false
- Increments nonce by 1

### Query Functions

```solidity
function needsUpdate(bytes32 strategyId) external view returns (bool)
function getReport(bytes32 strategyId) external view returns (ValueReport memory)
function isAuthorizedSigner(address signer) external view returns (bool)
```

---

## Security Mechanisms

### Signature Validation

```solidity
// EIP-191 prefix
bytes32 ethSignedHash = keccak256(abi.encodePacked(
    "\x19Ethereum Signed Message:\n32",
    messageHash
));

// Recover signer
address signer = ECDSA.recover(ethSignedHash, signature);
```

**Protections**:
- Uses OpenZeppelin's battle-tested ECDSA library
- Validates signature length = 65 bytes
- Handles signature malleability
- Returns address(0) on invalid recovery → caught and reverted

### Replay Prevention

1. **Nonce-Based**: Strictly increasing per strategy
2. **Gap-Bounded**: `nonce <= lastNonce + 1000` (prevents overflow attack)
3. **Signature Expiry**: 1-hour validity window
4. **Domain Separation**: Includes chainId and contract address in hash

### Duplicate Signer Prevention

```solidity
address[] memory usedSigners = new address[](signatures.length);
for (uint256 i = 0; i < signatures.length; i++) {
    // Check if already used
    for (uint256 j = 0; j < usedCount; j++) {
        if (usedSigners[j] == signer) {
            alreadyUsed = true;
            break;
        }
    }
    if (alreadyUsed) continue; // Skip duplicate
}
```

### Price Volatility Bounds

```solidity
uint256 changePercent = _calculateChangePercent(oldValue, newValue);
if (changePercent > maxPriceChangeBps[strategyId]) {
    revert PriceChangeExceedsBounds(changePercent, maxPriceChangeBps[strategyId]);
}
```

Default: 50% max change per update.

### Decimal Mismatch Protection

```solidity
// For first report only
if (lastReport.value == 0 && maxInitialValue[strategyId] > 0) {
    if (value > maxInitialValue[strategyId]) {
        revert InitialValueExceedsMax(value, maxInitialValue[strategyId]);
    }
}
```

**Attack Prevented**: Submitting 1e18 for a 6-decimal token.

---

## Events

### Valuation Events

```solidity
event ValueUpdated(
    bytes32 indexed strategyId,
    uint256 value,
    uint256 confidence,
    uint256 timestamp,
    bool isPush
);

event UpdateRequested(
    bytes32 indexed strategyId,
    address requester,
    UpdateReason reason  // STALENESS, THRESHOLD, ON_DEMAND, EMERGENCY
);
```

### Signer Events

```solidity
event SignerConfigured(address indexed signer, bool authorized, uint256 weight);
event SignerRemovalInitiated(address indexed signer, uint256 executeTimestamp);
event SignerRemovalCancelled(address indexed signer);
```

### Configuration Events

```solidity
event StrategyConfigured(bytes32 indexed strategyId, uint256 minUpdateInterval, uint256 maxStaleness, uint256 pushThreshold);
event RequiredWeightUpdated(uint256 newWeight);
event PriceChangeBoundsSet(bytes32 indexed strategyId, uint256 maxChangeBps);
event FallbackValueSet(bytes32 indexed strategyId, uint256 value);
```

### Emergency Events

```solidity
event EmergencyModeToggled(bool enabled);
event EmergencyValueUpdate(bytes32 indexed strategyId, uint256 value);
```

---

## Invariants & Assumptions

### Critical Invariants

| Invariant | Description |
|-----------|-------------|
| **Nonce Monotonicity** | `latestReports[id].nonce` always increases |
| **Multi-Sig Quorum** | Updates require `sum(weights) >= requiredWeight` |
| **Signature Freshness** | All signatures within 1-hour window |
| **Price Bounds** | Change ≤ maxPriceChangeBps (or first value ≤ maxInitialValue) |
| **Config Consistency** | `minUpdateInterval < maxStaleness` |
| **Atomic Batches** | All strategies update or none update |
| **Absolute Staleness** | Values older than 48h never used in health checks |

### Key Assumptions

1. **Keeper Availability**: At least one authorized keeper runs regularly
2. **Key Security**: Signer private keys are secure
3. **Owner Trust**: Owner acts in best interest (controls config)
4. **Asset Token**: IERC20(asset) is correct and trustworthy
5. **Price Data Quality**: Keepers calculate accurate values
6. **Escrow Compatibility**: getActiveStrategies() returns correctly

---

## Keeper Integration

### Message Signing (Python)

```python
from web3 import Web3
from eth_account import Account
from eth_account.messages import encode_defunct
from eth_abi import encode as abi_encode

# Build message hash
message_hash = Web3.keccak(abi_encode(
    ['bytes32', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'address'],
    [strategy_id, value, confidence, nonce, expiry, chain_id, valuer_address]
))

# Sign with EIP-191 prefix
message = encode_defunct(message_hash)
signed = Account.sign_message(message, private_key)
signature = signed.signature  # 65 bytes
```

### Submit Update (Python)

```python
tx = valuer_contract.functions.updateValue(
    strategy_id,
    value,
    confidence,
    nonce,
    expiry,
    [signature]
).build_transaction({
    'from': keeper_address,
    'gas': 200000,
    'nonce': web3.eth.get_transaction_count(keeper_address)
})

signed_tx = web3.eth.account.sign_transaction(tx, private_key)
tx_hash = web3.eth.send_raw_transaction(signed_tx.rawTransaction)
```

### Multi-Signer Batch (Python)

```python
# Both keepers sign same batch
batch_hash = Web3.keccak(abi_encode(
    ['bytes32[]', 'uint256[]', 'uint256[]', 'uint256', 'uint256', 'uint256', 'address'],
    [strategy_ids, values, confidences, nonce, expiry, chain_id, valuer_address]
))

sig1 = keeper1.sign_message(encode_defunct(batch_hash))
sig2 = keeper2.sign_message(encode_defunct(batch_hash))

tx = valuer.functions.batchUpdateValues(
    strategy_ids, values, confidences, nonce, expiry,
    [sig1.signature, sig2.signature]
).transact()
```

### Error Handling

| Error | Cause | Recovery |
|-------|-------|----------|
| `SignatureExpired` | Signature too old | Re-sign with fresh expiry |
| `StaleNonce` | Nonce already used | Query latest nonce, increment |
| `InsufficientSignatures` | Weight < requiredWeight | Add more signers or reduce threshold |
| `PriceChangeExceedsBounds` | Value changed too much | Wait or increase bounds |
| `UpdateTooFrequent` | Below minUpdateInterval | Wait or exceed pushThreshold |

---

## Configuration Guide

### Setting Up Multi-Sig

```solidity
// Add signers with weights
initiateSignerChange(keeper1, true, 100);
initiateSignerChange(keeper2, true, 50);
initiateSignerChange(keeper3, true, 50);

// Set threshold (e.g., require keeper1 OR both keeper2+3)
setRequiredWeight(100);
```

### Configuring Strategy

```solidity
bytes32 strategyId = keccak256("PT_KHYPE_LOOP");

// Set update parameters
configureStrategy(
    strategyId,
    5 minutes,      // minUpdateInterval
    1 hours,        // maxStaleness
    1000,           // pushThreshold (10%)
    90              // minConfidence
);

// Set price bounds (50% max change)
setPriceChangeBounds(strategyId, 5000);

// Set initial value limit
setMaxInitialValue(strategyId, 1000 * 1e18);

// Set fallback for emergencies
setFallbackValue(strategyId, 100 * 1e18);
```

### Emergency Recovery

```solidity
// 1. Enable emergency mode
setEmergencyMode(true);

// 2. Force set values
emergencyUpdate(strategyId, correctValue);

// 3. Disable emergency mode when keepers recovered
setEmergencyMode(false);
```
