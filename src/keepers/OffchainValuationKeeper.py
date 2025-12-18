#!/usr/bin/env python3

import json
import os
import sys
import time
import logging
from dataclasses import dataclass
from typing import Dict, List, Optional, Tuple, Any

from web3 import Web3
from eth_account import Account
from eth_account.messages import encode_defunct

try:
    from eth_abi import encode as abi_encode
except Exception as e:
    raise RuntimeError("eth-abi must be installed: pip install eth-abi") from e

# Load environment variables
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    pass

# Import from refactored utils modules
from utils.contract_utils import (
    ERC20_ABI, PT_TOKEN_ABI, WRAPPER_ABI, VALUER_ABI, ADAPTER_ABI,
    PENDLE_ORACLE_ABI, PENDLE_MARKET_ABI, FELIX_ABI, CHAINLINK_FEED_ABI,
    UNISWAP_V3_POSITION_MANAGER_ABI, UNISWAP_V3_POOL_ABI,
    UNISWAP_V2_PAIR_ABI, OTOKEN_ABI, MORPHO_CHAINLINK_ORACLE_ABI,
    AAVE_V3_POOL_ABI
)

from utils.math_utils import (
    norm_cdf, black_scholes, to_strategy_id,
    tick_to_sqrt_price_x96, calculate_amounts_from_liquidity
)

from utils import uniswap_utils
from utils import lending_utils
from utils import pricing_utils
from utils import conversion_utils
from utils import options_utils

# Configure logging
logging.basicConfig(
    level=os.environ.get("KEEPER_LOG_LEVEL", "INFO"),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("OffchainValuationKeeper")


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


@dataclass
class StrategyConfig:
    id_text: str
    mode: str
    escrow: str
    underlying: str
    confidence: int = 95
    extras: Dict[str, Any] = None
    adapter: str = None


class OffchainValuationKeeper:
    """
    REFACTORED: Main keeper class focusing on orchestration.
    Heavy-lifting delegated to utils modules.
    """

    def __init__(self, config_path: str):
        """Initialize the keeper with configuration"""
        with open(config_path, 'r') as f:
            self.config = json.load(f)

        rpc_url = self.config['rpc_url']
        request_kwargs = {'timeout': 30}
        self.w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs=request_kwargs))
        if not self.w3.is_connected():
            raise RuntimeError(f"Failed to connect to RPC at {rpc_url}")

        # Load signer account
        pk = os.environ.get("KEEPER_PRIVATE_KEY") or self.config.get('signer_private_key')
        if not pk:
            raise RuntimeError("Missing keeper private key")
        self.account = Account.from_key(pk)
        logger.info(f"Keeper signer: {self.account.address}")

        # Load contracts
        self.valuer_address = Web3.to_checksum_address(self.config['valuer_address'])
        self.valuer = self.w3.eth.contract(address=self.valuer_address, abi=VALUER_ABI)

        self.wrapper_address = Web3.to_checksum_address(
            self.config.get('wrapper_address') or self.valuer.functions.asset().call()
        )
        self.wrapper = self.w3.eth.contract(address=self.wrapper_address, abi=WRAPPER_ABI)
        logger.info(f"Valuer: {self.valuer_address}, Wrapper: {self.wrapper_address}")

        self.chain_id = self.config.get("chain_id", self.w3.eth.chain_id)

        # Keeper settings
        ks = self.config.get('keeper_settings', {})
        self.update_check_interval = int(ks.get('update_check_interval', 60))
        self.ttl_seconds = int(ks.get('ttl', 300))
        self.gas_limit = int(ks.get('gas_limit', 350_000))
        self.max_fee_gwei = float(ks.get('max_fee_gwei', 20.0))
        self.max_priority_gwei = float(ks.get('max_priority_gwei', 2.0))

        # Load strategies
        self.strategies: List[StrategyConfig] = []
        for s in self.config.get('strategies', []):
            escrow_addr = s.get('escrow_address') or s.get('escrow')
            underlying_addr = s.get('underlying_address') or s.get('underlying')
            mode = s.get('mode', 'underlying_balance')

            if 'holdings' in s:
                mode = 'holdings'
                extras = {'holdings': s['holdings']}
                if 'extras' in s:
                    extras.update(s['extras'])
            else:
                extras = s.get('extras', {})

            adapter_addr = s.get('adapter_address') or s.get('adapter') or escrow_addr

            self.strategies.append(
                StrategyConfig(
                    id_text=s['id'],
                    mode=mode,
                    escrow=Web3.to_checksum_address(escrow_addr) if escrow_addr else '',
                    underlying=Web3.to_checksum_address(underlying_addr) if underlying_addr else '',
                    confidence=int(s.get('confidence', 95)),
                    extras=extras,
                    adapter=Web3.to_checksum_address(adapter_addr) if adapter_addr else None
                )
            )

        # Caches
        self._erc20_cache: Dict[str, Tuple[Any, int]] = {}
        self._adapter_cache: Dict[str, Any] = {}

        # Metrics
        self.metrics = KeeperMetrics()
        self.summary_interval = 10
        self.update_cycle_count = 0

    # ========== CONTRACT HELPERS ==========

    def _erc20(self, addr: str):
        """Get cached ERC20 contract instance"""
        cs = Web3.to_checksum_address(addr)
        if cs in self._erc20_cache:
            return self._erc20_cache[cs]
        c = self.w3.eth.contract(address=cs, abi=ERC20_ABI)
        decimals = c.functions.decimals().call()
        self._erc20_cache[cs] = (c, decimals)
        return (c, decimals)

    def _adapter(self, addr: str):
        """Get cached adapter contract instance"""
        cs = Web3.to_checksum_address(addr)
        if cs in self._adapter_cache:
            return self._adapter_cache[cs]
        c = self.w3.eth.contract(address=cs, abi=ADAPTER_ABI)
        self._adapter_cache[cs] = c
        return c

    # ========== VALUATION MODES ==========
    # These methods orchestrate calls to utils modules

    def value_underlying_balance_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'underlying_balance'
        REFACTORED: Uses utils.conversion_utils ✅
        """
        # Read underlying balance using utils
        underlying_balance = conversion_utils.read_underlying_balance(
            w3=self.w3,
            erc20_abi=ERC20_ABI,
            token=s.underlying,
            holder=s.escrow
        )

        # Convert to wrapper shares using utils
        wrapper_shares = conversion_utils.convert_underlying_to_wrapper_shares(
            w3=self.w3,
            wrapper_abi=WRAPPER_ABI,
            wrapper_address=self.wrapper_address,
            underlying_amount=underlying_balance
        )

        logger.info(
            f"[{s.id_text}] underlying_balance mode: "
            f"balance={underlying_balance/1e18:.6f}, "
            f"wrapper_shares={wrapper_shares/1e18:.6f}"
        )

        return int(wrapper_shares)

    def value_uniswap_v3_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'uniswap_v3'
        REFACTORED: Uses utils.uniswap_utils ✅
        """
        extras = s.extras or {}

        # EXAMPLE: Using refactored uniswap_utils
        if 'token_id' in extras:
            # Manual token ID specification
            token_id = int(extras['token_id'])
            token_ids = [token_id]
        else:
            # Scan for positions
            position_manager = extras.get('position_manager')
            if not position_manager:
                raise ValueError(f"[{s.id_text}] Missing position_manager for uniswap_v3 mode")

            # ✅ Using utils function
            token_ids = uniswap_utils.scan_uniswap_v3_positions(
                w3=self.w3,
                position_manager_abi=UNISWAP_V3_POSITION_MANAGER_ABI,
                position_manager=position_manager,
                escrow=s.escrow,
                min_liquidity=extras.get('min_liquidity', 0)
            )

        if not token_ids:
            logger.warning(f"[{s.id_text}] No Uniswap V3 positions found")
            return 0

        # Value each position
        total_value_in_base = 0

        for token_id in token_ids:
            # ✅ Using utils function
            position = uniswap_utils.get_uniswap_v3_position(
                w3=self.w3,
                position_manager_abi=UNISWAP_V3_POSITION_MANAGER_ABI,
                position_manager=position_manager,
                token_id=token_id
            )

            # ... rest of valuation logic using position data ...
            # This demonstrates the integration pattern

        logger.info(f"[{s.id_text}] Uniswap V3 total value: {total_value_in_base}")
        return int(total_value_in_base)

    def value_pt_khype_loop_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'pt_khype_loop'
        PT-kHYPE looping strategy using Felix lending.

        Valuation Logic:
        1. Read idle kHYPE from escrow (using tracked accounting, not raw balanceOf)
        2. Read PT-kHYPE balance from escrow
        3. Get PT price
        4. Calculate PT value in underlying
        5. Read debt from Felix
        6. Total value = idle kHYPE + PT value - debt

        DONATION ATTACK PROTECTION:
        Uses read_escrow_tracked_idle() instead of raw balanceOf() for escrow idle assets.
        This prevents attackers from inflating valuation by donating directly to escrow.

        REFACTORED: Uses utils.pricing_utils and utils.lending_utils ✅
        """
        extras = s.extras or {}

        # 1. Get idle kHYPE from escrow using TRACKED VALUES (donation attack protection)
        # Uses allocations[strategyId] - externalDeposits[strategyId] instead of raw balanceOf
        escrow_khype_balance = 0
        if s.escrow:
            strategy_id = to_strategy_id(s.id_text)
            escrow_khype_balance = conversion_utils.read_escrow_tracked_idle(
                w3=self.w3,
                adapter_abi=ADAPTER_ABI,
                erc20_abi=ERC20_ABI,
                escrow_address=s.escrow,
                strategy_id=strategy_id
            )
            logger.debug(f"[{s.id_text}] Escrow tracked idle kHYPE: {escrow_khype_balance/1e18:.6f}")

        # 2. Get PT balance from escrow
        pt_address = extras.get('pt_khype_address')
        if not pt_address:
            logger.error(f"[{s.id_text}] Missing pt_khype_address")
            return 0

        pt_balance = conversion_utils.read_underlying_balance(
            w3=self.w3,
            erc20_abi=ERC20_ABI,
            token=pt_address,
            holder=s.escrow
        )

        # 3. Get PT price (choose pricing method based on config)
        pricing_method = extras.get('pricing_method', 'oracle')

        if pricing_method == 'linear_discount':
            pt_price = pricing_utils.get_pt_price_linear_discount(
                w3=self.w3,
                pt_abi=PT_TOKEN_ABI,
                pendle_market_abi=PENDLE_MARKET_ABI,
                pendle_oracle_abi=PENDLE_ORACLE_ABI,
                morpho_oracle_abi=MORPHO_CHAINLINK_ORACLE_ABI,
                pendle_linear_oracle_abi=None,  # Not needed for this implementation
                extras=extras,
                fetch_rate_from_felix_oracle_func=lending_utils.fetch_rate_from_felix_oracle,
                get_felix_oracle_price_func=lending_utils.get_felix_oracle_price,
                get_pt_price_func=lambda m, o: pricing_utils.get_pt_price(self.w3, PENDLE_ORACLE_ABI, m, o)
            )
        else:
            # Default: Use Pendle oracle
            pt_price = pricing_utils.get_pt_price(
                w3=self.w3,
                pendle_oracle_abi=PENDLE_ORACLE_ABI,
                market=extras.get('pendle_market'),
                oracle=extras.get('pt_oracle')
            )

        # 4. Calculate PT value in underlying
        pt_value_in_underlying = (pt_balance * pt_price) // 10**18

        # 5. Get lending debt
        lending_config = extras.get('lending', {})
        debt = lending_utils.get_lending_debt(
            w3=self.w3,
            erc20_abi=ERC20_ABI,
            felix_abi=FELIX_ABI,
            morpho_oracle_abi=MORPHO_CHAINLINK_ORACLE_ABI,
            pendle_oracle_abi=PENDLE_ORACLE_ABI,
            lending_config=lending_config,
            user=s.escrow
        )

        # 6. Calculate total value = idle kHYPE + PT value - debt
        total_value_underlying = max(0, escrow_khype_balance + pt_value_in_underlying - debt)

        # 7. Convert to wrapper shares
        wrapper_shares = conversion_utils.convert_underlying_to_wrapper_shares(
            w3=self.w3,
            wrapper_abi=WRAPPER_ABI,
            wrapper_address=self.wrapper_address,
            underlying_amount=total_value_underlying
        )

        logger.info(
            f"[{s.id_text}] pt_khype_loop: "
            f"escrow_khype={escrow_khype_balance/1e18:.6f}, "
            f"pt_balance={pt_balance/1e18:.6f}, "
            f"pt_price={pt_price/1e18:.6f}, "
            f"pt_value={pt_value_in_underlying/1e18:.6f}, "
            f"debt={debt/1e18:.6f}, "
            f"total_value={total_value_underlying/1e18:.6f}, "
            f"wrapper_shares={wrapper_shares/1e18:.6f}"
        )

        return int(wrapper_shares)

    def value_pt_khype_looper_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'pt_khype_looper'
        PT-kHYPE looping strategy using HyperLend (AAVE V3 fork).

        Architecture:
        - Vault deposits kHYPE to Escrow
        - Keeper transfers kHYPE to Looper
        - Looper converts kHYPE → PT-kHYPE → supplies to HyperLend → borrows wHYPE → loops
        - When unwinding, only kHYPE returns to Escrow

        Valuation Logic:
        1. Read kHYPE balance from escrow (using tracked accounting)
        2. Read kHYPE balance from looper (bounded by externalDeposits)
        3. Read PT-kHYPE collateral from looper (aToken in HyperLend)
        4. Get PT-kHYPE price
        5. Calculate looper PT value in underlying (kHYPE)
        6. Read wHYPE debt from looper
        7. Looper net value = looper kHYPE + PT value - debt
        8. Total value = escrow kHYPE + looper net value
        9. Monitor health factor

        DONATION ATTACK PROTECTION:
        - Escrow: Uses read_escrow_tracked_idle() (allocations - externalDeposits)
        - Looper: Bounds raw balance by externalDeposits (can't exceed what was sent)
        - PT collateral (aToken): Safe - tracked by HyperLend protocol
        - Debt: Safe - can't be reduced by donation

        REFACTORED: Uses utils.pricing_utils and utils.lending_utils
        """
        extras = s.extras or {}

        # Required addresses
        pt_address = extras.get('pt_khype_address')
        hyperlend_pool = extras.get('hyperlend_pool', '0x00A89d7a5A02160f20150EbEA7a2b5E4879A1A8b')
        looper_address = extras.get('looper_address')

        if not pt_address:
            logger.error(f"[{s.id_text}] Missing pt_khype_address")
            return 0

        if not looper_address:
            logger.error(f"[{s.id_text}] Missing looper_address")
            return 0

        strategy_id = to_strategy_id(s.id_text)

        # 1. Get kHYPE from escrow using TRACKED VALUES (donation attack protection)
        escrow_khype_balance = 0
        external_deposits = 0
        if s.escrow:
            escrow_khype_balance = conversion_utils.read_escrow_tracked_idle(
                w3=self.w3,
                adapter_abi=ADAPTER_ABI,
                erc20_abi=ERC20_ABI,
                escrow_address=s.escrow,
                strategy_id=strategy_id
            )
            logger.debug(f"[{s.id_text}] Escrow tracked idle kHYPE: {escrow_khype_balance/1e18:.6f}")

            # Read externalDeposits to bound looper balance (donation protection)
            try:
                escrow_contract = self.w3.eth.contract(
                    address=Web3.to_checksum_address(s.escrow),
                    abi=ADAPTER_ABI
                )
                external_deposits = int(escrow_contract.functions.externalDeposits(strategy_id).call())
            except Exception as e:
                logger.warning(f"[{s.id_text}] Failed to read externalDeposits: {e}")
                external_deposits = 0

        # 2. Get idle kHYPE from looper with DONATION PROTECTION
        # Read raw balance, but bound to prevent donation attacks while allowing yield
        looper_khype_raw = conversion_utils.read_underlying_balance(
            w3=self.w3,
            erc20_abi=ERC20_ABI,
            token=s.underlying,  # kHYPE
            holder=looper_address
        )

        # Get previous valuer value to allow for yield (yield was already validated by valuer)
        previous_valuer_value = 0
        try:
            report = self.valuer.functions.getReport(strategy_id).call()
            previous_valuer_value = int(report[0])  # value field
            logger.debug(f"[{s.id_text}] Previous valuer value: {previous_valuer_value/1e18:.6f}")
        except Exception as e:
            logger.debug(f"[{s.id_text}] Could not read previous valuer value: {e}")

        # Calculate maximum allowed looper balance:
        # 1. externalDeposits = what was sent from escrow (baseline)
        # 2. previous_valuer_value = includes validated yield (allows growth)
        # Use the higher of the two to allow yield while preventing donations
        max_allowed = max(external_deposits, previous_valuer_value)

        # Bound looper balance to prevent donation attacks
        looper_khype_balance = min(looper_khype_raw, max_allowed) if max_allowed > 0 else looper_khype_raw

        if looper_khype_raw > max_allowed and max_allowed > 0:
            excess = looper_khype_raw - max_allowed
            logger.warning(
                f"[{s.id_text}] DONATION ATTACK DETECTED: "
                f"Looper has {looper_khype_raw/1e18:.6f} kHYPE but max allowed is {max_allowed/1e18:.6f} "
                f"(externalDeposits={external_deposits/1e18:.6f}, prevValue={previous_valuer_value/1e18:.6f}). "
                f"Ignoring excess {excess/1e18:.6f} kHYPE"
            )

        logger.debug(f"[{s.id_text}] Looper bounded kHYPE: {looper_khype_balance/1e18:.6f}")

        # 3. Get PT-kHYPE collateral from looper (aToken in HyperLend)
        atoken_address = extras.get('pt_atoken_address')

        looper_pt_balance = 0
        try:
            looper_pt_balance = lending_utils.get_hyperlend_collateral_balance(
                w3=self.w3,
                erc20_abi=ERC20_ABI,
                aave_pool_abi=AAVE_V3_POOL_ABI,
                pool_address=hyperlend_pool,
                collateral_asset=pt_address,
                user=looper_address,
                atoken_address=atoken_address
            )
            logger.debug(f"[{s.id_text}] Looper aPT-kHYPE balance: {looper_pt_balance/1e18:.6f}")
        except Exception as e:
            logger.warning(f"[{s.id_text}] Failed to get looper aToken balance: {e}")

        # 3. Get PT price (choose pricing method based on config)
        pricing_method = extras.get('pricing_method', 'oracle')

        if pricing_method == 'linear_discount':
            pt_price = pricing_utils.get_pt_price_linear_discount(
                w3=self.w3,
                pt_abi=PT_TOKEN_ABI,
                pendle_market_abi=PENDLE_MARKET_ABI,
                pendle_oracle_abi=PENDLE_ORACLE_ABI,
                morpho_oracle_abi=MORPHO_CHAINLINK_ORACLE_ABI,
                pendle_linear_oracle_abi=None,
                extras=extras,
                fetch_rate_from_felix_oracle_func=lending_utils.fetch_rate_from_felix_oracle,
                get_felix_oracle_price_func=lending_utils.get_felix_oracle_price,
                get_pt_price_func=lambda m, o: pricing_utils.get_pt_price(self.w3, PENDLE_ORACLE_ABI, m, o)
            )
        else:
            # Default: Use Pendle oracle
            pt_price = pricing_utils.get_pt_price(
                w3=self.w3,
                pendle_oracle_abi=PENDLE_ORACLE_ABI,
                market=extras.get('pendle_market'),
                oracle=extras.get('pt_oracle')
            )

        # 4. Calculate looper PT value in underlying (kHYPE)
        looper_pt_value = (looper_pt_balance * pt_price) // 10**18

        # 5. Get wHYPE debt from looper (auto-discovers debt token via getReserveData)
        borrow_asset = extras.get('borrow_asset')
        debt_token = extras.get('debt_token')  # Optional override

        looper_debt_raw = lending_utils.get_hyperlend_debt(
            w3=self.w3,
            erc20_abi=ERC20_ABI,
            aave_pool_abi=AAVE_V3_POOL_ABI,
            pool_address=hyperlend_pool,
            borrow_asset=borrow_asset,
            user=looper_address,
            debt_token=debt_token
        )

        # 5b. Convert debt from wHYPE (HYPE) to kHYPE using Chainlink oracles
        # This is necessary because debt is in wHYPE but valuation is in kHYPE
        debt_feed = extras.get('chainlink_debt_feed')  # HYPE/USD feed
        target_feed = extras.get('chainlink_target_feed')  # kHYPE/USD feed

        if debt_feed and target_feed and looper_debt_raw > 0:
            looper_debt = lending_utils.convert_debt_via_chainlink(
                w3=self.w3,
                chainlink_abi=CHAINLINK_FEED_ABI,
                debt_amount=looper_debt_raw,
                debt_feed=debt_feed,
                target_feed=target_feed,
                sanity_min_ratio=extras.get('debt_ratio_min', 0.8),
                sanity_max_ratio=extras.get('debt_ratio_max', 1.2)
            )
            logger.debug(
                f"[{s.id_text}] Debt converted: {looper_debt_raw/1e18:.6f} wHYPE -> {looper_debt/1e18:.6f} kHYPE"
            )
        else:
            # No conversion configured - use raw debt (assumes same unit)
            looper_debt = looper_debt_raw
            if looper_debt_raw > 0:
                logger.warning(
                    f"[{s.id_text}] No Chainlink feeds configured - debt not converted. "
                    f"Set chainlink_debt_feed and chainlink_target_feed in extras for accurate valuation."
                )

        # 6. Calculate looper net value (idle kHYPE + PT value - debt)
        looper_net_value = max(0, looper_khype_balance + looper_pt_value - looper_debt)

        # 7. Total value = escrow kHYPE + looper net value
        total_value_underlying = escrow_khype_balance + looper_net_value

        # 8. Health factor monitoring (for looper position)
        health_threshold_warning = extras.get('health_factor_warning', 1.5)
        health_threshold_critical = extras.get('health_factor_critical', 1.2)

        health_factor, health_status = lending_utils.check_hyperlend_health_factor(
            w3=self.w3,
            aave_pool_abi=AAVE_V3_POOL_ABI,
            pool_address=hyperlend_pool,
            user=looper_address,
            warning_threshold=health_threshold_warning,
            critical_threshold=health_threshold_critical
        )

        # 9. Convert to wrapper shares
        wrapper_shares = conversion_utils.convert_underlying_to_wrapper_shares(
            w3=self.w3,
            wrapper_abi=WRAPPER_ABI,
            wrapper_address=self.wrapper_address,
            underlying_amount=total_value_underlying
        )

        # Build debt info string showing conversion if applicable
        if debt_feed and target_feed and looper_debt_raw > 0:
            debt_info = f"looper_debt={looper_debt_raw/1e18:.6f} wHYPE -> {looper_debt/1e18:.6f} kHYPE"
        else:
            debt_info = f"looper_debt={looper_debt/1e18:.6f}"

        logger.info(
            f"[{s.id_text}] pt_khype_looper: "
            f"escrow_khype={escrow_khype_balance/1e18:.6f}, "
            f"looper_khype={looper_khype_balance/1e18:.6f}, "
            f"looper_pt={looper_pt_balance/1e18:.6f}, "
            f"pt_price={pt_price/1e18:.6f}, "
            f"looper_pt_value={looper_pt_value/1e18:.6f}, "
            f"{debt_info}, "
            f"looper_net={looper_net_value/1e18:.6f}, "
            f"total_value={total_value_underlying/1e18:.6f}, "
            f"health_factor={health_factor/1e18:.4f} ({health_status}), "
            f"wrapper_shares={wrapper_shares/1e18:.6f}"
        )

        return int(wrapper_shares)

    def value_holdings_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'holdings'
        REFACTORED: Uses utils.conversion_utils ✅
        """
        extras = s.extras or {}
        holdings = extras.get('holdings', [])

        if not holdings:
            logger.warning(f"[{s.id_text}] No holdings configured")
            return 0

        total_value_in_wrapper = 0

        for holding in holdings:
            asset = holding.get('asset')
            if not asset:
                logger.error(f"[{s.id_text}] Holding missing 'asset' field")
                continue

            # Read asset balance
            balance = conversion_utils.read_underlying_balance(
                w3=self.w3,
                erc20_abi=ERC20_ABI,
                token=asset,
                holder=s.escrow
            )

            if balance == 0:
                continue

            # Convert asset to wrapper shares
            conversion_config = holding.get('conversion', {'method': 'none'})

            converted_value = conversion_utils.convert_asset_to_wrapper(
                w3=self.w3,
                wrapper_address=self.wrapper_address,
                amount=balance,
                from_asset=asset,
                conversion_config=conversion_config,
                convert_via_uniswap_v3_twap_func=lambda amt, from_asset, cfg: uniswap_utils.convert_via_uniswap_v3_twap(
                    self.w3, UNISWAP_V3_POOL_ABI, amt, from_asset, cfg,
                    lambda w3, v3_abi, v2_abi, pool, from_a, pool_type: conversion_utils.auto_detect_token_order(
                        w3, v3_abi, v2_abi, pool, from_a, pool_type
                    )
                ),
                convert_via_uniswap_v2_twap_func=lambda amt, from_asset, cfg: uniswap_utils.convert_via_uniswap_v2_twap(
                    self.w3, UNISWAP_V2_PAIR_ABI, amt, from_asset, cfg,
                    lambda w3, v3_abi, v2_abi, pool, from_a, pool_type: conversion_utils.auto_detect_token_order(
                        w3, v3_abi, v2_abi, pool, from_a, pool_type
                    )
                )
            )

            # Convert to wrapper shares if needed
            wrapper_shares = conversion_utils.convert_underlying_to_wrapper_shares(
                w3=self.w3,
                wrapper_abi=WRAPPER_ABI,
                wrapper_address=self.wrapper_address,
                underlying_amount=converted_value
            )

            total_value_in_wrapper += wrapper_shares

            logger.debug(
                f"[{s.id_text}] Holding {asset}: "
                f"balance={balance/1e18:.6f}, "
                f"wrapper_shares={wrapper_shares/1e18:.6f}"
            )

        logger.info(
            f"[{s.id_text}] holdings mode: "
            f"total_wrapper_shares={total_value_in_wrapper/1e18:.6f}"
        )

        return int(total_value_in_wrapper)

    def value_options_vault_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'options_vault'
        Values Rysk oToken positions using Black-Scholes pricing.

        Architecture:
        - Fetches positions from Rysk API (configurable: mainnet or testnet)
        - Gets IV from Rysk inventory API
        - Gets spot prices from Chainlink oracles OR Rysk index price (testnet)
        - Calculates option values using Black-Scholes
        - SHORT positions are treated as liabilities (subtracted)

        Configuration (extras):
            maker_wallet: Address holding oToken positions (required)
            oracles: Dict mapping symbol to Chainlink feed address (required for mainnet, optional for testnet)
                e.g., {"HYPE": "0xa5a72...", "kHYPE": "0xC66B2..."}
            wrapper_oracle: Chainlink feed for underlying→USD conversion (required unless use_rysk_index_price=true)
            risk_free_bps: Risk-free rate in basis points (default 0)
            default_iv_bps: Default IV in basis points (default 8000 = 80%)
            short_as_liability: Treat SHORT as liability (default true)
            api_timeout: API timeout in seconds (default 10)
            rysk_api_base: Base URL for Rysk API (default: https://v12.rysk.finance, for testnet use https://rip-testnet.rysk.finance)
            use_rysk_index_price: Use Rysk index price instead of Chainlink (default false, for testnet use true)
            underlying_symbol: Symbol for underlying in Rysk API (default "WETH", used when use_rysk_index_price=true)

        REFACTORED: Uses utils.options_utils ✅
        """
        extras = s.extras or {}

        # Required configuration
        maker_wallet = extras.get('maker_wallet')
        if not maker_wallet:
            logger.error(f"[{s.id_text}] Missing 'maker_wallet' in extras")
            return 0

        # Testnet configuration
        rysk_api_base = extras.get('rysk_api_base', 'https://v12.rysk.finance')
        use_rysk_index_price = extras.get('use_rysk_index_price', False)
        underlying_symbol = extras.get('underlying_symbol', 'WETH')

        # Oracles configuration (can be empty for testnet with use_rysk_index_price=true)
        oracles = extras.get('oracles', {})
        if not oracles and not use_rysk_index_price:
            logger.error(f"[{s.id_text}] Missing 'oracles' in extras (required unless use_rysk_index_price=true)")
            return 0

        # Wrapper oracle (required for mainnet, optional for testnet)
        wrapper_oracle = extras.get('wrapper_oracle')
        if not wrapper_oracle and not use_rysk_index_price:
            logger.error(f"[{s.id_text}] Missing 'wrapper_oracle' in extras (required unless use_rysk_index_price=true)")
            return 0

        # Optional configuration with defaults
        risk_free_rate = int(extras.get('risk_free_bps', 0)) / 10_000.0
        default_iv = int(extras.get('default_iv_bps', 8000)) / 10_000.0
        short_as_liability = extras.get('short_as_liability', True)
        api_timeout = int(extras.get('api_timeout', 10))

        logger.info(
            f"[{s.id_text}] options_vault config: "
            f"rysk_api={rysk_api_base}, use_rysk_index_price={use_rysk_index_price}, "
            f"escrow={s.escrow[:10]}..., underlying={s.underlying[:10]}..."
        )

        # Value options positions + underlying balance using utils
        wrapper_shares = options_utils.value_options_vault_positions(
            w3=self.w3,
            chainlink_abi=CHAINLINK_FEED_ABI,
            wrapper_abi=WRAPPER_ABI,
            erc20_abi=ERC20_ABI,
            maker_wallet=maker_wallet,
            escrow_address=s.escrow,
            underlying_address=s.underlying,
            oracles=oracles,
            wrapper_address=self.wrapper_address,
            wrapper_underlying_oracle=wrapper_oracle,
            risk_free_rate=risk_free_rate,
            default_iv=default_iv,
            short_as_liability=short_as_liability,
            api_timeout=api_timeout,
            rysk_api_base=rysk_api_base,
            use_rysk_index_price=use_rysk_index_price,
            underlying_symbol=underlying_symbol
        )

        logger.info(
            f"[{s.id_text}] options_vault mode: "
            f"maker_wallet={maker_wallet[:10]}..., "
            f"wrapper_shares={wrapper_shares/1e18:.6f}"
        )

        return int(wrapper_shares)

    def value_strategy_in_shares(self, s: StrategyConfig) -> int:
        """
        Main dispatcher for strategy valuation.
        Routes to appropriate mode handler.
        """
        mode = s.mode.lower()

        if mode == 'underlying_balance':
            return self.value_underlying_balance_mode(s)
        elif mode == 'pt_khype_loop':
            return self.value_pt_khype_loop_mode(s)
        elif mode == 'pt_khype_looper':
            return self.value_pt_khype_looper_mode(s)
        elif mode == 'holdings':
            return self.value_holdings_mode(s)
        elif mode == 'uniswap_v3':
            return self.value_uniswap_v3_mode(s)
        elif mode == 'options_vault':
            return self.value_options_vault_mode(s)
        else:
            raise ValueError(f"Unknown valuation mode: {mode}")

    # ========== CORE KEEPER LOGIC ==========

    def _next_nonce(self, strategy_id: bytes) -> int:
        """Get next nonce for strategy"""
        try:
            report = self.valuer.functions.getReport(strategy_id).call()
            current_nonce = report[3]
            return current_nonce + 1
        except Exception as e:
            logger.warning(f"Failed to read nonce, defaulting to 1: {e}")
            return 1

    def _sign_update(self, strategy_id: bytes, value: int, confidence: int, nonce: int, expiry: int) -> bytes:
        """
        Create EIP-191 signature for value update.

        The message format must match the contract's _verifySignatures():
            keccak256(abi.encode(strategyId, value, confidence, nonce, expiry, block.chainid, address(this)))

        Note: The 7th parameter (valuer contract address) is critical for signature validation.
        """
        message_hash = Web3.keccak(
            abi_encode(
                ['bytes32', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'address'],
                [strategy_id, value, confidence, nonce, expiry, self.chain_id, self.valuer_address]
            )
        )
        message = encode_defunct(primitive=message_hash)
        signed = self.account.sign_message(message)
        return signed.signature

    def _build_tx_params(self, gas_limit: Optional[int] = None, nonce_offset: int = 0) -> Dict[str, Any]:
        """
        Build transaction parameters with proper nonce and gas handling.

        Args:
            gas_limit: Optional gas limit override
            nonce_offset: Offset to add to nonce (for sequential txs in same block)
        """
        # Use 'pending' to include pending transactions in nonce calculation
        # This prevents "replacement transaction underpriced" errors
        nonce = self.w3.eth.get_transaction_count(self.account.address, 'pending') + nonce_offset

        # Get current gas prices from network and add buffer
        try:
            # Try to get current base fee and set appropriate prices
            latest_block = self.w3.eth.get_block('latest')
            base_fee = latest_block.get('baseFeePerGas', 0)

            if base_fee > 0:
                # EIP-1559: Set max fee to 2x base fee + priority fee for safety
                max_priority = Web3.to_wei(self.max_priority_gwei, 'gwei')
                max_fee = max(base_fee * 2 + max_priority, Web3.to_wei(self.max_fee_gwei, 'gwei'))
            else:
                # Fallback to configured values
                max_fee = Web3.to_wei(self.max_fee_gwei, 'gwei')
                max_priority = Web3.to_wei(self.max_priority_gwei, 'gwei')
        except Exception as e:
            logger.debug(f"Could not fetch dynamic gas price: {e}, using configured values")
            max_fee = Web3.to_wei(self.max_fee_gwei, 'gwei')
            max_priority = Web3.to_wei(self.max_priority_gwei, 'gwei')

        return {
            'from': self.account.address,
            'nonce': nonce,
            'gas': gas_limit or self.gas_limit,
            'maxFeePerGas': max_fee,
            'maxPriorityFeePerGas': max_priority,
            'chainId': self.chain_id
        }

    def _refresh_adapter_cache(self, s: StrategyConfig, nonce_offset: int = 0) -> bool:
        """SECURITY: Refresh adapter cache after valuer update"""
        if not s.adapter:
            return True

        try:
            adapter = self._adapter(s.adapter)
            tx = adapter.functions.refreshCachedValuation().build_transaction(
                self._build_tx_params(gas_limit=100_000, nonce_offset=nonce_offset)
            )
            signed_tx = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

            logger.info(f"[{s.id_text}] Refreshed adapter cache: {tx_hash.hex()}")
            return True

        except Exception as e:
            logger.error(f"[{s.id_text}] Failed to refresh adapter cache: {e}")
            return False

    def _compute_escrow_total_id(self, escrow_address: str) -> bytes:
        """
        Compute ESCROW_TOTAL_ID for an escrow address.

        This matches the Solidity computation:
            keccak256(abi.encodePacked("ESCROW_TOTAL", escrow_address))
        """
        escrow_bytes = bytes.fromhex(escrow_address[2:].lower())  # Remove 0x prefix
        packed = b"ESCROW_TOTAL" + escrow_bytes
        return Web3.keccak(packed)

    def _push_escrow_total(self, s: StrategyConfig, total_value: int, wait_for_receipt: bool = True) -> Optional[str]:
        """
        Push the ESCROW_TOTAL value to the valuer.

        This is a workaround for valuers that don't support registerEscrowTotal().
        The escrow's refreshCachedValuation() calls getValue(ESCROW_TOTAL_ID),
        so we push the total value directly to that ID.

        Args:
            s: Strategy configuration
            total_value: Total value to push
            wait_for_receipt: Whether to wait for the transaction receipt before returning
        """
        if not s.escrow:
            return None

        try:
            escrow_total_id = self._compute_escrow_total_id(s.escrow)
            nonce = self._next_nonce(escrow_total_id)
            expiry = int(time.time()) + self.ttl_seconds

            signature = self._sign_update(escrow_total_id, total_value, s.confidence, nonce, expiry)

            # No nonce_offset needed - chain state already reflects confirmed txs
            tx = self.valuer.functions.updateValue(
                escrow_total_id,
                total_value,
                s.confidence,
                nonce,
                expiry,
                [signature]
            ).build_transaction(self._build_tx_params())

            signed_tx = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

            logger.info(f"[{s.id_text}] Pushed ESCROW_TOTAL value={total_value}, tx={tx_hash.hex()}")

            # Wait for receipt if requested
            if wait_for_receipt:
                try:
                    receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=30)
                    if receipt['status'] == 1:
                        logger.debug(f"[{s.id_text}] ESCROW_TOTAL confirmed in block {receipt['blockNumber']}")
                    else:
                        logger.warning(f"[{s.id_text}] ESCROW_TOTAL reverted: {tx_hash.hex()}")
                except Exception as e:
                    logger.warning(f"[{s.id_text}] Could not wait for ESCROW_TOTAL receipt: {e}")

            return tx_hash.hex()

        except Exception as e:
            logger.warning(f"[{s.id_text}] Failed to push ESCROW_TOTAL: {e}")
            return None

    def push_strategy_value(self, s: StrategyConfig, retry_count: int = 0, max_retries: int = 3) -> Optional[str]:
        """
        Main method: Compute strategy value, sign, and push to valuer.

        Args:
            s: Strategy configuration
            retry_count: Current retry attempt (for internal use)
            max_retries: Maximum number of retry attempts
        """
        try:
            # Compute value
            value = self.value_strategy_in_shares(s)

            # Get nonce and prepare signature
            strategy_id = to_strategy_id(s.id_text)
            nonce = self._next_nonce(strategy_id)
            expiry = int(time.time()) + self.ttl_seconds

            signature = self._sign_update(strategy_id, value, s.confidence, nonce, expiry)

            # Build and send transaction
            tx = self.valuer.functions.updateValue(
                strategy_id,
                value,
                s.confidence,
                nonce,
                expiry,
                [signature]
            ).build_transaction(self._build_tx_params())

            signed_tx = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.raw_transaction)

            logger.info(f"[{s.id_text}] Pushed value={value}, tx={tx_hash.hex()}")

            # Wait for transaction to be mined before pushing ESCROW_TOTAL and refreshing cache
            try:
                receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=60)
                if receipt['status'] == 1:
                    logger.debug(f"[{s.id_text}] Transaction confirmed in block {receipt['blockNumber']}")

                    # Push ESCROW_TOTAL value (workaround for valuers without registerEscrowTotal)
                    # Note: For single-strategy escrows, ESCROW_TOTAL equals the strategy value
                    # This waits for receipt internally, so nonce will be updated on-chain
                    self._push_escrow_total(s, value, wait_for_receipt=True)

                    # Refresh adapter cache after confirmed (SECURITY)
                    # No nonce offset needed since we waited for ESCROW_TOTAL receipt
                    self._refresh_adapter_cache(s)
                else:
                    logger.warning(f"[{s.id_text}] Transaction reverted: {tx_hash.hex()}")
            except Exception as wait_error:
                # If we can't confirm the strategy TX, skip ESCROW_TOTAL and cache refresh
                # to avoid nonce conflicts. They'll be updated on the next cycle.
                logger.warning(f"[{s.id_text}] Could not confirm strategy TX: {wait_error}")
                logger.warning(f"[{s.id_text}] Skipping ESCROW_TOTAL and cache refresh - will retry next cycle")

            self.metrics.record_success(s.id_text, tx.get('gas', 0))
            return tx_hash.hex()

        except Exception as e:
            error_msg = str(e)

            # Retry on specific transient errors
            if retry_count < max_retries and any(err in error_msg.lower() for err in [
                'underpriced', 'nonce too low', 'already known', 'replacement transaction'
            ]):
                logger.warning(f"[{s.id_text}] Transient error, retrying ({retry_count + 1}/{max_retries}): {error_msg}")
                time.sleep(2 ** retry_count)  # Exponential backoff: 1s, 2s, 4s
                return self.push_strategy_value(s, retry_count + 1, max_retries)
            logger.error(f"[{s.id_text}] Failed to push value: {e}")
            self.metrics.record_failure(s.id_text, type(e).__name__)
            return None

    def run_once(self):
        """Run one update cycle for all strategies"""
        for s in self.strategies:
            self.metrics.record_attempt()
            self.push_strategy_value(s)

        self.update_cycle_count += 1
        if self.update_cycle_count % self.summary_interval == 0:
            self.metrics.log_summary()

    def run_forever(self):
        """Continuous keeper loop"""
        logger.info("Starting keeper in continuous mode...")

        while True:
            try:
                self.run_once()
                time.sleep(self.update_check_interval)
            except KeyboardInterrupt:
                logger.info("Keeper stopped by user")
                break
            except Exception as e:
                logger.error(f"Keeper cycle error: {e}", exc_info=True)
                time.sleep(self.update_check_interval)


def main():
    """Main entry point"""
    import sys

    if len(sys.argv) < 2:
        print("Usage: python OffchainValuationKeeper.py <config.json> [--mode once|forever]")
        sys.exit(1)

    config_path = sys.argv[1]
    mode = sys.argv[2] if len(sys.argv) > 2 else "--mode"
    mode_val = sys.argv[3] if len(sys.argv) > 3 else "forever"

    keeper = OffchainValuationKeeper(config_path)

    if mode_val == "once":
        keeper.run_once()
        keeper.metrics.log_summary()
    else:
        keeper.run_forever()


if __name__ == "__main__":
    main()
