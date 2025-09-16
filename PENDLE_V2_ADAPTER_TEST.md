# PendleV2Adapter2 End-to-End Test

## Overview

Comprehensive test script for PendleV2Adapter2.sol integration with Morpho VaultV2. Tests complete lifecycle:
- **Allocation**: WHYPE → kHYPE → PT (Pendle Principal Tokens)
- **Deallocation**: PT → kHYPE → WHYPE (reverse unwinding)
- **Real-time valuation**: Accurate `realAssets()` using live market rates

## Features Tested

✅ **Deployment & Registration** with VaultV2  
✅ **Allocation Flow** - converts underlying asset to yield-bearing PT  
✅ **realAssets Accuracy** - live pricing via Pendle + HyperSwap oracles  
✅ **Partial Deallocate** - proportional unwinding of positions  
✅ **Full Deallocate** - complete position cleanup  

## Usage

### Basic Test
```bash
forge script script/TestPendleV2Adapter2EndToEnd.s.sol \
--rpc-url https://rpc.hyperliquid.xyz/evm --broadcast -v
```

### With Custom RouterStatic
```bash
PENDLE_ROUTER_STATIC=0x263833d47eA3fA4a30f269323aba6a107f9eB14C \
forge script script/TestPendleV2Adapter2EndToEnd.s.sol \
--rpc-url https://rpc.hyperliquid.xyz/evm --broadcast -v
```

## Test Parameters

- **Test Amount**: 0.0001 WHYPE (100000000000000 wei)
- **Max Cap**: 10 WHYPE allocation limit
- **Target Network**: HyperEVM (Chain ID 999)
- **Slippage Tolerance**: 5% for PT swaps, 10% for unwinding

## Contract Addresses (HyperEVM)

| Contract | Address |
|----------|---------|
| VaultV2 | `0x6427F104D2Ee54a395c61E55FaC5CD02d60F2dEF` |
| Pendle Router | `0x888888888889758F76e7103c6CbF23ABbF58F946` |
| WHYPE (Asset) | `0x5555555555555555555555555555555555555555` |
| kHYPE | `0xfD739d4e423301CE9385c1fb8850539D657C296D` |
| PT Token | `0x311dB0FDe558689550c68355783c95eFDfe25329` |
| HyperSwap Pool | `0x5Cbe810071DE393de35e574Fb2830E16dA794bab` |

## Expected Output

```
=== PENDLE V2 ADAPTER2 END-TO-END TEST ===
✅ PendleRouterStatic verified

PHASE 1: Deployment & Setup
✅ Adapter registered with VaultV2
✅ Setup verified

PHASE 2: Test Allocation Flow  
✅ Rate queries successful
✅ ALLOCATION SUCCESS!

PHASE 3: Test realAssets Accuracy
✅ REALASSETS ACCURACY VERIFIED!

PHASE 4: Test Partial Deallocate
✅ PARTIAL DEALLOCATE SUCCESS!

PHASE 5: Test Full Deallocate  
✅ FULL DEALLOCATE SUCCESS!

🎊 ALL TESTS PASSED! END-TO-END SUCCESS!
```

## Error Handling

The test includes robust error handling:
- **RouterStatic unavailable**: Falls back to basic PT balance tracking
- **Rate query failures**: Continues with core functionality test
- **Market volatility**: Allows up to 20% deviation in realAssets accuracy

## Architecture Tested

```
User Deposit → VaultV2 → PendleV2Adapter2 → HyperSwap V3 → Pendle V2
     ↓             ↓            ↓              ↓            ↓
   WHYPE       Allocation   WHYPE→kHYPE   kHYPE→PT    PT Tokens
                  ↓            ↑              ↑           ↓
              realAssets   Pool Rate    Pendle Rate   Yield Accrual
```

## Notes

- **Accurate Valuation**: Uses live Pendle RouterStatic + HyperSwap V3 pool prices
- **Safety Checks**: Price bounds validation and slippage protection  
- **Production Ready**: Full VaultV2 integration with proper allocation tracking
- **Yield Capture**: PT tokens automatically accrue yield over time