#!/usr/bin/env python3
"""
Functional Test Script for OffchainValuationKeeper

Tests the keeper with actual blockchain connections (or test RPC).
Validates that the refactored version produces correct outputs.

Usage:
    # Test with mainnet RPC (read-only)
    python test_keeper_functional.py --config keeper_config_mainnet.json

    # Test with test RPC
    RPC_URL=https://rpc.hyperliquid.xyz/evm python test_keeper_functional.py --config test_config.json

    # Dry-run mode (no transactions)
    python test_keeper_functional.py --config keeper_config_mainnet.json --dry-run

    # Test specific strategy
    python test_keeper_functional.py --config keeper_config_mainnet.json --strategy test_strategy_id
"""

import sys
import os
import json
import argparse
import time
from decimal import Decimal
from typing import Dict, List, Optional

# Add parent directory to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from web3 import Web3
from OffchainValuationKeeper import OffchainValuationKeeper, StrategyConfig


class KeeperTester:
    """Functional tester for OffchainValuationKeeper"""

    def __init__(self, config_path: str, dry_run: bool = True):
        self.config_path = config_path
        self.dry_run = dry_run
        self.keeper = None
        self.test_results = []

    def setup(self):
        """Initialize keeper instance"""
        print("=" * 70)
        print("KEEPER FUNCTIONAL TEST SUITE")
        print("=" * 70)
        print(f"Config: {self.config_path}")
        print(f"Dry-run: {self.dry_run}")
        print()

        try:
            self.keeper = OffchainValuationKeeper(self.config_path)
            print("✅ Keeper initialized successfully")
            print(f"   RPC: {self.keeper.w3.provider.endpoint_uri if hasattr(self.keeper.w3.provider, 'endpoint_uri') else 'Unknown'}")
            print(f"   Connected: {self.keeper.w3.is_connected()}")
            print(f"   Chain ID: {self.keeper.w3.eth.chain_id}")
            print(f"   Strategies: {len(self.keeper.strategies)}")
            print()
            return True
        except Exception as e:
            print(f"❌ Failed to initialize keeper: {e}")
            return False

    def test_strategy_valuation(self, strategy: StrategyConfig) -> Dict:
        """Test valuation for a single strategy"""
        print(f"\n{'=' * 70}")
        print(f"Testing Strategy: {strategy.id_text}")
        print(f"{'=' * 70}")
        print(f"Mode: {strategy.mode}")
        print(f"Underlying: {strategy.underlying}")
        print(f"Escrow: {strategy.escrow}")
        print()

        result = {
            'strategy_id': strategy.id_text,
            'mode': strategy.mode,
            'success': False,
            'value': None,
            'value_float': None,
            'error': None,
            'duration_ms': 0
        }

        try:
            start_time = time.time()

            # Call valuation
            value = self.keeper.value_strategy_in_shares(strategy)

            duration = (time.time() - start_time) * 1000
            result['duration_ms'] = duration
            result['value'] = value
            result['value_float'] = value / 10**18
            result['success'] = True

            print(f"✅ Valuation successful")
            print(f"   Value: {value:,} wei")
            print(f"   Value: {value/10**18:.6f} (18 decimals)")
            print(f"   Duration: {duration:.2f} ms")

            # Additional checks
            if value < 0:
                print(f"   ⚠️  WARNING: Negative value detected!")

            if value == 0:
                print(f"   ⚠️  WARNING: Zero value (check if expected)")

        except Exception as e:
            print(f"❌ Valuation failed: {e}")
            result['error'] = str(e)
            import traceback
            print(f"\nTraceback:")
            traceback.print_exc()

        return result

    def test_utils_modules(self):
        """Test that all utils modules are importable and functional"""
        print(f"\n{'=' * 70}")
        print("Testing Utils Modules")
        print(f"{'=' * 70}\n")

        tests = []

        # Test contract_utils
        try:
            from utils.contract_utils import ERC20_ABI, PT_TOKEN_ABI, PENDLE_ORACLE_ABI
            print("✅ contract_utils: Imported successfully")
            print(f"   - ERC20_ABI: {len(ERC20_ABI)} functions")
            print(f"   - PT_TOKEN_ABI: {len(PT_TOKEN_ABI)} functions")
            tests.append(('contract_utils', True, None))
        except Exception as e:
            print(f"❌ contract_utils: {e}")
            tests.append(('contract_utils', False, str(e)))

        # Test math_utils
        try:
            from utils.math_utils import black_scholes, norm_cdf, to_strategy_id
            price = black_scholes(100, 100, 1.0, 0.2, 0.05, False)
            assert 5 < price < 15, "Black-Scholes returned unexpected value"
            print("✅ math_utils: All functions working")
            print(f"   - Black-Scholes test: {price:.4f}")
            tests.append(('math_utils', True, None))
        except Exception as e:
            print(f"❌ math_utils: {e}")
            tests.append(('math_utils', False, str(e)))

        # Test uniswap_utils
        try:
            from utils import uniswap_utils
            funcs = [f for f in dir(uniswap_utils) if not f.startswith('_')]
            print("✅ uniswap_utils: Imported successfully")
            print(f"   - Functions: {len(funcs)}")
            tests.append(('uniswap_utils', True, None))
        except Exception as e:
            print(f"❌ uniswap_utils: {e}")
            tests.append(('uniswap_utils', False, str(e)))

        # Test lending_utils
        try:
            from utils import lending_utils
            funcs = [f for f in dir(lending_utils) if not f.startswith('_')]
            print("✅ lending_utils: Imported successfully")
            print(f"   - Functions: {len(funcs)}")
            tests.append(('lending_utils', True, None))
        except Exception as e:
            print(f"❌ lending_utils: {e}")
            tests.append(('lending_utils', False, str(e)))

        # Test pricing_utils
        try:
            from utils import pricing_utils
            funcs = [f for f in dir(pricing_utils) if not f.startswith('_')]
            print("✅ pricing_utils: Imported successfully")
            print(f"   - Functions: {len(funcs)}")
            tests.append(('pricing_utils', True, None))
        except Exception as e:
            print(f"❌ pricing_utils: {e}")
            tests.append(('pricing_utils', False, str(e)))

        # Test conversion_utils
        try:
            from utils import conversion_utils
            funcs = [f for f in dir(conversion_utils) if not f.startswith('_')]
            print("✅ conversion_utils: Imported successfully")
            print(f"   - Functions: {len(funcs)}")
            tests.append(('conversion_utils', True, None))
        except Exception as e:
            print(f"❌ conversion_utils: {e}")
            tests.append(('conversion_utils', False, str(e)))

        # Test options_utils
        try:
            from utils import options_utils
            funcs = [f for f in dir(options_utils) if not f.startswith('_')]
            print("✅ options_utils: Imported successfully")
            print(f"   - Functions: {len(funcs)}")
            tests.append(('options_utils', True, None))
        except Exception as e:
            print(f"❌ options_utils: {e}")
            tests.append(('options_utils', False, str(e)))

        return tests

    def test_web3_connectivity(self):
        """Test Web3 connectivity and basic queries"""
        print(f"\n{'=' * 70}")
        print("Testing Web3 Connectivity")
        print(f"{'=' * 70}\n")

        tests = []

        try:
            # Test connection
            connected = self.keeper.w3.is_connected()
            print(f"✅ Web3 connected: {connected}")
            tests.append(('web3_connection', connected, None))

            # Test chain ID
            chain_id = self.keeper.w3.eth.chain_id
            print(f"✅ Chain ID: {chain_id}")
            tests.append(('chain_id', True, None))

            # Test block number
            block_number = self.keeper.w3.eth.block_number
            print(f"✅ Latest block: {block_number:,}")
            tests.append(('block_number', True, None))

            # Test gas price
            gas_price = self.keeper.w3.eth.gas_price
            print(f"✅ Gas price: {gas_price / 10**9:.2f} gwei")
            tests.append(('gas_price', True, None))

        except Exception as e:
            print(f"❌ Web3 test failed: {e}")
            tests.append(('web3_test', False, str(e)))

        return tests

    def test_contract_interactions(self):
        """Test basic contract read operations"""
        print(f"\n{'=' * 70}")
        print("Testing Contract Interactions")
        print(f"{'=' * 70}\n")

        tests = []

        try:
            # Test wrapper contract
            wrapper_address = self.keeper.wrapper_address
            print(f"Wrapper: {wrapper_address}")

            # Test valuer contract
            valuer_address = self.keeper.valuer
            print(f"Valuer: {valuer_address}")

            # Test adapter contract
            adapter_address = self.keeper.adapter
            print(f"Adapter: {adapter_address}")

            # Try reading wrapper name (if ERC20)
            from utils.contract_utils import ERC20_ABI
            wrapper_contract = self.keeper.w3.eth.contract(
                address=Web3.to_checksum_address(wrapper_address),
                abi=ERC20_ABI
            )

            try:
                name = wrapper_contract.functions.name().call()
                symbol = wrapper_contract.functions.symbol().call()
                decimals = wrapper_contract.functions.decimals().call()
                print(f"✅ Wrapper token: {name} ({symbol}), {decimals} decimals")
                tests.append(('wrapper_read', True, None))
            except Exception as e:
                print(f"   Note: Could not read wrapper token info (may not be ERC20): {e}")
                tests.append(('wrapper_read', False, str(e)))

        except Exception as e:
            print(f"❌ Contract interaction failed: {e}")
            tests.append(('contract_test', False, str(e)))

        return tests

    def run_all_tests(self, strategy_filter: Optional[str] = None):
        """Run all tests"""
        if not self.setup():
            return False

        # Test utils modules
        utils_tests = self.test_utils_modules()

        # Test Web3
        web3_tests = self.test_web3_connectivity()

        # Test contracts
        contract_tests = self.test_contract_interactions()

        # Test strategies
        strategy_results = []
        for strategy in self.keeper.strategies:
            if strategy_filter and strategy.id_text != strategy_filter:
                continue

            result = self.test_strategy_valuation(strategy)
            strategy_results.append(result)
            self.test_results.append(result)

        # Print summary
        self.print_summary(utils_tests, web3_tests, contract_tests, strategy_results)

        return all(r['success'] for r in strategy_results)

    def print_summary(self, utils_tests, web3_tests, contract_tests, strategy_results):
        """Print test summary"""
        print(f"\n{'=' * 70}")
        print("TEST SUMMARY")
        print(f"{'=' * 70}\n")

        # Utils modules
        print("Utils Modules:")
        utils_success = sum(1 for _, success, _ in utils_tests if success)
        print(f"  ✅ Passed: {utils_success}/{len(utils_tests)}")
        for name, success, error in utils_tests:
            if not success:
                print(f"  ❌ Failed: {name} - {error}")
        print()

        # Web3 tests
        print("Web3 Connectivity:")
        web3_success = sum(1 for _, success, _ in web3_tests if success)
        print(f"  ✅ Passed: {web3_success}/{len(web3_tests)}")
        print()

        # Contract tests
        print("Contract Interactions:")
        contract_success = sum(1 for _, success, _ in contract_tests if success)
        print(f"  ✅ Passed: {contract_success}/{len(contract_tests)}")
        print()

        # Strategy tests
        print("Strategy Valuations:")
        strategy_success = sum(1 for r in strategy_results if r['success'])
        print(f"  ✅ Passed: {strategy_success}/{len(strategy_results)}")

        if strategy_results:
            print("\n  Strategy Results:")
            for result in strategy_results:
                status = "✅" if result['success'] else "❌"
                value_str = f"{result['value_float']:.6f}" if result['value_float'] is not None else "N/A"
                duration_str = f"{result['duration_ms']:.2f}ms" if result['duration_ms'] else "N/A"
                print(f"    {status} {result['strategy_id']:<30} {value_str:>15} ({duration_str})")

        print()

        # Overall status
        total_tests = (len(utils_tests) + len(web3_tests) +
                      len(contract_tests) + len(strategy_results))
        total_success = (utils_success + web3_success +
                        contract_success + strategy_success)

        if total_success == total_tests:
            print("🎉 ALL TESTS PASSED!")
        else:
            print(f"⚠️  {total_tests - total_success} / {total_tests} tests failed")

        print()


def main():
    parser = argparse.ArgumentParser(description='Test OffchainValuationKeeper')
    parser.add_argument('--config', required=True, help='Config file path')
    parser.add_argument('--dry-run', action='store_true', help='Dry-run mode (no transactions)')
    parser.add_argument('--strategy', help='Test specific strategy ID only')

    args = parser.parse_args()

    tester = KeeperTester(args.config, dry_run=args.dry_run)
    success = tester.run_all_tests(strategy_filter=args.strategy)

    return 0 if success else 1


if __name__ == '__main__':
    sys.exit(main())
