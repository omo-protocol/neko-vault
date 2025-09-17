# PendleV2AdapterKHYPE Integration

## Quick Start

For complete documentation, deployment instructions, and testing procedures, see:

**📖 [Complete PendleV2AdapterKHYPE Documentation](docs/PendleV2AdapterKHYPE.md)**

## Current Deployment (HyperEVM)

- **VaultV2**: `0xE6c25968473FA49a886d2d50312a18ddbD40F4de`
- **PendleV2AdapterKHYPE**: `0x58aD57e970cEFc09e01692DCe378F8BC59925f76`
- **Status**: ✅ Fully operational

## Quick Test

```bash
# Test basic allocation/deallocation (replace <YOUR_PRIVATE_KEY> with actual private key)
PRIVATE_KEY=<YOUR_PRIVATE_KEY> \
forge script script/TestSmallAllocation.s.sol \
--rpc-url https://rpc.hyperliquid.xyz/evm \
--broadcast -v
```

**🚨 Security**: Never commit private keys to version control. Use environment variables or .env files.

## Key Files

- **Implementation**: `src/adapters/PendleV2AdapterKHYPE.sol`
- **Documentation**: `docs/PendleV2AdapterKHYPE.md`
- **Deployment**: `script/DeployOnlyNewVaultV2.s.sol`
- **Testing**: `script/TestSmallAllocation.s.sol`
- **End-to-End**: `script/TestRealDeployedVaultEndToEnd.s.sol`

## Architecture

```
User → VaultV2 → PendleV2AdapterKHYPE → Pendle Router → PT-kHYPE
     kHYPE                                            Yield Generation
```

For detailed information, troubleshooting, and advanced usage, see the [complete documentation](docs/PendleV2AdapterKHYPE.md).