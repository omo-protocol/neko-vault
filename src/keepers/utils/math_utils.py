"""
Mathematical helper functions for OffchainValuationKeeper
"""
import math


def norm_cdf(x: float) -> float:
    """Cumulative distribution function for the standard normal distribution."""
    return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))


def black_scholes(S: float, K: float, T: float, sigma: float, r: float, is_put: bool) -> float:
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
        return K * math.exp(-r * T) * norm_cdf(-d2) - S * norm_cdf(-d1)
    else:
        return S * norm_cdf(d1) - K * math.exp(-r * T) * norm_cdf(d2)


def to_strategy_id(text_id: str) -> bytes:
    """Convert text strategy ID to bytes32 keccak256 hash"""
    from web3 import Web3
    return Web3.keccak(text=text_id)


def tick_to_sqrt_price_x96(tick: int) -> int:
    """
    Convert Uniswap V3 tick to sqrtPriceX96

    Formula: sqrtPriceX96 = 1.0001^(tick/2) * 2^96
    """
    # Calculate sqrt price in float
    sqrt_price = 1.0001 ** (tick / 2)

    # Convert to X96 format (multiply by 2^96)
    sqrt_price_x96 = int(sqrt_price * (2 ** 96))

    return sqrt_price_x96


def calculate_amounts_from_liquidity(
    liquidity: int,
    sqrt_price_current_x96: int,
    tick_lower: int,
    tick_upper: int
) -> tuple:
    """
    Calculate token amounts from Uniswap V3 liquidity position

    Returns:
        (amount0, amount1) in token units
    """
    # Convert ticks to sqrt prices
    sqrt_price_lower_x96 = tick_to_sqrt_price_x96(tick_lower)
    sqrt_price_upper_x96 = tick_to_sqrt_price_x96(tick_upper)

    # Ensure sqrt prices are in correct order
    if sqrt_price_lower_x96 > sqrt_price_upper_x96:
        sqrt_price_lower_x96, sqrt_price_upper_x96 = sqrt_price_upper_x96, sqrt_price_lower_x96

    amount0 = 0
    amount1 = 0

    # If current price is below the range, only token0 is held
    if sqrt_price_current_x96 <= sqrt_price_lower_x96:
        amount0 = int(
            liquidity * (sqrt_price_upper_x96 - sqrt_price_lower_x96) /
            (sqrt_price_upper_x96 * sqrt_price_lower_x96) * (2 ** 96)
        )

    # If current price is above the range, only token1 is held
    elif sqrt_price_current_x96 >= sqrt_price_upper_x96:
        amount1 = int(
            liquidity * (sqrt_price_upper_x96 - sqrt_price_lower_x96) /
            (2 ** 96)
        )

    # If current price is within the range, both tokens are held
    else:
        amount0 = int(
            liquidity * (sqrt_price_upper_x96 - sqrt_price_current_x96) /
            (sqrt_price_upper_x96 * sqrt_price_current_x96) * (2 ** 96)
        )
        amount1 = int(
            liquidity * (sqrt_price_current_x96 - sqrt_price_lower_x96) /
            (2 ** 96)
        )

    return (amount0, amount1)
