# 🚀 POC Deployment Guide - VaultV2 + PendleV2Adapter (NO TIMELOCKS)

This guide is for **Proof of Concept deployment ONLY** - deploys and configures everything immediately without timelock delays for faster testing and iteration.

⚠️ **WARNING: This configuration is NOT suitable for production use with real funds!**

## 🎯 Quick POC Deployment

### Prerequisites
```bash
# Configure your .env file
PRIVATE_KEY=0x...
VAULT_ASSET=0x5555555555555555555555555555555555555555  # HyperETH on HyperEVM
VAULT_OWNER=0x77D6B4d8142BcC2C6A518EfDB6A7cAF2985F26Fd    # Your address
PENDLE_ROUTER=0x888888888889758F76e7103c6CbF23ABbF58F946
PENDLE_PT_ORACLE=0x9a9fa8338dd5e5b2188006f1cd2ef26d921650c2
PENDLE_SY_ORACLE=0x9a9fa8338dd5e5b2188006f1cd2ef26d921650c2
TIMELOCK_DELAY=0  # POC: No delays!
```

### Single Command Deployment
```bash
# Deploy everything in one go
forge script script/DeployPOC.s.sol --rpc-url $RPC_URL --broadcast
```

**What this does:**
1. ✅ Deploys VaultV2Factory + VaultV2 instance
2. ✅ Deploys MorphoMarket/MorphoVault adapter factories
3. ✅ Deploys PendleV2Adapter
4. ✅ Sets curator/allocator roles
5. ✅ **Disables all timelocks (sets to 0)**
6. ✅ **Enables PendleV2Adapter immediately**

## 🔧 POC Operations

### 1. Set Caps for Pendle Markets
```bash
# Get adapter IDs for a specific Pendle market
forge script script/DeployPOC.s.sol --sig "getAdapterIds(address,address)" \\
  0xPENDLE_ADAPTER_ADDRESS 0xPENDLE_MARKET_ADDRESS --rpc-url $RPC_URL

# Set caps immediately (no timelock wait!)
forge script script/DeployPOC.s.sol --sig "setCaps(address,bytes32[],uint256[])" \\
  0xVAULT_ADDRESS "[0xID1,0xID2,0xID3]" "[1000000,500000,300000]" \\
  --rpc-url $RPC_URL --broadcast
```

### 2. Test Allocation to Pendle
```bash
# Prepare Pendle call data (example for swapExactTokenForPt)
PENDLE_CALLDATA=0x...  # Your encoded Pendle operation

# Test allocation immediately
forge script script/DeployPOC.s.sol --sig "testAllocation(address,address,uint256,bytes)" \\
  0xVAULT_ADDRESS 0xADAPTER_ADDRESS 1000000 $PENDLE_CALLDATA \\
  --rpc-url $RPC_URL --broadcast
```

### 3. Monitor Balances
```bash
# Check vault total assets
cast call 0xVAULT_ADDRESS "totalAssets()" --rpc-url $RPC_URL

# Check adapter real assets
cast call 0xADAPTER_ADDRESS "realAssets()" --rpc-url $RPC_URL

# Check if adapter is enabled
cast call 0xVAULT_ADDRESS "isAdapter(address)" 0xADAPTER_ADDRESS --rpc-url $RPC_URL
```

## 🛡️ Security Transition

### Before Moving to Production

**Enable production timelocks:**
```bash
# This sets 1-day timelock delays on critical functions
TIMELOCK_DELAY=86400 forge script script/DeployPOC.s.sol --sig "enableProductionTimelocks(address)" \\
  0xVAULT_ADDRESS --rpc-url $RPC_URL --broadcast
```

**After enabling timelocks, all future changes will require:**
1. Submit change with timelock
2. Wait 24 hours (or configured delay)
3. Execute the change

## 📊 POC vs Production Comparison

| Feature | POC Deployment | Production Deployment |
|---------|---------------|----------------------|
| Timelock Delays | ❌ Disabled (0 seconds) | ✅ Enabled (24+ hours) |
| Adapter Changes | ⚡ Immediate | 🛡️ Timelocked |
| Cap Changes | ⚡ Immediate | 🛡️ Timelocked |
| Security | ⚠️ Low (testing only) | ✅ High |
| Speed | 🚀 Fast iteration | 🐌 Secure but slow |

## 🔄 POC Testing Workflow

### Complete Test Example
```bash
# 1. Deploy everything
forge script script/DeployPOC.s.sol --rpc-url $RPC_URL --broadcast

# 2. Get deployment addresses from output
VAULT_ADDRESS=0x...
ADAPTER_ADDRESS=0x...
MARKET_ADDRESS=0x...  # Pendle market you want to test

# 3. Set caps for the market
forge script script/DeployPOC.s.sol --sig "getAdapterIds(address,address)" \\
  $ADAPTER_ADDRESS $MARKET_ADDRESS --rpc-url $RPC_URL

# Copy the IDs from output, then:
forge script script/DeployPOC.s.sol --sig "setCaps(address,bytes32[],uint256[])" \\
  $VAULT_ADDRESS "[0xID1,0xID2,0xID3]" "[10000000,5000000,3000000]" \\
  --rpc-url $RPC_URL --broadcast

# 4. Prepare test allocation data
# (This depends on which Pendle operation you want to test)

# 5. Test allocation
forge script script/DeployPOC.s.sol --sig "testAllocation(address,address,uint256,bytes)" \\
  $VAULT_ADDRESS $ADAPTER_ADDRESS 1000000 0xCALLDATA \\
  --rpc-url $RPC_URL --broadcast

# 6. Verify results
cast call $VAULT_ADDRESS "totalAssets()" --rpc-url $RPC_URL
cast call $ADAPTER_ADDRESS "realAssets()" --rpc-url $RPC_URL
```

## ⚠️ Important Reminders

### Security Warnings
1. **NO TIMELOCKS** = Anyone with curator role can change configurations immediately
2. **FOR TESTING ONLY** = Do not use with significant funds
3. **NO EMERGENCY DELAYS** = Changes happen instantly
4. **LIMITED GOVERNANCE** = Reduced safety mechanisms

### When to Use POC vs Production
- **Use POC for:**
  - Testing new Pendle markets
  - Developing allocation strategies  
  - Integration testing
  - Performance benchmarking
  - UI/UX development

- **Use Production for:**
  - Real user funds
  - Mainnet deployment
  - Long-term operations
  - Multi-sig governance

## 🔄 Upgrading POC to Production

To transition a tested POC to production:

1. **Enable timelocks:**
   ```bash
   forge script script/DeployPOC.s.sol --sig "enableProductionTimelocks(address)" \\
     $VAULT_ADDRESS --rpc-url $RPC_URL --broadcast
   ```

2. **Set proper multisig governance:**
   - Transfer ownership to multisig
   - Set curator to governance contract
   - Configure sentinel roles

3. **Audit configuration:**
   - Review all caps
   - Test emergency procedures
   - Verify oracle configurations

4. **Deploy fresh for production** (recommended):
   - Use standard deployment scripts with timelocks
   - Proper governance setup from start
   - Clean deployment history

---

**Happy testing! 🧪**

Remember: This POC setup is designed for speed and iteration, not security. Always transition to proper timelock-protected deployment before handling real funds.