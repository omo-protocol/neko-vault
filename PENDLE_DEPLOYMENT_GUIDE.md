# VaultV2 + PendleV2Adapter End-to-End Deployment Guide

This guide demonstrates how to deploy and integrate PendleV2Adapter with VaultV2, following the complete workflow from INSTRUCTIONS.md.

## 🚀 Quick Start

### Prerequisites
- Foundry installed
- RPC access to target network (Ethereum/Arbitrum)
- Private keys for deployer, vault owner, curator, allocator
- Pendle protocol addresses (Router V3, Oracles)

### Complete Workflow

```bash
# 1. Configure environment
cp .env.example .env
# Edit .env with your configuration

# 2. Deploy VaultV2 + Adapters
forge script script/DeployVaultV2.s.sol --rpc-url $RPC_URL --broadcast

# 3. Deploy PendleV2Adapter  
forge script script/DeployPendleV2Adapter.s.sol --rpc-url $RPC_URL --broadcast

# 4. Configure vault roles
VAULT_ADDRESS=<deployed_vault> forge script script/ConfigureVaultV2.s.sol --sig "configureRoles()" --rpc-url $RPC_URL --broadcast

# 5. Add PendleV2Adapter (with timelock)
VAULT_ADDRESS=<vault> forge script script/DeployPendleV2Adapter.s.sol --sig "submitAddAdapterTimelock(address)" <adapter> --rpc-url $RPC_URL --broadcast

# 6. Wait timelock delay (24 hours default), then execute
forge script script/DeployPendleV2Adapter.s.sol --sig "executeAddAdapter(address)" <adapter> --rpc-url $RPC_URL --broadcast

# 7. Set caps for Pendle markets
forge script script/DeployPendleV2Adapter.s.sol --sig "submitSetCapsTimelock(bytes32[],uint256[])" [ids] [caps] --rpc-url $RPC_URL --broadcast

# 8. Test allocation
ALLOCATOR_PRIVATE_KEY=<key> forge script script/DeployPendleV2Adapter.s.sol --sig "testAllocation(address,address,uint256,bytes)" <adapter> <market> <assets> <calldata> --rpc-url $RPC_URL --broadcast
```

## 📋 Step-by-Step Guide

### Step 1: Environment Setup

Create `.env` file with required configuration:

```bash
# Required
PRIVATE_KEY=0x...
RPC_URL=https://arb-mainnet.g.alchemy.com/v2/YOUR_KEY
VAULT_ASSET=0xaf88d065e77c8cC2239327C5EDb3A432268e5831  # USDC on Arbitrum
VAULT_OWNER=0x...     # Your multisig
VAULT_CURATOR=0x...   # Curator address
VAULT_ALLOCATOR=0x... # Allocator address

# PendleV2 Configuration
PENDLE_ROUTER=0x888888888889758F76e7103c6CbF23ABbF58F946     # Pendle Router V3
PENDLE_PT_ORACLE=0x2AC16C4e6caa0ba45751C4bAb4866d1a04f3Aca3  # Pendle PT Oracle
PENDLE_SY_ORACLE=0x1Fd95db7B7C0067De8D45C0cb35D59796adfD187  # Pendle SY Oracle

# Timelock
TIMELOCK_DELAY=86400  # 1 day
```

### Step 2: Deploy VaultV2 Ecosystem

```bash
forge script script/DeployVaultV2.s.sol --rpc-url $RPC_URL --broadcast --verify
```

Expected output:
```
[SUCCESS] VaultV2Factory deployed at: 0x...
[SUCCESS] VaultV2 deployed at: 0x...
[SUCCESS] MorphoMarketV1AdapterFactory deployed at: 0x...
[SUCCESS] MorphoVaultV1AdapterFactory deployed at: 0x...
```

Save the VaultV2 address for next steps.

### Step 3: Deploy PendleV2Adapter

```bash
VAULT_ADDRESS=0x... forge script script/DeployPendleV2Adapter.s.sol --rpc-url $RPC_URL --broadcast --verify
```

Expected output:
```
[SUCCESS] PendleV2Adapter deployed at: 0x...
  Vault: 0x...
  Pendle Router: 0x888888888889758F76e7103c6CbF23ABbF58F946
  PT Oracle: 0x2AC16C4e6caa0ba45751C4bAb4866d1a04f3Aca3
  SY Oracle: 0x1Fd95db7B7C0067De8D45C0cb35D59796adfD187
```

### Step 4: Configure Vault Roles

```bash
VAULT_ADDRESS=0x... forge script script/ConfigureVaultV2.s.sol --sig "configureRoles()" --rpc-url $RPC_URL --broadcast
```

This sets curator, allocator, and sentinel roles as configured.

### Step 5: Add PendleV2Adapter (Timelocked)

Submit timelock to enable adapter:
```bash
VAULT_ADDRESS=0x... CURATOR_PRIVATE_KEY=0x... forge script script/DeployPendleV2Adapter.s.sol --sig "submitAddAdapterTimelock(address)" 0xADAPTER_ADDRESS --rpc-url $RPC_URL --broadcast
```

Wait for timelock delay (24 hours), then execute:
```bash
VAULT_ADDRESS=0x... forge script script/DeployPendleV2Adapter.s.sol --sig "executeAddAdapter(address)" 0xADAPTER_ADDRESS --rpc-url $RPC_URL --broadcast
```

### Step 6: Configure Risk Caps

Get adapter risk IDs for a specific Pendle market:
```bash
forge script script/DeployPendleV2Adapter.s.sol --sig "getAdapterIds(address,address)" 0xADAPTER_ADDRESS 0xPENDLE_MARKET_ADDRESS --rpc-url $RPC_URL
```

Submit caps (example for 3 IDs: adapter, market, PT):
```bash
VAULT_ADDRESS=0x... CURATOR_PRIVATE_KEY=0x... forge script script/DeployPendleV2Adapter.s.sol --sig "submitSetCapsTimelock(bytes32[],uint256[])" "[0x...,0x...,0x...]" "[1000000,500000,300000]" --rpc-url $RPC_URL --broadcast
```

Execute caps after timelock delay.

### Step 7: Test Allocation

Prepare Pendle call data for swapExactTokenForPt:
```solidity
// Example call data structure
struct PendleCall {
    uint8 callType;        // e.g., 1 for swapExactTokenForPt
    address market;        // Pendle market address
    uint256 minPtOut;      // Minimum PT tokens out
    bytes routerCallData;  // Router-specific call data
}
```

Test allocation:
```bash
VAULT_ADDRESS=0x... ALLOCATOR_PRIVATE_KEY=0x... forge script script/DeployPendleV2Adapter.s.sol --sig "testAllocation(address,address,uint256,bytes)" 0xADAPTER_ADDRESS 0xMARKET_ADDRESS 1000000 0xCALLDATA --rpc-url $RPC_URL --broadcast
```

## 🔍 Verification & Monitoring

### Check Adapter Status
```bash
# Verify adapter is enabled
cast call 0xVAULT_ADDRESS "isAdapter(address)" 0xADAPTER_ADDRESS --rpc-url $RPC_URL

# Check real assets in adapter
cast call 0xADAPTER_ADDRESS "realAssets()" --rpc-url $RPC_URL

# Check vault total assets
cast call 0xVAULT_ADDRESS "totalAssets()" --rpc-url $RPC_URL
```

### Monitor Caps Usage
```bash
# Check allocation for specific ID
cast call 0xVAULT_ADDRESS "allocation(bytes32)" 0xID --rpc-url $RPC_URL

# Check absolute cap
cast call 0xVAULT_ADDRESS "absoluteCap(bytes32)" 0xID --rpc-url $RPC_URL
```

## 🧪 Testing Workflow

### 1. Testnet Deployment
Always test on Sepolia/Goerli before mainnet:
```bash
# Use testnet configuration
RPC_URL=https://eth-sepolia.g.alchemy.com/v2/YOUR_KEY
PENDLE_ROUTER=0x263833d47eA3fA4a30f269323aba6a107f9eB14C
# ... other testnet addresses
```

### 2. Integration Tests
```bash
# Deploy all components
forge script script/DeployVaultV2.s.sol --rpc-url $RPC_URL --broadcast
forge script script/DeployPendleV2Adapter.s.sol --rpc-url $RPC_URL --broadcast

# Configure without timelocks for faster testing
TIMELOCK_DELAY=0 forge script script/ConfigureVaultV2.s.sol --sig "configureRoles()" --rpc-url $RPC_URL --broadcast

# Test allocate/deallocate cycles
# Test forceDeallocate functionality
# Verify oracle price feeds
```

### 3. Production Checklist
- [ ] Timelocks configured with appropriate delays
- [ ] Caps set for all Pendle markets/PTs
- [ ] Oracle addresses verified and active
- [ ] Emergency procedures tested (forceDeallocate)
- [ ] Multisig owners configured
- [ ] Gas optimizations reviewed

## 📚 Key Concepts

### Risk IDs
PendleV2Adapter generates 3 risk IDs per market:
1. **Adapter ID**: `keccak256(abi.encode("this", address(adapter)))`
2. **Market ID**: `keccak256(abi.encode("market", marketAddress))`  
3. **PT ID**: `keccak256(abi.encode("pt", ptTokenAddress))`

### Pendle Call Types
The adapter supports various Pendle operations:
- `swapExactTokenForPt`: Swap USDC → PT tokens
- `swapExactPtForToken`: Swap PT tokens → USDC  
- `addLiquidityDualSyAndPt`: Add LP liquidity
- `removeLiquidityDualSyAndPt`: Remove LP liquidity

### Oracle Integration
- **PT Oracle**: Provides PT token prices with TWAP
- **SY Oracle**: Provides SY token prices for wrapped assets
- Adapter uses both oracles for accurate `realAssets()` calculation

## 🚨 Security Considerations

1. **Timelock Delays**: Set appropriate delays for production (≥24h)
2. **Cap Limits**: Set reasonable caps to limit exposure
3. **Oracle Risk**: Monitor oracle prices and TWAP periods
4. **Slippage Protection**: Use minOut parameters in Pendle calls
5. **Emergency Exits**: Test forceDeallocate with penalty calculations

## 📞 Support

For issues or questions:
1. Check INSTRUCTIONS.md for detailed concepts
2. Review Pendle documentation for router usage
3. Test on testnet before mainnet deployment
4. Monitor adapter realAssets() vs vault totalAssets()

## 🔗 Useful Links

- [Pendle Router V3 Docs](https://docs.pendle.finance/Developers/Contracts/PendleRouter)
- [Pendle Oracle Docs](https://docs.pendle.finance/Developers/Oracles/HowToIntegratePtAndLpOracle)
- [VaultV2 Architecture](./README.md)
- [INSTRUCTIONS.md](./INSTRUCTIONS.md)