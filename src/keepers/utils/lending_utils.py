"""
Lending protocol utility functions (Felix, Morpho, Aave, Compound)
"""
import logging
from typing import Dict, Any
from web3 import Web3
from eth_abi import encode as abi_encode

logger = logging.getLogger("OffchainValuationKeeper.lending")


def get_felix_debt(w3: Web3, felix_abi: list, felix: str, market_id: str, user: str) -> int:
    """
    Get user's debt from Felix lending (Morpho Blue fork).

    Args:
        w3: Web3 instance
        felix_abi: Felix contract ABI
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
        felix_contract = w3.eth.contract(address=felix_cs, abi=felix_abi)

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
        logger.critical(
            f"CRITICAL: Felix debt query FAILED for {user}! "
            f"Cannot safely value strategy without debt data. "
            f"Error: {e}"
        )
        raise RuntimeError(f"Felix debt query failed - cannot value strategy safely: {e}") from e


def fetch_rate_from_felix_oracle(w3: Web3, morpho_oracle_abi: list, pendle_oracle_abi: list, felix_oracle_address: str) -> float:
    """
    Fetch the actual rate parameter from Felix's oracle contracts.

    Args:
        w3: Web3 instance
        morpho_oracle_abi: Morpho Chainlink Oracle V2 ABI
        pendle_oracle_abi: Pendle Linear Discount Oracle ABI
        felix_oracle_address: Address of Felix's MorphoChainlinkOracleV2 oracle

    Returns:
        Rate as float (e.g., 0.21 for 21% annual discount)
    """
    try:
        # Step 1: Query Morpho Chainlink Oracle V2 to get the BASE_FEED_1
        oracle_cs = Web3.to_checksum_address(felix_oracle_address)
        morpho_oracle = w3.eth.contract(address=oracle_cs, abi=morpho_oracle_abi)

        base_feed_address = morpho_oracle.functions.BASE_FEED_1().call()
        logger.debug(f"Morpho oracle BASE_FEED_1: {base_feed_address}")

        # Step 2: Query the Pendle Linear Discount Oracle
        feed_cs = Web3.to_checksum_address(base_feed_address)
        pendle_feed = w3.eth.contract(address=feed_cs, abi=pendle_oracle_abi)

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


def get_felix_oracle_price(w3: Web3, morpho_oracle_abi: list, felix_oracle_address: str) -> int:
    """
    Get the current PT price directly from Felix's oracle contract.

    Args:
        w3: Web3 instance
        morpho_oracle_abi: Morpho Chainlink Oracle V2 ABI
        felix_oracle_address: Address of Felix's MorphoChainlinkOracleV2 oracle

    Returns:
        Price scaled by 1e36 (Morpho Blue format)
    """
    try:
        oracle_cs = Web3.to_checksum_address(felix_oracle_address)
        morpho_oracle = w3.eth.contract(address=oracle_cs, abi=morpho_oracle_abi)

        price = morpho_oracle.functions.price().call()
        logger.debug(f"Felix oracle price: {price} ({price/1e36:.6f})")

        return price

    except Exception as e:
        logger.error(f"Failed to get price from Felix oracle {felix_oracle_address}: {e}")
        return 0


def get_morpho_blue_debt(w3: Web3, felix_abi: list, morpho_address: str, market_params: Dict, user: str) -> int:
    """
    Get user's debt from Morpho Blue.

    Args:
        w3: Web3 instance
        felix_abi: Morpho/Felix ABI (compatible)
        morpho_address: Morpho Blue contract address
        market_params: Market parameters dict (loanToken, collateralToken, oracle, irm, lltv)
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

        morpho = w3.eth.contract(address=morpho_cs, abi=felix_abi)

        # Compute market ID from parameters
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
        logger.critical(
            f"CRITICAL: Morpho Blue debt query FAILED for {user}! "
            f"Cannot safely value strategy without debt data. Error: {e}"
        )
        raise RuntimeError(f"Morpho Blue debt query failed - cannot value strategy safely: {e}") from e


def get_aave_v3_debt(w3: Web3, erc20_abi: list, pool_address: str, debt_token: str, user: str) -> int:
    """
    Get user's debt from Aave V3.

    Args:
        w3: Web3 instance
        erc20_abi: ERC20 ABI for debt token
        pool_address: Aave V3 Pool contract address
        debt_token: Variable debt token address
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
        debt_erc = w3.eth.contract(address=debt_token_cs, abi=erc20_abi)
        debt_balance = int(debt_erc.functions.balanceOf(user_cs).call())

        logger.debug(f"Aave V3 debt: {debt_balance / 1e18:.6f}")
        return debt_balance

    except Exception as e:
        logger.critical(
            f"CRITICAL: Aave V3 debt query FAILED for {user}! "
            f"Cannot safely value strategy without debt data. Error: {e}"
        )
        raise RuntimeError(f"Aave V3 debt query failed - cannot value strategy safely: {e}") from e


def get_compound_v3_debt(w3: Web3, comet_address: str, user: str) -> int:
    """
    Get user's debt from Compound V3 (Comet).

    Args:
        w3: Web3 instance
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
        comet = w3.eth.contract(address=comet_cs, abi=comet_abi)

        debt = int(comet.functions.borrowBalanceOf(user_cs).call())
        logger.debug(f"Compound V3 debt: {debt / 1e18:.6f}")
        return debt

    except Exception as e:
        logger.critical(
            f"CRITICAL: Compound V3 debt query FAILED for {user}! "
            f"Cannot safely value strategy without debt data. Error: {e}"
        )
        raise RuntimeError(f"Compound V3 debt query failed - cannot value strategy safely: {e}") from e


def get_lending_debt(
    w3: Web3,
    erc20_abi: list,
    felix_abi: list,
    morpho_oracle_abi: list,
    pendle_oracle_abi: list,
    lending_config: Dict[str, Any],
    user: str
) -> int:
    """
    Generic lending debt dispatcher that routes to protocol-specific implementations.

    Args:
        w3: Web3 instance
        erc20_abi: ERC20 ABI
        felix_abi: Felix/Morpho ABI
        morpho_oracle_abi: Morpho Chainlink Oracle ABI
        pendle_oracle_abi: Pendle Linear Oracle ABI
        lending_config: Configuration dict with protocol and parameters
        user: Borrower address (escrow)

    Returns:
        Debt amount in underlying token units (18 decimals)
    """
    protocol = lending_config.get('protocol', '').lower()

    if protocol == 'felix' or protocol == 'felix_lending':
        address = lending_config.get('address')
        market_id = lending_config.get('market_id')
        return get_felix_debt(w3, felix_abi, address, market_id, user)

    elif protocol == 'morpho' or protocol == 'morpho_blue':
        address = lending_config.get('address')
        market_params = lending_config.get('market_params')
        return get_morpho_blue_debt(w3, felix_abi, address, market_params, user)

    elif protocol == 'aave_v3':
        pool_address = lending_config.get('pool_address')
        debt_token = lending_config.get('debt_token')
        return get_aave_v3_debt(w3, erc20_abi, pool_address, debt_token, user)

    elif protocol == 'compound_v3':
        comet_address = lending_config.get('comet_address')
        return get_compound_v3_debt(w3, comet_address, user)

    elif protocol == 'none' or not protocol:
        logger.debug(f"No lending protocol configured, returning 0 debt")
        return 0

    else:
        raise ValueError(
            f"CRITICAL: Unsupported lending protocol '{protocol}'. "
            f"Cannot safely calculate debt - strategy may be overvalued if we continue. "
            f"Supported protocols: felix, morpho, aave_v3, compound_v3, none"
        )
