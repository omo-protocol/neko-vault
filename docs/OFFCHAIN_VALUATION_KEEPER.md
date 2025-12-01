# OffchainValuationKeeper - Technical Specification

> Python service for off-chain strategy valuation
> Location: `src/keepers/OffchainValuationKeeper.py`

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Valuation Modes](#valuation-modes)
- [Configuration](#configuration)
- [Security Features](#security-features)
- [Error Handling](#error-handling)
- [Deployment Guide](#deployment-guide)
- [Monitoring](#monitoring)

---

## Overview

OffchainValuationKeeper is a Python service that:
1. Monitors DeFi strategy positions continuously
2. Calculates valuations using external oracles (Pendle, Chainlink, Uniswap)
3. Signs reports with ECDSA (EIP-191)
4. Submits to UniversalValuerOffchain contract

### Key Responsibilities

- **Value Calculation**: Compute net strategy value (assets - liabilities)
- **Oracle Integration**: Query Pendle TWAP, Chainlink feeds, Uniswap pools
- **Signature Generation**: Create EIP-191 compliant signatures
- **Cache Refresh**: Update adapter's cached valuation after updates
- **Metrics Tracking**: Monitor success rates, gas usage, errors

### Data Flow

```
┌─────────────────────────────────────────────────────────────────┐
│                    KEEPER EXECUTION LOOP                         │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  FOR EACH STRATEGY:                                              │
│  ┌─────────────────────────────────────────────────────────────┐ │
│  │ 1. Query On-Chain Balances                                  │ │
│  │    └── ptToken.balanceOf(escrow)                            │ │
│  │    └── morpho.position(marketId, escrow)                    │ │
│  ├─────────────────────────────────────────────────────────────┤ │
│  │ 2. Fetch External Prices                                    │ │
│  │    └── pendle_oracle.getPtToAssetRate(market, 1800)         │ │
│  │    └── chainlink.latestRoundData()                          │ │
│  ├─────────────────────────────────────────────────────────────┤ │
│  │ 3. Calculate Net Value                                      │ │
│  │    └── collateral = balance × price                         │ │
│  │    └── debt = borrow_value                                  │ │
│  │    └── net = collateral - debt (or 0 if underwater)         │ │
│  ├─────────────────────────────────────────────────────────────┤ │
│  │ 4. Sign Message (EIP-191)                                   │ │
│  │    └── hash = keccak256(strategyId, value, conf, nonce...)  │ │
│  │    └── sig = sign("\x19Ethereum Signed Message:\n32" + hash)│ │
│  ├─────────────────────────────────────────────────────────────┤ │
│  │ 5. Submit to Valuer                                         │ │
│  │    └── valuer.updateValue(strategyId, value, conf, nonce...) │ │
│  ├─────────────────────────────────────────────────────────────┤ │
│  │ 6. Refresh Adapter Cache (SECURITY FIX)                     │ │
│  │    └── adapter.refreshCachedValuation()                     │ │
│  └─────────────────────────────────────────────────────────────┘ │
│                                                                  │
│  WAIT update_check_interval (default 60s)                        │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

---

## Architecture

### Class Structure

```python
class OffchainValuationKeeper:
    def __init__(self, config_path: str):
        self.w3: Web3                     # Web3 connection
        self.account: Account             # Signing account
        self.valuer: Contract             # UniversalValuerOffchain
        self.wrapper: Contract            # Wrapper token (vault asset)
        self.strategies: List[StrategyConfig]
        self.metrics: KeeperMetrics

    def run_once(self):
        """Single update cycle for all strategies"""

    def run_daemon(self):
        """Continuous loop with interval"""

    def value_strategy(self, strategy: StrategyConfig) -> int:
        """Route to appropriate valuation mode"""
```

### StrategyConfig

```python
@dataclass
class StrategyConfig:
    id_text: str              # e.g., "PT_KHYPE_LOOP"
    mode: str                 # Valuation mode
    escrow: str               # Escrow address
    underlying: str           # Underlying token address
    confidence: int = 95      # Confidence level (0-100)
    extras: Dict[str, Any]    # Mode-specific parameters
    adapter: str = None       # Adapter for cache refresh
```

### KeeperMetrics

```python
class KeeperMetrics:
    updates_attempted: int
    updates_succeeded: int
    updates_failed: int
    total_gas_used: int
    last_update_time: Dict[str, float]
    errors_by_type: Dict[str, int]
    start_time: float
```

---

## Valuation Modes

### Mode: `underlying_balance`

**Purpose**: Simple balance read with wrapper conversion.

**Use Case**: Strategies holding rebasing tokens (e.g., stETH → wstETH).

**Formula**:
```
value = wrapper.convertToShares(underlying.balanceOf(escrow))
```

**Configuration**:
```json
{
  "id": "REBASING_STRATEGY",
  "mode": "underlying_balance",
  "escrow": "0x...",
  "underlying": "0x..."  // stETH address
}
```

**Security**: Rejects if `underlying == wrapper` (prevents double-counting).

---

### Mode: `pt_khype_loop`

**Purpose**: Leveraged PT strategies using Pendle + Felix.

**Strategy Structure**:
1. Escrow holds PT-kHYPE tokens (collateral)
2. PT-kHYPE deposited in Felix as collateral
3. kHYPE borrowed against collateral
4. Loop repeats for leverage

**Formula**:
```
pt_balance = pt_token.balanceOf(escrow)
pt_price = pendle_oracle.getPtToAssetRate(market, 1800)  # 30-min TWAP
collateral = pt_balance × pt_price
debt = felix.position(marketId, escrow).borrowShares → assets
net = max(0, collateral - debt)
value = wrapper.convertToShares(net)
```

**Pricing Models**:
1. `pendle_oracle` (default): Pendle's 30-min TWAP
2. `linear_discount`: Mathematical model P(t,T)
3. `felix_oracle_direct`: Read directly from Felix oracle

**Configuration**:
```json
{
  "id": "PT_KHYPE_LOOP",
  "mode": "pt_khype_loop",
  "escrow": "0x...",
  "confidence": 95,
  "extras": {
    "pt_khype_address": "0x...",
    "pendle_market": "0x...",
    "pt_oracle": "0x...",
    "felix_lending": "0x...",
    "felix_market_id": "0x...",
    "pricing_model": "pendle_oracle",
    "include_underlying_dust": true,
    "underlying_decimals": 18
  }
}
```

**Security Features**:
- Decimal mismatch protection (validates PT vs underlying decimals)
- Underwater detection (logs CRITICAL_ALERT, returns 0)
- RPC failure handling (raises instead of returning 0)
- Optional dust/rewards tracking

---

### Mode: `pt_loop`

**Purpose**: Generic PT strategy for any lending protocol.

**Supported Lending Protocols**:
- `felix`: Felix Lending (Morpho Blue fork)
- `morpho`: Morpho Blue native
- `aave_v3`: Aave V3
- `compound_v3`: Compound V3 (Comet)
- `none`: Pure PT holding (no leverage)

**Configuration**:
```json
{
  "id": "PT_WSTETH_MORPHO",
  "mode": "pt_loop",
  "escrow": "0x...",
  "extras": {
    "pt_address": "0x...",
    "pricing_model": "pendle_oracle",
    "pendle_market": "0x...",
    "pt_oracle": "0x...",
    "lending_config": {
      "protocol": "morpho",
      "address": "0x...",
      "market_params": {
        "loanToken": "0x...",
        "collateralToken": "0x...",
        "oracle": "0x...",
        "irm": "0x...",
        "lltv": 860000000000000000
      }
    },
    "asset_conversion": {
      "method": "uniswap_v3_twap",
      "pool_address": "0x...",
      "twap_duration": 1800
    }
  }
}
```

---

### Mode: `holdings`

**Purpose**: Multi-token holdings with signed weights.

**Formula**:
```
total = Σ (token[i].balanceOf(escrow) × sign[i])
```

**Configuration**:
```json
{
  "id": "MULTI_TOKEN",
  "mode": "holdings",
  "escrow": "0x...",
  "holdings": [
    {"token": "0x...", "sign": 1},   // Asset (+)
    {"token": "0x...", "sign": -1}   // Liability (-)
  ]
}
```

**Security**: Rejects if holdings include wrapper asset.

---

### Mode: `uniswap_v3`

**Purpose**: Uniswap V3 LP position valuation.

**Components Valued**:
1. Liquidity position (token0 + token1 amounts)
2. Uncollected fees (tokensOwed0, tokensOwed1)

**Formula**:
```
position = nftManager.positions(tokenId)
(amount0, amount1) = calculateAmountsFromLiquidity(position)
fees = (position.tokensOwed0, position.tokensOwed1)
total = (amount0 + fees0) × price0 + (amount1 + fees1) × price1
value = convertToBaseAsset(total)
```

**Pricing Options**:
- `use_pool_twap: true`: Uniswap V3 TWAP (30-min default)
- `chainlink_oracle`: External Chainlink feed

**Configuration**:
```json
{
  "id": "UNISWAP_LP",
  "mode": "uniswap_v3",
  "escrow": "0x...",
  "extras": {
    "token_id": 12345,
    "pool_address": "0x...",
    "base_asset": "0x...",
    "use_pool_twap": true,
    "twap_duration": 1800
  }
}
```

---

### Mode: `options_otoken`

**Purpose**: Black-Scholes options valuation.

**Integrations**:
- Rysk API for market data (IV, spot)
- Chainlink for asset prices

**Formula**:
```
for each option:
    (S, K, T, σ, r, is_put) = getOptionParams(otoken)
    price = BlackScholes(S, K, T, σ, r, is_put)
    value += qty × price × side
```

**Configuration**:
```json
{
  "id": "OPTIONS_PORTFOLIO",
  "mode": "options_otoken",
  "escrow": "0x...",
  "extras": {
    "options": [
      {"token": "0x...", "side": 1, "symbol": "ETH"},
      {"token": "0x...", "side": -1, "symbol": "ETH"}
    ],
    "risk_free_bps": 500,
    "default_iv_bps": 8000,
    "oracles": {
      "0x...": "0x..."  // asset → Chainlink feed
    }
  }
}
```

---

## Configuration

### Configuration File Structure

```json
{
  "rpc_url": "https://rpc.hyperliquid.xyz/evm",
  "chain_id": 999,
  "valuer_address": "0x...",
  "wrapper_address": "0x...",

  "keeper_settings": {
    "update_check_interval": 60,
    "ttl": 300,
    "gas_limit": 350000,
    "max_fee_gwei": 20.0,
    "max_priority_gwei": 2.0,
    "enable_cache_refresh": true,
    "cache_refresh_gas_limit": 200000
  },

  "strategies": [
    {
      "id": "PT_KHYPE_LOOP",
      "mode": "pt_khype_loop",
      "escrow": "0x...",
      "adapter": "0x...",
      "confidence": 95,
      "extras": { ... }
    }
  ]
}
```

### Environment Variables

```bash
KEEPER_PRIVATE_KEY=0x...     # Signer private key
KEEPER_LOG_LEVEL=INFO        # Logging level (DEBUG, INFO, WARNING, ERROR)
```

### CLI Usage

```bash
# Single update cycle
python src/keepers/OffchainValuationKeeper.py config.json --mode once

# Continuous daemon
python src/keepers/OffchainValuationKeeper.py config.json --mode daemon
```

---

## Security Features

### Critical Fixes Applied

| Issue | Severity | Fix |
|-------|----------|-----|
| Zero debt on RPC failure | CRITICAL | Raise instead of return 0 |
| Hardcoded 0.95 price | CRITICAL | Raise instead of return default |
| Decimal mismatch | HIGH | Dynamic decimal handling |
| Silent underwater | MEDIUM | CRITICAL_ALERT logging |
| Ignored dust/rewards | MEDIUM | Optional tracking |

### Error Handling Philosophy

**Fail-Closed Design**: If we can't read data accurately, we don't submit.

```python
# BAD - Silent failure causes over-valuation
except Exception as e:
    return 0  # Strategy appears to have no debt!

# GOOD - Explicit failure prevents bad data
except Exception as e:
    logger.critical(f"CRITICAL: Debt query FAILED!")
    raise RuntimeError("Cannot value strategy safely") from e
```

### Double-Counting Prevention

The on-chain valuer adds `IERC20(asset).balanceOf(escrow)` in `getTotalValue()`.

**All modes validate**:
- `underlying_balance`: Rejects if underlying == wrapper
- `holdings`: Rejects if holdings include wrapper
- `uniswap_v3`: Only values LP position, not idle balance
- `pt_*_loop`: Only values PT position + debt, not idle wrapper

### Decimal Handling

```python
# Fetch actual decimals
pt_token, pt_decimals = self._erc20(pt_address)
underlying_decimals = extras.get('underlying_decimals', 18)

# Normalize if different
if pt_decimals != underlying_decimals:
    collateral = (pt_balance * pt_price * (10 ** underlying_decimals)) // (10**18 * (10 ** pt_decimals))
else:
    collateral = (pt_balance * pt_price) // 10**18
```

### Underwater Position Handling

```python
if net_underlying < 0:
    loss_amount = abs(net_underlying)
    logger.critical(
        f"CRITICAL_ALERT: [{s.id_text}] UNDERWATER POSITION - STRATEGY INSOLVENT!\n"
        f"  Collateral value: {collateral/1e18:.4f}\n"
        f"  Debt value:       {debt/1e18:.4f}\n"
        f"  Shortfall:        {loss_amount/1e18:.4f}\n"
        f"  ACTION REQUIRED: Review strategy health."
    )
    return 0  # Cannot report negative on-chain
```

---

## Error Handling

### RPC Errors

```python
try:
    debt = felix.position(marketId, escrow).borrowShares
except Exception as e:
    # CRITICAL: Never return 0 on failure
    logger.critical(f"Felix debt query FAILED: {e}")
    raise RuntimeError("Cannot value strategy safely")
```

### Oracle Errors

```python
pt_rate = oracle.getPtToAssetRate(market, 1800)

# Bounds check
if pt_rate < 0.5e18 or pt_rate > 1.05e18:
    raise ValueError(f"PT price {pt_rate/1e18} outside [0.5, 1.05]")
```

### Transaction Errors

| Error | Recovery |
|-------|----------|
| Nonce too low | Re-fetch nonce from chain |
| Gas too low | Increase gas limit |
| Signature expired | Re-sign with fresh expiry |
| Insufficient funds | Alert operator, pause |

---

## Deployment Guide

### Prerequisites

```bash
# Python 3.8+
pip install web3 eth-abi eth-account python-dotenv requests
```

### Systemd Service

```ini
[Unit]
Description=OffchainValuationKeeper
After=network.target

[Service]
Type=simple
User=keeper
WorkingDirectory=/opt/vault-v2
Environment="KEEPER_PRIVATE_KEY=0x..."
Environment="KEEPER_LOG_LEVEL=INFO"
ExecStart=/opt/vault-v2/venv/bin/python \
    src/keepers/OffchainValuationKeeper.py \
    keeper_config_mainnet.json \
    --mode daemon
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

### Docker

```dockerfile
FROM python:3.10-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt

COPY src/keepers/ /app/keepers/
COPY keeper_config.json /app/

ENV KEEPER_LOG_LEVEL=INFO

CMD ["python", "keepers/OffchainValuationKeeper.py", "keeper_config.json", "--mode", "daemon"]
```

---

## Monitoring

### Key Metrics

| Metric | Target | Alert Threshold |
|--------|--------|-----------------|
| Update success rate | > 99% | < 95% |
| Update latency | < 5s | > 30s |
| Gas per update | ~163k | > 300k |
| Time since last update | < 60s | > 300s |
| Underwater strategies | 0 | > 0 |

### Log Levels

```python
DEBUG   # Detailed execution info
INFO    # Normal operations
WARNING # Non-critical issues
ERROR   # Recoverable errors
CRITICAL # Requires immediate action
```

### Alert Conditions

```bash
# Monitor for critical alerts
tail -f keeper.log | grep "CRITICAL"

# Check last update times
grep "Update successful" keeper.log | tail -5

# Monitor gas usage trends
grep "gas=" keeper.log | awk '{print $NF}'
```

### Health Check Endpoint

```python
# Add to keeper for monitoring
def health_check(self):
    return {
        "status": "healthy" if self.last_success < 300 else "degraded",
        "uptime_hours": self.metrics.get_summary()["uptime_hours"],
        "success_rate": self.metrics.get_summary()["success_rate"],
        "last_update": self.metrics.last_update_time,
        "errors": self.metrics.errors_by_type
    }
```
