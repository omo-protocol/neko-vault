#!/usr/bin/env python3
"""
OffchainValuationKeeper - Off-chain service for strategy valuation

Refined to:
- Compute strategy value in WRAPPER UNITS (wrapper shares), consistent with UniversalValuerOffchain
- Create correct EIP-191 signatures matching on-chain validation
- Submit updateValue with monotonically increasing nonce and TTL expiry
- SECURITY FIX: Automatically refresh adapter cache after valuer updates to prevent cache poisoning
- Support modes:
  * underlying_balance: read underlying (rebasing) balance at escrow and convert to wrapper shares
  * pt_khype_loop: production implementation for leveraged PT strategies (SUPPORTS LINEAR DISCOUNT MODEL)
  * holdings: sum multiple token holdings with signs (assets +1, liabilities -1)
  * uniswap_v3: Uniswap V3 LP position valuation (NEW)

PT Pricing Models (pt_khype_loop mode):
- pendle_oracle (default): Uses Pendle's 30-min TWAP oracle for market-based pricing
- linear_discount: Mathematical model from PT_LINEAR_DISCOUNT_MODEL.md
  Formula: P(t,T) = previewRedeem(1) × [(1 - 1/(1 + r(T-t))) × t/T + 1/(1 + r(T-t))]
  Configuration: pricing_model, rate, maturity (or auto_detect_maturity)
  Use case: Predictable, conservative pricing independent of market conditions

Uniswap V3 Valuation (uniswap_v3 mode):
- Reads NFT position from NonFungiblePositionManager
- Calculates token amounts from liquidity using Uniswap V3 math
- Includes uncollected fees (tokensOwed0, tokensOwed1)
- Converts all tokens to base asset (e.g., wstHYPE → wHYPE)
- Uses pool TWAP (30-min default) or Chainlink oracle for pricing
- Configuration: token_id, pool_address, base_asset, use_pool_twap, chainlink_oracle

Important:
- The on-chain valuer adds idle wrapper balance itself (IERC20(asset).balanceOf(escrow)) in getTotalValue.
  Do NOT include idle wrapper balance in the off-chain reported value to avoid double-counting.
- strategyId is computed as keccak256(text_id), matching the docs.

Security:
- CRITICAL: All modes validate against double counting
- underlying_balance: Rejects configurations where underlying == wrapper
- holdings: Rejects holdings arrays that include the wrapper asset
- uniswap_v3: Only values LP position, not idle wrapper balance
- These validations prevent the idle escrow balance from being counted twice in getTotalValue()
- Linear discount: Validates maturity, bounds checks [0.5, 1.05], fallback to oracle on errors
- Uniswap V3: Validates ownership, uses TWAP for manipulation resistance
"""

import json
import os
import sys
import time
import logging
import requests
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple, Any
import math

from web3 import Web3
from eth_account import Account
from eth_account.messages import encode_defunct

try:
    # Required for proper abi.encode() matching Solidity encoding
    from eth_abi import encode as abi_encode
except Exception as e:
    raise RuntimeError("eth-abi must be installed: pip install eth-abi") from e

# Load environment variables from .env file
try:
    from dotenv import load_dotenv
    load_dotenv()  # Loads .env from current directory
except ImportError:
    # python-dotenv not installed, will rely on system environment variables
    pass


# Configure logging
logging.basicConfig(
    level=os.environ.get("KEEPER_LOG_LEVEL", "INFO"),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("OffchainValuationKeeper")


# Metrics tracking
class KeeperMetrics:
    """Track keeper performance metrics"""
    def __init__(self):
        self.updates_attempted = 0
        self.updates_succeeded = 0
        self.updates_failed = 0
        self.total_gas_used = 0
        self.last_update_time = {}
        self.errors_by_type = {}
        self.start_time = time.time()

    def record_attempt(self):
        self.updates_attempted += 1

    def record_success(self, strategy_id: str, gas_used: int = 0):
        self.updates_succeeded += 1
        self.total_gas_used += gas_used
        self.last_update_time[strategy_id] = time.time()

    def record_failure(self, strategy_id: str, error_type: str):
        self.updates_failed += 1
        self.errors_by_type[error_type] = self.errors_by_type.get(error_type, 0) + 1

    def get_summary(self) -> Dict[str, Any]:
        uptime = time.time() - self.start_time
        success_rate = (self.updates_succeeded / max(1, self.updates_attempted)) * 100
        return {
            "uptime_seconds": uptime,
            "uptime_hours": uptime / 3600,
            "updates_attempted": self.updates_attempted,
            "updates_succeeded": self.updates_succeeded,
            "updates_failed": self.updates_failed,
            "success_rate": f"{success_rate:.2f}%",
            "total_gas_used": self.total_gas_used,
            "avg_gas_per_update": self.total_gas_used // max(1, self.updates_succeeded),
            "errors_by_type": self.errors_by_type,
            "last_updates": self.last_update_time
        }

    def log_summary(self):
        summary = self.get_summary()
        logger.info("=" * 60)
        logger.info("KEEPER METRICS SUMMARY")
        logger.info("=" * 60)
        logger.info(f"Uptime: {summary['uptime_hours']:.2f} hours")
        logger.info(f"Updates: {summary['updates_succeeded']}/{summary['updates_attempted']} ({summary['success_rate']})")
        logger.info(f"Total gas used: {summary['total_gas_used']:,}")
        logger.info(f"Average gas/update: {summary['avg_gas_per_update']:,}")
        if summary['errors_by_type']:
            logger.info(f"Errors by type: {summary['errors_by_type']}")
        logger.info("=" * 60)


# Minimal ABIs
ERC20_ABI = [
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "balanceOf", "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

# PT token ABI (ERC5095/Pendle Principal Token)
PT_TOKEN_ABI = [
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "balanceOf", "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "previewRedeem", "inputs": [{"name": "shares", "type": "uint256"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "expiry", "inputs": [],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

# Pendle market ABI extension
PENDLE_MARKET_ABI = [
    {"name": "expiry", "inputs": [],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

# Pendle Linear Discount Oracle ABI (Chainlink-style feed)
PENDLE_LINEAR_ORACLE_ABI = [
    {"name": "PT", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "baseDiscountPerYear", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "latestRoundData", "inputs": [], "outputs": [
        {"name": "roundId", "type": "uint80"},
        {"name": "answer", "type": "int256"},
        {"name": "startedAt", "type": "uint256"},
        {"name": "updatedAt", "type": "uint256"},
        {"name": "answeredInRound", "type": "uint80"}
    ], "stateMutability": "view", "type": "function"},
]

# Morpho Chainlink Oracle V2 ABI
MORPHO_CHAINLINK_ORACLE_ABI = [
    {"name": "BASE_FEED_1", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "price", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

WRAPPER_ABI = [
    {"name": "convertToShares", "inputs": [{"name": "assets", "type": "uint256"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "convertToAssets", "inputs": [{"name": "shares", "type": "uint256"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

PENDLE_ORACLE_ABI = [
    {"name": "getPtToAssetRate", "inputs": [
        {"name": "market", "type": "address"},
        {"name": "duration", "type": "uint32"}
    ], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "getOracleState", "inputs": [
        {"name": "market", "type": "address"},
        {"name": "duration", "type": "uint32"}
    ], "outputs": [
        {"name": "increaseCardinalityRequired", "type": "bool"},
        {"name": "cardinalityRequired", "type": "uint16"},
        {"name": "oldestObservationSatisfied", "type": "bool"}
    ], "stateMutability": "view", "type": "function"},
]

FELIX_ABI = [
    {"name": "position", "inputs": [
        {"name": "id", "type": "bytes32"},
        {"name": "user", "type": "address"}
    ], "outputs": [
        {"name": "supplyShares", "type": "uint256"},
        {"name": "borrowShares", "type": "uint128"},
        {"name": "collateral", "type": "uint128"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "totalBorrowAssets", "inputs": [{"name": "id", "type": "bytes32"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "totalBorrowShares", "inputs": [{"name": "id", "type": "bytes32"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "market", "inputs": [{"name": "id", "type": "bytes32"}], "outputs": [
        {"name": "totalSupplyAssets", "type": "uint128"},
        {"name": "totalSupplyShares", "type": "uint128"},
        {"name": "totalBorrowAssets", "type": "uint128"},
        {"name": "totalBorrowShares", "type": "uint128"},
        {"name": "lastUpdate", "type": "uint128"},
        {"name": "fee", "type": "uint128"}
    ], "stateMutability": "view", "type": "function"},
]

VALUER_ABI = [
    {"name": "getReport", "inputs": [{"name": "strategyId", "type": "bytes32"}], "outputs": [{
        "components": [
            {"name": "value", "type": "uint256"},
            {"name": "timestamp", "type": "uint256"},
            {"name": "confidence", "type": "uint256"},
            {"name": "nonce", "type": "uint256"},
            {"name": "isPush", "type": "bool"},
            {"name": "lastUpdater", "type": "address"},
        ],
        "type": "tuple"
    }], "stateMutability": "view", "type": "function"},
    {"name": "updateValue", "inputs": [
        {"name": "strategyId", "type": "bytes32"},
        {"name": "value", "type": "uint256"},
        {"name": "confidence", "type": "uint256"},
        {"name": "nonce", "type": "uint256"},
        {"name": "expiry", "type": "uint256"},
        {"name": "signatures", "type": "bytes[]"}
    ], "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"name": "requiredWeight", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view",
     "type": "function"},
    {"name": "owner", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "asset", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
]

# UniversalAdapterEscrow ABI (for cache refresh)
ADAPTER_ABI = [
    {"name": "refreshCachedValuation", "inputs": [], "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"name": "getCachedValuation", "inputs": [], "outputs": [
        {"name": "value", "type": "uint256"},
        {"name": "timestamp", "type": "uint256"},
        {"name": "isStale", "type": "bool"}
    ], "stateMutability": "view", "type": "function"},
]

# Uniswap V3 NonFungiblePositionManager ABI (includes ERC721Enumerable)
UNISWAP_V3_POSITION_MANAGER_ABI = [
    {"name": "positions", "inputs": [{"name": "tokenId", "type": "uint256"}], "outputs": [
        {"name": "nonce", "type": "uint96"},
        {"name": "operator", "type": "address"},
        {"name": "token0", "type": "address"},
        {"name": "token1", "type": "address"},
        {"name": "fee", "type": "uint24"},
        {"name": "tickLower", "type": "int24"},
        {"name": "tickUpper", "type": "int24"},
        {"name": "liquidity", "type": "uint128"},
        {"name": "feeGrowthInside0LastX128", "type": "uint256"},
        {"name": "feeGrowthInside1LastX128", "type": "uint256"},
        {"name": "tokensOwed0", "type": "uint128"},
        {"name": "tokensOwed1", "type": "uint128"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "ownerOf", "inputs": [{"name": "tokenId", "type": "uint256"}],
     "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    # ERC721Enumerable functions for position scanning
    {"name": "balanceOf", "inputs": [{"name": "owner", "type": "address"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "tokenOfOwnerByIndex", "inputs": [
        {"name": "owner", "type": "address"},
        {"name": "index", "type": "uint256"}
    ], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

# Uniswap V3 Pool ABI
UNISWAP_V3_POOL_ABI = [
    {"name": "slot0", "inputs": [], "outputs": [
        {"name": "sqrtPriceX96", "type": "uint160"},
        {"name": "tick", "type": "int24"},
        {"name": "observationIndex", "type": "uint16"},
        {"name": "observationCardinality", "type": "uint16"},
        {"name": "observationCardinalityNext", "type": "uint16"},
        {"name": "feeProtocol", "type": "uint8"},
        {"name": "unlocked", "type": "bool"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "observe", "inputs": [{"name": "secondsAgos", "type": "uint32[]"}], "outputs": [
        {"name": "tickCumulatives", "type": "int56[]"},
        {"name": "secondsPerLiquidityCumulativeX128s", "type": "uint160[]"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "token0", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "token1", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "liquidity", "inputs": [], "outputs": [{"type": "uint128"}], "stateMutability": "view", "type": "function"},
]

# Chainlink Price Feed ABI (for external oracles)
CHAINLINK_FEED_ABI = [
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "latestRoundData", "inputs": [], "outputs": [
        {"name": "roundId", "type": "uint80"},
        {"name": "answer", "type": "int256"},
        {"name": "startedAt", "type": "uint256"},
        {"name": "updatedAt", "type": "uint256"},
        {"name": "answeredInRound", "type": "uint80"}
    ], "stateMutability": "view", "type": "function"},
]

# Uniswap V2 Pair ABI (for V2 TWAP price queries)
UNISWAP_V2_PAIR_ABI = [
    {"name": "getReserves", "inputs": [], "outputs": [
        {"name": "reserve0", "type": "uint112"},
        {"name": "reserve1", "type": "uint112"},
        {"name": "blockTimestampLast", "type": "uint32"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "price0CumulativeLast", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "price1CumulativeLast", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "token0", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "token1", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
]

# OToken ABI for options valuation
OTOKEN_ABI = [
    {"name": "underlyingAsset", "inputs": [], "outputs": [{"type": "address"}],
     "stateMutability": "view", "type": "function"},
    {"name": "strikeAsset", "inputs": [], "outputs": [{"type": "address"}],
     "stateMutability": "view", "type": "function"},
    {"name": "strikePrice", "inputs": [], "outputs": [{"type": "uint256"}],
     "stateMutability": "view", "type": "function"},
    {"name": "expiryTimestamp", "inputs": [], "outputs": [{"type": "uint256"}],
     "stateMutability": "view", "type": "function"},
    {"name": "isPut", "inputs": [], "outputs": [{"type": "bool"}],
     "stateMutability": "view", "type": "function"},
]


@dataclass
class StrategyConfig:
    id_text: str                 # e.g., "PT_KHYPE_LOOP"
    mode: str                    # "underlying_balance" | "pt_khype_loop"
    escrow: str                  # escrow address (checksum)
    underlying: str              # rebasing token (e.g., stETH), checksum
    confidence: int = 95         # confidence to attach to the update
    # Optional per-mode extras (dict bag of values)
    extras: Dict[str, Any] = None
    # Optional adapter address for cache refresh (SECURITY FIX: prevents cache poisoning)
    adapter: str = None          # adapter address (checksum), if different from escrow


class OffchainValuationKeeper:
    def __init__(self, config_path: str):
        """Initialize the keeper with configuration"""
        with open(config_path, 'r') as f:
            self.config = json.load(f)

        rpc_url = self.config['rpc_url']
        # Add timeout to HTTP provider to prevent hanging
        request_kwargs = {'timeout': 30}  # 30 second timeout for RPC calls
        self.w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs=request_kwargs))
        if not self.w3.is_connected():
            raise RuntimeError(f"Failed to connect to RPC at {rpc_url}")

        # Load signer account (env override > config)
        pk = os.environ.get("KEEPER_PRIVATE_KEY") or self.config.get('signer_private_key') or self.config.get('private_key')
        if not pk:
            raise RuntimeError("Missing keeper private key (env KEEPER_PRIVATE_KEY or config.signer_private_key)")
        self.account = Account.from_key(pk)
        logger.info(f"Keeper signer: {self.account.address}")

        # Load contracts
        self.valuer_address = Web3.to_checksum_address(self.config['valuer_address'])
        self.valuer = self.w3.eth.contract(address=self.valuer_address, abi=VALUER_ABI)

        # Wrapper used for unit conversion into SHARES (the vault's asset)
        self.wrapper_address = Web3.to_checksum_address(
            self.config.get('wrapper_address') or self.valuer.functions.asset().call()
        )
        self.wrapper = self.w3.eth.contract(address=self.wrapper_address, abi=WRAPPER_ABI)
        logger.info(f"Valuer: {self.valuer_address}, Wrapper (asset): {self.wrapper_address}")

        # Chain id for signing
        self.chain_id = self.config.get("chain_id", self.w3.eth.chain_id)

        # Keeper settings
        ks = self.config.get('keeper_settings', {})
        self.update_check_interval = int(ks.get('update_check_interval', 60))
        self.ttl_seconds = int(ks.get('ttl', 300))  # expiry TTL; must be <= MAX_SIGNATURE_AGE (1h) on-chain
        self.gas_limit = int(ks.get('gas_limit', 350_000))
        self.max_fee_gwei = float(ks.get('max_fee_gwei', 20.0))
        self.max_priority_gwei = float(ks.get('max_priority_gwei', 2.0))

        # Strategies
        self.strategies: List[StrategyConfig] = []
        for s in self.config.get('strategies', []):
            # Support both old and new config formats
            escrow_addr = s.get('escrow_address') or s.get('escrow')
            underlying_addr = s.get('underlying_address') or s.get('underlying')

            # Determine mode
            mode = s.get('mode', 'underlying_balance')

            # If holdings array is present, use holdings mode
            if 'holdings' in s:
                mode = 'holdings'
                extras = {'holdings': s['holdings']}
                # Add other extras if present
                if 'extras' in s:
                    extras.update(s['extras'])
            else:
                extras = s.get('extras', {})

            # Parse adapter address (for cache refresh after valuer updates)
            # If not specified, use escrow address (common case where adapter == escrow)
            adapter_addr = s.get('adapter_address') or s.get('adapter') or escrow_addr

            self.strategies.append(
                StrategyConfig(
                    id_text=s['id'],
                    mode=mode,
                    escrow=Web3.to_checksum_address(escrow_addr) if escrow_addr else '',
                    underlying=Web3.to_checksum_address(underlying_addr) if underlying_addr else '',
                    confidence=int(s.get('confidence') or s.get('min_confidence', 95)),
                    extras=extras,
                    adapter=Web3.to_checksum_address(adapter_addr) if adapter_addr else None
                )
            )

        # Caches
        self._erc20_cache: Dict[str, Tuple[Any, int]] = {}

        # Metrics
        self.metrics = KeeperMetrics()

        # Summary logging interval (log every 10 update cycles)
        self.summary_interval = 10
        self.update_cycle_count = 0

        # Cache refresh settings (SECURITY FIX: prevent cache poisoning)
        self.enable_cache_refresh = ks.get('enable_cache_refresh', True)
        self.cache_refresh_gas_limit = int(ks.get('cache_refresh_gas_limit', 200_000))
        
        # Cache for adapter contracts
        self._adapter_cache: Dict[str, Any] = {}

    def _erc20(self, addr: str):
        cs = Web3.to_checksum_address(addr)
        if cs in self._erc20_cache:
            return self._erc20_cache[cs]
        c = self.w3.eth.contract(address=cs, abi=ERC20_ABI)
        try:
            dec = int(c.functions.decimals().call())
        except Exception:
            dec = 18
        self._erc20_cache[cs] = (c, dec)
        self._erc20_cache[cs] = (c, dec)
        return self._erc20_cache[cs]

    def _otoken(self, addr: str):
        """Get OToken contract instance."""
        cs = Web3.to_checksum_address(addr)
        return self.w3.eth.contract(address=cs, abi=OTOKEN_ABI)

    def _adapter(self, addr: str):
        """Get UniversalAdapterEscrow contract instance (cached)."""
        cs = Web3.to_checksum_address(addr)
        if cs in self._adapter_cache:
            return self._adapter_cache[cs]
        c = self.w3.eth.contract(address=cs, abi=ADAPTER_ABI)
        self._adapter_cache[cs] = c
        return c

    @staticmethod
    def _norm_cdf(x: float) -> float:
        """Cumulative distribution function for the standard normal distribution."""
        return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))

    @staticmethod
    def _black_scholes(S: float, K: float, T: float, sigma: float, r: float, is_put: bool) -> float:
        """
        Calculate Black-Scholes option price.

        Args:
            S: Underlying price
            K: Strike price
            T: Time to expiry in years
            sigma: Implied volatility (decimal)
            r: Risk-free rate (decimal)
            is_put: True for put option, False for call option

        Returns:
            Option price
        """
        if T <= 0 or sigma <= 0 or S <= 0 or K <= 0:
            return max(0.0, (K - S) if is_put else (S - K))

        sqrtT = math.sqrt(T)
        d1 = (math.log(S / K) + (r + 0.5 * sigma**2) * T) / (sigma * sqrtT)
        d2 = d1 - sigma * sqrtT

        if is_put:
            return K * math.exp(-r * T) * OffchainValuationKeeper._norm_cdf(-d2) - S * OffchainValuationKeeper._norm_cdf(-d1)
        else:
            return S * OffchainValuationKeeper._norm_cdf(d1) - K * math.exp(-r * T) * OffchainValuationKeeper._norm_cdf(d2)

    def _get_asset_price_in_base(self, asset: str, oracles: Dict[str, str]) -> float:
        """
        Get asset price in terms of base asset (wrapper underlying) using Chainlink feeds.

        Args:
            asset: Asset address to price
            oracles: Dictionary mapping asset address (lowercase) to Chainlink feed address

        Returns:
            Price of 1 unit of asset in base asset terms (float)
        """
        asset_lower = asset.lower()

        feed_address = oracles.get(asset_lower)
        if not feed_address:
            # Don't log warning here as we might be using Rysk API data instead
            return 0.0

        try:
            feed_cs = Web3.to_checksum_address(feed_address)
            feed = self.w3.eth.contract(address=feed_cs, abi=CHAINLINK_FEED_ABI)

            # Get price
            data = feed.functions.latestRoundData().call()
            price = int(data[1])
            decimals = int(feed.functions.decimals().call())

            # Return as float
            return float(price) / (10 ** decimals)

        except Exception as e:
            logger.error(f"Error fetching price for {asset}: {e}")
            return 0.0

    def _fetch_rysk_market_data(self) -> Dict[str, Any]:
        """
        Fetch option market data (IV, Spot) from Rysk API.

        Returns:
            Dictionary mapping "{symbol}-{strike}-{expiry}-{is_put}" -> {S, sigma}
            Key format: "SYMBOL-STRIKE_FLOAT-EXPIRY_INT-IS_PUT_BOOL"
            Example: "ETH-3000.0-1758873600-True"
        """
        try:
            url = "https://v12.rysk.finance/api/inventory"
            response = requests.get(url, timeout=10)
            response.raise_for_status()
            data = response.json()

            market_data = {}

            # Iterate over assets (ETH, WBTC, etc.)
            for symbol, asset_data in data.items():
                combinations = asset_data.get("combinations", {})
                for key, combo in combinations.items():
                    # Key format in API: "STRIKE-EXPIRY" (e.g. "104000.000000-1758873600")
                    # We need to parse this or use the fields in 'combo'

                    strike = float(combo.get("strike", 0))
                    expiry = int(combo.get("expiration_timestamp", 0))
                    is_put = bool(combo.get("isPut", False))

                    # Get market data
                    bid_iv = float(combo.get("bidIv", 0))
                    ask_iv = float(combo.get("askIv", 0))

                    # Use average IV
                    iv = (bid_iv + ask_iv) / 2.0 / 100.0 # Convert % to decimal

                    # Get spot price (index)
                    spot = float(combo.get("index", 0))

                    # Store in our map
                    # Key: SYMBOL-STRIKE-EXPIRY-IS_PUT
                    # We normalize strike to remove trailing zeros for better matching?
                    # Or keep it float. Let's use a consistent string format.
                    # Rysk API uses 6 decimals for strike in the key, but 'strike' field is a number.

                    lookup_key = f"{symbol.upper()}-{strike:.6f}-{expiry}-{is_put}"
                    market_data[lookup_key] = {"S": spot, "sigma": iv}

            return market_data

        except Exception as e:
            logger.error(f"Error fetching Rysk API data: {e}")
            return {}

    def value_options_otoken_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'options_otoken'
        Valuation for options held in MPC wallet using Black-Scholes model.
        Integrates with Rysk API for market data (IV, Spot).
        """
        extras = s.extras or {}
        opts = extras.get("options", [])
        if not opts:
            return 0

        r = int(extras.get("risk_free_bps", 0)) / 10_000.0
        default_iv = int(extras.get("default_iv_bps", 8000)) / 10_000.0
        now = time.time()
        total_value_base = 0.0

        # Oracle config: map asset -> feed
        oracles = {k.lower(): v for k, v in extras.get("oracles", {}).items()}

        # Fetch Rysk API data
        rysk_data = self._fetch_rysk_market_data()

        # Symbol map: Address -> Symbol (e.g. 0x... -> ETH)
        # This is needed to look up in Rysk data
        symbol_map = {k.lower(): v.upper() for k, v in extras.get("symbol_map", {}).items()}

        for opt in opts:
            token_addr = opt["token"]
            side = int(opt.get("side", 1)) # 1 for long, -1 for short

            # Check if specific IV provided in config (overrides API)
            config_iv = opt.get("iv_bps")

            try:
                o = self._otoken(token_addr)
                erc, dec = self._erc20(token_addr)

                raw_bal = int(erc.functions.balanceOf(s.escrow).call())
                if raw_bal == 0:
                    continue

                qty = float(raw_bal) / (10 ** dec)

                # Load option params
                underlying_addr = o.functions.underlyingAsset().call()
                strike_asset = o.functions.strikeAsset().call()
                strike_raw = int(o.functions.strikePrice().call())
                expiry = int(o.functions.expiryTimestamp().call())
                is_put = bool(o.functions.isPut().call())

                # Determine Strike Price (K)
                # Assuming strikePrice is 1e8 scaled (Opyn standard)
                # We need to verify this assumption or make it configurable.
                # Rysk OTokens usually use 1e8 for strike.
                K = float(strike_raw) / 1e8

                # Try to get data from Rysk API
                # We need the symbol of the underlying
                symbol = symbol_map.get(underlying_addr.lower())
                if not symbol:
                    # Try to get symbol from config option item
                    symbol = opt.get("symbol")

                market_data_item = None
                if symbol:
                    # Construct lookup key: SYMBOL-STRIKE-EXPIRY-IS_PUT
                    # Strike formatted to 6 decimals to match our parser
                    lookup_key = f"{symbol.upper()}-{K:.6f}-{expiry}-{is_put}"
                    market_data_item = rysk_data.get(lookup_key)

                if market_data_item and not config_iv:
                    # Use API data
                    S = market_data_item["S"]
                    sigma = market_data_item["sigma"]
                    # Note: K is already set
                    # If strike asset is not USD, we might need to adjust K?
                    # Rysk API 'strike' is usually in USD (e.g. 3000 for ETH).
                    # And 'index' is in USD.
                    # So BS gives value in USD.
                else:
                    # Fallback to manual oracles / config IV
                    p_underlying = self._get_asset_price_in_base(underlying_addr, oracles)
                    p_strike_asset = self._get_asset_price_in_base(strike_asset, oracles)

                    S = p_underlying
                    # Adjust K if necessary (e.g. if K is in Strike Asset terms)
                    # If strike asset is USDC (approx 1), K is roughly K_raw/1e8.
                    # We multiply by p_strike_asset to be safe if it's not 1.0
                    K = (float(strike_raw) / 1e8) * (p_strike_asset if p_strike_asset > 0 else 1.0)

                    if config_iv:
                        sigma = int(config_iv) / 10_000.0
                    else:
                        sigma = default_iv

                T = max(0.0, (expiry - now) / (365.25 * 86400))

                price = OffchainValuationKeeper._black_scholes(S, K, T, sigma, r, is_put)

                # Value of position in USD (assuming S, K are USD-based)
                position_value_usd = qty * price

                # Convert to Base Asset
                # We need Base Asset Price in USD
                # If we used Rysk API, S is in USD.
                # If we used Oracles, S was p_underlying (which we assumed was USD or relative to base).
                # Let's assume everything is USD-denominated for simplicity in this integration,
                # then convert final USD value to Base Asset.

                # Get Base Asset Price (USD)
                # We need an oracle for the base asset (s.underlying)
                p_base = self._get_asset_price_in_base(s.underlying, oracles)

                # If base asset is one of the Rysk assets, we could potentially use Rysk index?
                # But let's stick to configured oracles for base asset to be safe.

                if p_base > 0:
                    position_value_base = position_value_usd / p_base
                    total_value_base += side * position_value_base
                else:
                    # If we can't price the base asset, we can't convert.
                    # But if the base asset IS the underlying (e.g. WETH vault holding WETH options),
                    # and we have S (Price of Underlying in USD), then p_base = S.
                    if s.underlying.lower() == underlying_addr.lower() and S > 0:
                         position_value_base = position_value_usd / S
                         total_value_base += side * position_value_base
                    else:
                        logger.warning(f"Base asset price is 0, cannot convert option value for {token_addr}")

            except Exception as e:
                logger.error(f"Error valuing option {token_addr}: {e}")
                continue

        if total_value_base < 0:
            total_value_base = 0.0

        # Convert to integer with 18 decimals (assuming base asset is 18 decimals or we convert to it)
        # The vault expects value in Wrapper Shares.
        # First we get value in Underlying (Base).
        # Assuming base asset has 18 decimals?
        # We should check s.underlying decimals.
        _, base_dec = self._erc20(s.underlying)

        total_value_base_int = int(total_value_base * (10 ** base_dec))

        return self._convert_underlying_to_wrapper_shares(total_value_base_int)

    @staticmethod
    def to_strategy_id(text_id: str) -> bytes:
        """Compute bytes32 strategyId = keccak256(text_id)"""
        return Web3.keccak(text=text_id)

    def _convert_underlying_to_wrapper_shares(self, underlying_amount: int) -> int:
        """Convert underlying units (rebasing token) to wrapper shares using on-chain convertToShares."""
        if underlying_amount <= 0:
            return 0
        try:
            # Try calling convertToShares (for ERC4626 vaults like wstETH)
            shares = self.wrapper.functions.convertToShares(int(underlying_amount)).call()
            return int(shares)
        except Exception as e:
            # For standard ERC20 tokens (like kHYPE), underlying == shares (1:1)
            logger.debug(f"convertToShares not available (standard ERC20), using 1:1 ratio: {e}")
            return int(underlying_amount)

    def _read_underlying_balance(self, token: str, holder: str) -> int:
        """Read ERC20 balanceOf(holder) for token."""
        erc, _ = self._erc20(token)
        try:
            return int(erc.functions.balanceOf(holder).call())
        except Exception as e:
            raise RuntimeError(f"balanceOf({token}, {holder}) failed: {e}")

    def _get_pt_price(self, market: str, oracle: str) -> int:
        """
        Get PT to asset exchange rate from Pendle oracle.

        Args:
            market: Pendle market address
            oracle: Pendle PT oracle address

        Returns:
            PT price ratio in 18 decimals (1e18 = 1:1, 0.95e18 = 95% of underlying)

        Raises:
            ValueError: If oracle configuration is missing or price is out of bounds
            RuntimeError: If oracle query fails
        """
        # CRITICAL FIX: Do NOT default to hardcoded price!
        # Hardcoded 0.95 is dangerous during market crashes/oracle failures
        # Example: PT drops to $0.60, oracle halts → reports $0.95 → 58% over-valuation
        # This allows users to exit at inflated prices, causing protocol insolvency
        if not market or not oracle:
            raise ValueError(
                "Missing Pendle market or oracle address - cannot safely price PT. "
                "Configure pendle_market and pt_oracle in strategy extras."
            )

        try:
            market_cs = Web3.to_checksum_address(market)
            oracle_cs = Web3.to_checksum_address(oracle)
            oracle_contract = self.w3.eth.contract(address=oracle_cs, abi=PENDLE_ORACLE_ABI)

            # Use 30 minute TWAP for stable pricing
            duration = 1800  # 30 minutes in seconds

            # Check oracle state first
            try:
                oracle_state = oracle_contract.functions.getOracleState(market_cs, duration).call()
                if oracle_state[0]:  # increaseCardinalityRequired
                    logger.warning(
                        f"Pendle oracle cardinality needs increase. "
                        f"Required: {oracle_state[1]}, may affect price accuracy"
                    )
            except Exception as e:
                logger.debug(f"Could not check oracle state: {e}")

            # Get PT to asset rate (18 decimals)
            pt_rate = int(oracle_contract.functions.getPtToAssetRate(market_cs, duration).call())

            # Sanity check: PT price should be between 0.5 and 1.05 (50% to 105%)
            # CRITICAL FIX: Raise error instead of returning hardcoded value
            if pt_rate < int(0.5 * 10**18) or pt_rate > int(1.05 * 10**18):
                raise ValueError(
                    f"PT price {pt_rate/1e18:.4f} outside expected range [0.5, 1.05]. "
                    f"Oracle may be stale or market conditions are extreme. "
                    f"Cannot safely value strategy."
                )

            logger.debug(f"PT price from oracle: {pt_rate/1e18:.6f}")
            return pt_rate

        except ValueError:
            # Re-raise validation errors
            raise
        except Exception as e:
            # CRITICAL FIX: Do NOT return hardcoded 0.95 on oracle failure!
            logger.critical(
                f"CRITICAL: Pendle oracle query FAILED! "
                f"Cannot safely price PT tokens. Error: {e}"
            )
            raise RuntimeError(f"Pendle oracle query failed - cannot value strategy safely: {e}") from e

    def _get_felix_debt(self, felix: str, market_id: str, user: str) -> int:
        """
        Get user's debt from Felix lending (Morpho Blue fork).

        Args:
            felix: Felix lending contract address
            market_id: Market ID (bytes32)
            user: User address

        Returns:
            Debt amount in underlying token (18 decimals)
        """
        if not felix or felix == "0x0000000000000000000000000000000000000000":
            logger.debug("No Felix address configured, assuming 0 debt")
            return 0

        if not market_id:
            logger.warning("Missing Felix market_id, assuming 0 debt")
            return 0

        try:
            felix_cs = Web3.to_checksum_address(felix)
            user_cs = Web3.to_checksum_address(user)
            felix_contract = self.w3.eth.contract(address=felix_cs, abi=FELIX_ABI)

            # Convert market_id to bytes32 if it's a hex string
            if isinstance(market_id, str):
                if market_id.startswith('0x'):
                    market_id_bytes = bytes.fromhex(market_id[2:])
                else:
                    market_id_bytes = bytes.fromhex(market_id)
            else:
                market_id_bytes = market_id

            # Get user position (supplyShares, borrowShares, collateral)
            position = felix_contract.functions.position(market_id_bytes, user_cs).call()
            borrow_shares = int(position[1])  # borrowShares is second element

            if borrow_shares == 0:
                logger.debug(f"No borrow shares for user {user_cs}")
                return 0

            # Get market totals to convert shares to assets
            # Try direct totalBorrowAssets call first (more efficient)
            try:
                total_borrow_assets = int(felix_contract.functions.totalBorrowAssets(market_id_bytes).call())
                total_borrow_shares = int(felix_contract.functions.totalBorrowShares(market_id_bytes).call())
            except Exception:
                # Fallback: get from market() struct
                market_data = felix_contract.functions.market(market_id_bytes).call()
                total_borrow_assets = int(market_data[2])  # totalBorrowAssets
                total_borrow_shares = int(market_data[3])  # totalBorrowShares

            # Convert shares to assets
            if total_borrow_shares == 0:
                logger.warning("Felix market has 0 total borrow shares but user has shares")
                return 0

            debt_assets = (borrow_shares * total_borrow_assets) // total_borrow_shares

            logger.debug(
                f"Felix debt: shares={borrow_shares}, "
                f"total_assets={total_borrow_assets/1e18:.4f}, "
                f"total_shares={total_borrow_shares}, "
                f"debt={debt_assets/1e18:.4f}"
            )

            return debt_assets

        except Exception as e:
            # CRITICAL FIX: Do NOT return 0 on RPC failure!
            # Returning 0 debt on error causes massive over-reporting of strategy value
            # Example: $1M assets + $800k debt = $200k net value
            #          RPC error → reports $0 debt → $1M reported (5x over-valuation)
            # This could lead to protocol insolvency via arbitrage attacks
            logger.critical(
                f"CRITICAL: Felix debt query FAILED for {user}! "
                f"Cannot safely value strategy without debt data. "
                f"Error: {e}"
            )
            raise RuntimeError(f"Felix debt query failed - cannot value strategy safely: {e}") from e

    def _fetch_rate_from_felix_oracle(self, felix_oracle_address: str) -> float:
        """
        Fetch the actual rate parameter from Felix's oracle contracts.

        This queries the Morpho Chainlink Oracle V2 wrapper and extracts the
        baseDiscountPerYear from the underlying Pendle Linear Discount Oracle.

        Args:
            felix_oracle_address: Address of Felix's MorphoChainlinkOracleV2 oracle
                                 (e.g., 0x225e9e58BE07dB30C0Ed6CF081E0BAE413E39d68)

        Returns:
            Rate as float (e.g., 0.21 for 21% annual discount)
        """
        try:
            # Step 1: Query Morpho Chainlink Oracle V2 to get the BASE_FEED_1
            oracle_cs = Web3.to_checksum_address(felix_oracle_address)
            morpho_oracle = self.w3.eth.contract(address=oracle_cs, abi=MORPHO_CHAINLINK_ORACLE_ABI)

            base_feed_address = morpho_oracle.functions.BASE_FEED_1().call()
            logger.debug(f"Morpho oracle BASE_FEED_1: {base_feed_address}")

            # Step 2: Query the Pendle Linear Discount Oracle (Chainlink-style feed)
            feed_cs = Web3.to_checksum_address(base_feed_address)
            pendle_feed = self.w3.eth.contract(address=feed_cs, abi=PENDLE_LINEAR_ORACLE_ABI)

            # Get base discount per year (in 18 decimals)
            base_discount_raw = pendle_feed.functions.baseDiscountPerYear().call()
            rate = float(base_discount_raw) / 1e18

            # Get PT address for verification
            pt_address = pendle_feed.functions.PT().call()

            logger.info(
                f"Fetched rate from Felix oracle: "
                f"felix_oracle={felix_oracle_address}, "
                f"pendle_feed={base_feed_address}, "
                f"PT={pt_address}, "
                f"rate={rate:.4f} ({rate*100:.2f}%)"
            )

            return rate

        except Exception as e:
            logger.error(f"Failed to fetch rate from Felix oracle {felix_oracle_address}: {e}")
            return 0.0

    def _get_felix_oracle_price(self, felix_oracle_address: str) -> int:
        """
        Get the current PT price directly from Felix's oracle contract.

        This can be used to compare your keeper's calculated price against
        Felix's actual oracle price for validation.

        Args:
            felix_oracle_address: Address of Felix's MorphoChainlinkOracleV2 oracle

        Returns:
            Price scaled by 1e36 (Morpho Blue format)
        """
        try:
            oracle_cs = Web3.to_checksum_address(felix_oracle_address)
            morpho_oracle = self.w3.eth.contract(address=oracle_cs, abi=MORPHO_CHAINLINK_ORACLE_ABI)

            price = morpho_oracle.functions.price().call()
            logger.debug(f"Felix oracle price: {price} ({price/1e36:.6f})")

            return price

        except Exception as e:
            logger.error(f"Failed to get price from Felix oracle {felix_oracle_address}: {e}")
            return 0

    # ============= Generic Lending Protocol Dispatcher =============

    def _get_lending_debt(self, lending_config: Dict[str, Any], user: str) -> int:
        """
        Generic lending debt dispatcher that routes to protocol-specific implementations.

        This allows value_pt_loop_mode to work with any lending protocol by configuration.

        Args:
            lending_config: Configuration dict containing:
                - protocol: Protocol name ('felix', 'morpho', 'aave_v3', 'compound_v3', etc.)
                - address: Main protocol contract address
                - Additional protocol-specific parameters
            user: Borrower address (escrow)

        Returns:
            Debt amount in underlying token units (18 decimals)

        Example configs:
            # Felix (Morpho Blue fork)
            {
                "protocol": "felix",
                "address": "0x...",
                "market_id": "0x..."
            }

            # Morpho Blue
            {
                "protocol": "morpho",
                "address": "0x...",
                "market_params": {...}
            }

            # Aave V3
            {
                "protocol": "aave_v3",
                "pool_address": "0x...",
                "debt_token": "0x..."
            }
        """
        protocol = lending_config.get('protocol', '').lower()

        if protocol == 'felix' or protocol == 'felix_lending':
            # Felix Lending (Morpho Blue fork)
            address = lending_config.get('address')
            market_id = lending_config.get('market_id')
            return self._get_felix_debt(address, market_id, user)

        elif protocol == 'morpho' or protocol == 'morpho_blue':
            # Morpho Blue native
            address = lending_config.get('address')
            market_params = lending_config.get('market_params')
            return self._get_morpho_blue_debt(address, market_params, user)

        elif protocol == 'aave_v3':
            # Aave V3
            pool_address = lending_config.get('pool_address')
            debt_token = lending_config.get('debt_token')
            return self._get_aave_v3_debt(pool_address, debt_token, user)

        elif protocol == 'compound_v3':
            # Compound V3 (Comet)
            comet_address = lending_config.get('comet_address')
            return self._get_compound_v3_debt(comet_address, user)

        elif protocol == 'none' or not protocol:
            # No lending protocol (pure PT holding)
            logger.debug(f"No lending protocol configured, returning 0 debt")
            return 0

        else:
            logger.error(f"Unsupported lending protocol: {protocol}")
            return 0

    def _get_morpho_blue_debt(self, morpho_address: str, market_params: Dict, user: str) -> int:
        """
        Get user's debt from Morpho Blue.

        Morpho Blue uses market parameters to identify markets instead of market IDs.

        Args:
            morpho_address: Morpho Blue contract address
            market_params: Market parameters dict containing:
                - loanToken, collateralToken, oracle, irm, lltv
            user: Borrower address

        Returns:
            Debt amount in underlying token (18 decimals)
        """
        if not morpho_address or not market_params:
            logger.debug("Missing Morpho Blue config, assuming 0 debt")
            return 0

        try:
            morpho_cs = Web3.to_checksum_address(morpho_address)
            user_cs = Web3.to_checksum_address(user)

            # Morpho Blue uses similar ABI to Morpho (Felix fork)
            morpho = self.w3.eth.contract(address=morpho_cs, abi=FELIX_ABI)

            # Compute market ID from parameters
            # marketId = keccak256(abi.encode(marketParams))
            market_params_tuple = (
                Web3.to_checksum_address(market_params['loanToken']),
                Web3.to_checksum_address(market_params['collateralToken']),
                Web3.to_checksum_address(market_params['oracle']),
                Web3.to_checksum_address(market_params['irm']),
                int(market_params['lltv'])
            )
            market_id = Web3.keccak(abi_encode(
                ['address', 'address', 'address', 'address', 'uint256'],
                list(market_params_tuple)
            ))

            # Get position
            position = morpho.functions.position(market_id, user_cs).call()
            borrow_shares = int(position[1])

            if borrow_shares == 0:
                return 0

            # Convert shares to assets
            total_borrow_assets = int(morpho.functions.totalBorrowAssets(market_id).call())
            total_borrow_shares = int(morpho.functions.totalBorrowShares(market_id).call())

            if total_borrow_shares == 0:
                return 0

            debt = (borrow_shares * total_borrow_assets) // total_borrow_shares
            logger.debug(f"Morpho Blue debt: {debt / 1e18:.6f}")
            return debt

        except Exception as e:
            # CRITICAL FIX: Do NOT return 0 on RPC failure!
            # Same issue as Felix - returning 0 debt causes massive over-valuation
            logger.critical(
                f"CRITICAL: Morpho Blue debt query FAILED for {user}! "
                f"Cannot safely value strategy without debt data. Error: {e}"
            )
            raise RuntimeError(f"Morpho Blue debt query failed - cannot value strategy safely: {e}") from e

    def _get_aave_v3_debt(self, pool_address: str, debt_token: str, user: str) -> int:
        """
        Get user's debt from Aave V3.

        Args:
            pool_address: Aave V3 Pool contract address
            debt_token: Variable debt token address (or 'stable' for stable debt)
            user: Borrower address

        Returns:
            Debt amount in underlying token
        """
        if not debt_token or debt_token == "0x0000000000000000000000000000000000000000":
            logger.debug("No Aave debt token configured, assuming 0 debt")
            return 0

        try:
            debt_token_cs = Web3.to_checksum_address(debt_token)
            user_cs = Web3.to_checksum_address(user)

            # Aave debt tokens are ERC20-like and track balances
            debt_erc, _ = self._erc20(debt_token_cs)
            debt_balance = int(debt_erc.functions.balanceOf(user_cs).call())

            logger.debug(f"Aave V3 debt: {debt_balance / 1e18:.6f}")
            return debt_balance

        except Exception as e:
            # CRITICAL FIX: Do NOT return 0 on RPC failure!
            # Same issue as Felix - returning 0 debt causes massive over-valuation
            logger.critical(
                f"CRITICAL: Aave V3 debt query FAILED for {user}! "
                f"Cannot safely value strategy without debt data. Error: {e}"
            )
            raise RuntimeError(f"Aave V3 debt query failed - cannot value strategy safely: {e}") from e

    def _get_compound_v3_debt(self, comet_address: str, user: str) -> int:
        """
        Get user's debt from Compound V3 (Comet).

        Args:
            comet_address: Comet contract address
            user: Borrower address

        Returns:
            Debt amount in base token
        """
        if not comet_address or comet_address == "0x0000000000000000000000000000000000000000":
            logger.debug("No Compound V3 address configured, assuming 0 debt")
            return 0

        try:
            comet_cs = Web3.to_checksum_address(comet_address)
            user_cs = Web3.to_checksum_address(user)

            # Compound V3 has borrowBalanceOf() method
            comet_abi = [{"inputs":[{"name":"account","type":"address"}],"name":"borrowBalanceOf","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"}]
            comet = self.w3.eth.contract(address=comet_cs, abi=comet_abi)

            debt = int(comet.functions.borrowBalanceOf(user_cs).call())
            logger.debug(f"Compound V3 debt: {debt / 1e18:.6f}")
            return debt

        except Exception as e:
            # CRITICAL FIX: Do NOT return 0 on RPC failure!
            # Same issue as Felix - returning 0 debt causes massive over-valuation
            logger.critical(
                f"CRITICAL: Compound V3 debt query FAILED for {user}! "
                f"Cannot safely value strategy without debt data. Error: {e}"
            )
            raise RuntimeError(f"Compound V3 debt query failed - cannot value strategy safely: {e}") from e

    # ============= End Generic Lending Protocol Dispatcher =============

    # ============= Generic Asset Conversion System =============

    def _auto_detect_token_order(self, pool_address: str, from_asset: str, pool_type: str = 'v3') -> bool:
        """
        Auto-detect token ordering in Uniswap pool.

        Queries the pool contract to determine if from_asset is token0 or token1.

        Args:
            pool_address: Uniswap pool address
            from_asset: Source asset address
            pool_type: 'v3' or 'v2' (determines ABI)

        Returns:
            True if from_asset == token0, False if from_asset == token1

        Raises:
            RuntimeError if from_asset is neither token0 nor token1
        """
        try:
            pool_cs = Web3.to_checksum_address(pool_address)
            from_cs = Web3.to_checksum_address(from_asset)

            # Select ABI based on pool type
            abi = UNISWAP_V3_POOL_ABI if pool_type == 'v3' else UNISWAP_V2_PAIR_ABI
            pool = self.w3.eth.contract(address=pool_cs, abi=abi)

            # Query token addresses
            token0 = Web3.to_checksum_address(pool.functions.token0().call())
            token1 = Web3.to_checksum_address(pool.functions.token1().call())

            logger.debug(
                f"Pool tokens: token0={token0}, token1={token1}, from_asset={from_cs}"
            )

            # Compare addresses (case-insensitive)
            if token0.lower() == from_cs.lower():
                logger.debug(f"Auto-detected: from_asset is token0 → token0_is_from=True")
                return True
            elif token1.lower() == from_cs.lower():
                logger.debug(f"Auto-detected: from_asset is token1 → token0_is_from=False")
                return False
            else:
                raise RuntimeError(
                    f"from_asset {from_cs} is neither token0 ({token0}) nor token1 ({token1}) "
                    f"in pool {pool_cs}. Wrong pool address?"
                )

        except Exception as e:
            logger.error(f"Error auto-detecting token order: {e}")
            raise

    def _convert_asset_to_wrapper(self, amount: int, from_asset: str, conversion_config: Dict[str, Any]) -> int:
        """
        Generic asset conversion dispatcher for PT underlying → vault wrapper conversions.

        Use case: When PT underlying asset ≠ vault wrapper asset
        Example: PT-kHYPE (underlying=kHYPE) in wHYPE vault requires kHYPE→wHYPE conversion

        Args:
            amount: Amount in from_asset units (18 decimals)
            from_asset: Source asset address (PT underlying, e.g., kHYPE)
            conversion_config: Configuration dict containing:
                - method: Conversion method ('uniswap_v3_twap', 'uniswap_v2_twap', 'chainlink', 'fixed_ratio', 'none')
                - Additional method-specific parameters

        Returns:
            Amount in wrapper asset units (18 decimals)

        Supported methods:
            1. uniswap_v3_twap: Uniswap V3 TWAP oracle (manipulation resistant)
            2. uniswap_v2_twap: Uniswap V2 cumulative price oracle
            3. chainlink: Chainlink price feed (two feeds or direct pair)
            4. fixed_ratio: Fixed conversion ratio (testing only)
            5. none: 1:1 conversion or skip (when assets are same)

        Example configs:
            # Uniswap V3 TWAP
            {
                "method": "uniswap_v3_twap",
                "pool_address": "0x...",
                "twap_duration": 1800,  # 30 min
                "token0_is_from": true  # kHYPE is token0
            }

            # Chainlink
            {
                "method": "chainlink",
                "from_feed": "0x...",  # kHYPE/USD
                "to_feed": "0x..."     # wHYPE/USD
            }
        """
        if amount <= 0:
            return 0

        method = conversion_config.get('method', 'none').lower()

        # Check if conversion needed
        from_normalized = Web3.to_checksum_address(from_asset).lower()
        wrapper_normalized = self.wrapper_address.lower()

        if from_normalized == wrapper_normalized or method == 'none':
            logger.debug(f"Assets match or method=none, skipping conversion: {amount / 1e18:.6f}")
            return amount

        # Route to conversion method
        if method == 'uniswap_v3_twap':
            return self._convert_via_uniswap_v3_twap(amount, from_asset, conversion_config)
        elif method == 'uniswap_v2_twap':
            return self._convert_via_uniswap_v2_twap(amount, from_asset, conversion_config)
        elif method == 'chainlink':
            return self._convert_via_chainlink(amount, from_asset, conversion_config)
        elif method == 'fixed_ratio':
            return self._convert_via_fixed_ratio(amount, conversion_config)
        else:
            logger.error(f"Unsupported asset conversion method: {method}, returning unconverted")
            return amount

    def _convert_via_uniswap_v3_twap(self, amount: int, from_asset: str, config: Dict) -> int:
        """
        Convert asset using Uniswap V3 pool TWAP.

        This uses the observe() function to get time-weighted average tick over a period,
        providing manipulation-resistant pricing.

        Args:
            amount: Amount in from_asset
            from_asset: Source asset address
            config: Dict with:
                - pool_address: Required
                - twap_duration: Optional (default 1800s)
                - token0_is_from: Optional (auto-detected if omitted)

        Returns:
            Amount in wrapper asset
        """
        pool_address = config.get('pool_address')
        twap_duration = int(config.get('twap_duration', 1800))  # Default 30 min

        if not pool_address:
            logger.error("Missing pool_address for uniswap_v3_twap conversion")
            return amount

        try:
            pool_cs = Web3.to_checksum_address(pool_address)
            pool = self.w3.eth.contract(address=pool_cs, abi=UNISWAP_V3_POOL_ABI)

            # Auto-detect token ordering if not specified
            if 'token0_is_from' in config:
                token0_is_from = config.get('token0_is_from')
                logger.debug(f"Using manual token0_is_from={token0_is_from}")
            else:
                token0_is_from = self._auto_detect_token_order(pool_address, from_asset, pool_type='v3')
                logger.info(f"Auto-detected token0_is_from={token0_is_from} for pool {pool_cs}")

            # Query TWAP via observe()
            seconds_agos = [twap_duration, 0]  # [past, now]
            observations = pool.functions.observe(seconds_agos).call()
            tick_cumulatives = observations[0]

            # Calculate time-weighted average tick
            tick_cumulative_delta = tick_cumulatives[1] - tick_cumulatives[0]
            time_delta = twap_duration
            avg_tick = tick_cumulative_delta // time_delta

            # Convert tick to price ratio
            # price = 1.0001 ^ tick (in token1/token0)
            price_ratio = 1.0001 ** avg_tick

            # Adjust direction based on token order
            if token0_is_from:
                # from_asset is token0, want token1/token0 ratio
                converted_amount = int(amount * price_ratio)
            else:
                # from_asset is token1, want token0/token1 ratio (inverse)
                converted_amount = int(amount / price_ratio)

            # Sanity check: price should be reasonable (0.5x to 2x)
            if converted_amount < amount // 2 or converted_amount > amount * 2:
                logger.warning(
                    f"Uniswap V3 TWAP conversion ratio {converted_amount/amount:.4f} outside [0.5, 2.0], "
                    f"using 1:1"
                )
                return amount

            logger.debug(
                f"Uniswap V3 TWAP conversion: {amount/1e18:.6f} → {converted_amount/1e18:.6f} "
                f"(ratio={converted_amount/amount:.6f}, tick={avg_tick})"
            )
            return converted_amount

        except Exception as e:
            logger.error(f"Error in Uniswap V3 TWAP conversion: {e}, using 1:1")
            return amount

    def _convert_via_uniswap_v2_twap(self, amount: int, from_asset: str, config: Dict) -> int:
        """
        Convert asset using Uniswap V2 cumulative price oracle.

        Note: Uniswap V2 TWAP requires storing previous cumulative price and timestamp.
        This implementation uses current reserves as an approximation.
        For production, implement proper TWAP tracking with state storage.

        Args:
            amount: Amount in from_asset
            from_asset: Source asset address
            config: Dict with:
                - pair_address: Required
                - token0_is_from: Optional (auto-detected if omitted)

        Returns:
            Amount in wrapper asset
        """
        pair_address = config.get('pair_address')

        if not pair_address:
            logger.error("Missing pair_address for uniswap_v2_twap conversion")
            return amount

        try:
            pair_cs = Web3.to_checksum_address(pair_address)
            pair = self.w3.eth.contract(address=pair_cs, abi=UNISWAP_V2_PAIR_ABI)

            # Auto-detect token ordering if not specified
            if 'token0_is_from' in config:
                token0_is_from = config.get('token0_is_from')
                logger.debug(f"Using manual token0_is_from={token0_is_from}")
            else:
                token0_is_from = self._auto_detect_token_order(pair_address, from_asset, pool_type='v2')
                logger.info(f"Auto-detected token0_is_from={token0_is_from} for pair {pair_cs}")

            # Get current reserves
            reserves = pair.functions.getReserves().call()
            reserve0, reserve1 = int(reserves[0]), int(reserves[1])

            if reserve0 == 0 or reserve1 == 0:
                logger.warning("Uniswap V2 pair has zero reserves, using 1:1")
                return amount

            # Calculate spot price ratio
            if token0_is_from:
                # from_asset is token0, price = reserve1/reserve0
                converted_amount = (amount * reserve1) // reserve0
            else:
                # from_asset is token1, price = reserve0/reserve1
                converted_amount = (amount * reserve0) // reserve1

            # Sanity check
            if converted_amount < amount // 2 or converted_amount > amount * 2:
                logger.warning(
                    f"Uniswap V2 conversion ratio {converted_amount/amount:.4f} outside [0.5, 2.0], "
                    f"using 1:1"
                )
                return amount

            logger.debug(
                f"Uniswap V2 conversion: {amount/1e18:.6f} → {converted_amount/1e18:.6f} "
                f"(reserves: {reserve0/1e18:.2f} / {reserve1/1e18:.2f})"
            )
            return converted_amount

        except Exception as e:
            logger.error(f"Error in Uniswap V2 conversion: {e}, using 1:1")
            return amount

    def _convert_via_chainlink(self, amount: int, from_asset: str, config: Dict) -> int:
        """
        Convert asset using Chainlink price feeds.

        Supports two modes:
        1. Two feeds: from_asset/USD and wrapper/USD, compute ratio
        2. Direct pair feed: from_asset/wrapper

        Args:
            amount: Amount in from_asset
            from_asset: Source asset address
            config: Dict with from_feed, to_feed (mode 1) or pair_feed (mode 2)

        Returns:
            Amount in wrapper asset
        """
        pair_feed = config.get('pair_feed')
        from_feed = config.get('from_feed')
        to_feed = config.get('to_feed')

        try:
            if pair_feed:
                # Mode 2: Direct pair feed (from_asset/wrapper)
                feed_cs = Web3.to_checksum_address(pair_feed)
                feed = self.w3.eth.contract(address=feed_cs, abi=CHAINLINK_FEED_ABI)

                round_data = feed.functions.latestRoundData().call()
                price = int(round_data[1])  # answer
                decimals = int(feed.functions.decimals().call())

                # Convert to 18 decimals
                price_18dec = (price * 10**18) // (10**decimals)
                converted_amount = (amount * price_18dec) // 10**18

            elif from_feed and to_feed:
                # Mode 1: Two feeds (from_asset/USD, wrapper/USD)
                from_feed_cs = Web3.to_checksum_address(from_feed)
                to_feed_cs = Web3.to_checksum_address(to_feed)

                from_oracle = self.w3.eth.contract(address=from_feed_cs, abi=CHAINLINK_FEED_ABI)
                to_oracle = self.w3.eth.contract(address=to_feed_cs, abi=CHAINLINK_FEED_ABI)

                from_data = from_oracle.functions.latestRoundData().call()
                to_data = to_oracle.functions.latestRoundData().call()

                from_price = int(from_data[1])
                to_price = int(to_data[1])
                from_decimals = int(from_oracle.functions.decimals().call())
                to_decimals = int(to_oracle.functions.decimals().call())

                # Normalize to 18 decimals
                from_price_18 = (from_price * 10**18) // (10**from_decimals)
                to_price_18 = (to_price * 10**18) // (10**to_decimals)

                # Ratio: from_price / to_price
                if to_price_18 == 0:
                    logger.error("Chainlink to_feed price is 0, using 1:1")
                    return amount

                converted_amount = (amount * from_price_18) // to_price_18

            else:
                logger.error("Chainlink conversion requires either pair_feed or (from_feed + to_feed)")
                return amount

            # Sanity check
            if converted_amount < amount // 2 or converted_amount > amount * 2:
                logger.warning(
                    f"Chainlink conversion ratio {converted_amount/amount:.4f} outside [0.5, 2.0], "
                    f"using 1:1"
                )
                return amount

            logger.debug(
                f"Chainlink conversion: {amount/1e18:.6f} → {converted_amount/1e18:.6f}"
            )
            return converted_amount

        except Exception as e:
            logger.error(f"Error in Chainlink conversion: {e}, using 1:1")
            return amount

    def _convert_via_fixed_ratio(self, amount: int, config: Dict) -> int:
        """
        Convert asset using fixed ratio (for testing or stable pairs).

        Args:
            amount: Amount in from_asset
            config: Dict with 'ratio' (18 decimals, e.g., 0.95e18 = 95%)

        Returns:
            Amount in wrapper asset
        """
        ratio = int(config.get('ratio', 10**18))  # Default 1:1

        if ratio <= 0:
            logger.error("Fixed ratio must be > 0, using 1:1")
            return amount

        converted_amount = (amount * ratio) // 10**18

        logger.debug(
            f"Fixed ratio conversion: {amount/1e18:.6f} → {converted_amount/1e18:.6f} "
            f"(ratio={ratio/1e18:.6f})"
        )
        return converted_amount

    # ============= End Generic Asset Conversion System =============

    def _get_maturity_timestamp(self, pt_address: str, market_address: str = None) -> int:
        """
        Get PT maturity timestamp from PT contract or Pendle market.

        Args:
            pt_address: PT token contract address
            market_address: Optional Pendle market address (fallback)

        Returns:
            Unix timestamp of maturity, or 0 if unable to determine
        """
        try:
            # Try PT contract first
            pt_cs = Web3.to_checksum_address(pt_address)
            pt_contract = self.w3.eth.contract(address=pt_cs, abi=PT_TOKEN_ABI)

            try:
                maturity = int(pt_contract.functions.expiry().call())
                if maturity > 0:
                    logger.debug(f"Maturity from PT contract: {maturity}")
                    return maturity
            except Exception as e:
                logger.debug(f"PT contract expiry() failed: {e}")

            # Fallback to market contract
            if market_address:
                market_cs = Web3.to_checksum_address(market_address)
                market_contract = self.w3.eth.contract(address=market_cs, abi=PENDLE_MARKET_ABI)
                maturity = int(market_contract.functions.expiry().call())
                logger.debug(f"Maturity from market contract: {maturity}")
                return maturity

        except Exception as e:
            logger.error(f"Failed to get maturity timestamp: {e}")

        return 0

    def _get_pt_price_linear_discount(self, extras: Dict) -> int:
        """
        Calculate PT price using linear discount model from PT_LINEAR_DISCOUNT_MODEL.md

        Formula:
        P(t,T) = previewRedeem(1) × [(1 - 1/(1 + r(T-t))) × t/T + 1/(1 + r(T-t))]

        Where:
        - previewRedeem(1): PT redemption rate at maturity
        - T: Maturity timestamp
        - t: Current timestamp
        - r: Non-compounded instantaneous rate

        The model assumes PT discount evolves linearly in time:
        - At start (t=0): PT priced at par value discounted by rate r
        - At maturity (t=T): PT priced at par value (redemption rate)
        - Linear interpolation between these two points

        Args:
            extras: Strategy configuration extras containing:
                - pt_khype_address: PT token contract address
                - rate: Non-compounded annual rate (default 0.05 = 5%)
                - felix_oracle_address: Auto-fetch rate from Felix oracle (overrides rate parameter)
                - maturity: Unix timestamp of PT maturity (optional if auto_detect_maturity=true)
                - auto_detect_maturity: Query maturity from contract (default false)
                - fallback_to_oracle: Use Pendle oracle if linear fails (default true)
                - pendle_market, pt_oracle: For fallback pricing
                - validate_against_felix: Compare calculated price with Felix oracle (default false)

        Returns:
            PT price ratio in 18 decimals (e.g., 0.95e18 = 95% of underlying)
        """
        pt_address = extras.get('pt_khype_address')

        # Auto-fetch rate from Felix oracle if configured
        felix_oracle_address = extras.get('felix_oracle_address')
        if felix_oracle_address:
            rate = self._fetch_rate_from_felix_oracle(felix_oracle_address)
            if rate <= 0:
                logger.warning("Failed to fetch rate from Felix oracle, using configured rate")
                rate = float(extras.get('rate', 0.05))
        else:
            rate = float(extras.get('rate', 0.05))  # Default 5% annual

        if not pt_address:
            logger.error("Missing pt_khype_address for linear discount pricing")
            return int(0.95 * 10**18)

        try:
            # 1. Get maturity timestamp
            maturity = extras.get('maturity')
            if not maturity or extras.get('auto_detect_maturity'):
                detected = self._get_maturity_timestamp(
                    pt_address,
                    extras.get('pendle_market')
                )
                if detected > 0:
                    maturity = detected
                    logger.info(f"Auto-detected maturity: {maturity}")

            if not maturity:
                logger.error("Missing maturity timestamp for linear discount model")
                if extras.get('fallback_to_oracle', True):
                    logger.info("Falling back to Pendle oracle pricing")
                    return self._get_pt_price(extras.get('pendle_market'), extras.get('pt_oracle'))
                return int(0.95 * 10**18)

            # 2. Get current time
            current_time = int(time.time())
            time_to_maturity = maturity - current_time

            # 3. Check if matured
            if time_to_maturity <= 0:
                logger.info(f"PT matured (maturity={maturity}, now={current_time}), using par value")
                # At maturity, PT = redemption rate (par value)
                pt_cs = Web3.to_checksum_address(pt_address)
                pt_contract = self.w3.eth.contract(address=pt_cs, abi=PT_TOKEN_ABI)
                preview_redeem = pt_contract.functions.previewRedeem(10**18).call()
                return int(preview_redeem)  # Already in 18 decimals

            # 4. Get redemption rate: previewRedeem(1)
            pt_cs = Web3.to_checksum_address(pt_address)
            pt_contract = self.w3.eth.contract(address=pt_cs, abi=PT_TOKEN_ABI)
            preview_redeem_raw = pt_contract.functions.previewRedeem(10**18).call()
            redemption_rate = float(preview_redeem_raw) / 10**18

            logger.debug(f"Linear discount: redemption_rate={redemption_rate:.6f}")

            # 5. Calculate discount factor: 1 / (1 + r × (T - t))
            # Convert time to years for rate calculation
            years_to_maturity = time_to_maturity / (365.25 * 24 * 3600)
            discount_factor = 1.0 / (1.0 + rate * years_to_maturity)

            # 6. Calculate time fraction: t / T
            time_fraction = float(current_time) / float(maturity)

            # 7. Apply linear discount formula
            # P(t,T) = previewRedeem(1) × [(1 - discount_factor) × time_fraction + discount_factor]
            # Rewritten: P = R × [(1 - β) × α + β] where R=redemption, α=t/T, β=discount_factor
            linear_component = (1.0 - discount_factor) * time_fraction
            price_ratio = redemption_rate * (linear_component + discount_factor)

            # 8. Convert to 18 decimal integer
            price_18dec = int(price_ratio * 10**18)

            # 9. Sanity checks
            min_price = int(0.5 * 10**18)
            max_price = int(1.05 * 10**18)

            if price_18dec < min_price or price_18dec > max_price:
                logger.warning(
                    f"Linear discount price {price_18dec/1e18:.4f} outside bounds [0.5, 1.05], "
                    f"redemption={redemption_rate:.4f}, years_to_maturity={years_to_maturity:.4f}"
                )
                # Optionally fallback to oracle
                if extras.get('fallback_to_oracle', True):
                    logger.info("Falling back to Pendle oracle pricing")
                    return self._get_pt_price(extras.get('pendle_market'), extras.get('pt_oracle'))
                # Or clamp
                price_18dec = max(min_price, min(price_18dec, max_price))

            logger.info(
                f"Linear discount pricing: "
                f"redemption={redemption_rate:.4f}, "
                f"time_to_maturity={time_to_maturity/86400:.1f}d, "
                f"years={years_to_maturity:.4f}, "
                f"rate={rate:.4f}, "
                f"discount_factor={discount_factor:.4f}, "
                f"time_fraction={time_fraction:.4f}, "
                f"price={price_ratio:.6f}"
            )

            # Optional: Validate against Felix oracle
            if extras.get('validate_against_felix', False) and felix_oracle_address:
                try:
                    felix_price_36dec = self._get_felix_oracle_price(felix_oracle_address)
                    felix_price = felix_price_36dec / 1e36
                    divergence = abs(price_ratio - felix_price) / felix_price * 100

                    logger.info(
                        f"Felix oracle validation: "
                        f"keeper_price={price_ratio:.6f}, "
                        f"felix_price={felix_price:.6f}, "
                        f"divergence={divergence:.2f}%"
                    )

                    if divergence > 5.0:  # Alert if >5% divergence
                        logger.warning(
                            f"⚠️  PRICE DIVERGENCE DETECTED: {divergence:.2f}% difference from Felix oracle! "
                            f"keeper={price_ratio:.6f}, felix={felix_price:.6f}"
                        )
                except Exception as e:
                    logger.debug(f"Could not validate against Felix oracle: {e}")

            return price_18dec

        except Exception as e:
            logger.error(f"Linear discount pricing failed: {e}", exc_info=True)
            # Fallback to oracle or default
            if extras.get('fallback_to_oracle', True):
                logger.info("Falling back to Pendle oracle pricing")
                return self._get_pt_price(extras.get('pendle_market'), extras.get('pt_oracle'))
            return int(0.95 * 10**18)

    # ------------- Uniswap V3 Helper Methods -------------

    def _scan_uniswap_v3_positions(
        self,
        position_manager: str,
        escrow: str,
        pool_address: str = None,
        min_liquidity: int = 0
    ) -> List[int]:
        """
        Scan for Uniswap V3 positions owned by escrow address.

        Uses ERC721Enumerable to find all NFT positions held by the escrow,
        then filters for positions with non-zero liquidity.

        Args:
            position_manager: NonFungiblePositionManager address
            escrow: Escrow address to scan
            pool_address: Optional - filter for specific pool
            min_liquidity: Minimum liquidity threshold (default 0)

        Returns:
            List of token IDs with active liquidity
        """
        try:
            pm_cs = Web3.to_checksum_address(position_manager)
            escrow_cs = Web3.to_checksum_address(escrow)
            pm_contract = self.w3.eth.contract(address=pm_cs, abi=UNISWAP_V3_POSITION_MANAGER_ABI)

            # Get number of positions owned by escrow
            balance = pm_contract.functions.balanceOf(escrow_cs).call()
            logger.debug(f"Escrow {escrow} owns {balance} Uniswap V3 positions")

            if balance == 0:
                logger.info(f"No Uniswap V3 positions found for escrow {escrow}")
                return []

            active_positions = []

            # Enumerate through all positions
            for index in range(balance):
                try:
                    # Get token ID at this index
                    token_id = pm_contract.functions.tokenOfOwnerByIndex(escrow_cs, index).call()
                    logger.debug(f"Found position #{token_id} at index {index}")

                    # Get position details
                    position = pm_contract.functions.positions(token_id).call()
                    liquidity = position[7]  # liquidity is 8th element (index 7)

                    # Filter by pool if specified
                    if pool_address:
                        token0 = position[2]
                        token1 = position[3]
                        fee = position[4]

                        # TODO: We could compute pool address from token0/token1/fee
                        # For now, just read pool from position (would need Factory contract)
                        # Skipping pool filter for now unless we add Factory ABI

                    # Filter by liquidity
                    if liquidity > min_liquidity:
                        active_positions.append(int(token_id))
                        logger.debug(
                            f"Position #{token_id}: liquidity={liquidity/1e18:.6f} "
                            f"(threshold={min_liquidity})"
                        )
                    else:
                        logger.debug(f"Position #{token_id}: skipping (liquidity={liquidity} < {min_liquidity})")

                except Exception as e:
                    logger.warning(f"Failed to read position at index {index}: {e}")
                    continue

            logger.info(
                f"Found {len(active_positions)} active positions for escrow {escrow}: {active_positions}"
            )
            return active_positions

        except Exception as e:
            logger.error(f"Failed to scan Uniswap V3 positions: {e}", exc_info=True)
            return []

    def _get_uniswap_v3_position(self, position_manager: str, token_id: int) -> Dict[str, Any]:
        """
        Read Uniswap V3 NFT position details from NonFungiblePositionManager.

        Args:
            position_manager: Address of Uniswap V3 NonFungiblePositionManager
            token_id: NFT token ID of the position

        Returns:
            Dictionary with position details:
            {
                'token0': address, 'token1': address,
                'fee': uint24, 'tickLower': int24, 'tickUpper': int24,
                'liquidity': uint128,
                'tokensOwed0': uint128, 'tokensOwed1': uint128
            }
        """
        try:
            pm_cs = Web3.to_checksum_address(position_manager)
            pm_contract = self.w3.eth.contract(address=pm_cs, abi=UNISWAP_V3_POSITION_MANAGER_ABI)

            # Call positions(tokenId)
            position = pm_contract.functions.positions(int(token_id)).call()

            # Unpack position tuple
            # (nonce, operator, token0, token1, fee, tickLower, tickUpper, liquidity,
            #  feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwed0, tokensOwed1)
            return {
                'nonce': position[0],
                'operator': position[1],
                'token0': position[2],
                'token1': position[3],
                'fee': position[4],
                'tickLower': position[5],
                'tickUpper': position[6],
                'liquidity': position[7],
                'feeGrowthInside0LastX128': position[8],
                'feeGrowthInside1LastX128': position[9],
                'tokensOwed0': position[10],
                'tokensOwed1': position[11],
            }

        except Exception as e:
            logger.error(f"Failed to read Uniswap V3 position {token_id}: {e}")
            raise

    def _get_pool_current_tick(self, pool_address: str) -> int:
        """
        Get current tick from Uniswap V3 pool's slot0.

        Args:
            pool_address: Uniswap V3 pool address

        Returns:
            Current tick (int24)
        """
        try:
            pool_cs = Web3.to_checksum_address(pool_address)
            pool_contract = self.w3.eth.contract(address=pool_cs, abi=UNISWAP_V3_POOL_ABI)

            slot0 = pool_contract.functions.slot0().call()
            # slot0 returns: (sqrtPriceX96, tick, observationIndex, observationCardinality, ...)
            current_tick = int(slot0[1])

            logger.debug(f"Pool {pool_address} current tick: {current_tick}")
            return current_tick

        except Exception as e:
            logger.error(f"Failed to get pool current tick: {e}")
            raise

    def _get_pool_twap_tick(self, pool_address: str, twap_seconds: int = 1800) -> int:
        """
        Get time-weighted average tick from Uniswap V3 pool.

        Args:
            pool_address: Uniswap V3 pool address
            twap_seconds: TWAP period in seconds (default 1800 = 30 minutes)

        Returns:
            TWAP tick (int24)
        """
        try:
            pool_cs = Web3.to_checksum_address(pool_address)
            pool_contract = self.w3.eth.contract(address=pool_cs, abi=UNISWAP_V3_POOL_ABI)

            # Query observations: [twap_seconds ago, now]
            seconds_agos = [twap_seconds, 0]
            observations = pool_contract.functions.observe(seconds_agos).call()

            # observations returns: (tickCumulatives[], secondsPerLiquidityCumulativeX128s[])
            tick_cumulatives = observations[0]

            # Calculate TWAP: (tickCumulative_now - tickCumulative_past) / time_elapsed
            tick_cumulative_delta = tick_cumulatives[1] - tick_cumulatives[0]
            twap_tick = tick_cumulative_delta // twap_seconds

            logger.debug(f"Pool {pool_address} TWAP tick ({twap_seconds}s): {twap_tick}")
            return int(twap_tick)

        except Exception as e:
            logger.warning(f"TWAP calculation failed, falling back to current tick: {e}")
            return self._get_pool_current_tick(pool_address)

    def _calculate_amounts_from_liquidity(
        self,
        liquidity: int,
        tick_lower: int,
        tick_upper: int,
        tick_current: int
    ) -> Tuple[int, int]:
        """
        Calculate token amounts from Uniswap V3 liquidity and tick range.

        Uses Uniswap V3 math formulas:
        - If current tick < tick_lower: all liquidity in token0
        - If current tick > tick_upper: all liquidity in token1
        - Otherwise: liquidity split between both tokens

        Args:
            liquidity: Position liquidity (uint128)
            tick_lower: Lower tick of position range
            tick_upper: Upper tick of position range
            tick_current: Current pool tick

        Returns:
            Tuple of (amount0, amount1) in token decimals
        """
        try:
            if liquidity == 0:
                return (0, 0)

            # Convert ticks to sqrt prices (Q96 format)
            sqrt_price_current = self._tick_to_sqrt_price_x96(tick_current)
            sqrt_price_lower = self._tick_to_sqrt_price_x96(tick_lower)
            sqrt_price_upper = self._tick_to_sqrt_price_x96(tick_upper)

            amount0 = 0
            amount1 = 0

            if tick_current < tick_lower:
                # All liquidity in token0
                # amount0 = liquidity * (sqrt(upper) - sqrt(lower)) / (sqrt(upper) * sqrt(lower))
                amount0 = (liquidity * (sqrt_price_upper - sqrt_price_lower)) // (2**96)
                amount0 = (amount0 * (2**96)) // sqrt_price_lower
                amount0 = (amount0 * (2**96)) // sqrt_price_upper

            elif tick_current >= tick_upper:
                # All liquidity in token1
                # amount1 = liquidity * (sqrt(upper) - sqrt(lower))
                amount1 = (liquidity * (sqrt_price_upper - sqrt_price_lower)) // (2**96)

            else:
                # Liquidity split between both tokens
                # amount0 = liquidity * (sqrt(upper) - sqrt(current)) / (sqrt(upper) * sqrt(current))
                if sqrt_price_current < sqrt_price_upper:
                    delta = sqrt_price_upper - sqrt_price_current
                    amount0 = (liquidity * delta) // (2**96)
                    amount0 = (amount0 * (2**96)) // sqrt_price_current
                    amount0 = (amount0 * (2**96)) // sqrt_price_upper

                # amount1 = liquidity * (sqrt(current) - sqrt(lower))
                if sqrt_price_current > sqrt_price_lower:
                    delta = sqrt_price_current - sqrt_price_lower
                    amount1 = (liquidity * delta) // (2**96)

            logger.debug(
                f"Calculated amounts: liquidity={liquidity}, "
                f"ticks=[{tick_lower}, {tick_current}, {tick_upper}], "
                f"amount0={amount0}, amount1={amount1}"
            )

            return (int(amount0), int(amount1))

        except Exception as e:
            logger.error(f"Failed to calculate amounts from liquidity: {e}")
            return (0, 0)

    def _tick_to_sqrt_price_x96(self, tick: int) -> int:
        """
        Convert tick to sqrtPriceX96 (Q96 fixed point format).

        Formula: sqrtPrice = 1.0001^(tick/2) * 2^96

        Args:
            tick: Pool tick (int24)

        Returns:
            sqrtPriceX96 (uint160)
        """
        # Use Python's decimal precision for accurate calculation
        import math

        # sqrtPrice = 1.0001^(tick/2)
        sqrt_price_float = math.pow(1.0001, tick / 2.0)

        # Convert to Q96 format (multiply by 2^96)
        sqrt_price_x96 = int(sqrt_price_float * (2**96))

        return sqrt_price_x96

    def _get_token_price_from_pool(
        self,
        pool_address: str,
        token_in: str,
        token_out: str,
        use_twap: bool = True,
        twap_seconds: int = 1800
    ) -> float:
        """
        Get token price from Uniswap V3 pool.

        Args:
            pool_address: Uniswap V3 pool address
            token_in: Input token address
            token_out: Output token address
            use_twap: Use TWAP instead of current price (default True)
            twap_seconds: TWAP period (default 1800s = 30min)

        Returns:
            Price as float (token_out per token_in)
        """
        try:
            pool_cs = Web3.to_checksum_address(pool_address)
            pool_contract = self.w3.eth.contract(address=pool_cs, abi=UNISWAP_V3_POOL_ABI)

            # Get pool's token0 and token1
            pool_token0 = pool_contract.functions.token0().call()
            pool_token1 = pool_contract.functions.token1().call()

            token_in_cs = Web3.to_checksum_address(token_in)
            token_out_cs = Web3.to_checksum_address(token_out)

            # Determine if we need to invert the price
            is_token0_in = (token_in_cs.lower() == pool_token0.lower())
            is_token1_out = (token_out_cs.lower() == pool_token1.lower())

            # Get tick (TWAP or current)
            if use_twap:
                tick = self._get_pool_twap_tick(pool_address, twap_seconds)
            else:
                tick = self._get_pool_current_tick(pool_address)

            # Convert tick to price: price = 1.0001^tick
            import math
            price = math.pow(1.0001, tick)

            # price represents token1/token0 ratio
            # If we want token0 in terms of token1: use price directly
            # If we want token1 in terms of token0: use 1/price

            if is_token0_in and is_token1_out:
                # token0 → token1: use price directly
                final_price = price
            elif not is_token0_in and not is_token1_out:
                # token1 → token0: invert price
                final_price = 1.0 / price if price > 0 else 0
            else:
                logger.error(
                    f"Token mismatch: pool has {pool_token0}/{pool_token1}, "
                    f"requested {token_in}/{token_out}"
                )
                return 0.0

            logger.debug(
                f"Pool price: {token_in} → {token_out} = {final_price:.6f} "
                f"(tick={tick}, {'TWAP' if use_twap else 'current'})"
            )

            return final_price

        except Exception as e:
            logger.error(f"Failed to get token price from pool: {e}")
            return 0.0

    def _get_token_price_from_chainlink(self, oracle_address: str) -> float:
        """
        Get token price from Chainlink oracle.

        Args:
            oracle_address: Chainlink price feed address

        Returns:
            Price as float (scaled by feed decimals)
        """
        try:
            oracle_cs = Web3.to_checksum_address(oracle_address)
            oracle_contract = self.w3.eth.contract(address=oracle_cs, abi=CHAINLINK_FEED_ABI)

            # Get decimals
            decimals = oracle_contract.functions.decimals().call()

            # Get latest price
            round_data = oracle_contract.functions.latestRoundData().call()
            # (roundId, answer, startedAt, updatedAt, answeredInRound)
            price_raw = round_data[1]
            updated_at = round_data[3]

            # Check staleness (< 24 hours old)
            if time.time() - updated_at > 86400:
                logger.warning(f"Chainlink oracle price is stale (updated {time.time() - updated_at}s ago)")

            price = float(price_raw) / (10 ** decimals)

            logger.debug(f"Chainlink oracle price: {price:.6f} (decimals={decimals})")
            return price

        except Exception as e:
            logger.error(f"Failed to get Chainlink oracle price: {e}")
            return 0.0

    # ------------- Valuation modes -------------

    def value_underlying_balance_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'underlying_balance'
        - Read escrow's balance of the underlying (rebasing) token
        - Convert to wrapper shares via convertToShares

        ⚠️  CRITICAL SECURITY: Only use when underlying ≠ wrapper!
            Valid example: stETH (underlying) → wstETH (wrapper)
            Invalid example: kHYPE (underlying) == kHYPE (wrapper) → DOUBLE COUNTING

            The on-chain getTotalValue() adds idle wrapper balance automatically.
            If you report the wrapper balance here, it gets counted twice.
        """
        # SECURITY FIX: Prevent double counting when underlying == wrapper
        # Use case-insensitive comparison to handle checksum variations
        underlying_normalized = s.underlying.lower()
        wrapper_normalized = self.wrapper_address.lower()

        if underlying_normalized == wrapper_normalized:
            raise RuntimeError(
                f"\n{'='*70}\n"
                f"⚠️  DOUBLE COUNTING VULNERABILITY DETECTED\n"
                f"{'='*70}\n"
                f"Strategy: {s.id_text}\n"
                f"Mode: underlying_balance\n"
                f"Problem: underlying ({s.underlying}) == wrapper ({self.wrapper_address})\n"
                f"\n"
                f"This causes the escrow's idle balance to be counted TWICE:\n"
                f"  1. Once in your strategy value (from balanceOf)\n"
                f"  2. Once in getTotalValue() idle assets (automatic)\n"
                f"\n"
                f"Solutions:\n"
                f"  A. Use 'pt_khype_loop' mode for leveraged PT strategies\n"
                f"  B. Use 'holdings' mode with explicit token list (excluding wrapper)\n"
                f"  C. Use different underlying token (e.g., stETH with wstETH wrapper)\n"
                f"\n"
                f"The 'underlying_balance' mode is designed for rebasing tokens where\n"
                f"underlying ≠ wrapper (e.g., stETH → wstETH conversions).\n"
                f"{'='*70}\n"
            )

        underlying_bal = self._read_underlying_balance(s.underlying, s.escrow)
        shares = self._convert_underlying_to_wrapper_shares(underlying_bal)
        logger.debug(f"[{s.id_text}] underlying_balance: underlying={underlying_bal}, shares={shares}")
        return shares

    def value_pt_khype_loop_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'pt_khype_loop'
        Production implementation for PT kHYPE leveraged loop strategy.

        UPDATED: Supports both Pendle oracle and linear discount pricing models

        Strategy structure:
        1. Escrow holds PT-kHYPE tokens (collateral)
        2. PT-kHYPE deposited in Felix lending as collateral
        3. kHYPE borrowed against PT-kHYPE collateral
        4. Loop repeats for leverage

        Valuation:
        - Collateral value = PT balance * PT price (Pendle oracle OR linear discount)
        - Debt value = borrowed kHYPE (from Felix lending)
        - Net value = collateral_value - debt_value
        - Convert to wrapper shares

        Pricing model configuration (via extras):
        - pricing_model: "pendle_oracle" (default) or "linear_discount"
        - For linear_discount: rate, maturity (or auto_detect_maturity)
        - For pendle_oracle: pendle_market, pt_oracle
        """
        try:
            extras = s.extras or {}

            # Validate required config
            pt_address = extras.get('pt_khype_address')
            felix_lending = extras.get('felix_lending')
            felix_market_id = extras.get('felix_market_id')

            if not pt_address:
                logger.warning(f"[{s.id_text}] Missing pt_khype_address")
                return 0

            # 1. Get PT-kHYPE balance held by escrow
            logger.debug(f"[{s.id_text}] Querying PT balance at {s.escrow}...")
            pt_token, pt_decimals = self._erc20(pt_address)
            pt_balance = int(pt_token.functions.balanceOf(s.escrow).call())
            logger.debug(f"[{s.id_text}] PT balance: {pt_balance / (10 ** pt_decimals):.6f} (decimals={pt_decimals})")

            if pt_balance == 0:
                logger.info(f"[{s.id_text}] No PT balance, returning 0")
                return 0

            # 2. Get PT price (model selection)
            pricing_model = extras.get('pricing_model', 'pendle_oracle').lower()

            logger.debug(f"[{s.id_text}] Using pricing model: {pricing_model}")

            if pricing_model == 'linear_discount':
                pt_price_ratio = self._get_pt_price_linear_discount(extras)
            elif pricing_model == 'felix_oracle_direct':
                # Read price directly from Felix oracle (scaled from 1e36 to 1e18)
                felix_oracle_address = extras.get('felix_oracle_address')
                if not felix_oracle_address:
                    logger.error(f"[{s.id_text}] felix_oracle_direct requires felix_oracle_address")
                    return 0
                price_36dec = self._get_felix_oracle_price(felix_oracle_address)
                pt_price_ratio = int((price_36dec * 10**18) // 10**36)  # Convert 36 decimals to 18
                logger.info(f"[{s.id_text}] Felix oracle direct: price={pt_price_ratio/1e18:.6f}")
            else:  # Default to Pendle oracle
                pendle_market = extras.get('pendle_market')
                pt_oracle = extras.get('pt_oracle')
                pt_price_ratio = self._get_pt_price(pendle_market, pt_oracle)

            logger.debug(f"[{s.id_text}] PT price: {pt_price_ratio / 1e18:.6f}")

            # 3. Calculate collateral value in underlying kHYPE
            # HIGH SECURITY FIX: Validate decimals to prevent conversion math errors
            # The calculation (pt_balance * pt_price_ratio) // 10**18 assumes pt_decimals == underlying_decimals
            # If this assumption is violated, value could be off by 10^12 or more
            underlying_decimals = extras.get('underlying_decimals', 18)
            if pt_decimals != underlying_decimals:
                logger.warning(
                    f"[{s.id_text}] PT decimals ({pt_decimals}) != underlying decimals ({underlying_decimals}). "
                    f"Applying decimal normalization."
                )
                # Normalize: convert pt_balance to underlying decimals scale
                # collateral = (pt_balance * pt_price_ratio * 10^underlying_decimals) / (10^18 * 10^pt_decimals)
                collateral_value_underlying = (pt_balance * pt_price_ratio * (10 ** underlying_decimals)) // (10**18 * (10 ** pt_decimals))
            else:
                # Standard case: pt_decimals == underlying_decimals
                collateral_value_underlying = (pt_balance * pt_price_ratio) // 10**18
            logger.debug(f"[{s.id_text}] Collateral value: {collateral_value_underlying / (10 ** underlying_decimals):.6f} kHYPE")

            # 4. Get debt from Felix lending
            logger.debug(f"[{s.id_text}] Querying Felix debt...")
            debt_underlying = self._get_felix_debt(felix_lending, felix_market_id, s.escrow)
            logger.debug(f"[{s.id_text}] Debt: {debt_underlying / 1e18:.6f} kHYPE")

            # 4b. MEDIUM FIX: Optionally include underlying dust and rewards
            # By default, pt_khype_loop only counts PT tokens. This misses:
            # - Uninvested underlying tokens (kHYPE dust in escrow)
            # - Claimed reward tokens (PENDLE, MORPHO, etc.)
            # Enable via: include_underlying_dust: true and/or rewards_tokens: [...]
            additional_assets = 0

            if extras.get('include_underlying_dust', False):
                # Add underlying token (kHYPE) balance that isn't in the loop
                underlying_address = s.underlying or extras.get('underlying_address')
                if underlying_address and underlying_address != self.wrapper_address:
                    try:
                        underlying_token, underlying_dec = self._erc20(underlying_address)
                        dust_balance = int(underlying_token.functions.balanceOf(s.escrow).call())
                        if dust_balance > 0:
                            # Normalize to underlying_decimals if different
                            if underlying_dec != underlying_decimals:
                                dust_balance = (dust_balance * (10 ** underlying_decimals)) // (10 ** underlying_dec)
                            additional_assets += dust_balance
                            logger.info(
                                f"[{s.id_text}] Including underlying dust: "
                                f"{dust_balance / (10 ** underlying_decimals):.6f}"
                            )
                    except Exception as e:
                        logger.warning(f"[{s.id_text}] Failed to read underlying dust: {e}")

            # Add reward token values if configured
            rewards_tokens = extras.get('rewards_tokens', [])
            for reward_config in rewards_tokens:
                try:
                    reward_addr = reward_config.get('address')
                    reward_price = reward_config.get('price_in_underlying', 0)  # Price of 1 reward in underlying
                    if reward_addr and reward_price > 0:
                        reward_token, reward_dec = self._erc20(reward_addr)
                        reward_balance = int(reward_token.functions.balanceOf(s.escrow).call())
                        if reward_balance > 0:
                            # value = balance * price (assume price is 18 decimals)
                            reward_value = (reward_balance * int(reward_price * 1e18)) // (10 ** reward_dec)
                            # Normalize to underlying_decimals
                            reward_value = (reward_value * (10 ** underlying_decimals)) // 10**18
                            additional_assets += reward_value
                            logger.info(
                                f"[{s.id_text}] Including reward token {reward_addr[:10]}...: "
                                f"balance={reward_balance / (10 ** reward_dec):.4f}, "
                                f"value={reward_value / (10 ** underlying_decimals):.6f} underlying"
                            )
                except Exception as e:
                    logger.warning(f"[{s.id_text}] Failed to read reward token {reward_config}: {e}")

            if additional_assets > 0:
                logger.info(
                    f"[{s.id_text}] Total additional assets (dust + rewards): "
                    f"{additional_assets / (10 ** underlying_decimals):.6f} underlying"
                )

            # 5. Calculate net value (protect against underwater positions)
            # Include additional assets in the calculation
            net_underlying = collateral_value_underlying + additional_assets - debt_underlying
            if net_underlying < 0:
                # MEDIUM SECURITY FIX: Use CRITICAL log level for underwater positions
                # This alerts operations teams that the strategy is effectively insolvent
                # Note: Reporting 0 hides bad debt. If vault has idle cash, that cash is
                # effectively covering this strategy's debt but will appear as "available"
                loss_amount = abs(net_underlying)
                logger.critical(
                    f"CRITICAL_ALERT: [{s.id_text}] UNDERWATER POSITION - STRATEGY INSOLVENT!\n"
                    f"  Collateral value: {collateral_value_underlying/1e18:.4f} kHYPE\n"
                    f"  Debt value:       {debt_underlying/1e18:.4f} kHYPE\n"
                    f"  Shortfall:        {loss_amount/1e18:.4f} kHYPE\n"
                    f"  ACTION REQUIRED: Review strategy health, consider liquidation or rebalancing."
                )
                # Return 0 for underwater positions to prevent bad debt reporting
                # Note: This masks the negative value - idle vault balance will appear higher
                return 0

            # 6. Convert to wrapper shares (vault's asset denomination)
            shares = self._convert_underlying_to_wrapper_shares(net_underlying)

            logger.info(
                f"[{s.id_text}] PT kHYPE Loop ({pricing_model}): "
                f"pt_balance={pt_balance/1e18:.6f} PT, "
                f"pt_price={pt_price_ratio/1e18:.6f}, "
                f"collateral={collateral_value_underlying/1e18:.4f} kHYPE, "
                f"debt={debt_underlying/1e18:.4f} kHYPE, "
                f"net={net_underlying/1e18:.4f} kHYPE, "
                f"shares={shares/1e18:.6f} wrapper"
            )
            return shares

        except Exception as e:
            logger.error(f"Error in pt_khype_loop valuation for {s.id_text}: {e}", exc_info=True)
            return 0

    def value_pt_loop_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'pt_loop'
        GENERIC implementation for ANY PT token leveraged loop strategy.

        This is the protocol-agnostic version that works with any PT token and any lending protocol.
        Use this for new strategies instead of the legacy pt_khype_loop_mode.

        Strategy structure:
        1. Escrow holds PT tokens (collateral)
        2. PT tokens deposited in a lending protocol as collateral
        3. Underlying asset borrowed against PT collateral
        4. Loop repeats for leverage

        Valuation:
        - Collateral value = PT balance × PT price
        - Debt value = borrowed amount (from lending protocol)
        - Net value = collateral_value - debt_value
        - Convert to wrapper shares

        Required configuration (via extras):
        - pt_address: PT token contract address (any PT, not just kHYPE)
        - pricing_model: "pendle_oracle" (default), "linear_discount", or "felix_oracle_direct"
        - lending_config: Dict containing lending protocol configuration
            {
                "protocol": "felix" | "morpho" | "aave_v3" | "compound_v3" | "none",
                ... protocol-specific parameters
            }

        Example configs:

        # Felix Lending
        {
            "mode": "pt_loop",
            "pt_address": "0x...",
            "pricing_model": "pendle_oracle",
            "pendle_market": "0x...",
            "pt_oracle": "0x...",
            "lending_config": {
                "protocol": "felix",
                "address": "0x...",
                "market_id": "0x..."
            }
        }

        # Morpho Blue
        {
            "mode": "pt_loop",
            "pt_address": "0x...",
            "pricing_model": "linear_discount",
            "rate": 0.05,
            "maturity": 1735689600,
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
            }
        }

        # Pure PT holding (no leverage)
        {
            "mode": "pt_loop",
            "pt_address": "0x...",
            "pricing_model": "pendle_oracle",
            "pendle_market": "0x...",
            "pt_oracle": "0x...",
            "lending_config": {
                "protocol": "none"
            }
        }

        Security features:
        - Underwater position protection (returns 0 if collateral < debt)
        - Double counting prevention (only active collateral, no idle balance)
        - Graceful error handling (returns 0 on failure, doesn't crash keeper)
        - Detailed logging for debugging
        """
        try:
            extras = s.extras or {}

            # ===== 1. Validate required configuration =====
            pt_address = extras.get('pt_address')
            if not pt_address:
                logger.warning(f"[{s.id_text}] Missing pt_address in pt_loop mode")
                return 0

            lending_config = extras.get('lending_config', {})
            if not isinstance(lending_config, dict):
                logger.warning(f"[{s.id_text}] Invalid lending_config (must be dict)")
                lending_config = {}

            # ===== 2. Get PT token balance held by escrow =====
            logger.debug(f"[{s.id_text}] Querying PT balance at {s.escrow}...")
            pt_token, pt_decimals = self._erc20(pt_address)
            pt_balance = int(pt_token.functions.balanceOf(s.escrow).call())
            logger.debug(f"[{s.id_text}] PT balance: {pt_balance / (10 ** pt_decimals):.6f} (decimals={pt_decimals})")

            if pt_balance == 0:
                logger.info(f"[{s.id_text}] No PT balance, returning 0")
                return 0

            # ===== 3. Get PT price (model selection) =====
            pricing_model = extras.get('pricing_model', 'pendle_oracle').lower()
            logger.debug(f"[{s.id_text}] Using pricing model: {pricing_model}")

            if pricing_model == 'linear_discount':
                pt_price_ratio = self._get_pt_price_linear_discount(extras)
            elif pricing_model == 'felix_oracle_direct':
                felix_oracle_address = extras.get('felix_oracle_address')
                if not felix_oracle_address:
                    logger.error(f"[{s.id_text}] felix_oracle_direct requires felix_oracle_address")
                    return 0
                price_36dec = self._get_felix_oracle_price(felix_oracle_address)
                pt_price_ratio = int((price_36dec * 10**18) // 10**36)  # Convert 36 decimals to 18
                logger.info(f"[{s.id_text}] Felix oracle direct: price={pt_price_ratio/1e18:.6f}")
            else:  # Default to Pendle oracle
                pendle_market = extras.get('pendle_market')
                pt_oracle = extras.get('pt_oracle')
                pt_price_ratio = self._get_pt_price(pendle_market, pt_oracle)

            logger.debug(f"[{s.id_text}] PT price: {pt_price_ratio / 1e18:.6f}")

            # ===== 4. Calculate collateral value in underlying asset =====
            # HIGH SECURITY FIX: Validate decimals to prevent conversion math errors
            # The calculation (pt_balance * pt_price_ratio) // 10**18 assumes pt_decimals == underlying_decimals
            # If this assumption is violated, value could be off by 10^12 or more
            underlying_decimals = extras.get('underlying_decimals', 18)
            if pt_decimals != underlying_decimals:
                logger.warning(
                    f"[{s.id_text}] PT decimals ({pt_decimals}) != underlying decimals ({underlying_decimals}). "
                    f"Applying decimal normalization."
                )
                # Normalize: convert pt_balance to underlying decimals scale
                # collateral = (pt_balance * pt_price_ratio * 10^underlying_decimals) / (10^18 * 10^pt_decimals)
                collateral_value_underlying = (pt_balance * pt_price_ratio * (10 ** underlying_decimals)) // (10**18 * (10 ** pt_decimals))
            else:
                # Standard case: pt_decimals == underlying_decimals
                collateral_value_underlying = (pt_balance * pt_price_ratio) // 10**18
            logger.debug(f"[{s.id_text}] Collateral value: {collateral_value_underlying / (10 ** underlying_decimals):.6f} underlying")

            # ===== 5. Get debt from lending protocol (generic dispatcher) =====
            logger.debug(f"[{s.id_text}] Querying lending debt via generic dispatcher...")
            debt_underlying = self._get_lending_debt(lending_config, s.escrow)
            logger.debug(f"[{s.id_text}] Debt: {debt_underlying / 1e18:.6f} underlying")

            # ===== 5b. MEDIUM FIX: Optionally include underlying dust and rewards =====
            # By default, pt_loop only counts PT tokens. This misses:
            # - Uninvested underlying tokens (dust in escrow)
            # - Claimed reward tokens (PENDLE, MORPHO, etc.)
            # Enable via: include_underlying_dust: true and/or rewards_tokens: [...]
            additional_assets = 0

            if extras.get('include_underlying_dust', False):
                # Add underlying token balance that isn't in the loop
                # Use pt_underlying_asset if specified, otherwise fall back to s.underlying
                underlying_address = extras.get('pt_underlying_asset') or s.underlying
                if underlying_address and underlying_address.lower() != self.wrapper_address.lower():
                    try:
                        underlying_token, underlying_dec = self._erc20(underlying_address)
                        dust_balance = int(underlying_token.functions.balanceOf(s.escrow).call())
                        if dust_balance > 0:
                            # Normalize to underlying_decimals if different
                            if underlying_dec != underlying_decimals:
                                dust_balance = (dust_balance * (10 ** underlying_decimals)) // (10 ** underlying_dec)
                            additional_assets += dust_balance
                            logger.info(
                                f"[{s.id_text}] Including underlying dust: "
                                f"{dust_balance / (10 ** underlying_decimals):.6f}"
                            )
                    except Exception as e:
                        logger.warning(f"[{s.id_text}] Failed to read underlying dust: {e}")

            # Add reward token values if configured
            rewards_tokens = extras.get('rewards_tokens', [])
            for reward_config in rewards_tokens:
                try:
                    reward_addr = reward_config.get('address')
                    reward_price = reward_config.get('price_in_underlying', 0)  # Price of 1 reward in underlying
                    if reward_addr and reward_price > 0:
                        reward_token, reward_dec = self._erc20(reward_addr)
                        reward_balance = int(reward_token.functions.balanceOf(s.escrow).call())
                        if reward_balance > 0:
                            # value = balance * price (assume price is 18 decimals)
                            reward_value = (reward_balance * int(reward_price * 1e18)) // (10 ** reward_dec)
                            # Normalize to underlying_decimals
                            reward_value = (reward_value * (10 ** underlying_decimals)) // 10**18
                            additional_assets += reward_value
                            logger.info(
                                f"[{s.id_text}] Including reward token {reward_addr[:10]}...: "
                                f"balance={reward_balance / (10 ** reward_dec):.4f}, "
                                f"value={reward_value / (10 ** underlying_decimals):.6f} underlying"
                            )
                except Exception as e:
                    logger.warning(f"[{s.id_text}] Failed to read reward token {reward_config}: {e}")

            if additional_assets > 0:
                logger.info(
                    f"[{s.id_text}] Total additional assets (dust + rewards): "
                    f"{additional_assets / (10 ** underlying_decimals):.6f} underlying"
                )

            # ===== 6. Calculate net value (protect against underwater positions) =====
            # Include additional assets in the calculation
            net_underlying = collateral_value_underlying + additional_assets - debt_underlying
            if net_underlying < 0:
                # MEDIUM SECURITY FIX: Use CRITICAL log level for underwater positions
                # This alerts operations teams that the strategy is effectively insolvent
                # Note: Reporting 0 hides bad debt. If vault has idle cash, that cash is
                # effectively covering this strategy's debt but will appear as "available"
                loss_amount = abs(net_underlying)
                logger.critical(
                    f"CRITICAL_ALERT: [{s.id_text}] UNDERWATER POSITION - STRATEGY INSOLVENT!\n"
                    f"  Collateral value: {collateral_value_underlying/(10**underlying_decimals):.4f} underlying\n"
                    f"  Debt value:       {debt_underlying/(10**underlying_decimals):.4f} underlying\n"
                    f"  Shortfall:        {loss_amount/(10**underlying_decimals):.4f} underlying\n"
                    f"  ACTION REQUIRED: Review strategy health, consider liquidation or rebalancing."
                )
                # Return 0 for underwater positions to prevent bad debt reporting
                # Note: This masks the negative value - idle vault balance will appear higher
                return 0

            # ===== 7. Convert PT underlying → wrapper (if different assets) =====
            # Example: kHYPE (PT underlying) → wHYPE (vault wrapper)
            pt_underlying_asset = extras.get('pt_underlying_asset')
            asset_conversion = extras.get('asset_conversion', {})

            # Auto-detect PT underlying if not specified
            if not pt_underlying_asset and asset_conversion:
                # Try to get underlying from PT contract (standard Pendle PT has SY property)
                logger.debug(f"[{s.id_text}] PT underlying not specified, checking conversion config")
                pt_underlying_asset = asset_conversion.get('from_asset')

            # Apply asset conversion if configured
            if pt_underlying_asset and asset_conversion:
                logger.debug(f"[{s.id_text}] Converting from PT underlying to wrapper...")
                net_in_wrapper = self._convert_asset_to_wrapper(
                    net_underlying,
                    pt_underlying_asset,
                    asset_conversion
                )
                logger.debug(
                    f"[{s.id_text}] Asset conversion: "
                    f"{net_underlying/1e18:.6f} PT underlying → {net_in_wrapper/1e18:.6f} wrapper "
                    f"(ratio={(net_in_wrapper/net_underlying if net_underlying > 0 else 1):.6f})"
                )
            else:
                # No conversion needed (PT underlying == wrapper, or 1:1 assumed)
                net_in_wrapper = net_underlying
                logger.debug(f"[{s.id_text}] No asset conversion needed (PT underlying == wrapper)")

            # ===== 8. Convert wrapper amount → wrapper shares =====
            shares = self._convert_underlying_to_wrapper_shares(net_in_wrapper)

            # ===== 9. Log comprehensive summary =====
            protocol_name = lending_config.get('protocol', 'none')
            conversion_method = asset_conversion.get('method', 'none') if asset_conversion else 'none'

            if conversion_method != 'none':
                # Multi-asset flow: PT underlying → wrapper → shares
                logger.info(
                    f"[{s.id_text}] PT Loop (multi-asset): "
                    f"pricing={pricing_model}, lending={protocol_name}, conversion={conversion_method} | "
                    f"PT={pt_balance/1e18:.6f} @ {pt_price_ratio/1e18:.6f} = "
                    f"{collateral_value_underlying/1e18:.4f} PT_underlying | "
                    f"debt={debt_underlying/1e18:.4f} PT_underlying | "
                    f"net_PT_underlying={net_underlying/1e18:.4f} → "
                    f"net_wrapper={net_in_wrapper/1e18:.4f} → "
                    f"shares={shares/1e18:.6f}"
                )
            else:
                # Single-asset flow: PT underlying == wrapper
                logger.info(
                    f"[{s.id_text}] PT Loop ({pricing_model} + {protocol_name}): "
                    f"pt_balance={pt_balance/1e18:.6f} PT, "
                    f"pt_price={pt_price_ratio/1e18:.6f}, "
                    f"collateral={collateral_value_underlying/1e18:.4f} underlying, "
                    f"debt={debt_underlying/1e18:.4f} underlying, "
                    f"net={net_underlying/1e18:.4f} underlying, "
                    f"shares={shares/1e18:.6f} wrapper"
                )
            return shares

        except Exception as e:
            logger.error(f"Error in pt_loop valuation for {s.id_text}: {e}", exc_info=True)
            return 0

    def value_holdings_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'holdings'
        - Sum up all holdings with their signs (+1 for assets, -1 for liabilities)
        - Supports multiple token types (erc20, pt, etc.)
        - Convert total underlying to wrapper shares

        ⚠️  CRITICAL SECURITY: Do NOT include wrapper asset in holdings array!
            The on-chain getTotalValue() adds idle wrapper balance automatically.
            Including it here causes double counting.

            Valid example:
            holdings: [
                {"token": "PT-kHYPE", "sign": 1},      # Collateral
                {"token": "borrowed-kHYPE", "sign": -1}  # Debt
            ]
            # Note: kHYPE wrapper is NOT listed - added automatically by getTotalValue()

            Invalid example (causes double counting):
            holdings: [
                {"token": "PT-kHYPE", "sign": 1},
                {"token": "kHYPE", "sign": 1},  # ❌ WRONG - this is the wrapper!
                {"token": "borrowed-kHYPE", "sign": -1}
            ]
        """
        try:
            holdings = s.extras.get('holdings', []) if s.extras else []
            total_underlying = 0

            # SECURITY FIX: Validate holdings don't include wrapper asset
            wrapper_normalized = self.wrapper_address.lower()

            for holding in holdings:
                holding_type = holding.get('type', 'erc20')
                token_addr = holding.get('token')
                sign = holding.get('sign', 1)

                if not token_addr:
                    continue

                # Normalize token address for comparison
                token_normalized = Web3.to_checksum_address(token_addr).lower()

                # Check if this holding is the wrapper asset
                if token_normalized == wrapper_normalized:
                    raise RuntimeError(
                        f"\n{'='*70}\n"
                        f"⚠️  DOUBLE COUNTING VULNERABILITY DETECTED\n"
                        f"{'='*70}\n"
                        f"Strategy: {s.id_text}\n"
                        f"Mode: holdings\n"
                        f"Problem: Holdings array includes wrapper asset\n"
                        f"  Wrapper: {self.wrapper_address}\n"
                        f"  Holding: {token_addr} (sign={sign})\n"
                        f"\n"
                        f"This causes the escrow's idle balance to be counted TWICE:\n"
                        f"  1. Once in your holdings calculation (from balanceOf)\n"
                        f"  2. Once in getTotalValue() idle assets (automatic)\n"
                        f"\n"
                        f"Solution: REMOVE wrapper asset from holdings array\n"
                        f"  getTotalValue() automatically adds: IERC20(asset).balanceOf(escrow)\n"
                        f"  You should only list tokens deployed in external protocols.\n"
                        f"\n"
                        f"Correct holdings configuration:\n"
                        f"  holdings: [\n"
                        f"    {{\"token\": \"PT-Token\", \"sign\": 1}},    # Collateral in protocol\n"
                        f"    {{\"token\": \"Borrowed\", \"sign\": -1}}    # Debt in protocol\n"
                        f"  ]\n"
                        f"  # Idle wrapper balance is added automatically - don't list it!\n"
                        f"{'='*70}\n"
                    )

                # Get token balance
                token, _ = self._erc20(token_addr)
                balance = int(token.functions.balanceOf(s.escrow).call())

                # Apply sign (1 for assets, -1 for liabilities)
                total_underlying += sign * balance

                logger.debug(f"[{s.id_text}] holding: token={token_addr}, balance={balance}, sign={sign}")

            # Ensure non-negative
            if total_underlying < 0:
                logger.warning(
                    f"[{s.id_text}] Negative holdings total ({total_underlying}), "
                    f"clamping to 0 (strategy may be underwater)"
                )
                total_underlying = 0

            # Convert to wrapper shares
            shares = self._convert_underlying_to_wrapper_shares(total_underlying)
            logger.debug(f"[{s.id_text}] holdings total: underlying={total_underlying}, shares={shares}")
            return shares

        except RuntimeError:
            # Re-raise validation errors (don't catch our own security checks)
            raise
        except Exception as e:
            logger.error(f"Error in holdings valuation: {e}", exc_info=True)
            return 0

    def value_uniswap_v3_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'uniswap_v3'
        Value a Uniswap V3 LP position and convert to base asset (wrapper shares).

        For a wHYPE-wstHYPE LP position valued in wHYPE:
        1. Extract configuration (position_manager, pool_address, base_asset, etc.)
        2. Auto-detect token_id if not provided (scans escrow for NFT positions)
        3. Validate ownership (escrow owns the NFT)
        4. Read position details from NonFungiblePositionManager
        5. Get current tick from pool (TWAP or spot)
        6. Calculate token0/token1 amounts from liquidity + tick range
        7. Include uncollected fees (tokensOwed0, tokensOwed1)
        8. Convert non-base tokens to base asset (wstHYPE → wHYPE)
        9. Convert to wrapper shares

        ⚠️  CRITICAL SECURITY: Only value LP position (not idle wrapper balance)
            The on-chain getTotalValue() adds idle wrapper balance automatically.

        Configuration (extras):
        - position_manager: NonFungiblePositionManager address (default: Hyperswap)
        - token_id: NFT token ID (optional - will auto-scan if not provided)
        - pool_address: Uniswap V3 pool address
        - base_asset: Asset to value everything in (usually wrapper asset)
        - use_pool_twap: Use pool TWAP for pricing (default True)
        - twap_seconds: TWAP period in seconds (default 1800 = 30min)
        - chainlink_oracle: Optional Chainlink oracle for non-base token pricing
        - validate_ownership: Verify escrow owns the NFT (default True)
        - auto_scan_positions: Auto-scan for positions if token_id not provided (default True)
        """
        try:
            extras = s.extras or {}

            # 1. Extract configuration
            position_manager = extras.get(
                'position_manager',
                '0x6eDA206207c09e5428F281761DdC0D300851fBC8'  # Mainnet NFT Position Manager, Hyperswap
            )
            token_id = extras.get('token_id')
            pool_address = extras.get('pool_address')
            base_asset = extras.get('base_asset', self.wrapper_address)
            use_twap = extras.get('use_pool_twap', True)
            twap_seconds = extras.get('twap_seconds', 1800)
            chainlink_oracle = extras.get('chainlink_oracle')
            validate_ownership = extras.get('validate_ownership', True)
            auto_scan = extras.get('auto_scan_positions', True)

            # 2. Auto-detect token_id if not provided
            if not token_id and auto_scan:
                logger.info(f"[{s.id_text}] No token_id provided, scanning escrow for positions...")

                # Scan for positions owned by escrow
                positions = self._scan_uniswap_v3_positions(
                    position_manager=position_manager,
                    escrow=s.escrow,
                    pool_address=pool_address,
                    min_liquidity=0  # Include all positions with any liquidity
                )

                if len(positions) == 0:
                    logger.warning(f"[{s.id_text}] No Uniswap V3 positions found in escrow")
                    return 0
                elif len(positions) == 1:
                    token_id = positions[0]
                    logger.info(f"[{s.id_text}] Auto-detected position: #{token_id}")
                else:
                    logger.error(
                        f"[{s.id_text}] Multiple positions found ({len(positions)}): {positions}. "
                        f"Please specify token_id explicitly in config"
                    )
                    return 0

            # Validate token_id is set
            if not token_id:
                logger.error(f"[{s.id_text}] Missing token_id and auto_scan is disabled")
                return 0

            if not pool_address:
                logger.error(f"[{s.id_text}] Missing pool_address for Uniswap V3 position")
                return 0

            logger.debug(f"[{s.id_text}] Valuing Uniswap V3 position #{token_id}")

            # 3. Validate ownership (optional but recommended)
            if validate_ownership:
                try:
                    pm_cs = Web3.to_checksum_address(position_manager)
                    pm_contract = self.w3.eth.contract(address=pm_cs, abi=UNISWAP_V3_POSITION_MANAGER_ABI)
                    owner = pm_contract.functions.ownerOf(int(token_id)).call()

                    if owner.lower() != s.escrow.lower():
                        logger.error(
                            f"[{s.id_text}] Ownership mismatch: "
                            f"position #{token_id} owned by {owner}, expected {s.escrow}"
                        )
                        return 0
                    logger.debug(f"[{s.id_text}] Ownership verified: escrow owns position #{token_id}")
                except Exception as e:
                    logger.warning(f"[{s.id_text}] Could not validate ownership: {e}")

            # 4. Read position details
            position = self._get_uniswap_v3_position(position_manager, token_id)

            liquidity = position['liquidity']
            if liquidity == 0:
                logger.info(f"[{s.id_text}] Position #{token_id} has zero liquidity")
                return 0

            token0 = position['token0']
            token1 = position['token1']
            tick_lower = position['tickLower']
            tick_upper = position['tickUpper']
            tokens_owed0 = position['tokensOwed0']
            tokens_owed1 = position['tokensOwed1']

            logger.debug(
                f"[{s.id_text}] Position: token0={token0}, token1={token1}, "
                f"liquidity={liquidity}, ticks=[{tick_lower}, {tick_upper}]"
            )

            # 5. Get current tick from pool
            if use_twap:
                tick_current = self._get_pool_twap_tick(pool_address, twap_seconds)
                logger.debug(f"[{s.id_text}] Using TWAP tick: {tick_current} ({twap_seconds}s)")
            else:
                tick_current = self._get_pool_current_tick(pool_address)
                logger.debug(f"[{s.id_text}] Using current tick: {tick_current}")

            # 6. Calculate token amounts from liquidity
            amount0, amount1 = self._calculate_amounts_from_liquidity(
                liquidity, tick_lower, tick_upper, tick_current
            )

            # 7. Add uncollected fees
            total_amount0 = amount0 + tokens_owed0
            total_amount1 = amount1 + tokens_owed1

            logger.debug(
                f"[{s.id_text}] Token amounts: "
                f"token0={total_amount0/1e18:.6f} (principal={amount0/1e18:.6f}, fees={tokens_owed0/1e18:.6f}), "
                f"token1={total_amount1/1e18:.6f} (principal={amount1/1e18:.6f}, fees={tokens_owed1/1e18:.6f})"
            )

            # 8. Convert everything to base asset
            base_asset_cs = Web3.to_checksum_address(base_asset)
            token0_cs = Web3.to_checksum_address(token0)
            token1_cs = Web3.to_checksum_address(token1)

            # Determine which token is the base asset
            token0_is_base = (token0_cs.lower() == base_asset_cs.lower())
            token1_is_base = (token1_cs.lower() == base_asset_cs.lower())

            if not token0_is_base and not token1_is_base:
                logger.error(
                    f"[{s.id_text}] Neither token0 nor token1 matches base asset: "
                    f"token0={token0}, token1={token1}, base={base_asset}"
                )
                return 0

            # Convert to base asset value
            total_value_in_base = 0

            if token0_is_base:
                # token0 is base: add directly
                total_value_in_base += total_amount0
                logger.debug(f"[{s.id_text}] Token0 is base asset, added {total_amount0/1e18:.6f}")

                # Convert token1 to base
                if total_amount1 > 0:
                    if chainlink_oracle:
                        # Use Chainlink oracle for pricing
                        price = self._get_token_price_from_chainlink(chainlink_oracle)
                        token1_value_in_base = int(total_amount1 * price)
                        logger.debug(
                            f"[{s.id_text}] Token1 → base (Chainlink): "
                            f"{total_amount1/1e18:.6f} * {price:.6f} = {token1_value_in_base/1e18:.6f}"
                        )
                    else:
                        # Use pool TWAP for pricing
                        price = self._get_token_price_from_pool(
                            pool_address, token1, token0, use_twap, twap_seconds
                        )
                        token1_value_in_base = int(total_amount1 * price)
                        logger.debug(
                            f"[{s.id_text}] Token1 → base (pool): "
                            f"{total_amount1/1e18:.6f} * {price:.6f} = {token1_value_in_base/1e18:.6f}"
                        )
                    total_value_in_base += token1_value_in_base

            elif token1_is_base:
                # token1 is base: add directly
                total_value_in_base += total_amount1
                logger.debug(f"[{s.id_text}] Token1 is base asset, added {total_amount1/1e18:.6f}")

                # Convert token0 to base
                if total_amount0 > 0:
                    if chainlink_oracle:
                        # Use Chainlink oracle for pricing
                        price = self._get_token_price_from_chainlink(chainlink_oracle)
                        token0_value_in_base = int(total_amount0 * price)
                        logger.debug(
                            f"[{s.id_text}] Token0 → base (Chainlink): "
                            f"{total_amount0/1e18:.6f} * {price:.6f} = {token0_value_in_base/1e18:.6f}"
                        )
                    else:
                        # Use pool TWAP for pricing
                        price = self._get_token_price_from_pool(
                            pool_address, token0, token1, use_twap, twap_seconds
                        )
                        token0_value_in_base = int(total_amount0 * price)
                        logger.debug(
                            f"[{s.id_text}] Token0 → base (pool): "
                            f"{total_amount0/1e18:.6f} * {price:.6f} = {token0_value_in_base/1e18:.6f}"
                        )
                    total_value_in_base += token0_value_in_base

            # Ensure non-negative
            if total_value_in_base < 0:
                logger.warning(f"[{s.id_text}] Negative value calculated, clamping to 0")
                total_value_in_base = 0

            # 9. Convert to wrapper shares
            shares = self._convert_underlying_to_wrapper_shares(total_value_in_base)

            logger.info(
                f"[{s.id_text}] Uniswap V3 position #{token_id}: "
                f"liquidity={liquidity}, "
                f"token0_amount={total_amount0/1e18:.6f}, "
                f"token1_amount={total_amount1/1e18:.6f}, "
                f"total_value={total_value_in_base/1e18:.6f} base asset, "
                f"shares={shares/1e18:.6f} wrapper"
            )

            return shares

        except Exception as e:
            logger.error(f"Error in uniswap_v3 valuation for {s.id_text}: {e}", exc_info=True)
            return 0

    def value_strategy_in_shares(self, s: StrategyConfig) -> int:
        """
        Route strategy valuation to the appropriate mode handler.

        Supported modes:
        - underlying_balance: Read rebasing token balance and convert to wrapper shares
        - pt_khype_loop: PT kHYPE leveraged loop strategy (legacy, Felix-specific)
        - pt_loop: Generic PT loop strategy for any PT token and lending protocol
        - holdings: Sum multiple token holdings with signs
        - uniswap_v3: Uniswap V3 LP position valuation
        - options_otoken: Options valuation using Black-Scholes
        """
        mode = s.mode.lower()
        if mode == "underlying_balance":
            return self.value_underlying_balance_mode(s)
        elif mode == "pt_khype_loop":
            return self.value_pt_khype_loop_mode(s)
        elif mode == "pt_loop":
            return self.value_pt_loop_mode(s)
        elif mode == "holdings":
            return self.value_holdings_mode(s)
        elif mode == "uniswap_v3":
            return self.value_uniswap_v3_mode(s)
        elif mode == "options_otoken":
            return self.value_options_otoken_mode(s)
        else:
            raise RuntimeError(f"Unsupported strategy mode: {s.mode}")

    # ------------- Signing and submitting -------------

    def _next_nonce(self, strategy_id: bytes) -> int:
        """Fetch report and return nonce+1."""
        try:
            report = self.valuer.functions.getReport(strategy_id).call()
            # report struct: (value, timestamp, confidence, nonce, isPush, lastUpdater)
            return int(report[3]) + 1
        except Exception as e:
            logger.warning(f"getReport failed for {strategy_id.hex()}: {e}, using nonce=1")
            return 1

    def _sign_update(self, strategy_id: bytes, value: int, confidence: int, nonce: int, expiry: int) -> bytes:
        """
        Match UniversalValuerOffchain._verifySignatures:
        keccak256(abi.encode(strategyId, value, confidence, nonce, expiry, chainid, valuerAddress))
        Then EIP-191 prefix and sign.
        """
        payload = abi_encode(
            ['bytes32', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'address'],
            [strategy_id, value, confidence, nonce, expiry, int(self.chain_id), self.valuer_address]
        )
        hashed = Web3.keccak(payload)
        msg = encode_defunct(primitive=hashed)
        signed = Account.sign_message(msg, private_key=self.account.key)
        return signed.signature  # bytes

    def _build_tx_params(self, gas_limit: Optional[int] = None) -> Dict[str, Any]:
        """Build EIP-1559 gas params with sane defaults."""
        max_fee = self.w3.to_wei(self.max_fee_gwei, "gwei")
        max_prio = self.w3.to_wei(self.max_priority_gwei, "gwei")
        nonce = self.w3.eth.get_transaction_count(self.account.address)
        return {
            "chainId": self.chain_id,
            "from": self.account.address,
            "nonce": nonce,
            "gas": gas_limit or self.gas_limit,
            "maxFeePerGas": max_fee,
            "maxPriorityFeePerGas": max_prio,
        }

    def _refresh_adapter_cache(self, s: StrategyConfig) -> bool:
        """
        SECURITY FIX: Refresh adapter cached valuation after valuer update.
        
        This prevents cache poisoning by ensuring the adapter cache is updated
        AFTER the valuer has fresh keeper-validated data, not in the same
        transaction as state changes.
        
        Args:
            s: Strategy configuration containing adapter address
            
        Returns:
            True if cache refresh succeeded, False otherwise
        """
        if not self.enable_cache_refresh:
            logger.debug(f"[{s.id_text}] Cache refresh disabled in config")
            return True
            
        if not s.adapter:
            logger.debug(f"[{s.id_text}] No adapter address configured, skipping cache refresh")
            return True
            
        try:
            adapter = self._adapter(s.adapter)
            
            # Check current cache state before refresh
            try:
                cache_info = adapter.functions.getCachedValuation().call()
                old_value = cache_info[0]
                old_timestamp = cache_info[1]
                is_stale = cache_info[2]
                logger.debug(
                    f"[{s.id_text}] Cache before refresh: "
                    f"value={old_value/1e18:.6f}, "
                    f"timestamp={old_timestamp}, "
                    f"stale={is_stale}"
                )
            except Exception as e:
                logger.debug(f"[{s.id_text}] Could not read cache state: {e}")
            
            # Build and send refreshCachedValuation transaction
            tx_params = self._build_tx_params(gas_limit=self.cache_refresh_gas_limit)
            func = adapter.functions.refreshCachedValuation()
            tx = func.build_transaction(tx_params)
            signed = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed.rawTransaction)
            
            # Wait for receipt
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
            
            if receipt['status'] == 1:
                gas_used = int(receipt.get('gasUsed', 0))
                
                # Verify cache was updated
                try:
                    new_cache_info = adapter.functions.getCachedValuation().call()
                    new_value = new_cache_info[0]
                    new_timestamp = new_cache_info[1]
                    new_is_stale = new_cache_info[2]
                    
                    logger.info(
                        f"✓ Cache refreshed: {s.id_text}, "
                        f"value={new_value/1e18:.6f}, "
                        f"timestamp={new_timestamp}, "
                        f"stale={new_is_stale}, "
                        f"gas={gas_used:,}, "
                        f"tx={tx_hash.hex()}"
                    )
                except Exception as e:
                    logger.warning(f"[{s.id_text}] Could not verify cache update: {e}")
                    
                return True
            else:
                logger.warning(
                    f"[{s.id_text}] Cache refresh transaction reverted: {receipt}"
                )
                return False
                
        except Exception as e:
            error_msg = str(e)
            
            # Check if error is expected/acceptable
            acceptable_errors = [
                "Valuation too low",
                "Valuation too high",
                "Valuer call failed"
            ]
            
            is_acceptable = any(err in error_msg for err in acceptable_errors)
            
            if is_acceptable:
                logger.warning(
                    f"[{s.id_text}] Cache refresh rejected (expected): {error_msg}. "
                    f"This is normal if valuer data hasn't been updated yet or sanity checks fail."
                )
                return True  # Don't treat as fatal error
            else:
                logger.error(
                    f"[{s.id_text}] Cache refresh failed: {e}", 
                    exc_info=True
                )
                return False

    def push_strategy_value(self, s: StrategyConfig, retry_count: int = 0) -> Optional[str]:
        """
        Compute value in shares, sign, and submit updateValue with retry logic.

        Args:
            s: Strategy configuration
            retry_count: Current retry attempt (for internal use)

        Returns:
            Transaction hash if successful, None otherwise
        """
        max_retries = 3
        retry_delay = 5  # seconds

        # Record attempt
        if retry_count == 0:
            self.metrics.record_attempt()

        try:
            strategy_id = self.to_strategy_id(s.id_text)

            # Compute strategy value
            value_shares = self.value_strategy_in_shares(s)

            # Skip update if value is 0 and previous value was also 0
            try:
                report = self.valuer.functions.getReport(strategy_id).call()
                prev_value = int(report[0])
                if value_shares == 0 and prev_value == 0:
                    logger.debug(f"[{s.id_text}] Skipping update, value unchanged at 0")
                    return None
            except Exception:
                pass  # First time update or error reading report

            # Confidence
            conf = int(s.confidence)

            # Nonce and expiry (TTL)
            nonce = self._next_nonce(strategy_id)
            expiry = int(time.time()) + self.ttl_seconds

            # Sign update
            sig = self._sign_update(strategy_id, value_shares, conf, nonce, expiry)

            # Build and send transaction
            tx_params = self._build_tx_params()
            func = self.valuer.functions.updateValue(strategy_id, value_shares, conf, nonce, expiry, [sig])
            tx = func.build_transaction(tx_params)
            signed = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed.rawTransaction)

            # Wait for receipt to confirm
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

            if receipt['status'] == 1:
                h = tx_hash.hex()
                gas_used = int(receipt.get('gasUsed', 0))

                # Record success
                self.metrics.record_success(s.id_text, gas_used)

                logger.info(
                    f"✓ Update successful: {s.id_text}, "
                    f"value={value_shares/1e18:.6f} shares, "
                    f"nonce={nonce}, conf={conf}%, gas={gas_used:,}, tx={h}"
                )
                
                # SECURITY FIX: Refresh adapter cache after successful valuer update
                # This prevents cache poisoning by ensuring cache contains fresh keeper-validated data
                self._refresh_adapter_cache(s)
                
                return h
            else:
                # Record failure
                self.metrics.record_failure(s.id_text, "tx_reverted")
                logger.error(f"Transaction failed: {s.id_text}, receipt={receipt}")
                return None

        except ValueError as e:
            # Handle RPC errors with retry
            error_msg = str(e)
            logger.warning(f"RPC error for {s.id_text}: {error_msg}")

            # Check if error is retryable
            retryable_errors = [
                "nonce too low",
                "replacement transaction underpriced",
                "already known",
                "timeout",
                "connection"
            ]

            is_retryable = any(err in error_msg.lower() for err in retryable_errors)

            if is_retryable and retry_count < max_retries:
                logger.info(f"Retrying {s.id_text} (attempt {retry_count + 1}/{max_retries})")
                time.sleep(retry_delay * (retry_count + 1))  # Exponential backoff
                return self.push_strategy_value(s, retry_count + 1)

            # Record failure
            error_type = "rpc_error"
            for err in retryable_errors:
                if err in error_msg.lower():
                    error_type = err.replace(" ", "_")
                    break
            self.metrics.record_failure(s.id_text, error_type)

            logger.error(f"push_strategy_value failed for {s.id_text}: {e}", exc_info=True)
            return None

        except Exception as e:
            # Record failure
            self.metrics.record_failure(s.id_text, type(e).__name__)
            logger.error(f"push_strategy_value failed for {s.id_text}: {e}", exc_info=True)
            return None

    # ------------- Run loops -------------

    def run_once(self):
        """Execute one update cycle for all strategies"""
        for s in self.strategies:
            self.push_strategy_value(s)

        # Increment cycle count and log summary periodically
        self.update_cycle_count += 1
        if self.update_cycle_count % self.summary_interval == 0:
            self.metrics.log_summary()

    def run_forever(self):
        """Run keeper loop indefinitely with monitoring"""
        logger.info("=" * 60)
        logger.info("Starting OffchainValuationKeeper")
        logger.info("=" * 60)
        logger.info(f"RPC: {self.config['rpc_url']}")
        logger.info(f"Valuer: {self.valuer_address}")
        logger.info(f"Wrapper: {self.wrapper_address}")
        logger.info(f"Signer: {self.account.address}")
        logger.info(f"Strategies: {len(self.strategies)}")
        for s in self.strategies:
            logger.info(f"  - {s.id_text} ({s.mode})")
        logger.info(f"Update interval: {self.update_check_interval}s")
        logger.info("=" * 60)

        while True:
            start = time.time()
            try:
                self.run_once()
            except KeyboardInterrupt:
                logger.info("\nShutdown requested by user")
                self.metrics.log_summary()
                break
            except Exception as e:
                logger.error(f"run_once error: {e}", exc_info=True)
                self.metrics.record_failure("system", "run_once_error")

            # Sleep the remainder of the interval
            elapsed = time.time() - start
            sleep_s = max(1.0, self.update_check_interval - elapsed)
            logger.debug(f"Cycle completed in {elapsed:.2f}s, sleeping {sleep_s:.2f}s")
            time.sleep(sleep_s)


def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else 'keeper_config.json'
    keeper = OffchainValuationKeeper(config_path)
    mode = keeper.config.get("mode", "loop").lower()
    if mode == "once":
        keeper.run_once()
    else:
        keeper.run_forever()


if __name__ == "__main__":
    main()
