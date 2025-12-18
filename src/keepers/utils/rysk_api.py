"""
Rysk V12 API integration for options vault valuation.

API Endpoints:
- Maker Positions: https://v12.rysk.finance/api/maker/positions?address=0x...
- Inventory (IV data): https://v12.rysk.finance/api/inventory

Features:
- Position caching with configurable TTL to reduce API calls
- Inventory caching for IV data
"""
import logging
import requests
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional, Any, Tuple

logger = logging.getLogger("OffchainValuationKeeper.rysk")

# Default Rysk API base URL (mainnet)
DEFAULT_RYSK_API_BASE = "https://v12.rysk.finance"

# Default cache TTL in seconds
DEFAULT_POSITION_CACHE_TTL = 30  # 30 seconds
DEFAULT_INVENTORY_CACHE_TTL = 60  # 60 seconds


@dataclass
class CacheEntry:
    """Cache entry with timestamp and data."""
    data: Any
    timestamp: float
    ttl: float

    def is_valid(self) -> bool:
        """Check if cache entry is still valid."""
        return (time.time() - self.timestamp) < self.ttl


class RyskAPICache:
    """
    In-memory cache for Rysk API responses.

    Reduces API calls by caching:
    - Positions per wallet address
    - Inventory IV data
    """

    def __init__(
        self,
        position_ttl: float = DEFAULT_POSITION_CACHE_TTL,
        inventory_ttl: float = DEFAULT_INVENTORY_CACHE_TTL
    ):
        self.position_ttl = position_ttl
        self.inventory_ttl = inventory_ttl
        self._positions_cache: Dict[str, CacheEntry] = {}
        self._inventory_cache: Dict[str, CacheEntry] = {}
        self._stats = {
            'position_hits': 0,
            'position_misses': 0,
            'inventory_hits': 0,
            'inventory_misses': 0
        }

    def get_positions(self, cache_key: str) -> Optional[List]:
        """Get cached positions if valid."""
        if cache_key in self._positions_cache:
            entry = self._positions_cache[cache_key]
            if entry.is_valid():
                self._stats['position_hits'] += 1
                logger.debug(f"Cache HIT for positions: {cache_key[:20]}...")
                return entry.data
        self._stats['position_misses'] += 1
        return None

    def set_positions(self, cache_key: str, positions: List) -> None:
        """Cache positions."""
        self._positions_cache[cache_key] = CacheEntry(
            data=positions,
            timestamp=time.time(),
            ttl=self.position_ttl
        )
        logger.debug(f"Cached {len(positions)} positions for {cache_key[:20]}... (TTL: {self.position_ttl}s)")

    def get_inventory(self, cache_key: str) -> Optional[Dict]:
        """Get cached inventory if valid."""
        if cache_key in self._inventory_cache:
            entry = self._inventory_cache[cache_key]
            if entry.is_valid():
                self._stats['inventory_hits'] += 1
                logger.debug(f"Cache HIT for inventory: {cache_key[:30]}...")
                return entry.data
        self._stats['inventory_misses'] += 1
        return None

    def set_inventory(self, cache_key: str, inventory: Dict) -> None:
        """Cache inventory."""
        self._inventory_cache[cache_key] = CacheEntry(
            data=inventory,
            timestamp=time.time(),
            ttl=self.inventory_ttl
        )
        logger.debug(f"Cached {len(inventory)} inventory items (TTL: {self.inventory_ttl}s)")

    def clear(self) -> None:
        """Clear all caches."""
        self._positions_cache.clear()
        self._inventory_cache.clear()
        logger.info("Cleared all Rysk API caches")

    def get_stats(self) -> Dict[str, int]:
        """Get cache statistics."""
        return self._stats.copy()

    def log_stats(self) -> None:
        """Log cache statistics."""
        stats = self._stats
        pos_total = stats['position_hits'] + stats['position_misses']
        inv_total = stats['inventory_hits'] + stats['inventory_misses']

        pos_hit_rate = (stats['position_hits'] / pos_total * 100) if pos_total > 0 else 0
        inv_hit_rate = (stats['inventory_hits'] / inv_total * 100) if inv_total > 0 else 0

        logger.info(
            f"Rysk API Cache Stats - "
            f"Positions: {stats['position_hits']}/{pos_total} hits ({pos_hit_rate:.1f}%), "
            f"Inventory: {stats['inventory_hits']}/{inv_total} hits ({inv_hit_rate:.1f}%)"
        )


# Global cache instance (can be replaced per-keeper if needed)
_global_cache: Optional[RyskAPICache] = None


def get_cache(
    position_ttl: float = DEFAULT_POSITION_CACHE_TTL,
    inventory_ttl: float = DEFAULT_INVENTORY_CACHE_TTL
) -> RyskAPICache:
    """Get or create the global cache instance."""
    global _global_cache
    if _global_cache is None:
        _global_cache = RyskAPICache(position_ttl, inventory_ttl)
    return _global_cache


def set_cache_ttl(position_ttl: float = None, inventory_ttl: float = None) -> None:
    """Update cache TTL settings."""
    global _global_cache
    if _global_cache is None:
        _global_cache = RyskAPICache(
            position_ttl or DEFAULT_POSITION_CACHE_TTL,
            inventory_ttl or DEFAULT_INVENTORY_CACHE_TTL
        )
    else:
        if position_ttl is not None:
            _global_cache.position_ttl = position_ttl
        if inventory_ttl is not None:
            _global_cache.inventory_ttl = inventory_ttl
    logger.info(f"Cache TTL updated - positions: {_global_cache.position_ttl}s, inventory: {_global_cache.inventory_ttl}s")


@dataclass
class RyskPosition:
    """
    Parsed Rysk maker position.

    From Rysk API response:
    {
        "assetAddress": "0x...",       // oToken ERC20 address
        "balance": "2300000000000000000",  // e18
        "strike": "40500000000000000000",   // e18 (USD)
        "expiry": 1753430400,              // unix timestamp
        "isPut": false,
        "underlying": "HYPE",
        "optionAsset": "0x555...",         // underlying token address
        "premium": "-22000000000000000000"  // negative = SHORT
    }
    """
    asset_address: str       # oToken ERC20 address
    balance: int             # raw balance (e18)
    strike: float            # strike price in USD
    expiry: int              # unix timestamp
    is_put: bool
    underlying_symbol: str   # "HYPE", "kHYPE", etc.
    option_asset: str        # underlying token address
    premium: int             # aggregate premium (e18, negative = sold)

    @property
    def is_short(self) -> bool:
        """
        Positions with negative premium are SHORT (maker sold options).
        SHORT positions represent liabilities.
        """
        return self.premium < 0

    @property
    def balance_float(self) -> float:
        """Balance as float (e18 -> decimal)"""
        return float(self.balance) / 1e18


def fetch_maker_positions(
    wallet_address: str,
    timeout: int = 10,
    api_base_url: str = DEFAULT_RYSK_API_BASE,
    use_cache: bool = True
) -> List[RyskPosition]:
    """
    Fetch maker positions from Rysk API with optional caching.

    API: {api_base_url}/api/maker/positions?address=0x...

    Args:
        wallet_address: Address holding oToken positions
        timeout: Request timeout in seconds
        api_base_url: Base URL for Rysk API (default: mainnet v12.rysk.finance)
        use_cache: Whether to use caching (default True)

    Returns:
        List of RyskPosition dataclasses
    """
    # Check cache first
    cache_key = f"{api_base_url}:{wallet_address.lower()}"
    if use_cache:
        cache = get_cache()
        cached = cache.get_positions(cache_key)
        if cached is not None:
            return cached

    try:
        url = f"{api_base_url}/api/maker/positions?address={wallet_address}"
        logger.debug(f"Fetching Rysk positions: {url}")

        response = requests.get(url, timeout=timeout)
        response.raise_for_status()

        data = response.json()
        positions = []

        # Handle both list and dict responses
        if isinstance(data, dict):
            data = data.get('positions', data.get('data', []))

        if not isinstance(data, list):
            logger.warning(f"Unexpected Rysk API response format: {type(data)}")
            return []

        for item in data:
            # Skip non-otoken positions (e.g., USDT0 balance)
            if not item.get('isOtoken', True):
                continue

            try:
                pos = RyskPosition(
                    asset_address=item.get('assetAddress', ''),
                    balance=int(item.get('balance', 0)),
                    strike=float(int(item.get('strike', 0))) / 1e18,  # e18 -> USD
                    expiry=int(item.get('expiry', 0)),
                    is_put=bool(item.get('isPut', False)),
                    underlying_symbol=item.get('underlying', '').upper(),
                    option_asset=item.get('optionAsset', ''),
                    premium=int(item.get('premium', 0))
                )
                positions.append(pos)
            except (ValueError, TypeError) as e:
                logger.warning(f"Error parsing position {item.get('assetAddress')}: {e}")
                continue

        logger.info(f"Fetched {len(positions)} oToken positions for {wallet_address[:10]}...")

        # Cache the result
        if use_cache:
            cache = get_cache()
            cache.set_positions(cache_key, positions)

        return positions

    except requests.exceptions.Timeout:
        logger.error(f"Rysk maker API timeout for {wallet_address}")
        return []
    except requests.exceptions.RequestException as e:
        logger.error(f"Rysk maker API error: {e}")
        return []
    except Exception as e:
        logger.error(f"Error fetching/parsing Rysk positions: {e}")
        return []


def fetch_inventory_iv(
    timeout: int = 10,
    api_base_url: str = DEFAULT_RYSK_API_BASE,
    use_cache: bool = True
) -> Dict[str, Dict]:
    """
    Fetch IV data from Rysk inventory API with optional caching.

    API: {api_base_url}/api/inventory

    Args:
        timeout: Request timeout in seconds
        api_base_url: Base URL for Rysk API (default: mainnet v12.rysk.finance)
        use_cache: Whether to use caching (default True)

    Returns:
        Dict mapping option keys to IV data:
        {
            "HYPE-40.5-1753430400-False": {
                "bidIv": 0.75,   # decimal
                "askIv": 0.85,   # decimal
                "index": 28.5   # spot price
            },
            ...
        }
        Key format: "{SYMBOL}-{STRIKE}-{EXPIRY}-{IS_PUT}"
    """
    # Check cache first
    cache_key = f"{api_base_url}:inventory"
    if use_cache:
        cache = get_cache()
        cached = cache.get_inventory(cache_key)
        if cached is not None:
            return cached

    try:
        inventory_url = f"{api_base_url}/api/inventory"
        logger.debug(f"Fetching Rysk inventory: {inventory_url}")

        response = requests.get(inventory_url, timeout=timeout)
        response.raise_for_status()

        data = response.json()
        result = {}

        # API structure: { "HYPE": { "combinations": { ... } }, ... }
        for symbol, asset_data in data.items():
            if not isinstance(asset_data, dict):
                continue

            combinations = asset_data.get('combinations', {})
            for key, combo in combinations.items():
                if not isinstance(combo, dict):
                    continue

                try:
                    strike = float(combo.get('strike', 0))
                    expiry = int(combo.get('expiration_timestamp', 0))
                    is_put = bool(combo.get('isPut', False))

                    # IV is in percentage (e.g., 75.0 for 75%), convert to decimal
                    bid_iv = float(combo.get('bidIv', 0)) / 100.0
                    ask_iv = float(combo.get('askIv', 0)) / 100.0
                    index = float(combo.get('index', 0))

                    lookup_key = f"{symbol.upper()}-{strike:.1f}-{expiry}-{is_put}"
                    result[lookup_key] = {
                        'bidIv': bid_iv,
                        'askIv': ask_iv,
                        'index': index
                    }
                except (ValueError, TypeError) as e:
                    logger.debug(f"Error parsing inventory item {key}: {e}")
                    continue

        logger.info(f"Fetched IV data for {len(result)} option combinations")
        return result

    except requests.exceptions.Timeout:
        logger.error("Rysk inventory API timeout")
        return {}
    except requests.exceptions.RequestException as e:
        logger.error(f"Rysk inventory API error: {e}")
        return {}
    except Exception as e:
        logger.error(f"Error fetching/parsing Rysk inventory: {e}")
        return {}


def get_iv_for_option(
    inventory_data: Dict[str, Dict],
    underlying_symbol: str,
    strike: float,
    expiry: int,
    is_put: bool,
    default_iv: float = 0.80
) -> float:
    """
    Look up IV for specific option from inventory data.

    Uses mid-IV (average of bid/ask) when available.
    Falls back to default_iv if not found.

    Args:
        inventory_data: Dict from fetch_inventory_iv()
        underlying_symbol: e.g., "HYPE"
        strike: Strike price in USD
        expiry: Unix timestamp
        is_put: True for puts
        default_iv: Default IV as decimal (0.80 = 80%)

    Returns:
        IV as decimal (0.80 = 80%)
    """
    # Build lookup key matching inventory format
    lookup_key = f"{underlying_symbol.upper()}-{strike:.1f}-{expiry}-{is_put}"

    if lookup_key in inventory_data:
        item = inventory_data[lookup_key]
        bid_iv = item.get('bidIv', 0)
        ask_iv = item.get('askIv', 0)

        # Use mid-IV if both bid and ask are available
        if bid_iv > 0 and ask_iv > 0:
            mid_iv = (bid_iv + ask_iv) / 2.0
            logger.debug(f"IV for {lookup_key}: bid={bid_iv:.2%}, ask={ask_iv:.2%}, mid={mid_iv:.2%}")
            return mid_iv
        elif ask_iv > 0:
            logger.debug(f"IV for {lookup_key}: using ask={ask_iv:.2%}")
            return ask_iv
        elif bid_iv > 0:
            logger.debug(f"IV for {lookup_key}: using bid={bid_iv:.2%}")
            return bid_iv

    logger.debug(f"Using default IV {default_iv:.2%} for {lookup_key}")
    return default_iv


def get_index_price_from_inventory(
    inventory_data: Dict[str, Dict],
    underlying_symbol: str
) -> Optional[float]:
    """
    Get index (spot) price from inventory data.

    This is a fallback if Chainlink is unavailable.
    Returns the most recent index price for the given underlying.

    Args:
        inventory_data: Dict from fetch_inventory_iv()
        underlying_symbol: e.g., "HYPE"

    Returns:
        Index price in USD, or None if not found
    """
    symbol_upper = underlying_symbol.upper()

    for key, item in inventory_data.items():
        if key.startswith(f"{symbol_upper}-"):
            index = item.get('index', 0)
            if index > 0:
                logger.debug(f"Index price for {symbol_upper} from inventory: ${index:.2f}")
                return index

    logger.debug(f"No index price found for {symbol_upper} in inventory")
    return None
