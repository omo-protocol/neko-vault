#!/usr/bin/env python3
"""
OffchainValuationKeeper - Off-chain service for strategy valuation

Refined to:
- Compute strategy value in WRAPPER UNITS (wrapper shares), consistent with UniversalValuerOffchain
- Create correct EIP-191 signatures matching on-chain validation
- Submit updateValue with monotonically increasing nonce and TTL expiry
- Support modes:
  * underlying_balance: read underlying (rebasing) balance at escrow and convert to wrapper shares
  * pt_khype_loop: production implementation for leveraged PT strategies
  * holdings: sum multiple token holdings with signs (assets +1, liabilities -1)

Important:
- The on-chain valuer adds idle wrapper balance itself (IERC20(asset).balanceOf(escrow)) in getTotalValue.
  Do NOT include idle wrapper balance in the off-chain reported value to avoid double-counting.
- strategyId is computed as keccak256(text_id), matching the docs.

Security:
- CRITICAL: Both 'underlying_balance' and 'holdings' modes validate against double counting
- underlying_balance: Rejects configurations where underlying == wrapper
- holdings: Rejects holdings arrays that include the wrapper asset
- These validations prevent the idle escrow balance from being counted twice in getTotalValue()
"""

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
    # Required for proper abi.encode() matching Solidity encoding
    from eth_abi import encode as abi_encode
except Exception as e:
    raise RuntimeError("eth-abi must be installed: pip install eth-abi") from e


# Configure logging
logging.basicConfig(
    level=os.environ.get("KEEPER_LOG_LEVEL", "INFO"),
    format="%(asctime)s - %(name)s - %(levelname)s - %(message)s"
)
logger = logging.getLogger("OffchainValuationKeeper")


# Metrics tracking
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


# Minimal ABIs
ERC20_ABI = [
    {"name": "decimals", "inputs": [], "outputs": [{"type": "uint8"}], "stateMutability": "view", "type": "function"},
    {"name": "balanceOf", "inputs": [{"name": "account", "type": "address"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

WRAPPER_ABI = [
    {"name": "convertToShares", "inputs": [{"name": "assets", "type": "uint256"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "convertToAssets", "inputs": [{"name": "shares", "type": "uint256"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
]

PENDLE_ORACLE_ABI = [
    {"name": "getPtToAssetRate", "inputs": [
        {"name": "market", "type": "address"},
        {"name": "duration", "type": "uint32"}
    ], "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "getOracleState", "inputs": [
        {"name": "market", "type": "address"},
        {"name": "duration", "type": "uint32"}
    ], "outputs": [
        {"name": "increaseCardinalityRequired", "type": "bool"},
        {"name": "cardinalityRequired", "type": "uint16"},
        {"name": "oldestObservationSatisfied", "type": "bool"}
    ], "stateMutability": "view", "type": "function"},
]

FELIX_ABI = [
    {"name": "position", "inputs": [
        {"name": "id", "type": "bytes32"},
        {"name": "user", "type": "address"}
    ], "outputs": [
        {"name": "supplyShares", "type": "uint256"},
        {"name": "borrowShares", "type": "uint128"},
        {"name": "collateral", "type": "uint128"}
    ], "stateMutability": "view", "type": "function"},
    {"name": "totalBorrowAssets", "inputs": [{"name": "id", "type": "bytes32"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "totalBorrowShares", "inputs": [{"name": "id", "type": "bytes32"}],
     "outputs": [{"type": "uint256"}], "stateMutability": "view", "type": "function"},
    {"name": "market", "inputs": [{"name": "id", "type": "bytes32"}], "outputs": [
        {"name": "totalSupplyAssets", "type": "uint128"},
        {"name": "totalSupplyShares", "type": "uint128"},
        {"name": "totalBorrowAssets", "type": "uint128"},
        {"name": "totalBorrowShares", "type": "uint128"},
        {"name": "lastUpdate", "type": "uint128"},
        {"name": "fee", "type": "uint128"}
    ], "stateMutability": "view", "type": "function"},
]

VALUER_ABI = [
    {"name": "getReport", "inputs": [{"name": "strategyId", "type": "bytes32"}], "outputs": [{
        "components": [
            {"name": "value", "type": "uint256"},
            {"name": "timestamp", "type": "uint256"},
            {"name": "confidence", "type": "uint256"},
            {"name": "nonce", "type": "uint256"},
            {"name": "isPush", "type": "bool"},
            {"name": "lastUpdater", "type": "address"},
        ],
        "type": "tuple"
    }], "stateMutability": "view", "type": "function"},
    {"name": "updateValue", "inputs": [
        {"name": "strategyId", "type": "bytes32"},
        {"name": "value", "type": "uint256"},
        {"name": "confidence", "type": "uint256"},
        {"name": "nonce", "type": "uint256"},
        {"name": "expiry", "type": "uint256"},
        {"name": "signatures", "type": "bytes[]"}
    ], "outputs": [], "stateMutability": "nonpayable", "type": "function"},
    {"name": "requiredWeight", "inputs": [], "outputs": [{"type": "uint256"}], "stateMutability": "view",
     "type": "function"},
    {"name": "owner", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
    {"name": "asset", "inputs": [], "outputs": [{"type": "address"}], "stateMutability": "view", "type": "function"},
]


@dataclass
class StrategyConfig:
    id_text: str                 # e.g., "PT_KHYPE_LOOP"
    mode: str                    # "underlying_balance" | "pt_khype_loop"
    escrow: str                  # escrow address (checksum)
    underlying: str              # rebasing token (e.g., stETH), checksum
    confidence: int = 95         # confidence to attach to the update
    # Optional per-mode extras (dict bag of values)
    extras: Dict[str, Any] = None


class OffchainValuationKeeper:
    def __init__(self, config_path: str):
        """Initialize the keeper with configuration"""
        with open(config_path, 'r') as f:
            self.config = json.load(f)

        rpc_url = self.config['rpc_url']
        # Add timeout to HTTP provider to prevent hanging
        request_kwargs = {'timeout': 30}  # 30 second timeout for RPC calls
        self.w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs=request_kwargs))
        if not self.w3.is_connected():
            raise RuntimeError(f"Failed to connect to RPC at {rpc_url}")

        # Load signer account (env override > config)
        pk = os.environ.get("KEEPER_PRIVATE_KEY") or self.config.get('signer_private_key') or self.config.get('private_key')
        if not pk:
            raise RuntimeError("Missing keeper private key (env KEEPER_PRIVATE_KEY or config.signer_private_key)")
        self.account = Account.from_key(pk)
        logger.info(f"Keeper signer: {self.account.address}")

        # Load contracts
        self.valuer_address = Web3.to_checksum_address(self.config['valuer_address'])
        self.valuer = self.w3.eth.contract(address=self.valuer_address, abi=VALUER_ABI)

        # Wrapper used for unit conversion into SHARES (the vault's asset)
        self.wrapper_address = Web3.to_checksum_address(
            self.config.get('wrapper_address') or self.valuer.functions.asset().call()
        )
        self.wrapper = self.w3.eth.contract(address=self.wrapper_address, abi=WRAPPER_ABI)
        logger.info(f"Valuer: {self.valuer_address}, Wrapper (asset): {self.wrapper_address}")

        # Chain id for signing
        self.chain_id = self.config.get("chain_id", self.w3.eth.chain_id)

        # Keeper settings
        ks = self.config.get('keeper_settings', {})
        self.update_check_interval = int(ks.get('update_check_interval', 60))
        self.ttl_seconds = int(ks.get('ttl', 300))  # expiry TTL; must be <= MAX_SIGNATURE_AGE (1h) on-chain
        self.gas_limit = int(ks.get('gas_limit', 350_000))
        self.max_fee_gwei = float(ks.get('max_fee_gwei', 20.0))
        self.max_priority_gwei = float(ks.get('max_priority_gwei', 2.0))

        # Strategies
        self.strategies: List[StrategyConfig] = []
        for s in self.config.get('strategies', []):
            # Support both old and new config formats
            escrow_addr = s.get('escrow_address') or s.get('escrow')
            underlying_addr = s.get('underlying_address') or s.get('underlying')

            # Determine mode
            mode = s.get('mode', 'underlying_balance')

            # If holdings array is present, use holdings mode
            if 'holdings' in s:
                mode = 'holdings'
                extras = {'holdings': s['holdings']}
                # Add other extras if present
                if 'extras' in s:
                    extras.update(s['extras'])
            else:
                extras = s.get('extras', {})

            self.strategies.append(
                StrategyConfig(
                    id_text=s['id'],
                    mode=mode,
                    escrow=Web3.to_checksum_address(escrow_addr) if escrow_addr else '',
                    underlying=Web3.to_checksum_address(underlying_addr) if underlying_addr else '',
                    confidence=int(s.get('confidence') or s.get('min_confidence', 95)),
                    extras=extras
                )
            )

        # Caches
        self._erc20_cache: Dict[str, Tuple[Any, int]] = {}

        # Metrics
        self.metrics = KeeperMetrics()

        # Summary logging interval (log every 10 update cycles)
        self.summary_interval = 10
        self.update_cycle_count = 0

    def _erc20(self, addr: str):
        cs = Web3.to_checksum_address(addr)
        if cs in self._erc20_cache:
            return self._erc20_cache[cs]
        c = self.w3.eth.contract(address=cs, abi=ERC20_ABI)
        try:
            dec = int(c.functions.decimals().call())
        except Exception:
            dec = 18
        self._erc20_cache[cs] = (c, dec)
        return self._erc20_cache[cs]

    @staticmethod
    def to_strategy_id(text_id: str) -> bytes:
        """Compute bytes32 strategyId = keccak256(text_id)"""
        return Web3.keccak(text=text_id)

    def _convert_underlying_to_wrapper_shares(self, underlying_amount: int) -> int:
        """Convert underlying units (rebasing token) to wrapper shares using on-chain convertToShares."""
        if underlying_amount <= 0:
            return 0
        try:
            # Try calling convertToShares (for ERC4626 vaults like wstETH)
            shares = self.wrapper.functions.convertToShares(int(underlying_amount)).call()
            return int(shares)
        except Exception as e:
            # For standard ERC20 tokens (like kHYPE), underlying == shares (1:1)
            logger.debug(f"convertToShares not available (standard ERC20), using 1:1 ratio: {e}")
            return int(underlying_amount)

    def _read_underlying_balance(self, token: str, holder: str) -> int:
        """Read ERC20 balanceOf(holder) for token."""
        erc, _ = self._erc20(token)
        try:
            return int(erc.functions.balanceOf(holder).call())
        except Exception as e:
            raise RuntimeError(f"balanceOf({token}, {holder}) failed: {e}")

    def _get_pt_price(self, market: str, oracle: str) -> int:
        """
        Get PT to asset exchange rate from Pendle oracle.

        Args:
            market: Pendle market address
            oracle: Pendle PT oracle address

        Returns:
            PT price ratio in 18 decimals (1e18 = 1:1, 0.95e18 = 95% of underlying)
        """
        if not market or not oracle:
            logger.warning("Missing Pendle market or oracle address, using default 0.95 ratio")
            return int(0.95 * 10**18)

        try:
            market_cs = Web3.to_checksum_address(market)
            oracle_cs = Web3.to_checksum_address(oracle)
            oracle_contract = self.w3.eth.contract(address=oracle_cs, abi=PENDLE_ORACLE_ABI)

            # Use 30 minute TWAP for stable pricing
            duration = 1800  # 30 minutes in seconds

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

            # Sanity check: PT price should be between 0.5 and 1.05 (50% to 105%)
            if pt_rate < int(0.5 * 10**18) or pt_rate > int(1.05 * 10**18):
                logger.warning(
                    f"PT price {pt_rate/1e18:.4f} outside expected range [0.5, 1.05], "
                    f"using default 0.95"
                )
                return int(0.95 * 10**18)

            logger.debug(f"PT price from oracle: {pt_rate/1e18:.6f}")
            return pt_rate

        except Exception as e:
            logger.error(f"Error querying Pendle oracle: {e}, using default 0.95 ratio")
            return int(0.95 * 10**18)

    def _get_felix_debt(self, felix: str, market_id: str, user: str) -> int:
        """
        Get user's debt from Felix lending (Morpho Blue fork).

        Args:
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
            felix_contract = self.w3.eth.contract(address=felix_cs, abi=FELIX_ABI)

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
            # Try direct totalBorrowAssets call first (more efficient)
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
            logger.error(f"Error querying Felix debt: {e}", exc_info=True)
            # Return 0 to allow strategy to continue (conservative approach)
            return 0

    # ------------- Valuation modes -------------

    def value_underlying_balance_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'underlying_balance'
        - Read escrow's balance of the underlying (rebasing) token
        - Convert to wrapper shares via convertToShares

        ⚠️  CRITICAL SECURITY: Only use when underlying ≠ wrapper!
            Valid example: stETH (underlying) → wstETH (wrapper)
            Invalid example: kHYPE (underlying) == kHYPE (wrapper) → DOUBLE COUNTING

            The on-chain getTotalValue() adds idle wrapper balance automatically.
            If you report the wrapper balance here, it gets counted twice.
        """
        # SECURITY FIX: Prevent double counting when underlying == wrapper
        # Use case-insensitive comparison to handle checksum variations
        underlying_normalized = s.underlying.lower()
        wrapper_normalized = self.wrapper_address.lower()

        if underlying_normalized == wrapper_normalized:
            raise RuntimeError(
                f"\n{'='*70}\n"
                f"⚠️  DOUBLE COUNTING VULNERABILITY DETECTED\n"
                f"{'='*70}\n"
                f"Strategy: {s.id_text}\n"
                f"Mode: underlying_balance\n"
                f"Problem: underlying ({s.underlying}) == wrapper ({self.wrapper_address})\n"
                f"\n"
                f"This causes the escrow's idle balance to be counted TWICE:\n"
                f"  1. Once in your strategy value (from balanceOf)\n"
                f"  2. Once in getTotalValue() idle assets (automatic)\n"
                f"\n"
                f"Solutions:\n"
                f"  A. Use 'pt_khype_loop' mode for leveraged PT strategies\n"
                f"  B. Use 'holdings' mode with explicit token list (excluding wrapper)\n"
                f"  C. Use different underlying token (e.g., stETH with wstETH wrapper)\n"
                f"\n"
                f"The 'underlying_balance' mode is designed for rebasing tokens where\n"
                f"underlying ≠ wrapper (e.g., stETH → wstETH conversions).\n"
                f"{'='*70}\n"
            )

        underlying_bal = self._read_underlying_balance(s.underlying, s.escrow)
        shares = self._convert_underlying_to_wrapper_shares(underlying_bal)
        logger.debug(f"[{s.id_text}] underlying_balance: underlying={underlying_bal}, shares={shares}")
        return shares

    def value_pt_khype_loop_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'pt_khype_loop'
        Production implementation for PT kHYPE leveraged loop strategy.

        Strategy structure:
        1. Escrow holds PT-kHYPE tokens (collateral)
        2. PT-kHYPE deposited in Felix lending as collateral
        3. kHYPE borrowed against PT-kHYPE collateral
        4. Loop repeats for leverage

        Valuation:
        - Collateral value = PT balance * PT price (from Pendle oracle)
        - Debt value = borrowed kHYPE (from Felix lending)
        - Net value = collateral_value - debt_value
        - Convert to wrapper shares
        """
        try:
            extras = s.extras or {}

            # Validate required config
            pt_address = extras.get('pt_khype_address')
            felix_lending = extras.get('felix_lending')
            pendle_market = extras.get('pendle_market')
            pt_oracle = extras.get('pt_oracle')
            felix_market_id = extras.get('felix_market_id')

            if not pt_address:
                logger.warning(f"[{s.id_text}] Missing pt_khype_address")
                return 0

            # 1. Get PT-kHYPE balance held by escrow
            logger.debug(f"[{s.id_text}] Querying PT balance at {s.escrow}...")
            pt_token, _ = self._erc20(pt_address)
            pt_balance = int(pt_token.functions.balanceOf(s.escrow).call())
            logger.debug(f"[{s.id_text}] PT balance: {pt_balance / 1e18:.6f}")

            if pt_balance == 0:
                logger.info(f"[{s.id_text}] No PT balance, returning 0")
                return 0

            # 2. Get PT price from Pendle oracle
            logger.debug(f"[{s.id_text}] Querying Pendle oracle for PT price...")
            pt_price_ratio = self._get_pt_price(pendle_market, pt_oracle)
            logger.debug(f"[{s.id_text}] PT price: {pt_price_ratio / 1e18:.4f}")

            # 3. Calculate collateral value in underlying kHYPE
            collateral_value_underlying = (pt_balance * pt_price_ratio) // 10**18
            logger.debug(f"[{s.id_text}] Collateral value: {collateral_value_underlying / 1e18:.4f} kHYPE")

            # 4. Get debt from Felix lending
            logger.debug(f"[{s.id_text}] Querying Felix debt...")
            debt_underlying = self._get_felix_debt(felix_lending, felix_market_id, s.escrow)
            logger.debug(f"[{s.id_text}] Debt: {debt_underlying / 1e18:.4f} kHYPE")

            # 5. Calculate net value (protect against underwater positions)
            net_underlying = collateral_value_underlying - debt_underlying
            if net_underlying < 0:
                logger.warning(
                    f"[{s.id_text}] UNDERWATER POSITION! "
                    f"collateral={collateral_value_underlying/1e18:.4f}, "
                    f"debt={debt_underlying/1e18:.4f}"
                )
                # Return 0 for underwater positions to prevent bad debt reporting
                return 0

            # 6. Convert to wrapper shares (vault's asset denomination)
            shares = self._convert_underlying_to_wrapper_shares(net_underlying)

            logger.info(
                f"[{s.id_text}] PT kHYPE Loop: "
                f"pt_balance={pt_balance/1e18:.6f} PT, "
                f"pt_price={pt_price_ratio/1e18:.4f}, "
                f"collateral={collateral_value_underlying/1e18:.4f} kHYPE, "
                f"debt={debt_underlying/1e18:.4f} kHYPE, "
                f"net={net_underlying/1e18:.4f} kHYPE, "
                f"shares={shares/1e18:.6f} wrapper"
            )
            return shares

        except Exception as e:
            logger.error(f"Error in pt_khype_loop valuation for {s.id_text}: {e}", exc_info=True)
            return 0

    def value_holdings_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'holdings'
        - Sum up all holdings with their signs (+1 for assets, -1 for liabilities)
        - Supports multiple token types (erc20, pt, etc.)
        - Convert total underlying to wrapper shares

        ⚠️  CRITICAL SECURITY: Do NOT include wrapper asset in holdings array!
            The on-chain getTotalValue() adds idle wrapper balance automatically.
            Including it here causes double counting.

            Valid example:
            holdings: [
                {"token": "PT-kHYPE", "sign": 1},      # Collateral
                {"token": "borrowed-kHYPE", "sign": -1}  # Debt
            ]
            # Note: kHYPE wrapper is NOT listed - added automatically by getTotalValue()

            Invalid example (causes double counting):
            holdings: [
                {"token": "PT-kHYPE", "sign": 1},
                {"token": "kHYPE", "sign": 1},  # ❌ WRONG - this is the wrapper!
                {"token": "borrowed-kHYPE", "sign": -1}
            ]
        """
        try:
            holdings = s.extras.get('holdings', []) if s.extras else []
            total_underlying = 0

            # SECURITY FIX: Validate holdings don't include wrapper asset
            wrapper_normalized = self.wrapper_address.lower()

            for holding in holdings:
                holding_type = holding.get('type', 'erc20')
                token_addr = holding.get('token')
                sign = holding.get('sign', 1)

                if not token_addr:
                    continue

                # Normalize token address for comparison
                token_normalized = Web3.to_checksum_address(token_addr).lower()

                # Check if this holding is the wrapper asset
                if token_normalized == wrapper_normalized:
                    raise RuntimeError(
                        f"\n{'='*70}\n"
                        f"⚠️  DOUBLE COUNTING VULNERABILITY DETECTED\n"
                        f"{'='*70}\n"
                        f"Strategy: {s.id_text}\n"
                        f"Mode: holdings\n"
                        f"Problem: Holdings array includes wrapper asset\n"
                        f"  Wrapper: {self.wrapper_address}\n"
                        f"  Holding: {token_addr} (sign={sign})\n"
                        f"\n"
                        f"This causes the escrow's idle balance to be counted TWICE:\n"
                        f"  1. Once in your holdings calculation (from balanceOf)\n"
                        f"  2. Once in getTotalValue() idle assets (automatic)\n"
                        f"\n"
                        f"Solution: REMOVE wrapper asset from holdings array\n"
                        f"  getTotalValue() automatically adds: IERC20(asset).balanceOf(escrow)\n"
                        f"  You should only list tokens deployed in external protocols.\n"
                        f"\n"
                        f"Correct holdings configuration:\n"
                        f"  holdings: [\n"
                        f"    {{\"token\": \"PT-Token\", \"sign\": 1}},    # Collateral in protocol\n"
                        f"    {{\"token\": \"Borrowed\", \"sign\": -1}}    # Debt in protocol\n"
                        f"  ]\n"
                        f"  # Idle wrapper balance is added automatically - don't list it!\n"
                        f"{'='*70}\n"
                    )

                # Get token balance
                token, _ = self._erc20(token_addr)
                balance = int(token.functions.balanceOf(s.escrow).call())

                # Apply sign (1 for assets, -1 for liabilities)
                total_underlying += sign * balance

                logger.debug(f"[{s.id_text}] holding: token={token_addr}, balance={balance}, sign={sign}")

            # Ensure non-negative
            if total_underlying < 0:
                logger.warning(
                    f"[{s.id_text}] Negative holdings total ({total_underlying}), "
                    f"clamping to 0 (strategy may be underwater)"
                )
                total_underlying = 0

            # Convert to wrapper shares
            shares = self._convert_underlying_to_wrapper_shares(total_underlying)
            logger.debug(f"[{s.id_text}] holdings total: underlying={total_underlying}, shares={shares}")
            return shares

        except RuntimeError:
            # Re-raise validation errors (don't catch our own security checks)
            raise
        except Exception as e:
            logger.error(f"Error in holdings valuation: {e}", exc_info=True)
            return 0

    def value_strategy_in_shares(self, s: StrategyConfig) -> int:
        mode = s.mode.lower()
        if mode == "underlying_balance":
            return self.value_underlying_balance_mode(s)
        elif mode == "pt_khype_loop":
            return self.value_pt_khype_loop_mode(s)
        elif mode == "holdings":
            return self.value_holdings_mode(s)
        else:
            raise RuntimeError(f"Unsupported strategy mode: {s.mode}")

    # ------------- Signing and submitting -------------

    def _next_nonce(self, strategy_id: bytes) -> int:
        """Fetch report and return nonce+1."""
        try:
            report = self.valuer.functions.getReport(strategy_id).call()
            # report struct: (value, timestamp, confidence, nonce, isPush, lastUpdater)
            return int(report[3]) + 1
        except Exception as e:
            logger.warning(f"getReport failed for {strategy_id.hex()}: {e}, using nonce=1")
            return 1

    def _sign_update(self, strategy_id: bytes, value: int, confidence: int, nonce: int, expiry: int) -> bytes:
        """
        Match UniversalValuerOffchain._verifySignatures:
        keccak256(abi.encode(strategyId, value, confidence, nonce, expiry, chainid, valuerAddress))
        Then EIP-191 prefix and sign.
        """
        payload = abi_encode(
            ['bytes32', 'uint256', 'uint256', 'uint256', 'uint256', 'uint256', 'address'],
            [strategy_id, value, confidence, nonce, expiry, int(self.chain_id), self.valuer_address]
        )
        hashed = Web3.keccak(payload)
        msg = encode_defunct(primitive=hashed)
        signed = Account.sign_message(msg, private_key=self.account.key)
        return signed.signature  # bytes

    def _build_tx_params(self) -> Dict[str, Any]:
        """Build EIP-1559 gas params with sane defaults."""
        max_fee = self.w3.to_wei(self.max_fee_gwei, "gwei")
        max_prio = self.w3.to_wei(self.max_priority_gwei, "gwei")
        nonce = self.w3.eth.get_transaction_count(self.account.address)
        return {
            "chainId": self.chain_id,
            "from": self.account.address,
            "nonce": nonce,
            "gas": self.gas_limit,
            "maxFeePerGas": max_fee,
            "maxPriorityFeePerGas": max_prio,
        }

    def push_strategy_value(self, s: StrategyConfig, retry_count: int = 0) -> Optional[str]:
        """
        Compute value in shares, sign, and submit updateValue with retry logic.

        Args:
            s: Strategy configuration
            retry_count: Current retry attempt (for internal use)

        Returns:
            Transaction hash if successful, None otherwise
        """
        max_retries = 3
        retry_delay = 5  # seconds

        # Record attempt
        if retry_count == 0:
            self.metrics.record_attempt()

        try:
            strategy_id = self.to_strategy_id(s.id_text)

            # Compute strategy value
            value_shares = self.value_strategy_in_shares(s)

            # Skip update if value is 0 and previous value was also 0
            try:
                report = self.valuer.functions.getReport(strategy_id).call()
                prev_value = int(report[0])
                if value_shares == 0 and prev_value == 0:
                    logger.debug(f"[{s.id_text}] Skipping update, value unchanged at 0")
                    return None
            except Exception:
                pass  # First time update or error reading report

            # Confidence
            conf = int(s.confidence)

            # Nonce and expiry (TTL)
            nonce = self._next_nonce(strategy_id)
            expiry = int(time.time()) + self.ttl_seconds

            # Sign update
            sig = self._sign_update(strategy_id, value_shares, conf, nonce, expiry)

            # Build and send transaction
            tx_params = self._build_tx_params()
            func = self.valuer.functions.updateValue(strategy_id, value_shares, conf, nonce, expiry, [sig])
            tx = func.build_transaction(tx_params)
            signed = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed.raw_transaction)

            # Wait for receipt to confirm
            receipt = self.w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

            if receipt['status'] == 1:
                h = tx_hash.hex()
                gas_used = int(receipt.get('gasUsed', 0))

                # Record success
                self.metrics.record_success(s.id_text, gas_used)

                logger.info(
                    f"✓ Update successful: {s.id_text}, "
                    f"value={value_shares/1e18:.6f} shares, "
                    f"nonce={nonce}, conf={conf}%, gas={gas_used:,}, tx={h}"
                )
                return h
            else:
                # Record failure
                self.metrics.record_failure(s.id_text, "tx_reverted")
                logger.error(f"Transaction failed: {s.id_text}, receipt={receipt}")
                return None

        except ValueError as e:
            # Handle RPC errors with retry
            error_msg = str(e)
            logger.warning(f"RPC error for {s.id_text}: {error_msg}")

            # Check if error is retryable
            retryable_errors = [
                "nonce too low",
                "replacement transaction underpriced",
                "already known",
                "timeout",
                "connection"
            ]

            is_retryable = any(err in error_msg.lower() for err in retryable_errors)

            if is_retryable and retry_count < max_retries:
                logger.info(f"Retrying {s.id_text} (attempt {retry_count + 1}/{max_retries})")
                time.sleep(retry_delay * (retry_count + 1))  # Exponential backoff
                return self.push_strategy_value(s, retry_count + 1)

            # Record failure
            error_type = "rpc_error"
            for err in retryable_errors:
                if err in error_msg.lower():
                    error_type = err.replace(" ", "_")
                    break
            self.metrics.record_failure(s.id_text, error_type)

            logger.error(f"push_strategy_value failed for {s.id_text}: {e}", exc_info=True)
            return None

        except Exception as e:
            # Record failure
            self.metrics.record_failure(s.id_text, type(e).__name__)
            logger.error(f"push_strategy_value failed for {s.id_text}: {e}", exc_info=True)
            return None

    # ------------- Run loops -------------

    def run_once(self):
        """Execute one update cycle for all strategies"""
        for s in self.strategies:
            self.push_strategy_value(s)

        # Increment cycle count and log summary periodically
        self.update_cycle_count += 1
        if self.update_cycle_count % self.summary_interval == 0:
            self.metrics.log_summary()

    def run_forever(self):
        """Run keeper loop indefinitely with monitoring"""
        logger.info("=" * 60)
        logger.info("Starting OffchainValuationKeeper")
        logger.info("=" * 60)
        logger.info(f"RPC: {self.config['rpc_url']}")
        logger.info(f"Valuer: {self.valuer_address}")
        logger.info(f"Wrapper: {self.wrapper_address}")
        logger.info(f"Signer: {self.account.address}")
        logger.info(f"Strategies: {len(self.strategies)}")
        for s in self.strategies:
            logger.info(f"  - {s.id_text} ({s.mode})")
        logger.info(f"Update interval: {self.update_check_interval}s")
        logger.info("=" * 60)

        while True:
            start = time.time()
            try:
                self.run_once()
            except KeyboardInterrupt:
                logger.info("\nShutdown requested by user")
                self.metrics.log_summary()
                break
            except Exception as e:
                logger.error(f"run_once error: {e}", exc_info=True)
                self.metrics.record_failure("system", "run_once_error")

            # Sleep the remainder of the interval
            elapsed = time.time() - start
            sleep_s = max(1.0, self.update_check_interval - elapsed)
            logger.debug(f"Cycle completed in {elapsed:.2f}s, sleeping {sleep_s:.2f}s")
            time.sleep(sleep_s)


def main():
    config_path = sys.argv[1] if len(sys.argv) > 1 else 'keeper_config.json'
    keeper = OffchainValuationKeeper(config_path)
    mode = keeper.config.get("mode", "loop").lower()
    if mode == "once":
        keeper.run_once()
    else:
        keeper.run_forever()


if __name__ == "__main__":
    main()