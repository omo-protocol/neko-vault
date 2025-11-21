# DeFi Protocol Integration with Rebase Tokens

## The Challenge: Different Protocols, Different Approaches

DeFi protocols handle rebase tokens in three ways:
1. **Accept wrapped versions only** (Most common - Aave, Compound, Pendle)
2. **Accept rebasing tokens directly** (Rare - some AMMs, staking protocols)
3. **Accept both** (Very rare - Curve stETH/ETH pool)

Our wrapper solution handles ALL scenarios seamlessly.

## Integration Scenarios

### Scenario 1: Protocol Accepts Wrapped Tokens Only (90% of DeFi)

```
VaultV2 → Adapter → Escrow → [wstETH] → Aave/Compound/Pendle
                              Wrapped     Accept wstETH only
                              tokens
```

**This is the EASIEST case - no conversion needed:**

```solidity
// Escrow already holds wstETH from vault
contract StrategyEscrow {
    // Deploy to Aave V3 (accepts wstETH, NOT stETH)
    function deployToAave() external {
        uint256 wstETHBalance = IERC20(wstETH).balanceOf(address(this));

        // Direct deployment - Aave wants wstETH anyway
        IERC20(wstETH).approve(AAVE_POOL, wstETHBalance);
        IAavePool(AAVE_POOL).supply(wstETH, wstETHBalance, address(this), 0);

        // Receive aWstETH (Aave's receipt token)
    }

    // Deploy to Compound V3 (accepts wstETH)
    function deployToCompound() external {
        uint256 wstETHBalance = IERC20(wstETH).balanceOf(address(this));

        IERC20(wstETH).approve(COMPOUND_COMET, wstETHBalance);
        IComet(COMPOUND_COMET).supply(wstETH, wstETHBalance);
    }
}
```

### Scenario 2: Protocol ONLY Accepts Rebasing Tokens (10% of DeFi)

```
VaultV2 → Adapter → Escrow → [wstETH] → UNWRAP → [stETH] → Protocol
                              Wrapped              Rebasing   Wants stETH
```

**Strategy: Unwrap at deployment, wrap at withdrawal:**

```solidity
contract StrategyEscrowWithUnwrap {
    address constant wstETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    address constant stETH = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Deploy to protocol that ONLY accepts stETH
    function deployToStETHOnlyProtocol() external {
        uint256 wstETHBalance = IERC20(wstETH).balanceOf(address(this));

        // Step 1: Unwrap wstETH → stETH
        uint256 stETHReceived = IWrapper(wstETH).redeem(
            wstETHBalance,
            address(this),  // Escrow receives stETH
            address(this)   // Escrow owns shares
        );

        // Step 2: Deploy stETH to protocol
        IERC20(stETH).approve(STETH_ONLY_PROTOCOL, stETHReceived);
        IProtocol(STETH_ONLY_PROTOCOL).stake(stETHReceived);

        // Escrow now has protocol position in stETH terms
    }

    // Withdraw from protocol and re-wrap
    function withdrawFromStETHOnlyProtocol(uint256 amount) external {
        // Step 1: Withdraw stETH from protocol
        uint256 stETHReceived = IProtocol(STETH_ONLY_PROTOCOL).unstake(amount);

        // Step 2: Re-wrap stETH → wstETH
        IERC20(stETH).approve(wstETH, stETHReceived);
        uint256 wstETHReceived = IWrapper(wstETH).deposit(
            stETHReceived,
            address(this)  // Escrow receives wstETH
        );

        // Escrow now holds wstETH again, compatible with vault
    }
}
```

### Scenario 3: AMM Pools with Mixed Assets

```
Example: Curve stETH/ETH pool accepts both stETH (rebasing) and ETH
```

```solidity
contract CurveIntegration {
    // Curve pool that accepts stETH directly
    address constant CURVE_STETH_POOL = 0xDC24316b9AE028F1497c275EB9192a3Ea0f67022;

    function addLiquidityToCurve(uint256 ethAmount) external {
        // Escrow has wstETH, need stETH for Curve
        uint256 wstETHBalance = IERC20(wstETH).balanceOf(address(this));

        // Unwrap for Curve
        uint256 stETHAmount = IWrapper(wstETH).redeem(
            wstETHBalance,
            address(this),
            address(this)
        );

        // Add liquidity with stETH + ETH
        uint256[2] memory amounts = [ethAmount, stETHAmount];
        ICurvePool(CURVE_STETH_POOL).add_liquidity{value: ethAmount}(
            amounts,
            0  // min LP tokens
        );

        // Receive Curve LP tokens (these are NOT rebasing)
    }

    function removeLiquidityFromCurve(uint256 lpTokens) external {
        // Remove liquidity
        uint256[2] memory minAmounts = [0, 0];
        ICurvePool(CURVE_STETH_POOL).remove_liquidity(
            lpTokens,
            minAmounts
        );

        // Receive ETH + stETH
        uint256 stETHBalance = IERC20(stETH).balanceOf(address(this));

        // Re-wrap stETH → wstETH for vault compatibility
        IERC20(stETH).approve(wstETH, stETHBalance);
        IWrapper(wstETH).deposit(stETHBalance, address(this));
    }
}
```

## Advanced Integration: Multi-Protocol Strategies

### Example: stETH Yield Loop Strategy

```solidity
contract YieldLoopStrategy {
    // Strategy: wstETH → stETH → Lido → stETH rebases → Compound → borrow → repeat

    function executeYieldLoop(uint256 loops) external {
        uint256 wstETHBalance = IERC20(wstETH).balanceOf(address(this));

        for (uint i = 0; i < loops; i++) {
            // 1. Some protocols need stETH
            if (protocolNeedsRebasing[targetProtocol]) {
                // Unwrap wstETH → stETH
                uint256 stETHAmount = IWrapper(wstETH).redeem(
                    wstETHBalance,
                    address(this),
                    address(this)
                );

                // Deploy to rebasing protocol
                deployToRebasingProtocol(stETHAmount);

            } else {
                // 2. Most protocols prefer wstETH
                // Direct deployment without unwrapping
                deployToWrappedProtocol(wstETHBalance);
            }

            // 3. Borrow against position
            uint256 borrowed = borrowAgainstPosition();

            // 4. Convert borrowed assets to wstETH for next loop
            wstETHBalance = swapToWstETH(borrowed);
        }
    }
}
```

## Handling Different Rebase Token Types

### 1. Positive Rebase Only (stETH)

```solidity
// stETH only goes up (except for slashing events)
contract StETHStrategy {
    function handleStETH() external {
        // Can safely unwrap/wrap anytime
        // Balance only increases over time

        uint256 wstETHAmount = IERC20(wstETH).balanceOf(address(this));

        // Unwrap if protocol needs stETH
        uint256 stETHAmount = unwrap(wstETHAmount);
        // stETHAmount will grow over time due to rebases

        // Re-wrap when done
        uint256 newWstETHAmount = wrap(stETHAmount);
        // newWstETHAmount may be less than original due to exchange rate changes
        // But total value is preserved or increased
    }
}
```

### 2. Positive/Negative Rebase (AMPL)

```solidity
// AMPL can rebase up OR down based on price
contract AMPLStrategy {
    function handleAMPL() external {
        uint256 wAMPLAmount = IERC20(wAMPL).balanceOf(address(this));

        // More careful with AMPL - can lose tokens on negative rebase
        if (needsUnwrappedAMPL()) {
            // Track initial value
            uint256 initialValue = getAMPLValue(wAMPLAmount);

            // Unwrap
            uint256 amplAmount = IWrapper(wAMPL).redeem(wAMPLAmount, address(this), address(this));

            // Use in protocol that needs rebasing AMPL
            deployToAMPLProtocol(amplAmount);

            // Monitor for negative rebases
            if (amplAmount < previousAMPLBalance) {
                // Negative rebase detected, might want to exit position
                emergencyExit();
            }
        }
    }
}
```

### 3. Algorithmic Rebase (OHM)

```solidity
// OHM rebases based on protocol rules
contract OHMStrategy {
    function handleOHM() external {
        // gOHM is wrapped OHM (like wstETH for stETH)
        uint256 gOHMBalance = IERC20(gOHM).balanceOf(address(this));

        // Most protocols accept gOHM
        // Only unwrap for specific OHM-native protocols

        if (protocolType == ProtocolType.OLYMPUS_NATIVE) {
            // Unwrap gOHM → OHM for Olympus staking
            uint256 ohmAmount = IgOHM(gOHM).unwrap(gOHMBalance);

            // Stake in Olympus
            IOlympus(OLYMPUS_STAKING).stake(ohmAmount);

            // Receive sOHM (another rebasing token!)
            // This creates nested rebasing complexity
        }
    }
}
```

## Complete Example: Complex Multi-Protocol Flow

```solidity
contract ComplexRebaseStrategy {
    // Goal: Maximize yield using multiple protocols with different requirements

    function executeStrategy() external {
        uint256 totalWstETH = IERC20(wstETH).balanceOf(address(this));

        // Split allocation across protocols
        uint256 aaveAllocation = totalWstETH * 40 / 100;
        uint256 curveAllocation = totalWstETH * 30 / 100;
        uint256 lidoAllocation = totalWstETH * 30 / 100;

        // 1. Deploy to Aave (wants wstETH)
        IERC20(wstETH).approve(AAVE_POOL, aaveAllocation);
        IAavePool(AAVE_POOL).supply(wstETH, aaveAllocation, address(this), 0);

        // 2. Deploy to Curve (wants stETH)
        uint256 stETHForCurve = IWrapper(wstETH).redeem(
            curveAllocation,
            address(this),
            address(this)
        );
        deployCurveLP(stETHForCurve);

        // 3. Keep some for Lido staking (wants ETH, gives stETH)
        uint256 stETHForSwap = IWrapper(wstETH).redeem(
            lidoAllocation,
            address(this),
            address(this)
        );
        uint256 ethAmount = swapStETHForETH(stETHForSwap);
        stakeLido(ethAmount);  // Receive stETH back

        // 4. Re-wrap any remaining stETH
        uint256 finalStETHBalance = IERC20(stETH).balanceOf(address(this));
        if (finalStETHBalance > 0) {
            IERC20(stETH).approve(wstETH, finalStETHBalance);
            IWrapper(wstETH).deposit(finalStETHBalance, address(this));
        }
    }

    function exitStrategy() external {
        // 1. Exit Aave (receive wstETH directly)
        uint256 aaveBalance = IERC20(aWstETH).balanceOf(address(this));
        IAavePool(AAVE_POOL).withdraw(wstETH, aaveBalance, address(this));

        // 2. Exit Curve (receive stETH)
        uint256 lpBalance = IERC20(CURVE_LP).balanceOf(address(this));
        exitCurveLP(lpBalance);  // Receive stETH

        // 3. Wrap all stETH back to wstETH
        uint256 totalStETH = IERC20(stETH).balanceOf(address(this));
        IERC20(stETH).approve(wstETH, totalStETH);
        IWrapper(wstETH).deposit(totalStETH, address(this));

        // Escrow now has all funds back as wstETH
        // Ready to return to vault
    }
}
```

## Valuation with Mixed Protocols

```solidity
contract MixedProtocolValuer {
    function getTotalValue() external view returns (uint256) {
        uint256 totalValue = 0;

        // 1. Value wstETH holdings (direct)
        uint256 wstETHBalance = IERC20(wstETH).balanceOf(escrow);
        totalValue += wstETHBalance * getWstETHPrice() / 1e18;

        // 2. Value stETH holdings (need to account for rebasing)
        uint256 stETHBalance = IERC20(stETH).balanceOf(escrow);
        if (stETHBalance > 0) {
            // Convert to wstETH equivalent for consistent valuation
            uint256 wstETHEquivalent = IWrapper(wstETH).convertToShares(stETHBalance);
            totalValue += wstETHEquivalent * getWstETHPrice() / 1e18;
        }

        // 3. Value protocol positions
        totalValue += getAavePosition();  // Already in wstETH
        totalValue += getCurvePosition();  // Need to handle LP tokens
        totalValue += getLidoPosition();   // In stETH, convert to wstETH

        return totalValue;
    }
}
```

## Key Design Decisions

### When to Unwrap (wstETH → stETH):
1. **Protocol explicitly requires rebasing token**
2. **Better yield with rebasing version**
3. **Temporary for specific operations**

### When to Keep Wrapped:
1. **Protocol accepts wrapped version** (most common)
2. **Lending/borrowing protocols** (need stable collateral)
3. **Long-term holdings** (easier accounting)

### Best Practices:

```solidity
contract BestPractices {
    // Always re-wrap before returning to vault
    modifier ensureWrapped() {
        _;
        _wrapAllRebasingTokens();
    }

    // Track unwrap/wrap costs
    event UnwrapWrapCost(uint256 gasUsed, uint256 slippage);

    // Minimize unwrap/wrap cycles
    function batchOperations() external ensureWrapped {
        // Do all unwrapped operations together
        uint256 totalToUnwrap = calculateTotalUnwrapNeeded();
        uint256 stETH = IWrapper(wstETH).redeem(totalToUnwrap, address(this), address(this));

        // Execute all stETH operations
        executeAllRebasingOperations(stETH);

        // Single re-wrap at the end
        // Auto-handled by modifier
    }

    function _wrapAllRebasingTokens() internal {
        // Wrap any loose stETH
        uint256 stETHBalance = IERC20(stETH).balanceOf(address(this));
        if (stETHBalance > 0) {
            IERC20(stETH).approve(wstETH, stETHBalance);
            IWrapper(wstETH).deposit(stETHBalance, address(this));
        }

        // Wrap any loose AMPL
        uint256 amplBalance = IERC20(AMPL).balanceOf(address(this));
        if (amplBalance > 0) {
            IERC20(AMPL).approve(wAMPL, amplBalance);
            IWrapper(wAMPL).deposit(amplBalance, address(this));
        }
    }
}
```

## Summary

The wrapper approach provides maximum flexibility:

1. **Default Path (90% of DeFi)**: Keep everything wrapped, deploy directly
2. **Special Cases (10% of DeFi)**: Unwrap temporarily, re-wrap after
3. **Complex Strategies**: Mix both approaches as needed
4. **Always End Wrapped**: Ensure compatibility with VaultV2

This design means VaultV2 never needs to know about rebasing complexity, while still allowing strategies to interact with ANY DeFi protocol, whether it accepts wrapped or rebasing tokens.