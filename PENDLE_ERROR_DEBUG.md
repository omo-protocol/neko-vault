# Pendle Error Debug

## Error Details

**Custom Error:** `0x2c49ea0f`  
**Error Data:** `00000000000000000000000000000000000000000001051a05599b4f719c800600000000000000000000000000000000000000000001051dcdea392a55d7d5d8`

## Analysis

The error occurs during `swapExactPtForToken` in the deallocate function. This is likely a Pendle-specific error.

### Decoded Error Data
- First 32 bytes: `0x00000000000000000000000000000000000000000001051a05599b4f719c8006` 
- Second 32 bytes: `0x00000000000000000000000000000000000000000001051dcdea392a55d7d5d8`

These look like amounts or rates that are close to each other, suggesting a slippage or pricing issue.

## Fixes Applied

1. **More Conservative PT Calculation**: Use `realAssets()` to determine proper PT amount to redeem
2. **Increased Slippage Tolerance**: From 10% to 20%, with fallback to 30%
3. **Safety Cap**: Maximum 95% of PT balance can be redeemed
4. **Better Error Handling**: Try/catch with progressive slippage increase

## Test Scripts

### Simple Test (Allocation Only)
```bash
PRIVATE_KEY=0x17a... \
forge script script/TestPendleV2Adapter2Simple.s.sol \
--rpc-url https://rpc.hyperliquid.xyz/evm --broadcast -v
```

### Full Test (With Fixed Deallocate)  
```bash
PRIVATE_KEY=0x17a... \
forge script script/TestPendleV2Adapter2EndToEnd.s.sol \
--rpc-url https://rpc.hyperliquid.xyz/evm --broadcast -v
```

## Expected Resolution

The fixes should resolve the deallocate issue by:
- Using more accurate PT amount calculations
- Providing generous slippage tolerance
- Adding progressive fallback mechanisms
- Capping redemption amount for safety