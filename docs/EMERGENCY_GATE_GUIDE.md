# Emergency Gate for VaultV2 - Complete Guide

## Overview

The `EmergencyGate` contract provides a flexible, timelocked emergency pause mechanism for VaultV2. It implements all four gate interfaces to control deposits, withdrawals, and share transfers.

**Key Features:**
- ✅ 4 operational modes: NORMAL, DEPOSIT_ONLY, WITHDRAWAL_ONLY, EMERGENCY
- ✅ Exception list for emergency operations
- ✅ Owner-based access control
- ✅ Never reverts (gate requirement)
- ✅ Gas-optimized
- ✅ Event emission for monitoring

---

## Architecture

### Gate Modes

| Mode | Deposits | Withdrawals | Transfers | Use Case |
|------|----------|-------------|-----------|----------|
| **NORMAL** | ✅ Allowed | ✅ Allowed | ✅ Allowed | Normal operations |
| **DEPOSIT_ONLY** | ❌ Blocked | ✅ Allowed | ❌ Blocked | Prevent new money, allow exits |
| **WITHDRAWAL_ONLY** | ✅ Allowed | ❌ Blocked | ✅ Allowed | Allow deposits, prevent exits (rare) |
| **EMERGENCY** | ❌ Blocked | ❌ Blocked | ❌ Blocked | Complete lockdown |

### How It Works

```
VaultV2.deposit()
  → checks canSendAssets(msg.sender)
  → checks canReceiveShares(onBehalf)
    → EmergencyGate returns true/false based on mode
    → If false, deposit reverts with "CannotSendAssets" or "CannotReceiveShares"

VaultV2.withdraw()
  → checks canSendShares(onBehalf)
  → checks canReceiveAssets(receiver)
    → EmergencyGate returns true/false based on mode
    → If false, withdrawal reverts
```

---

## Deployment

### Step 1: Deploy EmergencyGate

```bash
# Set environment variables
export VAULT_ADDRESS="0x..."
export GATE_OWNER="0x..."  # Multisig or emergency address
export INITIAL_MODE="0"    # 0=NORMAL, 1=DEPOSIT_ONLY, 2=WITHDRAWAL_ONLY, 3=EMERGENCY
export EXCEPTIONS="0xAddr1,0xAddr2,0xAddr3"  # Optional: comma-separated addresses

# Deploy
forge script script/DeployEmergencyGate.s.sol \
  --rpc-url https://rpc.hyperliquid.xyz/evm \
  --broadcast \
  --verify
```

**Example Output:**
```
EmergencyGate deployed at: 0xABCD1234...
Vault: 0x5678EFGH...
Owner: 0xMultisig...
Mode: NORMAL
```

### Step 2: Configure Exceptions (Optional)

```solidity
// Add trusted addresses that bypass restrictions
EmergencyGate gate = EmergencyGate(0xABCD1234...);

// Single exception
gate.setException(emergencyMultisig, true);
gate.setException(trustedContract, true);

// Batch exceptions (more gas efficient)
address[] memory trustedAddresses = new address[](3);
trustedAddresses[0] = emergencyMultisig;
trustedAddresses[1] = trustedContract1;
trustedAddresses[2] = trustedContract2;
gate.setExceptionBatch(trustedAddresses, true);
```

### Step 3: Connect Gate to Vault (TIMELOCKED!)

```solidity
// Get vault and gate
VaultV2 vault = VaultV2(vaultAddress);
EmergencyGate gate = EmergencyGate(gateAddress);

// IMPORTANT: This requires curator role and timelock!

// 1. Submit gate changes (curator only)
bytes memory data1 = abi.encodeWithSelector(
    IVaultV2.setReceiveSharesGate.selector,
    address(gate)
);
vault.submit(data1);

bytes memory data2 = abi.encodeWithSelector(
    IVaultV2.setSendSharesGate.selector,
    address(gate)
);
vault.submit(data2);

bytes memory data3 = abi.encodeWithSelector(
    IVaultV2.setReceiveAssetsGate.selector,
    address(gate)
);
vault.submit(data3);

bytes memory data4 = abi.encodeWithSelector(
    IVaultV2.setSendAssetsGate.selector,
    address(gate)
);
vault.submit(data4);

// 2. Wait for timelock expiration
// Check timelock duration: vault.timelock(IVaultV2.setReceiveSharesGate.selector)
// Check execution time: vault.executableAt(data1)

// 3. Execute after timelock expires
vault.setReceiveSharesGate(address(gate));
vault.setSendSharesGate(address(gate));
vault.setReceiveAssetsGate(address(gate));
vault.setSendAssetsGate(address(gate));
```

**⏰ TIMELOCK IMPACT:**
- Timelock can be hours to weeks depending on vault configuration
- During timelock period, vault operates normally (NO protection yet)
- After execution, gate becomes active

---

## Emergency Response Procedures

### 🚨 Scenario 1: Block New Deposits (Most Common)

**When to Use:** Adapter exploit, compromised strategy, preventing panic deposits

```solidity
// IMMEDIATE ACTION (No timelock if gate already configured!)
EmergencyGate gate = EmergencyGate(gateAddress);
gate.setMode(EmergencyGate.Mode.DEPOSIT_ONLY);

// Or use convenience function
gate.activateEmergency();  // Blocks everything
```

**Effect:**
- ❌ No new deposits accepted
- ✅ Existing users can still withdraw
- ❌ Share transfers blocked
- Gate owner can adjust mode anytime

### 🚨 Scenario 2: Complete Emergency Lockdown

**When to Use:** Critical security incident, multiple attack vectors

```solidity
// IMMEDIATE ACTION
EmergencyGate gate = EmergencyGate(gateAddress);
gate.activateEmergency();  // Sets mode to EMERGENCY
```

**Effect:**
- ❌ No deposits
- ❌ No withdrawals
- ❌ No transfers
- ✅ Exceptions still work (emergency multisig, etc.)

### 🚨 Scenario 3: Combined Defense (Multi-Layer)

**Immediate Actions (No Timelock):**

```solidity
// LAYER 1: Pause adapter (if UniversalAdapterEscrow)
UniversalAdapterEscrow adapter = UniversalAdapterEscrow(adapterAddress);
adapter.setPaused(true);

// LAYER 2: Activate gate emergency mode
EmergencyGate gate = EmergencyGate(gateAddress);
gate.activateEmergency();

// LAYER 3: Decrease caps (sentinels can do immediately)
VaultV2 vault = VaultV2(vaultAddress);
vault.decreaseAbsoluteCap(idData, 0);
vault.decreaseRelativeCap(idData, 0);
```

**Effect:** Maximum protection across all layers!

### 🚨 Scenario 4: Selective Access During Emergency

**When to Use:** Allow emergency operations by trusted addresses

```solidity
// 1. Activate emergency mode (blocks everyone)
gate.activateEmergency();

// 2. Add exceptions for emergency operations
gate.setException(emergencyMultisigAddress, true);
gate.setException(recoveryContractAddress, true);

// Now only exception addresses can interact with vault
```

### ✅ Recovery: Return to Normal

```solidity
// After threat is resolved
EmergencyGate gate = EmergencyGate(gateAddress);
gate.deactivateEmergency();  // Returns to NORMAL mode

// Or set specific mode
gate.setMode(EmergencyGate.Mode.NORMAL);
```

---

## Testing Guide

### Test 1: Check Current Configuration

```solidity
EmergencyGate gate = EmergencyGate(gateAddress);

// Check mode
console.log("Mode:", gate.getModeString());

// Check permissions for specific address
(bool canDeposit, bool canWithdraw, bool canTransfer) = gate.checkPermissions(userAddress);
console.log("User can deposit:", canDeposit);
console.log("User can withdraw:", canWithdraw);
console.log("User can transfer:", canTransfer);

// Check if address is exception
bool isException = gate.isException(userAddress);
console.log("Is exception:", isException);
```

### Test 2: Simulate Emergency Activation

```solidity
// Before activation
assertEq(gate.canSendAssets(user), true, "Should allow deposits");
assertEq(gate.canSendShares(user), true, "Should allow withdrawals");

// Activate emergency
vm.prank(gateOwner);
gate.activateEmergency();

// After activation
assertEq(gate.canSendAssets(user), false, "Should block deposits");
assertEq(gate.canSendShares(user), false, "Should block withdrawals");

// Exception should still work
assertEq(gate.canSendAssets(exceptionAddress), true, "Exception should bypass");
```

### Test 3: Test All 4 Modes

```solidity
// Test NORMAL mode
gate.setMode(EmergencyGate.Mode.NORMAL);
assertTrue(gate.canReceiveShares(user), "NORMAL: should allow receiving shares");
assertTrue(gate.canSendShares(user), "NORMAL: should allow sending shares");
assertTrue(gate.canReceiveAssets(user), "NORMAL: should allow receiving assets");
assertTrue(gate.canSendAssets(user), "NORMAL: should allow sending assets");

// Test DEPOSIT_ONLY mode (blocks deposits, allows withdrawals)
gate.setMode(EmergencyGate.Mode.DEPOSIT_ONLY);
assertTrue(gate.canReceiveShares(user), "DEPOSIT_ONLY: should allow receiving shares (withdraw)");
assertFalse(gate.canSendShares(user), "DEPOSIT_ONLY: should block sending shares (transfer)");
assertFalse(gate.canReceiveAssets(user), "DEPOSIT_ONLY: should block receiving assets (deposit)");
assertFalse(gate.canSendAssets(user), "DEPOSIT_ONLY: should block sending assets (deposit)");

// Test WITHDRAWAL_ONLY mode (allows deposits, blocks withdrawals)
gate.setMode(EmergencyGate.Mode.WITHDRAWAL_ONLY);
assertFalse(gate.canReceiveShares(user), "WITHDRAWAL_ONLY: should block receiving shares (deposit)");
assertTrue(gate.canSendShares(user), "WITHDRAWAL_ONLY: should allow sending shares (withdraw)");
assertTrue(gate.canReceiveAssets(user), "WITHDRAWAL_ONLY: should allow receiving assets (withdraw)");
assertTrue(gate.canSendAssets(user), "WITHDRAWAL_ONLY: should allow sending assets (deposit)");

// Test EMERGENCY mode (blocks everything)
gate.setMode(EmergencyGate.Mode.EMERGENCY);
assertFalse(gate.canReceiveShares(user), "EMERGENCY: should block receiving shares");
assertFalse(gate.canSendShares(user), "EMERGENCY: should block sending shares");
assertFalse(gate.canReceiveAssets(user), "EMERGENCY: should block receiving assets");
assertFalse(gate.canSendAssets(user), "EMERGENCY: should block sending assets");
```

---

## Integration with Vault Operations

### Deposit Flow

```solidity
// User attempts deposit
vault.deposit(1000e18, user);

// VaultV2 checks:
// 1. canSendAssets(msg.sender) → gate.canSendAssets(msg.sender)
// 2. canReceiveShares(onBehalf) → gate.canReceiveShares(user)

// If NORMAL mode: ✅ deposit succeeds
// If DEPOSIT_ONLY mode: ❌ reverts with "CannotSendAssets"
// If EMERGENCY mode: ❌ reverts with "CannotSendAssets"
```

### Withdrawal Flow

```solidity
// User attempts withdrawal
vault.withdraw(500e18, receiver, owner);

// VaultV2 checks:
// 1. canSendShares(owner) → gate.canSendShares(owner)
// 2. canReceiveAssets(receiver) → gate.canReceiveAssets(receiver)

// If NORMAL mode: ✅ withdrawal succeeds
// If DEPOSIT_ONLY mode: ✅ withdrawal succeeds (still allowed)
// If EMERGENCY mode: ❌ reverts with "CannotSendShares"
```

### Force Deallocate Flow

```solidity
// Anyone attempts force deallocate
vault.forceDeallocate(adapter, data, assets, onBehalf);

// VaultV2 checks:
// 1. deallocates from adapter
// 2. calls withdraw(penaltyAssets, address(this), onBehalf)
//    → canSendShares(onBehalf) → gate.canSendShares(onBehalf)

// If onBehalf is blocked: ❌ force deallocate fails
// If onBehalf is exception: ✅ force deallocate succeeds
// Vault receives assets (bypasses receiveAssetsGate by design)
```

---

## Gas Optimization

The EmergencyGate is designed for minimal gas consumption:

| Operation | Gas Cost | Notes |
|-----------|----------|-------|
| `canReceiveShares()` | ~2,500 | Single SLOAD + comparison |
| `canSendShares()` | ~2,500 | Single SLOAD + comparison |
| `canReceiveAssets()` | ~2,500 | Single SLOAD + comparison |
| `canSendAssets()` | ~2,500 | Single SLOAD + comparison |
| `setMode()` | ~30,000 | SSTORE + event |
| `activateEmergency()` | ~30,000 | SSTORE + event |
| `setException()` | ~25,000 | SSTORE + event |
| `setExceptionBatch(10)` | ~200,000 | 10 × SSTORE + events |

**Design Choices:**
- ✅ No loops in view functions
- ✅ Minimal storage reads
- ✅ No complex logic
- ✅ Never reverts in gate checks

---

## Security Considerations

### ✅ **What Gate Protects Against**

1. **Panic Deposits During Exploit**: Block new deposits when vulnerability discovered
2. **Bank Run**: Optionally block withdrawals during migration
3. **Share Price Manipulation**: Block transfers during price anomalies
4. **Unauthorized Access**: Enforce whitelist/blacklist policies
5. **Compliance Requirements**: Gate based on regulatory needs

### ⚠️ **What Gate CANNOT Protect Against**

1. **Allocator Actions**: Gate doesn't affect `allocate()` or `deallocate()`
2. **Immediate Threats**: Gate changes require timelock to activate
3. **Adapter Exploits**: If adapter is compromised, gate won't stop internal operations
4. **Fee Accrual Issues**: If fee recipient is blocked, `accrueInterest()` will revert (DoS)

### 🔒 **Best Practices**

1. **Always Deploy Gate Early**: Set up gate during vault initialization, before issues arise
2. **Configure Exceptions**: Add emergency addresses (multisig, owner, trusted contracts)
3. **Monitor Events**: Watch for `ModeChanged` events to detect emergency activations
4. **Test Regularly**: Verify gate works by checking `checkPermissions()`
5. **Document Procedures**: Ensure team knows how to activate emergency mode
6. **Consider Fee Recipients**: Never block fee recipient addresses (causes DoS)
7. **Vault Always Exception**: Gate automatically adds vault as exception

---

## Advanced: Gate Abdication

To make gate configuration permanent (cannot be changed), use abdication:

```solidity
// 1. Set gate to desired address
vault.setReceiveSharesGate(address(gate));

// 2. Abdicate (make it permanent - IRREVERSIBLE!)
vault.increaseTimelock(IVaultV2.setReceiveSharesGate.selector, type(uint256).max);

// Now gate can NEVER be changed!
```

**Two Strategies:**

### Strategy 1: Permanently Ungated (Permissionless)

```solidity
// 1. Ensure gate is address(0)
vault.setReceiveSharesGate(address(0));

// 2. Abdicate
vault.increaseTimelock(IVaultV2.setReceiveSharesGate.selector, type(uint256).max);

// Vault is now PERMANENTLY permissionless for this gate
```

### Strategy 2: Permanently Gated (Fixed Rules)

```solidity
// 1. Deploy immutable gate (no owner, or renounced ownership)
ImmutableGate immutableGate = new ImmutableGate();

// 2. Set gate
vault.setReceiveSharesGate(address(immutableGate));

// 3. Abdicate
vault.increaseTimelock(IVaultV2.setReceiveSharesGate.selector, type(uint256).max);

// Vault is now PERMANENTLY bound to these gate rules
```

**⚠️ WARNING:** Abdication is PERMANENT and IRREVERSIBLE! Only use if you're certain.

---

## Monitoring & Alerting

### Events to Monitor

```solidity
// Gate mode changes
event ModeChanged(Mode oldMode, Mode newMode, address indexed changedBy);

// Exception changes
event ExceptionSet(address indexed account, bool isException);

// Ownership changes
event OwnerChanged(address indexed oldOwner, address indexed newOwner);
```

### Monitoring Script Example

```javascript
// Monitor for emergency activations
gateContract.on("ModeChanged", (oldMode, newMode, changedBy, event) => {
  if (newMode === 3) {  // EMERGENCY mode
    alert(`🚨 EMERGENCY MODE ACTIVATED by ${changedBy}`);
    notify_team();
    page_on_call();
  }
});

// Monitor for suspicious exception additions
gateContract.on("ExceptionSet", (account, isException, event) => {
  if (isException && !knownTrustedAddresses.includes(account)) {
    alert(`⚠️ Unknown address added as exception: ${account}`);
  }
});
```

---

## FAQ

**Q: Can gate block forceDeallocate?**
A: Partially. If `onBehalf` is blocked by `sendSharesGate`, the `withdraw()` call will fail, preventing force deallocate. But vault still receives assets.

**Q: What happens if fee recipient is blocked?**
A: **CRITICAL**: If fee recipient is blocked by `receiveSharesGate`, `accrueInterest()` will revert, causing DoS on all vault operations! Never block fee recipients.

**Q: Can gate be changed immediately?**
A: No. Vault uses timelock for curator functions. Gate owner can change MODE immediately, but connecting gate to vault requires timelock.

**Q: What if gate owner is compromised?**
A: Compromised gate owner can change mode to block operations or add malicious exceptions. Use multisig for gate owner.

**Q: Does gate affect adapters?**
A: No. Gate only affects vault-level user operations (deposit, withdraw, transfer). Adapter operations (allocate, deallocate) are not affected.

**Q: Can I use gate for KYC/compliance?**
A: Yes! Set exceptions for KYC-approved addresses. Mode = EMERGENCY by default, add exceptions after KYC verification.

---

## Summary

**Deployment Checklist:**
- [ ] Deploy EmergencyGate with correct vault and owner
- [ ] Configure exceptions (multisig, emergency addresses)
- [ ] Submit gate changes to vault (curator)
- [ ] Wait for timelock expiration
- [ ] Execute gate changes
- [ ] Test with `checkPermissions()`
- [ ] Document emergency procedures
- [ ] Set up monitoring for `ModeChanged` events

**Emergency Checklist:**
- [ ] Pause adapter if applicable
- [ ] Activate emergency gate mode
- [ ] Decrease caps (sentinels)
- [ ] Notify team
- [ ] Investigate incident
- [ ] Plan recovery
- [ ] Return to normal mode after resolution

**Key Takeaways:**
- ✅ Gate provides flexible emergency controls
- ⏰ Gate requires timelock to connect to vault
- ⚡ Gate mode can be changed immediately by owner (once connected)
- 🛡️ Use exceptions for emergency operations
- 🔍 Monitor events for suspicious activity
- 🚫 Never block fee recipients (causes DoS)
