"""
Options valuation utility functions for Rysk oToken positions.

Implements Black-Scholes pricing for options vault valuation:
- Fetches positions from Rysk V12 API
- Gets IV from Rysk inventory API
- Gets spot prices from Chainlink oracles
- Values positions using Black-Scholes formula
- Treats SHORT positions as liabilities (negative value)
"""
import logging
import time
from typing import Dict, List, Optional
from web3 import Web3

from . import rysk_api
from .math_utils import black_scholes
from .pricing_utils import get_chainlink_price_usd, get_spot_price_for_symbol

logger = logging.getLogger("OffchainValuationKeeper.options")


def value_single_option_position(
    spot_price: float,
    strike_price: float,
    time_to_expiry: float,
    implied_vol: float,
    risk_free_rate: float,
    is_put: bool,
    balance: float,
    is_short: bool
) -> float:
    """
    Value a single option position using Black-Scholes.

    Args:
        spot_price: Current underlying price (S)
        strike_price: Strike price in USD (K)
        time_to_expiry: Time to expiry in years (T)
        implied_vol: Implied volatility as decimal (0.80 = 80%)
        risk_free_rate: Risk-free rate as decimal (0.03 = 3%)
        is_put: True for put option, False for call
        balance: Number of options held (float)
        is_short: True if SHORT (liability), False if LONG (asset)

    Returns:
        Position value in USD.
        - Positive for LONG positions (assets)
        - Negative for SHORT positions (liabilities)
    """
    if balance <= 0:
        return 0.0

    # Calculate single option price using Black-Scholes
    option_price = black_scholes(
        S=spot_price,
        K=strike_price,
        T=time_to_expiry,
        sigma=implied_vol,
        r=risk_free_rate,
        is_put=is_put
    )

    # Total position value
    position_value = balance * option_price

    # SHORT positions are liabilities (negative value)
    if is_short:
        position_value = -position_value

    logger.debug(
        f"Option value: S={spot_price:.2f}, K={strike_price:.2f}, T={time_to_expiry:.4f}y, "
        f"IV={implied_vol:.2%}, is_put={is_put}, balance={balance:.4f}, "
        f"is_short={is_short}, price={option_price:.4f}, value={position_value:.4f}"
    )

    return position_value


def value_options_vault_positions(
    w3: Web3,
    chainlink_abi: list,
    wrapper_abi: list,
    maker_wallet: str,
    oracles: Dict[str, str],
    wrapper_address: str,
    wrapper_underlying_oracle: str,
    risk_free_rate: float = 0.0,
    default_iv: float = 0.80,
    short_as_liability: bool = True,
    api_timeout: int = 10
) -> int:
    """
    Value all Rysk options positions for a maker wallet.

    Workflow:
    1. Fetch positions from Rysk API
    2. Fetch IV from Rysk inventory API
    3. For each position:
       - Get spot price from Chainlink oracle
       - Calculate time to expiry
       - Get IV from inventory or use default
       - Calculate Black-Scholes price
       - Apply SHORT/LONG direction
    4. Sum all position values in USD
    5. Convert USD → underlying using Chainlink
    6. Convert underlying → wrapper shares

    Args:
        w3: Web3 instance
        chainlink_abi: Chainlink price feed ABI
        wrapper_abi: ERC4626 wrapper ABI (for convertToShares)
        maker_wallet: Address holding oToken positions
        oracles: Dict mapping symbol (e.g., "HYPE") to Chainlink feed address
        wrapper_address: ERC4626 wrapper address
        wrapper_underlying_oracle: Chainlink feed for underlying → USD conversion
        risk_free_rate: Risk-free rate as decimal (default 0)
        default_iv: Default IV as decimal (default 0.80 = 80%)
        short_as_liability: If True, SHORT positions reduce value (default True)
        api_timeout: API request timeout in seconds (default 10)

    Returns:
        Total value in wrapper shares (18 decimals).
        Returns 0 if no positions or on error.
    """
    now = time.time()

    # 1. Fetch positions from Rysk API
    logger.info(f"Fetching Rysk positions for {maker_wallet[:10]}...")
    positions = rysk_api.fetch_maker_positions(maker_wallet, timeout=api_timeout)

    if not positions:
        logger.info("No oToken positions found")
        return 0

    logger.info(f"Found {len(positions)} oToken positions")

    # 2. Fetch IV data from Rysk inventory
    logger.info("Fetching Rysk inventory IV data...")
    inventory_data = rysk_api.fetch_inventory_iv(timeout=api_timeout)

    if not inventory_data:
        logger.warning("Failed to fetch inventory IV, will use default IV")

    # 3. Value each position
    total_value_usd = 0.0
    positions_valued = 0
    positions_skipped = 0

    for pos in positions:
        try:
            # Skip expired positions
            if pos.expiry <= now:
                logger.debug(f"Skipping expired position: {pos.asset_address[:10]}...")
                positions_skipped += 1
                continue

            # Get spot price from Chainlink
            try:
                spot_price = get_spot_price_for_symbol(
                    w3=w3,
                    chainlink_abi=chainlink_abi,
                    symbol=pos.underlying_symbol,
                    oracles=oracles
                )
            except ValueError as e:
                logger.warning(f"No oracle for {pos.underlying_symbol}, skipping: {e}")
                positions_skipped += 1
                continue
            except RuntimeError as e:
                logger.error(f"Oracle error for {pos.underlying_symbol}: {e}")
                positions_skipped += 1
                continue

            # Calculate time to expiry in years
            time_to_expiry = max(0.0, (pos.expiry - now) / (365.25 * 86400))

            if time_to_expiry <= 0:
                # At expiry, use intrinsic value
                time_to_expiry = 0.0001  # Tiny value to avoid division by zero

            # Get IV from inventory or use default
            iv = rysk_api.get_iv_for_option(
                inventory_data=inventory_data,
                underlying_symbol=pos.underlying_symbol,
                strike=pos.strike,
                expiry=pos.expiry,
                is_put=pos.is_put,
                default_iv=default_iv
            )

            # Determine if SHORT (liability)
            is_short = pos.is_short and short_as_liability

            # Calculate position value
            position_value = value_single_option_position(
                spot_price=spot_price,
                strike_price=pos.strike,
                time_to_expiry=time_to_expiry,
                implied_vol=iv,
                risk_free_rate=risk_free_rate,
                is_put=pos.is_put,
                balance=pos.balance_float,
                is_short=is_short
            )

            total_value_usd += position_value
            positions_valued += 1

            logger.info(
                f"Position {pos.asset_address[:10]}...: "
                f"{pos.underlying_symbol} {'PUT' if pos.is_put else 'CALL'} "
                f"K={pos.strike:.2f} exp={pos.expiry} "
                f"{'SHORT' if is_short else 'LONG'} "
                f"qty={pos.balance_float:.4f} → ${position_value:,.2f}"
            )

        except Exception as e:
            logger.error(f"Error valuing position {pos.asset_address}: {e}", exc_info=True)
            positions_skipped += 1
            continue

    logger.info(
        f"Valued {positions_valued} positions, skipped {positions_skipped}. "
        f"Total USD value: ${total_value_usd:,.2f}"
    )

    # Handle negative net value (more liabilities than assets)
    if total_value_usd < 0:
        logger.warning(
            f"Net position value is negative (${total_value_usd:,.2f}). "
            f"SHORT liabilities exceed LONG assets. Returning 0."
        )
        return 0

    if total_value_usd == 0:
        logger.info("Net position value is zero")
        return 0

    # 4. Convert USD → underlying assets
    # Get underlying price in USD
    try:
        underlying_price_usd = get_chainlink_price_usd(
            w3=w3,
            chainlink_abi=chainlink_abi,
            feed_address=wrapper_underlying_oracle
        )
    except RuntimeError as e:
        logger.error(f"Cannot convert USD to underlying: {e}")
        return 0

    if underlying_price_usd <= 0:
        logger.error(f"Invalid underlying price: {underlying_price_usd}")
        return 0

    # Convert USD value to underlying amount (18 decimals)
    underlying_amount = total_value_usd / underlying_price_usd
    underlying_amount_18dec = int(underlying_amount * 10**18)

    logger.info(
        f"Converted ${total_value_usd:,.2f} USD → "
        f"{underlying_amount:.6f} underlying @ ${underlying_price_usd:.4f}/unit "
        f"({underlying_amount_18dec} raw)"
    )

    # 5. Convert underlying → wrapper shares
    try:
        wrapper_cs = Web3.to_checksum_address(wrapper_address)
        wrapper = w3.eth.contract(address=wrapper_cs, abi=wrapper_abi)

        wrapper_shares = int(wrapper.functions.convertToShares(underlying_amount_18dec).call())

        logger.info(
            f"Converted {underlying_amount_18dec} underlying → "
            f"{wrapper_shares} wrapper shares"
        )

        return wrapper_shares

    except Exception as e:
        logger.error(f"Failed to convert to wrapper shares: {e}")
        # Fallback: return underlying amount as shares (assumes 1:1)
        logger.warning("Falling back to 1:1 underlying:shares ratio")
        return underlying_amount_18dec


# Legacy function for backward compatibility with old config format
def value_options_otoken(
    w3: Web3,
    otoken_abi: list,
    erc20_abi: list,
    strategy_config,
    black_scholes_func,
    get_asset_price_func,
    fetch_rysk_data_func,
    convert_to_wrapper_func
) -> int:
    """
    Legacy function for backward compatibility.

    This is the old interface that reads options from config.
    For new implementations, use value_options_vault_positions() instead.
    """
    extras = strategy_config.extras or {}
    opts = extras.get("options", [])

    if not opts:
        logger.debug("No options configured (legacy mode)")
        return 0

    # Extract configuration
    risk_free_rate = int(extras.get("risk_free_bps", 0)) / 10_000.0
    default_iv = int(extras.get("default_iv_bps", 8000)) / 10_000.0
    oracles = {k.lower(): v for k, v in extras.get("oracles", {}).items()}

    # Fetch market data
    rysk_data = fetch_rysk_data_func()

    total_value_base = 0.0
    now = time.time()

    for opt in opts:
        try:
            token_addr = opt["token"]
            side = int(opt.get("side", 1))  # 1=long, -1=short

            # Read OToken parameters
            token_cs = Web3.to_checksum_address(token_addr)
            otoken = w3.eth.contract(address=token_cs, abi=otoken_abi)
            erc = w3.eth.contract(address=token_cs, abi=erc20_abi)

            # Get balance
            escrow_cs = Web3.to_checksum_address(strategy_config.escrow)
            raw_bal = int(erc.functions.balanceOf(escrow_cs).call())

            if raw_bal == 0:
                continue

            decimals = int(erc.functions.decimals().call())
            qty = float(raw_bal) / (10 ** decimals)

            # Get option parameters
            underlying_addr = otoken.functions.underlyingAsset().call()
            strike_raw = int(otoken.functions.strikePrice().call())
            expiry = int(otoken.functions.expiryTimestamp().call())
            is_put = bool(otoken.functions.isPut().call())

            # Calculate parameters
            K = float(strike_raw) / 1e8  # Strike in USD
            T = max(0.0, (expiry - now) / (365.25 * 86400))

            # Get spot price and volatility
            S = get_asset_price_func(underlying_addr, oracles)
            sigma = opt.get("iv_bps", default_iv * 10000) / 10000.0

            # Calculate Black-Scholes price
            price = black_scholes_func(S, K, T, sigma, risk_free_rate, is_put)

            # Position value
            position_value_usd = qty * price

            # Convert to base asset
            p_base = get_asset_price_func(strategy_config.underlying, oracles)
            if p_base > 0:
                position_value_base = position_value_usd / p_base
                total_value_base += side * position_value_base

        except Exception as e:
            logger.error(f"Error valuing option {opt.get('token')}: {e}")
            continue

    # Ensure non-negative
    total_value_base = max(0.0, total_value_base)

    # Convert to integer with correct decimals
    total_value_base_int = int(total_value_base * 1e18)

    # Convert to wrapper shares
    return convert_to_wrapper_func(total_value_base_int)
