#!/usr/bin/env python3
"""
OffchainValuationKeeper - Off-chain service for strategy valuation

Refined to:
- Compute strategy value in WRAPPER UNITS (wrapper shares), consistent with UniversalValuerOffchain
- Create correct EIP-191 signatures matching on-chain validation
- Submit updateValue with monotonically increasing nonce and TTL expiry
- Support modes:
  * underlying_balance: read underlying (rebasing) balance at escrow and convert to wrapper shares
  * pt_khype_loop: example stub that converts a computed underlying net to wrapper shares

Important:
- The on-chain valuer adds idle wrapper balance itself (IERC20(asset).balanceOf(escrow)) in getTotalValue.
  Do NOT include idle wrapper balance in the off-chain reported value to avoid double-counting.
- strategyId is computed as keccak256(text_id), matching the docs.
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
        self.w3 = Web3(Web3.HTTPProvider(rpc_url))
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
            shares = self.wrapper.functions.convertToShares(int(underlying_amount)).call()
            return int(shares)
        except Exception as e:
            raise RuntimeError(f"convertToShares failed: {e}")

    def _read_underlying_balance(self, token: str, holder: str) -> int:
        """Read ERC20 balanceOf(holder) for token."""
        erc, _ = self._erc20(token)
        try:
            return int(erc.functions.balanceOf(holder).call())
        except Exception as e:
            raise RuntimeError(f"balanceOf({token}, {holder}) failed: {e}")

    # ------------- Valuation modes -------------

    def value_underlying_balance_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'underlying_balance'
        - Read escrow's balance of the underlying (rebasing) token
        - Convert to wrapper shares via convertToShares
        """
        underlying_bal = self._read_underlying_balance(s.underlying, s.escrow)
        shares = self._convert_underlying_to_wrapper_shares(underlying_bal)
        logger.debug(f"[{s.id_text}] underlying_balance: underlying={underlying_bal}, shares={shares}")
        return shares

    def value_pt_khype_loop_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'pt_khype_loop'
        - Get PT balance from escrow
        - Get PT price from Pendle oracle
        - Calculate collateral value in underlying
        - Get debt from Felix lending (if applicable)
        - Compute net underlying value
        - Convert to wrapper shares
        """
        try:
            extras = s.extras or {}
            pt_address = extras.get('pt_khype_address')
            felix_lending = extras.get('felix_lending')
            pendle_router = extras.get('pendle_router')

            # Get PT balance held by escrow
            pt_balance = 0
            if pt_address:
                pt_token, _ = self._erc20(pt_address)
                pt_balance = int(pt_token.functions.balanceOf(s.escrow).call())

            # Get PT price (simplified - in production, query Pendle oracle)
            # For now, assume PT trades at 0.95 of underlying
            pt_price_ratio = int(0.95 * 10**18)

            # Calculate collateral value in underlying
            collateral_value_underlying = (pt_balance * pt_price_ratio) // 10**18

            # Get debt from Felix (if address provided and not zero)
            debt_underlying = 0
            if felix_lending and felix_lending != "0x0000000000000000000000000000000000000000":
                # In production, query Felix lending contract for debt position
                # For now, assume no debt
                pass

            # Calculate net value
            net_underlying = collateral_value_underlying - debt_underlying
            if net_underlying < 0:
                net_underlying = 0

            # Convert to wrapper shares
            shares = self._convert_underlying_to_wrapper_shares(net_underlying)

            logger.debug(
                f"[{s.id_text}] pt_khype_loop: "
                f"pt_balance={pt_balance}, "
                f"collateral={collateral_value_underlying}, "
                f"debt={debt_underlying}, "
                f"net_underlying={net_underlying}, "
                f"shares={shares}"
            )
            return shares

        except Exception as e:
            logger.error(f"Error in pt_khype_loop valuation: {e}")
            return 0

    def value_holdings_mode(self, s: StrategyConfig) -> int:
        """
        Mode: 'holdings'
        - Sum up all holdings with their signs (+1 for assets, -1 for liabilities)
        - Supports multiple token types (erc20, pt, etc.)
        - Convert total underlying to wrapper shares
        """
        try:
            holdings = s.extras.get('holdings', []) if s.extras else []
            total_underlying = 0

            for holding in holdings:
                holding_type = holding.get('type', 'erc20')
                token_addr = holding.get('token')
                sign = holding.get('sign', 1)

                if not token_addr:
                    continue

                # Get token balance
                token, _ = self._erc20(token_addr)
                balance = int(token.functions.balanceOf(s.escrow).call())

                # Apply sign (1 for assets, -1 for liabilities)
                total_underlying += sign * balance

                logger.debug(f"[{s.id_text}] holding: token={token_addr}, balance={balance}, sign={sign}")

            # Ensure non-negative
            if total_underlying < 0:
                total_underlying = 0

            # Convert to wrapper shares
            shares = self._convert_underlying_to_wrapper_shares(total_underlying)
            logger.debug(f"[{s.id_text}] holdings total: underlying={total_underlying}, shares={shares}")
            return shares

        except Exception as e:
            logger.error(f"Error in holdings valuation: {e}")
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

    def push_strategy_value(self, s: StrategyConfig) -> Optional[str]:
        """Compute value in shares, sign, and submit updateValue."""
        try:
            strategy_id = self.to_strategy_id(s.id_text)
            value_shares = self.value_strategy_in_shares(s)

            # Confidence
            conf = int(s.confidence)

            # Nonce and expiry (TTL)
            nonce = self._next_nonce(strategy_id)
            expiry = int(time.time()) + self.ttl_seconds

            sig = self._sign_update(strategy_id, value_shares, conf, nonce, expiry)
            tx_params = self._build_tx_params()
            func = self.valuer.functions.updateValue(strategy_id, value_shares, conf, nonce, expiry, [sig])
            tx = func.build_transaction(tx_params)
            signed = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed.rawTransaction)
            h = tx_hash.hex()
            logger.info(f"Submitted updateValue: id={s.id_text}, shares={value_shares}, nonce={nonce}, conf={conf}, tx={h}")
            return h
        except Exception as e:
            logger.error(f"push_strategy_value failed for {s.id_text}: {e}", exc_info=True)
            return None

    # ------------- Run loops -------------

    def run_once(self):
        for s in self.strategies:
            self.push_strategy_value(s)

    def run_forever(self):
        logger.info("Starting OffchainValuationKeeper loop...")
        while True:
            start = time.time()
            try:
                self.run_once()
            except Exception as e:
                logger.error(f"run_once error: {e}", exc_info=True)
            # Sleep the remainder of the interval
            elapsed = time.time() - start
            sleep_s = max(1.0, self.update_check_interval - elapsed)
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