"""
Uniswap V2/V3 utility functions for pool interactions and liquidity calculations
"""
import math
import logging
import time
from typing import Dict, List, Tuple, Any
from web3 import Web3

logger = logging.getLogger("OffchainValuationKeeper.uniswap")


def scan_uniswap_v3_positions(
    w3: Web3,
    position_manager_abi: list,
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
        w3: Web3 instance
        position_manager_abi: NonFungiblePositionManager ABI
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
        pm_contract = w3.eth.contract(address=pm_cs, abi=position_manager_abi)

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


def get_uniswap_v3_position(w3: Web3, position_manager_abi: list, position_manager: str, token_id: int) -> Dict[str, Any]:
    """
    Read Uniswap V3 NFT position details from NonFungiblePositionManager.

    Args:
        w3: Web3 instance
        position_manager_abi: NonFungiblePositionManager ABI
        position_manager: Address of Uniswap V3 NonFungiblePositionManager
        token_id: NFT token ID of the position

    Returns:
        Dictionary with position details
    """
    try:
        pm_cs = Web3.to_checksum_address(position_manager)
        pm_contract = w3.eth.contract(address=pm_cs, abi=position_manager_abi)

        # Call positions(tokenId)
        position = pm_contract.functions.positions(int(token_id)).call()

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


def get_pool_current_tick(w3: Web3, pool_abi: list, pool_address: str) -> int:
    """
    Get current tick from Uniswap V3 pool's slot0.

    Args:
        w3: Web3 instance
        pool_abi: Uniswap V3 pool ABI
        pool_address: Uniswap V3 pool address

    Returns:
        Current tick (int24)
    """
    try:
        pool_cs = Web3.to_checksum_address(pool_address)
        pool_contract = w3.eth.contract(address=pool_cs, abi=pool_abi)

        slot0 = pool_contract.functions.slot0().call()
        current_tick = int(slot0[1])

        logger.debug(f"Pool {pool_address} current tick: {current_tick}")
        return current_tick

    except Exception as e:
        logger.error(f"Failed to get pool current tick: {e}")
        raise


def get_pool_twap_tick(w3: Web3, pool_abi: list, pool_address: str, twap_seconds: int = 1800) -> int:
    """
    Get time-weighted average tick from Uniswap V3 pool.

    Args:
        w3: Web3 instance
        pool_abi: Uniswap V3 pool ABI
        pool_address: Uniswap V3 pool address
        twap_seconds: TWAP period in seconds (default 1800 = 30 minutes)

    Returns:
        TWAP tick (int24)
    """
    try:
        pool_cs = Web3.to_checksum_address(pool_address)
        pool_contract = w3.eth.contract(address=pool_cs, abi=pool_abi)

        # Query observations: [twap_seconds ago, now]
        seconds_agos = [twap_seconds, 0]
        observations = pool_contract.functions.observe(seconds_agos).call()

        tick_cumulatives = observations[0]

        # Calculate TWAP
        tick_cumulative_delta = tick_cumulatives[1] - tick_cumulatives[0]
        twap_tick = tick_cumulative_delta // twap_seconds

        logger.debug(f"Pool {pool_address} TWAP tick ({twap_seconds}s): {twap_tick}")
        return int(twap_tick)

    except Exception as e:
        logger.warning(f"TWAP calculation failed, falling back to current tick: {e}")
        return get_pool_current_tick(w3, pool_abi, pool_address)


def tick_to_sqrt_price_x96(tick: int) -> int:
    """
    Convert tick to sqrtPriceX96 (Q96 fixed point format).

    Formula: sqrtPrice = 1.0001^(tick/2) * 2^96

    Args:
        tick: Pool tick (int24)

    Returns:
        sqrtPriceX96 (uint160)
    """
    sqrt_price_float = math.pow(1.0001, tick / 2.0)
    sqrt_price_x96 = int(sqrt_price_float * (2**96))
    return sqrt_price_x96


def calculate_amounts_from_liquidity(
    liquidity: int,
    tick_lower: int,
    tick_upper: int,
    tick_current: int
) -> Tuple[int, int]:
    """
    Calculate token amounts from Uniswap V3 liquidity and tick range.

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
        sqrt_price_current = tick_to_sqrt_price_x96(tick_current)
        sqrt_price_lower = tick_to_sqrt_price_x96(tick_lower)
        sqrt_price_upper = tick_to_sqrt_price_x96(tick_upper)

        amount0 = 0
        amount1 = 0

        if tick_current < tick_lower:
            # All liquidity in token0
            amount0 = (liquidity * (sqrt_price_upper - sqrt_price_lower)) // (2**96)
            amount0 = (amount0 * (2**96)) // sqrt_price_lower
            amount0 = (amount0 * (2**96)) // sqrt_price_upper

        elif tick_current >= tick_upper:
            # All liquidity in token1
            amount1 = (liquidity * (sqrt_price_upper - sqrt_price_lower)) // (2**96)

        else:
            # Liquidity split between both tokens
            if sqrt_price_current < sqrt_price_upper:
                delta = sqrt_price_upper - sqrt_price_current
                amount0 = (liquidity * delta) // (2**96)
                amount0 = (amount0 * (2**96)) // sqrt_price_current
                amount0 = (amount0 * (2**96)) // sqrt_price_upper

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


def get_token_price_from_pool(
    w3: Web3,
    pool_abi: list,
    pool_address: str,
    token_in: str,
    token_out: str,
    use_twap: bool = True,
    twap_seconds: int = 1800
) -> float:
    """
    Get token price from Uniswap V3 pool.

    Args:
        w3: Web3 instance
        pool_abi: Uniswap V3 pool ABI
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
        pool_contract = w3.eth.contract(address=pool_cs, abi=pool_abi)

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
            tick = get_pool_twap_tick(w3, pool_abi, pool_address, twap_seconds)
        else:
            tick = get_pool_current_tick(w3, pool_abi, pool_address)

        # Convert tick to price
        price = math.pow(1.0001, tick)

        if is_token0_in and is_token1_out:
            final_price = price
        elif not is_token0_in and not is_token1_out:
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


def convert_via_uniswap_v3_twap(w3: Web3, pool_abi: list, amount: int, from_asset: str, config: Dict, auto_detect_token_order_func) -> int:
    """
    Convert asset using Uniswap V3 pool TWAP.

    Args:
        w3: Web3 instance
        pool_abi: Uniswap V3 pool ABI
        amount: Amount in from_asset
        from_asset: Source asset address
        config: Dict with pool_address, twap_duration, token0_is_from
        auto_detect_token_order_func: Function to auto-detect token ordering

    Returns:
        Amount in wrapper asset
    """
    pool_address = config.get('pool_address')
    twap_duration = int(config.get('twap_duration', 1800))

    if not pool_address:
        logger.error("Missing pool_address for uniswap_v3_twap conversion")
        return amount

    try:
        pool_cs = Web3.to_checksum_address(pool_address)
        pool = w3.eth.contract(address=pool_cs, abi=pool_abi)

        # Auto-detect token ordering if not specified
        if 'token0_is_from' in config:
            token0_is_from = config.get('token0_is_from')
            logger.debug(f"Using manual token0_is_from={token0_is_from}")
        else:
            token0_is_from = auto_detect_token_order_func(pool_address, from_asset, pool_type='v3')
            logger.info(f"Auto-detected token0_is_from={token0_is_from} for pool {pool_cs}")

        # Query TWAP via observe()
        seconds_agos = [twap_duration, 0]
        observations = pool.functions.observe(seconds_agos).call()
        tick_cumulatives = observations[0]

        # Calculate time-weighted average tick
        tick_cumulative_delta = tick_cumulatives[1] - tick_cumulatives[0]
        time_delta = twap_duration
        avg_tick = tick_cumulative_delta // time_delta

        # Convert tick to price ratio
        price_ratio = 1.0001 ** avg_tick

        # Adjust direction based on token order
        if token0_is_from:
            converted_amount = int(amount * price_ratio)
        else:
            converted_amount = int(amount / price_ratio)

        # Sanity check
        if converted_amount < amount // 2 or converted_amount > amount * 2:
            ratio = converted_amount / amount if amount > 0 else 0
            raise RuntimeError(
                f"Uniswap V3 TWAP conversion ratio {ratio:.4f} outside safe bounds [0.5, 2.0]. "
                f"This may indicate a market crash, de-peg, or oracle manipulation."
            )

        logger.debug(
            f"Uniswap V3 TWAP conversion: {amount/1e18:.6f} → {converted_amount/1e18:.6f} "
            f"(ratio={converted_amount/amount:.6f}, tick={avg_tick})"
        )
        return converted_amount

    except RuntimeError:
        raise
    except Exception as e:
        raise RuntimeError(f"Uniswap V3 TWAP conversion failed - cannot safely value: {e}") from e


def convert_via_uniswap_v2_twap(w3: Web3, pair_abi: list, amount: int, from_asset: str, config: Dict, auto_detect_token_order_func) -> int:
    """
    Convert asset using Uniswap V2 reserves (SPOT PRICE - NOT TRUE TWAP).

    ⚠️  SECURITY WARNING: FLASH LOAN VULNERABLE ⚠️

    Args:
        w3: Web3 instance
        pair_abi: Uniswap V2 pair ABI
        amount: Amount in from_asset
        from_asset: Source asset address
        config: Dict with pair_address, token0_is_from
        auto_detect_token_order_func: Function to auto-detect token ordering

    Returns:
        Amount in wrapper asset
    """
    pair_address = config.get('pair_address')

    if not pair_address:
        logger.error("Missing pair_address for uniswap_v2_twap conversion")
        return amount

    try:
        logger.warning(
            "⚠️  USING UNISWAP V2 SPOT PRICE (NOT TWAP) - FLASH LOAN VULNERABLE!"
        )

        pair_cs = Web3.to_checksum_address(pair_address)
        pair = w3.eth.contract(address=pair_cs, abi=pair_abi)

        # Auto-detect token ordering if not specified
        if 'token0_is_from' in config:
            token0_is_from = config.get('token0_is_from')
        else:
            token0_is_from = auto_detect_token_order_func(pair_address, from_asset, pool_type='v2')

        # Get current reserves
        reserves = pair.functions.getReserves().call()
        reserve0, reserve1 = int(reserves[0]), int(reserves[1])

        if reserve0 == 0 or reserve1 == 0:
            raise RuntimeError(f"Uniswap V2 pair {pair_cs} has zero reserves")

        # Calculate spot price ratio
        if token0_is_from:
            converted_amount = (amount * reserve1) // reserve0
        else:
            converted_amount = (amount * reserve0) // reserve1

        # Sanity check
        if converted_amount < amount // 2 or converted_amount > amount * 2:
            ratio = converted_amount / amount if amount > 0 else 0
            raise RuntimeError(
                f"Uniswap V2 conversion ratio {ratio:.4f} outside safe bounds [0.5, 2.0]"
            )

        logger.debug(
            f"Uniswap V2 conversion: {amount/1e18:.6f} → {converted_amount/1e18:.6f}"
        )
        return converted_amount

    except RuntimeError:
        raise
    except Exception as e:
        raise RuntimeError(f"Uniswap V2 conversion failed: {e}") from e
