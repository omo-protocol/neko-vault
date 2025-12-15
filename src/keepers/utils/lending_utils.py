"""
Lending protocol utility functions (Felix, Morpho, Aave, Compound, HyperLend)
"""
import logging
from typing import Dict, Any, Tuple
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


# =============================================================================
# HyperLend (AAVE V3 Fork) Functions
# =============================================================================

def get_hyperlend_reserve_tokens(
    w3: Web3,
    aave_pool_abi: list,
    pool_address: str,
    asset_address: str
) -> Tuple[str, str]:
    """
    Auto-discover aToken and variableDebtToken addresses for an asset.

    Calls getReserveData(asset) on the HyperLend Pool to get token addresses.

    Args:
        w3: Web3 instance
        aave_pool_abi: AAVE V3 Pool ABI with getReserveData
        pool_address: HyperLend Pool contract address
        asset_address: The underlying asset address to query

    Returns:
        Tuple of (aTokenAddress, variableDebtTokenAddress)
    """
    if not pool_address or pool_address == "0x0000000000000000000000000000000000000000":
        logger.warning("No HyperLend pool address configured")
        return ("", "")

    if not asset_address or asset_address == "0x0000000000000000000000000000000000000000":
        logger.warning("No asset address provided for reserve token discovery")
        return ("", "")

    try:
        pool_cs = Web3.to_checksum_address(pool_address)
        asset_cs = Web3.to_checksum_address(asset_address)

        pool = w3.eth.contract(address=pool_cs, abi=aave_pool_abi)

        # getReserveData returns a tuple with token addresses at indices 8, 9, 10
        reserve_data = pool.functions.getReserveData(asset_cs).call()

        # Index 8: aTokenAddress
        # Index 9: stableDebtTokenAddress
        # Index 10: variableDebtTokenAddress
        atoken_address = reserve_data[8]
        variable_debt_token = reserve_data[10]

        logger.debug(
            f"HyperLend reserve tokens for {asset_address}: "
            f"aToken={atoken_address}, variableDebtToken={variable_debt_token}"
        )

        return (atoken_address, variable_debt_token)

    except Exception as e:
        logger.error(f"Failed to get HyperLend reserve tokens for {asset_address}: {e}")
        return ("", "")


def get_hyperlend_account_data(
    w3: Web3,
    aave_pool_abi: list,
    pool_address: str,
    user: str
) -> Dict[str, Any]:
    """
    Get user account data from HyperLend (AAVE V3 fork) including health factor.

    Args:
        w3: Web3 instance
        aave_pool_abi: AAVE V3 Pool ABI with getUserAccountData
        pool_address: HyperLend Pool contract address
        user: User/escrow address

    Returns:
        Dict with keys:
            - total_collateral_base: Total collateral in base currency (USD, 8 decimals)
            - total_debt_base: Total debt in base currency (USD, 8 decimals)
            - available_borrows_base: Available to borrow in base currency
            - liquidation_threshold: Current liquidation threshold (basis points)
            - ltv: Loan-to-value (basis points)
            - health_factor: Health factor scaled by 1e18 (1.0 = 1e18)
    """
    if not pool_address or pool_address == "0x0000000000000000000000000000000000000000":
        logger.warning("No HyperLend pool address configured")
        return {
            'total_collateral_base': 0,
            'total_debt_base': 0,
            'available_borrows_base': 0,
            'liquidation_threshold': 0,
            'ltv': 0,
            'health_factor': 0
        }

    try:
        pool_cs = Web3.to_checksum_address(pool_address)
        user_cs = Web3.to_checksum_address(user)

        pool = w3.eth.contract(address=pool_cs, abi=aave_pool_abi)

        # getUserAccountData returns:
        # (totalCollateralBase, totalDebtBase, availableBorrowsBase,
        #  currentLiquidationThreshold, ltv, healthFactor)
        account_data = pool.functions.getUserAccountData(user_cs).call()

        result = {
            'total_collateral_base': int(account_data[0]),
            'total_debt_base': int(account_data[1]),
            'available_borrows_base': int(account_data[2]),
            'liquidation_threshold': int(account_data[3]),
            'ltv': int(account_data[4]),
            'health_factor': int(account_data[5])
        }

        logger.debug(
            f"HyperLend account data: "
            f"collateral={result['total_collateral_base']/1e8:.2f} USD, "
            f"debt={result['total_debt_base']/1e8:.2f} USD, "
            f"health_factor={result['health_factor']/1e18:.4f}"
        )

        return result

    except Exception as e:
        logger.critical(
            f"CRITICAL: HyperLend getUserAccountData FAILED for {user}! "
            f"Cannot safely monitor position health. Error: {e}"
        )
        raise RuntimeError(f"HyperLend account data query failed: {e}") from e


def get_hyperlend_debt(
    w3: Web3,
    erc20_abi: list,
    aave_pool_abi: list,
    pool_address: str,
    borrow_asset: str,
    user: str,
    debt_token: str = None
) -> int:
    """
    Get user's debt from HyperLend (AAVE V3 fork).

    Can either:
    1. Use provided debt_token address directly
    2. Auto-discover debt token via getReserveData(borrow_asset)

    Args:
        w3: Web3 instance
        erc20_abi: ERC20 ABI for debt token balance
        aave_pool_abi: AAVE V3 Pool ABI
        pool_address: HyperLend Pool contract address
        borrow_asset: The borrowed asset address (e.g., wHYPE)
        user: Borrower address
        debt_token: Optional - variable debt token address (auto-discovered if None)

    Returns:
        Debt amount in underlying token units
    """
    if not pool_address or pool_address == "0x0000000000000000000000000000000000000000":
        logger.debug("No HyperLend pool address configured, assuming 0 debt")
        return 0

    try:
        user_cs = Web3.to_checksum_address(user)

        # Auto-discover debt token if not provided
        if not debt_token or debt_token == "0x0000000000000000000000000000000000000000":
            if not borrow_asset:
                logger.warning("No borrow_asset or debt_token configured, assuming 0 debt")
                return 0

            _, debt_token = get_hyperlend_reserve_tokens(
                w3, aave_pool_abi, pool_address, borrow_asset
            )

            if not debt_token:
                logger.warning(f"Could not auto-discover debt token for {borrow_asset}")
                return 0

        debt_token_cs = Web3.to_checksum_address(debt_token)

        # Read debt token balance
        debt_contract = w3.eth.contract(address=debt_token_cs, abi=erc20_abi)
        debt_balance = int(debt_contract.functions.balanceOf(user_cs).call())

        logger.debug(f"HyperLend debt: {debt_balance / 1e18:.6f}")
        return debt_balance

    except Exception as e:
        logger.critical(
            f"CRITICAL: HyperLend debt query FAILED for {user}! "
            f"Cannot safely value strategy without debt data. Error: {e}"
        )
        raise RuntimeError(f"HyperLend debt query failed - cannot value strategy safely: {e}") from e


def get_hyperlend_collateral_balance(
    w3: Web3,
    erc20_abi: list,
    aave_pool_abi: list,
    pool_address: str,
    collateral_asset: str,
    user: str,
    atoken_address: str = None
) -> int:
    """
    Get user's aToken (collateral) balance from HyperLend.

    Can either:
    1. Use provided atoken_address directly
    2. Auto-discover aToken via getReserveData(collateral_asset)

    Args:
        w3: Web3 instance
        erc20_abi: ERC20 ABI (aTokens are ERC20 compatible)
        aave_pool_abi: AAVE V3 Pool ABI
        pool_address: HyperLend Pool address
        collateral_asset: The collateral asset address (e.g., PT-kHYPE)
        user: User/escrow address
        atoken_address: Optional - aToken address (auto-discovered if None)

    Returns:
        aToken balance (represents collateral including accrued interest)
    """
    if not pool_address or pool_address == "0x0000000000000000000000000000000000000000":
        logger.warning("No HyperLend pool address configured")
        return 0

    try:
        user_cs = Web3.to_checksum_address(user)

        # Auto-discover aToken if not provided
        if not atoken_address or atoken_address == "0x0000000000000000000000000000000000000000":
            if not collateral_asset:
                logger.warning("No collateral_asset or atoken_address configured")
                return 0

            atoken_address, _ = get_hyperlend_reserve_tokens(
                w3, aave_pool_abi, pool_address, collateral_asset
            )

            if not atoken_address:
                logger.warning(f"Could not auto-discover aToken for {collateral_asset}")
                return 0

        atoken_cs = Web3.to_checksum_address(atoken_address)

        atoken = w3.eth.contract(address=atoken_cs, abi=erc20_abi)
        balance = int(atoken.functions.balanceOf(user_cs).call())

        logger.debug(f"HyperLend aToken balance: {balance / 1e18:.6f}")
        return balance

    except Exception as e:
        logger.error(f"Failed to get HyperLend aToken balance: {e}")
        raise RuntimeError(f"HyperLend aToken balance query failed: {e}") from e


def check_hyperlend_health_factor(
    w3: Web3,
    aave_pool_abi: list,
    pool_address: str,
    user: str,
    warning_threshold: float = 1.5,
    critical_threshold: float = 1.2
) -> Tuple[int, str]:
    """
    Check health factor and return warning level.

    Args:
        w3: Web3 instance
        aave_pool_abi: AAVE V3 Pool ABI
        pool_address: HyperLend Pool address
        user: User address
        warning_threshold: Health factor below which to warn (default 1.5)
        critical_threshold: Health factor below which is critical (default 1.2)

    Returns:
        Tuple of (health_factor, status) where status is 'healthy', 'warning', or 'critical'
    """
    account_data = get_hyperlend_account_data(w3, aave_pool_abi, pool_address, user)
    health_factor = account_data['health_factor']

    # No debt = essentially infinite health factor
    if account_data['total_debt_base'] == 0:
        return (0, 'healthy')

    # Convert thresholds to 1e18 scale
    warning_scaled = int(warning_threshold * 1e18)
    critical_scaled = int(critical_threshold * 1e18)

    if health_factor < critical_scaled:
        status = 'critical'
        logger.critical(
            f"CRITICAL: HyperLend health factor {health_factor/1e18:.4f} "
            f"below critical threshold {critical_threshold}! "
            f"Position at risk of liquidation."
        )
    elif health_factor < warning_scaled:
        status = 'warning'
        logger.warning(
            f"WARNING: HyperLend health factor {health_factor/1e18:.4f} "
            f"below warning threshold {warning_threshold}."
        )
    else:
        status = 'healthy'
        logger.debug(f"HyperLend health factor healthy: {health_factor/1e18:.4f}")

    return (health_factor, status)


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

    elif protocol == 'hyperlend':
        # Import AAVE_V3_POOL_ABI from contract_utils
        from utils.contract_utils import AAVE_V3_POOL_ABI
        pool_address = lending_config.get('pool_address', '0x00A89d7a5A02160f20150EbEA7a2b5E4879A1A8b')
        borrow_asset = lending_config.get('borrow_asset')
        debt_token = lending_config.get('debt_token')
        return get_hyperlend_debt(w3, erc20_abi, AAVE_V3_POOL_ABI, pool_address, borrow_asset, user, debt_token)

    elif protocol == 'none' or not protocol:
        logger.debug(f"No lending protocol configured, returning 0 debt")
        return 0

    else:
        raise ValueError(
            f"CRITICAL: Unsupported lending protocol '{protocol}'. "
            f"Cannot safely calculate debt - strategy may be overvalued if we continue. "
            f"Supported protocols: felix, morpho, aave_v3, compound_v3, hyperlend, none"
        )
