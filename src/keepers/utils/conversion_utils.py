"""
Asset conversion utility functions
"""
import logging
from typing import Dict, Any
from web3 import Web3

logger = logging.getLogger("OffchainValuationKeeper.conversion")


def convert_underlying_to_wrapper_shares(w3: Web3, wrapper_abi: list, wrapper_address: str, underlying_amount: int) -> int:
    """
    Convert underlying units (rebasing token) to wrapper shares using on-chain convertToShares.

    Args:
        w3: Web3 instance
        wrapper_abi: Wrapper contract ABI
        wrapper_address: Wrapper contract address
        underlying_amount: Amount in underlying units

    Returns:
        Amount in wrapper shares
    """
    if underlying_amount <= 0:
        return 0
    try:
        wrapper_cs = Web3.to_checksum_address(wrapper_address)
        wrapper = w3.eth.contract(address=wrapper_cs, abi=wrapper_abi)
        shares = wrapper.functions.convertToShares(int(underlying_amount)).call()
        return int(shares)
    except Exception as e:
        # For standard ERC20 tokens, underlying == shares (1:1)
        logger.debug(f"convertToShares not available (standard ERC20), using 1:1 ratio: {e}")
        return int(underlying_amount)


def read_underlying_balance(w3: Web3, erc20_abi: list, token: str, holder: str) -> int:
    """
    Read ERC20 balanceOf(holder) for token.

    WARNING: This reads raw balanceOf() which is vulnerable to donation attacks!
    For escrow idle assets, use read_escrow_tracked_idle() instead.

    Args:
        w3: Web3 instance
        erc20_abi: ERC20 ABI
        token: Token address
        holder: Holder address

    Returns:
        Token balance
    """
    try:
        token_cs = Web3.to_checksum_address(token)
        holder_cs = Web3.to_checksum_address(holder)
        erc = w3.eth.contract(address=token_cs, abi=erc20_abi)
        return int(erc.functions.balanceOf(holder_cs).call())
    except Exception as e:
        raise RuntimeError(f"balanceOf({token}, {holder}) failed: {e}")


def read_escrow_tracked_idle(
    w3: Web3,
    adapter_abi: list,
    erc20_abi: list,
    escrow_address: str,
    strategy_id: bytes
) -> int:
    """
    Read tracked idle assets from escrow using accounting-based protection.

    DONATION ATTACK PROTECTION:
    Instead of raw balanceOf(), uses:
        tracked_idle = allocations[strategyId] - externalDeposits[strategyId]
    Then bounds by actual balance to prevent over-counting.

    This prevents attackers from inflating valuation by donating assets
    directly to the escrow contract.

    Args:
        w3: Web3 instance
        adapter_abi: UniversalAdapterEscrow ABI (with allocations, externalDeposits)
        erc20_abi: ERC20 ABI
        escrow_address: Escrow contract address
        strategy_id: Strategy ID (bytes32)

    Returns:
        Tracked idle assets (bounded by actual balance)
    """
    try:
        escrow_cs = Web3.to_checksum_address(escrow_address)
        escrow = w3.eth.contract(address=escrow_cs, abi=adapter_abi)

        # Read tracked values from escrow accounting
        allocations = int(escrow.functions.allocations(strategy_id).call())
        external_deposits = int(escrow.functions.externalDeposits(strategy_id).call())

        # Calculate tracked idle (what should be in escrow for this strategy)
        tracked_idle = allocations - external_deposits if allocations > external_deposits else 0

        # Get actual balance as upper bound (can't count more than exists)
        asset_address = escrow.functions.asset().call()
        asset = w3.eth.contract(address=Web3.to_checksum_address(asset_address), abi=erc20_abi)
        actual_balance = int(asset.functions.balanceOf(escrow_cs).call())

        # Return minimum of tracked and actual (protects against both over-counting and under-counting)
        bounded_idle = min(tracked_idle, actual_balance)

        logger.debug(
            f"Escrow tracked idle: allocations={allocations/1e18:.6f}, "
            f"externalDeposits={external_deposits/1e18:.6f}, "
            f"tracked_idle={tracked_idle/1e18:.6f}, "
            f"actual_balance={actual_balance/1e18:.6f}, "
            f"bounded_idle={bounded_idle/1e18:.6f}"
        )

        return bounded_idle

    except Exception as e:
        logger.error(f"Failed to read escrow tracked idle: {e}")
        # Fallback to 0 for safety (don't use raw balance as fallback!)
        return 0


def auto_detect_token_order(w3: Web3, uniswap_v3_pool_abi: list, uniswap_v2_pair_abi: list, pool_address: str, from_asset: str, pool_type: str = 'v3') -> bool:
    """
    Auto-detect token ordering in Uniswap pool.

    Args:
        w3: Web3 instance
        uniswap_v3_pool_abi: Uniswap V3 pool ABI
        uniswap_v2_pair_abi: Uniswap V2 pair ABI
        pool_address: Uniswap pool address
        from_asset: Source asset address
        pool_type: 'v3' or 'v2'

    Returns:
        True if from_asset == token0, False if from_asset == token1
    """
    try:
        pool_cs = Web3.to_checksum_address(pool_address)
        from_cs = Web3.to_checksum_address(from_asset)

        # Select ABI based on pool type
        abi = uniswap_v3_pool_abi if pool_type == 'v3' else uniswap_v2_pair_abi
        pool = w3.eth.contract(address=pool_cs, abi=abi)

        # Query token addresses
        token0 = Web3.to_checksum_address(pool.functions.token0().call())
        token1 = Web3.to_checksum_address(pool.functions.token1().call())

        logger.debug(f"Pool tokens: token0={token0}, token1={token1}, from_asset={from_cs}")

        # Compare addresses
        if token0.lower() == from_cs.lower():
            logger.debug(f"Auto-detected: from_asset is token0")
            return True
        elif token1.lower() == from_cs.lower():
            logger.debug(f"Auto-detected: from_asset is token1")
            return False
        else:
            raise RuntimeError(
                f"from_asset {from_cs} is neither token0 ({token0}) nor token1 ({token1}) "
                f"in pool {pool_cs}"
            )

    except Exception as e:
        logger.error(f"Error auto-detecting token order: {e}")
        raise


def convert_via_chainlink(w3: Web3, chainlink_abi: list, amount: int, from_asset: str, config: Dict) -> int:
    """
    Convert asset using Chainlink price feeds.

    Supports two modes:
    1. Two feeds: from_asset/USD and wrapper/USD, compute ratio
    2. Direct pair feed: from_asset/wrapper

    Args:
        w3: Web3 instance
        chainlink_abi: Chainlink price feed ABI
        amount: Amount in from_asset
        from_asset: Source asset address
        config: Dict with from_feed, to_feed or pair_feed

    Returns:
        Amount in wrapper asset
    """
    pair_feed = config.get('pair_feed')
    from_feed = config.get('from_feed')
    to_feed = config.get('to_feed')

    try:
        if pair_feed:
            # Mode 2: Direct pair feed
            feed_cs = Web3.to_checksum_address(pair_feed)
            feed = w3.eth.contract(address=feed_cs, abi=chainlink_abi)

            round_data = feed.functions.latestRoundData().call()
            price = int(round_data[1])
            decimals = int(feed.functions.decimals().call())

            # Convert to 18 decimals
            price_18dec = (price * 10**18) // (10**decimals)
            converted_amount = (amount * price_18dec) // 10**18

        elif from_feed and to_feed:
            # Mode 1: Two feeds
            from_feed_cs = Web3.to_checksum_address(from_feed)
            to_feed_cs = Web3.to_checksum_address(to_feed)

            from_oracle = w3.eth.contract(address=from_feed_cs, abi=chainlink_abi)
            to_oracle = w3.eth.contract(address=to_feed_cs, abi=chainlink_abi)

            from_data = from_oracle.functions.latestRoundData().call()
            to_data = to_oracle.functions.latestRoundData().call()

            from_price = int(from_data[1])
            to_price = int(to_data[1])
            from_decimals = int(from_oracle.functions.decimals().call())
            to_decimals = int(to_oracle.functions.decimals().call())

            # Normalize to 18 decimals
            from_price_18 = (from_price * 10**18) // (10**from_decimals)
            to_price_18 = (to_price * 10**18) // (10**to_decimals)

            if to_price_18 == 0:
                logger.error("Chainlink to_feed price is 0, using 1:1")
                return amount

            converted_amount = (amount * from_price_18) // to_price_18

        else:
            logger.error("Chainlink conversion requires either pair_feed or (from_feed + to_feed)")
            return amount

        # Sanity check
        if converted_amount < amount // 2 or converted_amount > amount * 2:
            ratio = converted_amount / amount if amount > 0 else 0
            raise RuntimeError(
                f"Chainlink conversion ratio {ratio:.4f} outside safe bounds [0.5, 2.0]. "
                f"Oracle may be stale or market extreme."
            )

        logger.debug(f"Chainlink conversion: {amount/1e18:.6f} → {converted_amount/1e18:.6f}")
        return converted_amount

    except RuntimeError:
        raise
    except Exception as e:
        raise RuntimeError(f"Chainlink conversion failed: {e}") from e


def convert_via_fixed_ratio(amount: int, config: Dict) -> int:
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


def convert_asset_to_wrapper(
    w3: Web3,
    wrapper_address: str,
    amount: int,
    from_asset: str,
    conversion_config: Dict[str, Any],
    convert_via_uniswap_v3_twap_func,
    convert_via_uniswap_v2_twap_func
) -> int:
    """
    Generic asset conversion dispatcher for PT underlying → vault wrapper conversions.

    Args:
        w3: Web3 instance
        wrapper_address: Wrapper contract address
        amount: Amount in from_asset units
        from_asset: Source asset address
        conversion_config: Configuration dict with method and parameters
        convert_via_uniswap_v3_twap_func: Function for V3 TWAP conversion
        convert_via_uniswap_v2_twap_func: Function for V2 TWAP conversion

    Returns:
        Amount in wrapper asset units
    """
    if amount <= 0:
        return 0

    method = conversion_config.get('method', 'none').lower()

    # Check if conversion needed
    from_normalized = Web3.to_checksum_address(from_asset).lower()
    wrapper_normalized = wrapper_address.lower()

    if from_normalized == wrapper_normalized or method == 'none':
        logger.debug(f"Assets match or method=none, skipping conversion")
        return amount

    # Route to conversion method
    if method == 'uniswap_v3_twap':
        return convert_via_uniswap_v3_twap_func(amount, from_asset, conversion_config)
    elif method == 'uniswap_v2_twap':
        return convert_via_uniswap_v2_twap_func(amount, from_asset, conversion_config)
    elif method == 'chainlink':
        # Note: chainlink conversion is in this module
        logger.warning("Chainlink conversion requires chainlink_abi parameter")
        return amount
    elif method == 'fixed_ratio':
        return convert_via_fixed_ratio(amount, conversion_config)
    else:
        logger.error(f"Unsupported asset conversion method: {method}")
        return amount
