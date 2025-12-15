#!/usr/bin/env python3
"""
Comprehensive Test Suite for OffchainValuationKeeper

Tests all utils modules and valuation modes with mocking and integration tests.

Usage:
    # Run all tests
    python test_offchain_valuation_keeper.py

    # Run specific test class
    python test_offchain_valuation_keeper.py TestMathUtils

    # Run with verbose output
    python test_offchain_valuation_keeper.py -v

    # Run specific test method
    python test_offchain_valuation_keeper.py TestMathUtils.test_black_scholes_call
"""

import unittest
import sys
import os
import json
from unittest.mock import Mock, MagicMock, patch, call
from decimal import Decimal

# Add parent directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# Import utils modules
from utils import math_utils
from utils import uniswap_utils
from utils import lending_utils
from utils import pricing_utils
from utils import conversion_utils
from utils import options_utils
from utils.contract_utils import (
    ERC20_ABI, PT_TOKEN_ABI, PENDLE_ORACLE_ABI, FELIX_ABI,
    UNISWAP_V3_POOL_ABI, CHAINLINK_FEED_ABI
)


class TestMathUtils(unittest.TestCase):
    """Test math utility functions"""

    def test_norm_cdf_standard_values(self):
        """Test normal CDF with known values"""
        # P(Z < 0) = 0.5
        self.assertAlmostEqual(math_utils.norm_cdf(0.0), 0.5, places=4)

        # P(Z < 1) ≈ 0.8413
        self.assertAlmostEqual(math_utils.norm_cdf(1.0), 0.8413, places=3)

        # P(Z < -1) ≈ 0.1587
        self.assertAlmostEqual(math_utils.norm_cdf(-1.0), 0.1587, places=3)

        # P(Z < 2) ≈ 0.9772
        self.assertAlmostEqual(math_utils.norm_cdf(2.0), 0.9772, places=3)

    def test_black_scholes_call_atm(self):
        """Test Black-Scholes for at-the-money call option"""
        price = math_utils.black_scholes(
            S=100.0,  # Spot price
            K=100.0,  # Strike price (ATM)
            T=1.0,    # 1 year to expiry
            sigma=0.2,  # 20% volatility
            r=0.05,   # 5% risk-free rate
            is_put=False
        )

        # ATM call should be between 5 and 15
        self.assertGreater(price, 5.0)
        self.assertLess(price, 15.0)

        # ATM call should increase with volatility
        price_high_vol = math_utils.black_scholes(100.0, 100.0, 1.0, 0.4, 0.05, False)
        self.assertGreater(price_high_vol, price)

    def test_black_scholes_put_atm(self):
        """Test Black-Scholes for at-the-money put option"""
        price = math_utils.black_scholes(
            S=100.0,
            K=100.0,
            T=1.0,
            sigma=0.2,
            r=0.05,
            is_put=True
        )

        # ATM put should be positive
        self.assertGreater(price, 0.0)
        self.assertLess(price, 15.0)

    def test_black_scholes_call_itm(self):
        """Test Black-Scholes for in-the-money call"""
        price_itm = math_utils.black_scholes(
            S=110.0,  # Spot above strike
            K=100.0,
            T=1.0,
            sigma=0.2,
            r=0.05,
            is_put=False
        )

        price_atm = math_utils.black_scholes(100.0, 100.0, 1.0, 0.2, 0.05, False)

        # ITM call should be worth more than ATM call
        self.assertGreater(price_itm, price_atm)

        # Should have at least intrinsic value
        self.assertGreater(price_itm, 10.0)

    def test_black_scholes_zero_time(self):
        """Test Black-Scholes at expiry"""
        # Call at expiry, ITM
        price = math_utils.black_scholes(110.0, 100.0, 0.0, 0.2, 0.05, False)
        self.assertAlmostEqual(price, 10.0, places=2)

        # Call at expiry, OTM
        price = math_utils.black_scholes(90.0, 100.0, 0.0, 0.2, 0.05, False)
        self.assertAlmostEqual(price, 0.0, places=2)

        # Put at expiry, ITM
        price = math_utils.black_scholes(90.0, 100.0, 0.0, 0.2, 0.05, True)
        self.assertAlmostEqual(price, 10.0, places=2)

    def test_to_strategy_id(self):
        """Test strategy ID hashing"""
        strategy_id = math_utils.to_strategy_id("test_strategy")

        # Should return 32 bytes
        self.assertEqual(len(strategy_id), 32)

        # Same input should give same output
        strategy_id2 = math_utils.to_strategy_id("test_strategy")
        self.assertEqual(strategy_id, strategy_id2)

        # Different input should give different output
        strategy_id3 = math_utils.to_strategy_id("different_strategy")
        self.assertNotEqual(strategy_id, strategy_id3)

    def test_tick_to_sqrt_price_x96(self):
        """Test Uniswap V3 tick to sqrt price conversion"""
        # Tick 0 should give price ratio of 1
        sqrt_price = math_utils.tick_to_sqrt_price_x96(0)
        expected = 2 ** 96  # sqrt(1) * 2^96
        self.assertAlmostEqual(sqrt_price / expected, 1.0, places=6)

        # Positive tick should give sqrt_price > 2^96
        sqrt_price_positive = math_utils.tick_to_sqrt_price_x96(1000)
        self.assertGreater(sqrt_price_positive, 2 ** 96)

        # Negative tick should give sqrt_price < 2^96
        sqrt_price_negative = math_utils.tick_to_sqrt_price_x96(-1000)
        self.assertLess(sqrt_price_negative, 2 ** 96)

    def test_calculate_amounts_from_liquidity(self):
        """Test Uniswap V3 liquidity to amounts conversion"""
        liquidity = 1000000
        sqrt_price_current_x96 = 2 ** 96  # Price = 1
        tick_lower = -1000
        tick_upper = 1000

        amount0, amount1 = math_utils.calculate_amounts_from_liquidity(
            liquidity, sqrt_price_current_x96, tick_lower, tick_upper
        )

        # Both amounts should be positive
        self.assertGreater(amount0, 0)
        self.assertGreater(amount1, 0)

        # For symmetric range around current price, amounts should be similar
        ratio = amount0 / amount1
        self.assertGreater(ratio, 0.5)
        self.assertLess(ratio, 2.0)


class TestConversionUtils(unittest.TestCase):
    """Test asset conversion utility functions"""

    def setUp(self):
        """Set up mock Web3 instance"""
        self.mock_w3 = Mock()
        # Mock Web3.to_checksum_address to return proper hex addresses
        Web3.to_checksum_address = lambda x: x if x.startswith('0x') and len(x) == 42 else '0x' + '0' * 40

    def test_convert_underlying_to_wrapper_shares_with_wrapper(self):
        """Test conversion using wrapper's convertToShares"""
        mock_wrapper = Mock()
        mock_wrapper.functions.convertToShares.return_value.call.return_value = 950000000000000000  # 0.95 shares

        self.mock_w3.eth.contract.return_value = mock_wrapper

        shares = conversion_utils.convert_underlying_to_wrapper_shares(
            w3=self.mock_w3,
            wrapper_abi=[],
            wrapper_address="0x" + "1" * 40,
            underlying_amount=1000000000000000000  # 1.0
        )

        self.assertEqual(shares, 950000000000000000)

    def test_convert_underlying_to_wrapper_shares_standard_erc20(self):
        """Test conversion for standard ERC20 (1:1)"""
        mock_wrapper = Mock()
        mock_wrapper.functions.convertToShares.side_effect = Exception("Not implemented")

        self.mock_w3.eth.contract.return_value = mock_wrapper
        self.mock_w3.to_checksum_address = lambda x: x

        shares = conversion_utils.convert_underlying_to_wrapper_shares(
            w3=self.mock_w3,
            wrapper_abi=[],
            wrapper_address="0xWrapper",
            underlying_amount=1000000000000000000
        )

        # Should fallback to 1:1
        self.assertEqual(shares, 1000000000000000000)

    def test_read_underlying_balance(self):
        """Test reading ERC20 balance"""
        mock_token = Mock()
        mock_token.functions.balanceOf.return_value.call.return_value = 5000000000000000000  # 5.0

        self.mock_w3.eth.contract.return_value = mock_token
        self.mock_w3.to_checksum_address = lambda x: x

        balance = conversion_utils.read_underlying_balance(
            w3=self.mock_w3,
            erc20_abi=[],
            token="0xToken",
            holder="0xHolder"
        )

        self.assertEqual(balance, 5000000000000000000)

    def test_auto_detect_token_order_token0(self):
        """Test auto-detect when asset is token0"""
        mock_pool = Mock()
        mock_pool.functions.token0.return_value.call.return_value = "0xAsset"
        mock_pool.functions.token1.return_value.call.return_value = "0xOther"

        self.mock_w3.eth.contract.return_value = mock_pool
        self.mock_w3.to_checksum_address = lambda x: x

        is_token0 = conversion_utils.auto_detect_token_order(
            w3=self.mock_w3,
            uniswap_v3_pool_abi=[],
            uniswap_v2_pair_abi=[],
            pool_address="0xPool",
            from_asset="0xAsset",
            pool_type='v3'
        )

        self.assertTrue(is_token0)

    def test_auto_detect_token_order_token1(self):
        """Test auto-detect when asset is token1"""
        mock_pool = Mock()
        mock_pool.functions.token0.return_value.call.return_value = "0xOther"
        mock_pool.functions.token1.return_value.call.return_value = "0xAsset"

        self.mock_w3.eth.contract.return_value = mock_pool
        self.mock_w3.to_checksum_address = lambda x: x

        is_token0 = conversion_utils.auto_detect_token_order(
            w3=self.mock_w3,
            uniswap_v3_pool_abi=[],
            uniswap_v2_pair_abi=[],
            pool_address="0xPool",
            from_asset="0xAsset",
            pool_type='v3'
        )

        self.assertFalse(is_token0)

    def test_convert_via_fixed_ratio(self):
        """Test fixed ratio conversion"""
        # 1:1 ratio
        converted = conversion_utils.convert_via_fixed_ratio(
            amount=1000000000000000000,
            config={'ratio': 10**18}
        )
        self.assertEqual(converted, 1000000000000000000)

        # 0.95:1 ratio
        converted = conversion_utils.convert_via_fixed_ratio(
            amount=1000000000000000000,
            config={'ratio': int(0.95 * 10**18)}
        )
        self.assertEqual(converted, 950000000000000000)

    def test_convert_via_chainlink_pair_feed(self):
        """Test Chainlink conversion with pair feed"""
        mock_feed = Mock()
        mock_feed.functions.latestRoundData.return_value.call.return_value = [
            0, 950000000000000000, 0, 0, 0  # 0.95 with 18 decimals
        ]
        mock_feed.functions.decimals.return_value.call.return_value = 18

        self.mock_w3.eth.contract.return_value = mock_feed
        self.mock_w3.to_checksum_address = lambda x: x

        converted = conversion_utils.convert_via_chainlink(
            w3=self.mock_w3,
            chainlink_abi=[],
            amount=1000000000000000000,
            from_asset="0xAsset",
            config={'pair_feed': '0xFeed'}
        )

        self.assertAlmostEqual(converted / 10**18, 0.95, places=6)


class TestPricingUtils(unittest.TestCase):
    """Test pricing and oracle utility functions"""

    def setUp(self):
        """Set up mock Web3 instance"""
        self.mock_w3 = Mock()

    def test_get_pt_price_valid(self):
        """Test getting PT price from Pendle oracle"""
        mock_oracle = Mock()
        mock_oracle.functions.getPtToAssetRate.return_value.call.return_value = 950000000000000000  # 0.95
        mock_oracle.functions.getOracleState.return_value.call.return_value = [False, 0]

        self.mock_w3.eth.contract.return_value = mock_oracle
        self.mock_w3.to_checksum_address = lambda x: x

        price = pricing_utils.get_pt_price(
            w3=self.mock_w3,
            pendle_oracle_abi=[],
            market="0xMarket",
            oracle="0xOracle"
        )

        self.assertEqual(price, 950000000000000000)

    def test_get_pt_price_out_of_bounds(self):
        """Test PT price validation"""
        mock_oracle = Mock()
        mock_oracle.functions.getPtToAssetRate.return_value.call.return_value = 200000000000000000  # 0.2 (too low)
        mock_oracle.functions.getOracleState.return_value.call.return_value = [False, 0]

        self.mock_w3.eth.contract.return_value = mock_oracle
        self.mock_w3.to_checksum_address = lambda x: x

        with self.assertRaises(ValueError):
            pricing_utils.get_pt_price(
                w3=self.mock_w3,
                pendle_oracle_abi=[],
                market="0xMarket",
                oracle="0xOracle"
            )

    def test_get_token_price_from_chainlink(self):
        """Test getting token price from Chainlink"""
        mock_oracle = Mock()
        mock_oracle.functions.decimals.return_value.call.return_value = 8
        mock_oracle.functions.latestRoundData.return_value.call.return_value = [
            0, 180000000000, 0, 1700000000, 0  # $1800 with 8 decimals
        ]

        self.mock_w3.eth.contract.return_value = mock_oracle
        self.mock_w3.to_checksum_address = lambda x: x

        with patch('time.time', return_value=1700000100):  # Within 24hr
            price = pricing_utils.get_token_price_from_chainlink(
                w3=self.mock_w3,
                chainlink_abi=[],
                oracle_address="0xOracle"
            )

        self.assertAlmostEqual(price, 1800.0, places=2)


class TestLendingUtils(unittest.TestCase):
    """Test lending protocol utility functions"""

    def setUp(self):
        """Set up mock Web3 instance"""
        self.mock_w3 = Mock()

    def test_get_felix_debt(self):
        """Test getting debt from Felix protocol"""
        mock_felix = Mock()

        # Mock market() call
        mock_felix.functions.market.return_value.call.return_value = [
            1000000000000000000,  # totalSupplyAssets
            2000000000000000000,  # totalSupplyShares
            500000000000000000,   # totalBorrowAssets
            1000000000000000000,  # totalBorrowShares
            0, 0, 0, 0, 0, 0, 0   # Other fields
        ]

        # Mock position() call - user has 500 borrow shares
        mock_felix.functions.position.return_value.call.return_value = [
            0,  # supplyShares
            500000000000000000  # borrowShares (0.5)
        ]

        self.mock_w3.eth.contract.return_value = mock_felix
        self.mock_w3.to_checksum_address = lambda x: x
        self.mock_w3.keccak = lambda text: b'\x00' * 32

        debt = lending_utils.get_felix_debt(
            w3=self.mock_w3,
            felix_abi=[],
            felix="0xFelix",
            market_id=b'\x00' * 32,
            user="0xUser"
        )

        # 500 shares * (500 assets / 1000 shares) = 250 assets
        self.assertEqual(debt, 250000000000000000)

    def test_get_felix_debt_zero_shares(self):
        """Test Felix debt when user has no shares"""
        mock_felix = Mock()
        mock_felix.functions.market.return_value.call.return_value = [
            1000000000000000000, 2000000000000000000,
            500000000000000000, 1000000000000000000,
            0, 0, 0, 0, 0, 0, 0
        ]
        mock_felix.functions.position.return_value.call.return_value = [0, 0]

        self.mock_w3.eth.contract.return_value = mock_felix
        self.mock_w3.to_checksum_address = lambda x: x
        self.mock_w3.keccak = lambda text: b'\x00' * 32

        debt = lending_utils.get_felix_debt(
            w3=self.mock_w3,
            felix_abi=[],
            felix="0xFelix",
            market_id=b'\x00' * 32,
            user="0xUser"
        )

        self.assertEqual(debt, 0)


class TestUniswapUtils(unittest.TestCase):
    """Test Uniswap utility functions"""

    def setUp(self):
        """Set up mock Web3 instance"""
        self.mock_w3 = Mock()

    def test_get_pool_current_tick(self):
        """Test getting current tick from pool"""
        mock_pool = Mock()
        mock_pool.functions.slot0.return_value.call.return_value = [
            0, 12345, 0, 0, 0, 0, False  # slot0 with tick=12345
        ]

        self.mock_w3.eth.contract.return_value = mock_pool
        self.mock_w3.to_checksum_address = lambda x: x

        tick = uniswap_utils.get_pool_current_tick(
            w3=self.mock_w3,
            pool_abi=[],
            pool_address="0xPool"
        )

        self.assertEqual(tick, 12345)

    def test_scan_uniswap_v3_positions_zero_balance(self):
        """Test position scanning with zero positions"""
        mock_manager = Mock()
        mock_manager.functions.balanceOf.return_value.call.return_value = 0

        self.mock_w3.eth.contract.return_value = mock_manager
        self.mock_w3.to_checksum_address = lambda x: x

        token_ids = uniswap_utils.scan_uniswap_v3_positions(
            w3=self.mock_w3,
            position_manager_abi=[],
            position_manager="0xManager",
            escrow="0xEscrow",
            min_liquidity=0
        )

        self.assertEqual(token_ids, [])

    def test_get_uniswap_v3_position(self):
        """Test getting position details"""
        mock_manager = Mock()
        mock_manager.functions.positions.return_value.call.return_value = [
            0,  # nonce
            "0xOperator",  # operator
            "0xToken0",  # token0
            "0xToken1",  # token1
            3000,  # fee
            -1000,  # tickLower
            1000,  # tickUpper
            1000000,  # liquidity
            0, 0, 0, 0  # Other fields
        ]

        self.mock_w3.eth.contract.return_value = mock_manager
        self.mock_w3.to_checksum_address = lambda x: x

        position = uniswap_utils.get_uniswap_v3_position(
            w3=self.mock_w3,
            position_manager_abi=[],
            position_manager="0xManager",
            token_id=123
        )

        self.assertEqual(position['liquidity'], 1000000)
        self.assertEqual(position['tickLower'], -1000)
        self.assertEqual(position['tickUpper'], 1000)


class TestOptionsUtils(unittest.TestCase):
    """Test options valuation utility functions"""

    def setUp(self):
        """Set up mock Web3 instance and functions"""
        self.mock_w3 = Mock()

        # Mock strategy config
        self.strategy_config = Mock()
        self.strategy_config.escrow = "0xEscrow"
        self.strategy_config.underlying = "0xUnderlying"
        self.strategy_config.extras = {
            'options': [
                {
                    'token': '0xOToken1',
                    'side': 1,  # Long
                    'iv_bps': 8000  # 80%
                }
            ],
            'risk_free_bps': 500,  # 5%
            'default_iv_bps': 8000,
            'oracles': {
                '0xunderlying': '0xOracle1',
                '0xotoken1': '0xOracle2'
            },
            'symbol_map': {}
        }

    def test_value_options_otoken_no_positions(self):
        """Test options valuation with no positions"""
        self.strategy_config.extras = {'options': []}

        value = options_utils.value_options_otoken(
            w3=self.mock_w3,
            otoken_abi=[],
            erc20_abi=[],
            strategy_config=self.strategy_config,
            black_scholes_func=math_utils.black_scholes,
            get_asset_price_func=lambda addr, oracles: 100.0,
            fetch_rysk_data_func=lambda: {},
            convert_to_wrapper_func=lambda x: x
        )

        self.assertEqual(value, 0)

    def test_value_options_otoken_zero_balance(self):
        """Test options valuation with zero balance"""
        mock_otoken = Mock()
        mock_otoken.functions.balanceOf.return_value.call.return_value = 0
        mock_otoken.functions.decimals.return_value.call.return_value = 18

        self.mock_w3.eth.contract.return_value = mock_otoken
        self.mock_w3.to_checksum_address = lambda x: x

        value = options_utils.value_options_otoken(
            w3=self.mock_w3,
            otoken_abi=[],
            erc20_abi=[],
            strategy_config=self.strategy_config,
            black_scholes_func=math_utils.black_scholes,
            get_asset_price_func=lambda addr, oracles: 100.0,
            fetch_rysk_data_func=lambda: {},
            convert_to_wrapper_func=lambda x: x
        )

        self.assertEqual(value, 0)


class TestIntegration(unittest.TestCase):
    """Integration tests for full workflows"""

    def setUp(self):
        """Set up mock Web3 and config"""
        self.mock_w3 = Mock()
        self.mock_w3.to_checksum_address = lambda x: x

    def test_pt_loop_workflow(self):
        """Test complete PT loop valuation workflow"""
        # Mock PT token balance
        mock_pt = Mock()
        mock_pt.functions.balanceOf.return_value.call.return_value = 10 * 10**18

        # Mock Pendle oracle
        mock_oracle = Mock()
        mock_oracle.functions.getPtToAssetRate.return_value.call.return_value = int(0.95 * 10**18)
        mock_oracle.functions.getOracleState.return_value.call.return_value = [False, 0]

        # Mock Felix lending
        mock_felix = Mock()
        mock_felix.functions.market.return_value.call.return_value = [
            1000 * 10**18, 2000 * 10**18,  # Supply
            500 * 10**18, 1000 * 10**18,   # Borrow
            0, 0, 0, 0, 0, 0, 0
        ]
        mock_felix.functions.position.return_value.call.return_value = [
            0, 100 * 10**18  # 100 borrow shares
        ]

        # Mock wrapper
        mock_wrapper = Mock()
        mock_wrapper.functions.convertToShares.return_value.call.return_value = int(9.0 * 10**18)

        def mock_contract(address, abi):
            if 'oracle' in address.lower():
                return mock_oracle
            elif 'felix' in address.lower():
                return mock_felix
            elif 'wrapper' in address.lower():
                return mock_wrapper
            else:
                return mock_pt

        self.mock_w3.eth.contract = mock_contract
        self.mock_w3.keccak = lambda text: b'\x00' * 32

        # 1. Read PT balance
        pt_balance = conversion_utils.read_underlying_balance(
            self.mock_w3, [], "0xPT", "0xEscrow"
        )
        self.assertEqual(pt_balance, 10 * 10**18)

        # 2. Get PT price
        pt_price = pricing_utils.get_pt_price(
            self.mock_w3, [], "0xMarket", "0xOracle"
        )
        self.assertEqual(pt_price, int(0.95 * 10**18))

        # 3. Calculate PT value
        pt_value = (pt_balance * pt_price) // 10**18
        self.assertEqual(pt_value, int(9.5 * 10**18))

        # 4. Get debt
        debt = lending_utils.get_felix_debt(
            self.mock_w3, [], "0xFelix", b'\x00' * 32, "0xEscrow"
        )
        self.assertEqual(debt, 50 * 10**18)  # 100 shares * 0.5 rate

        # 5. Net value
        net_value = pt_value - debt
        self.assertEqual(net_value, int(9.0 * 10**18))


def run_tests():
    """Run all tests with coverage"""
    # Create test suite
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    # Add all test classes
    suite.addTests(loader.loadTestsFromTestCase(TestMathUtils))
    suite.addTests(loader.loadTestsFromTestCase(TestConversionUtils))
    suite.addTests(loader.loadTestsFromTestCase(TestPricingUtils))
    suite.addTests(loader.loadTestsFromTestCase(TestLendingUtils))
    suite.addTests(loader.loadTestsFromTestCase(TestUniswapUtils))
    suite.addTests(loader.loadTestsFromTestCase(TestOptionsUtils))
    suite.addTests(loader.loadTestsFromTestCase(TestIntegration))

    # Run tests with detailed output
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    # Print summary
    print("\n" + "=" * 70)
    print("TEST SUMMARY")
    print("=" * 70)
    print(f"Tests run: {result.testsRun}")
    print(f"Successes: {result.testsRun - len(result.failures) - len(result.errors)}")
    print(f"Failures: {len(result.failures)}")
    print(f"Errors: {len(result.errors)}")
    print(f"Skipped: {len(result.skipped)}")

    if result.wasSuccessful():
        print("\n✅ ALL TESTS PASSED!")
        return 0
    else:
        print("\n❌ SOME TESTS FAILED")
        return 1


if __name__ == '__main__':
    sys.exit(run_tests())
