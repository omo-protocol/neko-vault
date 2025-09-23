#!/usr/bin/env python3
"""
Off-chain Valuation Keeper Service
Calculates strategy values off-chain and submits signed reports to UniversalValuerOffchain
"""

import asyncio
import json
import logging
import time
from dataclasses import dataclass
from enum import Enum
from typing import Dict, List, Optional, Tuple

from eth_account import Account
from eth_account.messages import encode_defunct
from web3 import Web3
from web3.contract import Contract

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


class UpdateReason(Enum):
    """Reasons for updating a strategy value"""
    STALENESS = "staleness"
    THRESHOLD = "threshold"
    ON_DEMAND = "on_demand"
    SCHEDULED = "scheduled"


@dataclass
class StrategyConfig:
    """Configuration for a strategy"""
    strategy_id: bytes
    min_update_interval: int  # seconds
    max_staleness: int  # seconds
    push_threshold: int  # basis points
    min_confidence: int  # 0-100


@dataclass
class ValueReport:
    """Value report for a strategy"""
    value: int
    confidence: int
    timestamp: int
    nonce: int


class StrategyValuer:
    """Base class for strategy-specific valuers"""

    async def calculate_value(self, escrow_address: str, strategy_id: bytes) -> Tuple[int, int]:
        """
        Calculate strategy value and confidence
        Returns: (value, confidence)
        """
        raise NotImplementedError


class PTKHYPELoopValuer(StrategyValuer):
    """Valuer for PT-kHYPE loop strategy"""

    def __init__(self, web3: Web3, contracts: Dict[str, Contract]):
        self.w3 = web3
        self.felix = contracts['felix']
        self.pendle_market = contracts['pendle_market']
        self.pt_oracle = contracts['pt_oracle']
        self.khype = contracts['khype']

    async def calculate_value(self, escrow_address: str, strategy_id: bytes) -> Tuple[int, int]:
        """Calculate PT-kHYPE loop position value"""
        try:
            # Get Felix position
            collateral = self.felix.functions.collateral(escrow_address).call()
            debt = self.felix.functions.debt(escrow_address).call()

            # Get PT price from oracle
            pt_price = await self._get_pt_price()

            # Calculate net value
            collateral_value = collateral * pt_price // 10**18
            net_value = collateral_value - debt

            # Calculate confidence based on data freshness
            confidence = await self._calculate_confidence()

            logger.info(f"PT-kHYPE Loop Value: {net_value}, Confidence: {confidence}%")
            return net_value, confidence

        except Exception as e:
            logger.error(f"Error calculating PT-kHYPE value: {e}")
            return 0, 0

    async def _get_pt_price(self) -> int:
        """Get PT price from Pendle oracle"""
        # Call oracle for PT price
        price = self.pt_oracle.functions.getPtPrice().call()
        return price

    async def _calculate_confidence(self) -> int:
        """Calculate confidence score based on data quality"""
        # Check oracle freshness
        oracle_updated = self.pt_oracle.functions.lastUpdate().call()
        staleness = int(time.time()) - oracle_updated

        if staleness < 300:  # < 5 minutes
            return 100
        elif staleness < 900:  # < 15 minutes
            return 95
        elif staleness < 3600:  # < 1 hour
            return 90
        else:
            return 80


class VNekoValuer(StrategyValuer):
    """Valuer for vNeko strategies"""

    def __init__(self, web3: Web3, contracts: Dict[str, Contract]):
        self.w3 = web3
        self.vneko = contracts['vneko']
        self.morpho = contracts['morpho']

    async def calculate_value(self, escrow_address: str, strategy_id: bytes) -> Tuple[int, int]:
        """Calculate vNeko position value"""
        # Implementation for vNeko valuation
        # This would include LP positions, lending positions, etc.
        return 0, 100  # Placeholder


class OffchainValuationKeeper:
    """Main keeper service for off-chain valuation"""

    def __init__(
        self,
        web3: Web3,
        valuer_contract: Contract,
        private_key: str,
        configs: List[StrategyConfig]
    ):
        self.w3 = web3
        self.valuer_contract = valuer_contract
        self.account = Account.from_key(private_key)
        self.configs = {c.strategy_id: c for c in configs}
        self.last_updates: Dict[bytes, ValueReport] = {}
        self.nonces: Dict[bytes, int] = {}

        # Initialize strategy valuers
        self.valuers: Dict[bytes, StrategyValuer] = {}

    def add_valuer(self, strategy_id: bytes, valuer: StrategyValuer):
        """Add a strategy-specific valuer"""
        self.valuers[strategy_id] = valuer

    async def run(self):
        """Main keeper loop"""
        logger.info("Starting off-chain valuation keeper...")

        # Start background tasks
        tasks = [
            asyncio.create_task(self._monitor_update_requests()),
            asyncio.create_task(self._scheduled_updates()),
            asyncio.create_task(self._monitor_threshold_changes()),
        ]

        await asyncio.gather(*tasks)

    async def _monitor_update_requests(self):
        """Monitor on-chain update requests (pull model)"""
        while True:
            try:
                # Get latest block
                latest_block = self.w3.eth.block_number

                # Check for UpdateRequested events
                events = self.valuer_contract.events.UpdateRequested().get_logs(
                    fromBlock=latest_block - 10,
                    toBlock=latest_block
                )

                for event in events:
                    strategy_id = event['args']['strategyId']
                    requester = event['args']['requester']
                    reason = event['args']['reason']

                    logger.info(f"Update requested for {strategy_id.hex()} by {requester}")
                    await self._update_strategy_value(strategy_id, UpdateReason.ON_DEMAND)

            except Exception as e:
                logger.error(f"Error monitoring update requests: {e}")

            await asyncio.sleep(10)  # Check every 10 seconds

    async def _scheduled_updates(self):
        """Perform scheduled updates based on staleness"""
        while True:
            try:
                for strategy_id, config in self.configs.items():
                    last_update = self.last_updates.get(strategy_id)

                    # Check if update needed
                    if last_update:
                        staleness = int(time.time()) - last_update.timestamp
                        if staleness > config.max_staleness:
                            await self._update_strategy_value(strategy_id, UpdateReason.STALENESS)
                    else:
                        # No previous update, do initial
                        await self._update_strategy_value(strategy_id, UpdateReason.SCHEDULED)

            except Exception as e:
                logger.error(f"Error in scheduled updates: {e}")

            await asyncio.sleep(60)  # Check every minute

    async def _monitor_threshold_changes(self):
        """Monitor for significant value changes (push model)"""
        while True:
            try:
                for strategy_id, config in self.configs.items():
                    if strategy_id not in self.valuers:
                        continue

                    # Calculate current value
                    escrow = await self._get_escrow_for_strategy(strategy_id)
                    value, confidence = await self.valuers[strategy_id].calculate_value(
                        escrow,
                        strategy_id
                    )

                    # Check if change exceeds threshold
                    last_update = self.last_updates.get(strategy_id)
                    if last_update:
                        change_percent = self._calculate_change_percent(
                            last_update.value,
                            value
                        )

                        if change_percent >= config.push_threshold:
                            logger.info(f"Threshold exceeded for {strategy_id.hex()}: {change_percent} bps")
                            await self._push_value_update(
                                strategy_id,
                                value,
                                confidence,
                                UpdateReason.THRESHOLD
                            )

            except Exception as e:
                logger.error(f"Error monitoring thresholds: {e}")

            await asyncio.sleep(30)  # Check every 30 seconds

    async def _update_strategy_value(self, strategy_id: bytes, reason: UpdateReason):
        """Update a specific strategy value"""
        try:
            if strategy_id not in self.valuers:
                logger.warning(f"No valuer for strategy {strategy_id.hex()}")
                return

            # Get escrow address
            escrow = await self._get_escrow_for_strategy(strategy_id)

            # Calculate value
            value, confidence = await self.valuers[strategy_id].calculate_value(
                escrow,
                strategy_id
            )

            # Push update
            await self._push_value_update(strategy_id, value, confidence, reason)

        except Exception as e:
            logger.error(f"Error updating strategy {strategy_id.hex()}: {e}")

    async def _push_value_update(
        self,
        strategy_id: bytes,
        value: int,
        confidence: int,
        reason: UpdateReason
    ):
        """Push value update to chain"""
        try:
            # Get nonce
            nonce = self.nonces.get(strategy_id, 0) + 1

            # Create signature
            signature = self._sign_value(strategy_id, value, confidence, nonce)

            # Build transaction
            tx = self.valuer_contract.functions.updateValue(
                strategy_id,
                value,
                confidence,
                nonce,
                [signature]
            ).build_transaction({
                'from': self.account.address,
                'nonce': self.w3.eth.get_transaction_count(self.account.address),
                'gas': 200000,
                'gasPrice': self.w3.eth.gas_price
            })

            # Sign and send transaction
            signed_tx = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.rawTransaction)

            logger.info(f"Value update sent for {strategy_id.hex()}: {value} (tx: {tx_hash.hex()})")

            # Update local state
            self.last_updates[strategy_id] = ValueReport(
                value=value,
                confidence=confidence,
                timestamp=int(time.time()),
                nonce=nonce
            )
            self.nonces[strategy_id] = nonce

        except Exception as e:
            logger.error(f"Error pushing value update: {e}")

    def _sign_value(
        self,
        strategy_id: bytes,
        value: int,
        confidence: int,
        nonce: int
    ) -> bytes:
        """Sign a value report"""
        # Encode message
        message = Web3.solidity_keccak(
            ['bytes32', 'uint256', 'uint256', 'uint256', 'uint256', 'address'],
            [strategy_id, value, confidence, nonce, self.w3.eth.chain_id, self.valuer_contract.address]
        )

        # Sign message
        signed_message = self.account.sign_message(encode_defunct(message))

        # Return signature bytes
        return signed_message.signature

    async def _get_escrow_for_strategy(self, strategy_id: bytes) -> str:
        """Get escrow address for a strategy"""
        # This would interface with the adapter/escrow contracts
        # For now, return a placeholder
        return "0x0000000000000000000000000000000000000000"

    def _calculate_change_percent(self, old_value: int, new_value: int) -> int:
        """Calculate percentage change in basis points"""
        if old_value == 0:
            return 10000 if new_value > 0 else 0

        diff = abs(new_value - old_value)
        return (diff * 10000) // old_value

    async def batch_update(self, updates: List[Tuple[bytes, int, int]]):
        """Batch update multiple strategies"""
        try:
            strategy_ids = []
            values = []
            confidences = []

            for strategy_id, value, confidence in updates:
                strategy_ids.append(strategy_id)
                values.append(value)
                confidences.append(confidence)

            # Get shared nonce
            nonce = int(time.time())

            # Create batch signature
            batch_hash = Web3.solidity_keccak(
                ['bytes32[]', 'uint256[]', 'uint256[]', 'uint256'],
                [strategy_ids, values, confidences, nonce]
            )

            signature = self.account.sign_message(encode_defunct(batch_hash)).signature

            # Send batch update
            tx = self.valuer_contract.functions.batchUpdateValues(
                strategy_ids,
                values,
                confidences,
                nonce,
                [signature]
            ).build_transaction({
                'from': self.account.address,
                'nonce': self.w3.eth.get_transaction_count(self.account.address),
                'gas': 500000,
                'gasPrice': self.w3.eth.gas_price
            })

            signed_tx = self.account.sign_transaction(tx)
            tx_hash = self.w3.eth.send_raw_transaction(signed_tx.rawTransaction)

            logger.info(f"Batch update sent for {len(updates)} strategies (tx: {tx_hash.hex()})")

        except Exception as e:
            logger.error(f"Error in batch update: {e}")


async def main():
    """Main entry point"""
    # Load configuration
    with open('keeper_config.json', 'r') as f:
        config = json.load(f)

    # Connect to network
    w3 = Web3(Web3.HTTPProvider(config['rpc_url']))

    # Load contracts
    valuer_contract = w3.eth.contract(
        address=config['valuer_address'],
        abi=config['valuer_abi']
    )

    # Load other contracts (Felix, Pendle, etc.)
    contracts = {}
    for name, addr in config['contracts'].items():
        contracts[name] = w3.eth.contract(
            address=addr,
            abi=config['abis'][name]
        )

    # Create strategy configs
    configs = []
    for strategy in config['strategies']:
        configs.append(StrategyConfig(
            strategy_id=bytes.fromhex(strategy['id']),
            min_update_interval=strategy['min_update_interval'],
            max_staleness=strategy['max_staleness'],
            push_threshold=strategy['push_threshold'],
            min_confidence=strategy['min_confidence']
        ))

    # Create keeper
    keeper = OffchainValuationKeeper(
        w3,
        valuer_contract,
        config['private_key'],
        configs
    )

    # Add strategy valuers
    pt_loop_id = bytes.fromhex(config['strategies'][0]['id'])
    keeper.add_valuer(pt_loop_id, PTKHYPELoopValuer(w3, contracts))

    # Run keeper
    await keeper.run()


if __name__ == "__main__":
    asyncio.run(main())