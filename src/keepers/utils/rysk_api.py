"""
Rysk V12 API integration for options vault valuation.

API Endpoints:
- Maker Positions: https://v12.rysk.finance/api/maker/positions?address=0x...
- Inventory (IV data): https://v12.rysk.finance/api/inventory
"""
import logging
import requests
import time
from dataclasses import dataclass
from typing import Dict, List, Optional, Any

logger = logging.getLogger("OffchainValuationKeeper.rysk")

# Rysk V12 API endpoints
RYSK_MAKER_API = "https://v12.rysk.finance/api/maker/positions"
RYSK_INVENTORY_API = "https://v12.rysk.finance/api/inventory"


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


def fetch_maker_positions(wallet_address: str, timeout: int = 10) -> List[RyskPosition]:
    """
    Fetch maker positions from Rysk API.

    API: https://v12.rysk.finance/api/maker/positions?address=0x...

    Args:
        wallet_address: Address holding oToken positions
        timeout: Request timeout in seconds

    Returns:
        List of RyskPosition dataclasses
    """
    try:
        url = f"{RYSK_MAKER_API}?address={wallet_address}"
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


def fetch_inventory_iv(timeout: int = 10) -> Dict[str, Dict]:
    """
    Fetch IV data from Rysk inventory API.

    API: https://v12.rysk.finance/api/inventory

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
    try:
        logger.debug(f"Fetching Rysk inventory: {RYSK_INVENTORY_API}")

        response = requests.get(RYSK_INVENTORY_API, timeout=timeout)
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
