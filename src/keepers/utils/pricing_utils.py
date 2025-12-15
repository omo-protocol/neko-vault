"""
Pricing and oracle utility functions (Chainlink, Pendle, Rysk)
"""
import logging
import time
from typing import Dict, Any
from web3 import Web3

logger = logging.getLogger("OffchainValuationKeeper.pricing")


def get_pt_price(w3: Web3, pendle_oracle_abi: list, market: str, oracle: str) -> int:
    """
    Get PT to asset exchange rate from Pendle oracle.

    Args:
        w3: Web3 instance
        pendle_oracle_abi: Pendle PT oracle ABI
        market: Pendle market address
        oracle: Pendle PT oracle address

    Returns:
        PT price ratio in 18 decimals (1e18 = 1:1, 0.95e18 = 95% of underlying)
    """
    if not market or not oracle:
        raise ValueError(
            "Missing Pendle market or oracle address - cannot safely price PT. "
            "Configure pendle_market and pt_oracle in strategy extras."
        )

    try:
        market_cs = Web3.to_checksum_address(market)
        oracle_cs = Web3.to_checksum_address(oracle)
        oracle_contract = w3.eth.contract(address=oracle_cs, abi=pendle_oracle_abi)

        # Use 30 minute TWAP for stable pricing
        duration = 1800

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

        # Sanity check: PT price should be between 0.5 and 1.05
        if pt_rate < int(0.5 * 10**18) or pt_rate > int(1.05 * 10**18):
            raise ValueError(
                f"PT price {pt_rate/1e18:.4f} outside expected range [0.5, 1.05]. "
                f"Oracle may be stale or market conditions are extreme."
            )

        logger.debug(f"PT price from oracle: {pt_rate/1e18:.6f}")
        return pt_rate

    except ValueError:
        raise
    except Exception as e:
        logger.critical(
            f"CRITICAL: Pendle oracle query FAILED! "
            f"Cannot safely price PT tokens. Error: {e}"
        )
        raise RuntimeError(f"Pendle oracle query failed - cannot value strategy safely: {e}") from e


def get_maturity_timestamp(w3: Web3, pt_abi: list, pendle_market_abi: list, pt_address: str, market_address: str = None) -> int:
    """
    Get PT maturity timestamp from PT contract or Pendle market.

    Args:
        w3: Web3 instance
        pt_abi: PT token ABI
        pendle_market_abi: Pendle market ABI
        pt_address: PT token contract address
        market_address: Optional Pendle market address (fallback)

    Returns:
        Unix timestamp of maturity, or 0 if unable to determine
    """
    try:
        # Try PT contract first
        pt_cs = Web3.to_checksum_address(pt_address)
        pt_contract = w3.eth.contract(address=pt_cs, abi=pt_abi)

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
            market_contract = w3.eth.contract(address=market_cs, abi=pendle_market_abi)
            maturity = int(market_contract.functions.expiry().call())
            logger.debug(f"Maturity from market contract: {maturity}")
            return maturity

    except Exception as e:
        logger.error(f"Failed to get maturity timestamp: {e}")

    return 0


def get_pt_price_linear_discount(
    w3: Web3,
    pt_abi: list,
    pendle_market_abi: list,
    pendle_oracle_abi: list,
    morpho_oracle_abi: list,
    pendle_linear_oracle_abi: list,
    extras: Dict,
    fetch_rate_from_felix_oracle_func,
    get_felix_oracle_price_func,
    get_pt_price_func
) -> int:
    """
    Calculate PT price using linear discount model.

    Formula: P(t,T) = previewRedeem(1) × [(1 - 1/(1 + r(T-t))) × t/T + 1/(1 + r(T-t))]

    Args:
        w3: Web3 instance
        pt_abi: PT token ABI
        pendle_market_abi: Pendle market ABI
        pendle_oracle_abi: Pendle oracle ABI
        morpho_oracle_abi: Morpho oracle ABI
        pendle_linear_oracle_abi: Pendle linear oracle ABI
        extras: Strategy configuration extras
        fetch_rate_from_felix_oracle_func: Function to fetch rate from Felix oracle
        get_felix_oracle_price_func: Function to get Felix oracle price
        get_pt_price_func: Function to get PT price (fallback)

    Returns:
        PT price ratio in 18 decimals
    """
    pt_address = extras.get('pt_khype_address')

    # Auto-fetch rate from Felix oracle if configured
    felix_oracle_address = extras.get('felix_oracle_address')
    if felix_oracle_address:
        rate = fetch_rate_from_felix_oracle_func(felix_oracle_address)
        if rate <= 0:
            logger.warning("Failed to fetch rate from Felix oracle, using configured rate")
            rate = float(extras.get('rate', 0.05))
    else:
        rate = float(extras.get('rate', 0.05))

    if not pt_address:
        logger.error("Missing pt_khype_address for linear discount pricing")
        return int(0.95 * 10**18)

    try:
        # 1. Get maturity timestamp
        maturity = extras.get('maturity')
        if not maturity or extras.get('auto_detect_maturity'):
            detected = get_maturity_timestamp(
                w3,
                pt_abi,
                pendle_market_abi,
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
                return get_pt_price_func(extras.get('pendle_market'), extras.get('pt_oracle'))
            return int(0.95 * 10**18)

        # 2. Get current time
        current_time = int(time.time())
        time_to_maturity = maturity - current_time

        # 3. Check if matured
        if time_to_maturity <= 0:
            logger.info(f"PT matured, using par value")
            pt_cs = Web3.to_checksum_address(pt_address)
            pt_contract = w3.eth.contract(address=pt_cs, abi=pt_abi)
            preview_redeem = pt_contract.functions.previewRedeem(10**18).call()
            return int(preview_redeem)

        # 4. Get redemption rate
        pt_cs = Web3.to_checksum_address(pt_address)
        pt_contract = w3.eth.contract(address=pt_cs, abi=pt_abi)
        preview_redeem_raw = pt_contract.functions.previewRedeem(10**18).call()
        redemption_rate = float(preview_redeem_raw) / 10**18

        logger.debug(f"Linear discount: redemption_rate={redemption_rate:.6f}")

        # 5. Calculate discount factor
        years_to_maturity = time_to_maturity / (365.25 * 24 * 3600)
        discount_factor = 1.0 / (1.0 + rate * years_to_maturity)

        # 6. Calculate time fraction
        start_date = extras.get('start_date', extras.get('issuance_date'))
        if start_date:
            total_duration = maturity - start_date
            elapsed_time = current_time - start_date
            time_fraction = max(0.0, min(1.0, float(elapsed_time) / float(total_duration)))
        else:
            configured_duration = extras.get('duration', 365.25 * 24 * 3600)
            elapsed_time = configured_duration - time_to_maturity
            time_fraction = max(0.0, min(1.0, float(elapsed_time) / float(configured_duration)))
            logger.warning(
                f"No start_date configured. Using duration={configured_duration/86400:.1f}d. "
                f"Configure 'start_date' in extras for accurate pricing."
            )

        # 7. Apply linear discount formula
        linear_component = (1.0 - discount_factor) * time_fraction
        price_ratio = redemption_rate * (linear_component + discount_factor)

        # 8. Convert to 18 decimal integer
        price_18dec = int(price_ratio * 10**18)

        # 9. Sanity checks
        min_price = int(0.5 * 10**18)
        max_price = int(1.05 * 10**18)

        if price_18dec < min_price or price_18dec > max_price:
            logger.warning(
                f"Linear discount price {price_18dec/1e18:.4f} outside bounds [0.5, 1.05]"
            )
            if extras.get('fallback_to_oracle', True):
                logger.info("Falling back to Pendle oracle pricing")
                return get_pt_price_func(extras.get('pendle_market'), extras.get('pt_oracle'))
            price_18dec = max(min_price, min(price_18dec, max_price))

        logger.info(
            f"Linear discount pricing: "
            f"redemption={redemption_rate:.4f}, "
            f"time_to_maturity={time_to_maturity/86400:.1f}d, "
            f"rate={rate:.4f}, "
            f"price={price_ratio:.6f}"
        )

        # Optional: Validate against Felix oracle
        if extras.get('validate_against_felix', False) and felix_oracle_address:
            try:
                felix_price_36dec = get_felix_oracle_price_func(felix_oracle_address)
                felix_price = felix_price_36dec / 1e36
                divergence = abs(price_ratio - felix_price) / felix_price * 100
                max_divergence = extras.get('max_divergence_pct', 5.0)

                logger.info(
                    f"Felix oracle validation: "
                    f"keeper_price={price_ratio:.6f}, "
                    f"felix_price={felix_price:.6f}, "
                    f"divergence={divergence:.2f}%"
                )

                if divergence > max_divergence:
                    raise RuntimeError(
                        f"PRICE DIVERGENCE ABORT: {divergence:.2f}% difference exceeds {max_divergence}%"
                    )
            except RuntimeError:
                raise
            except Exception as e:
                logger.warning(f"Could not validate against Felix oracle: {e}")

        return price_18dec

    except Exception as e:
        logger.error(f"Linear discount pricing failed: {e}", exc_info=True)
        if extras.get('fallback_to_oracle', True):
            logger.info("Falling back to Pendle oracle pricing")
            return get_pt_price_func(extras.get('pendle_market'), extras.get('pt_oracle'))
        return int(0.95 * 10**18)


def get_token_price_from_chainlink(w3: Web3, chainlink_abi: list, oracle_address: str) -> float:
    """
    Get token price from Chainlink oracle.

    Args:
        w3: Web3 instance
        chainlink_abi: Chainlink price feed ABI
        oracle_address: Chainlink price feed address

    Returns:
        Price as float (scaled by feed decimals)
    """
    try:
        oracle_cs = Web3.to_checksum_address(oracle_address)
        oracle_contract = w3.eth.contract(address=oracle_cs, abi=chainlink_abi)

        # Get decimals
        decimals = oracle_contract.functions.decimals().call()

        # Get latest price
        round_data = oracle_contract.functions.latestRoundData().call()
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


def get_asset_price_in_base(w3: Web3, chainlink_abi: list, asset: str, oracles: Dict[str, str]) -> float:
    """
    Get asset price in terms of base asset using Chainlink feeds.

    Args:
        w3: Web3 instance
        chainlink_abi: Chainlink feed ABI
        asset: Asset address to price
        oracles: Dictionary mapping asset address (lowercase) to Chainlink feed address

    Returns:
        Price of 1 unit of asset in base asset terms (float)
    """
    asset_lower = asset.lower()

    if asset_lower not in oracles:
        logger.error(f"No oracle configured for asset {asset}")
        return 1.0  # Default 1:1

    oracle_address = oracles[asset_lower]
    return get_token_price_from_chainlink(w3, chainlink_abi, oracle_address)


def fetch_rysk_market_data() -> Dict[str, Any]:
    """
    Fetch options market data from Rysk.

    Returns:
        Dictionary with market data (volatility, rates, etc.)
    """
    try:
        # Placeholder - would need actual Rysk API endpoint
        logger.warning("Rysk market data fetching not implemented")
        return {
            'volatility': 0.80,  # 80% IV default
            'risk_free_rate': 0.03  # 3% default
        }
    except Exception as e:
        logger.error(f"Failed to fetch Rysk market data: {e}")
        return {
            'volatility': 0.80,
            'risk_free_rate': 0.03
        }
