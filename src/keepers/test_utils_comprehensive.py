#!/usr/bin/env python3
"""
Comprehensive Test Suite for Utils Modules
Properly mocked tests to achieve 100% coverage
"""

import unittest
import sys
import os
from unittest.mock import Mock, MagicMock, patch
from decimal import Decimal

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from utils import math_utils
from utils import uniswap_utils
from utils import lending_utils
from utils import pricing_utils
from utils import conversion_utils
from utils import options_utils


class TestMathUtilsComprehensive(unittest.TestCase):
    """Comprehensive tests for math_utils - targeting 100% coverage"""

    def test_norm_cdf_negative(self):
        """Test norm_cdf with negative values"""
        result = math_utils.norm_cdf(-1.0)
        self.assertAlmostEqual(result, 0.1587, places=3)

    def test_norm_cdf_positive(self):
        """Test norm_cdf with positive values"""
        result = math_utils.norm_cdf(1.0)
        self.assertAlmostEqual(result, 0.8413, places=3)

    def test_norm_cdf_zero(self):
        """Test norm_cdf at zero"""
        result = math_utils.norm_cdf(0.0)
        self.assertAlmostEqual(result, 0.5, places=4)

    def test_black_scholes_call_otm(self):
        """Test Black-Scholes for out-of-the-money call"""
        price = math_utils.black_scholes(90.0, 100.0, 1.0, 0.2, 0.05, False)
        self.assertGreater(price, 0.0)
        self.assertLess(price, 10.0)

    def test_black_scholes_call_itm(self):
        """Test Black-Scholes for in-the-money call"""
        price = math_utils.black_scholes(110.0, 100.0, 1.0, 0.2, 0.05, False)
        self.assertGreater(price, 10.0)

    def test_black_scholes_put_otm(self):
        """Test Black-Scholes for out-of-the-money put"""
        price = math_utils.black_scholes(110.0, 100.0, 1.0, 0.2, 0.05, True)
        self.assertGreater(price, 0.0)
        self.assertLess(price, 5.0)

    def test_black_scholes_put_itm(self):
        """Test Black-Scholes for in-the-money put"""
        price = math_utils.black_scholes(90.0, 100.0, 1.0, 0.2, 0.05, True)
        self.assertGreater(price, 5.0)

    def test_black_scholes_high_volatility(self):
        """Test Black-Scholes with high volatility"""
        price_low = math_utils.black_scholes(100.0, 100.0, 1.0, 0.2, 0.05, False)
        price_high = math_utils.black_scholes(100.0, 100.0, 1.0, 0.8, 0.05, False)
        self.assertGreater(price_high, price_low)

    def test_black_scholes_near_expiry(self):
        """Test Black-Scholes near expiry"""
        price = math_utils.black_scholes(105.0, 100.0, 0.01, 0.2, 0.05, False)
        self.assertGreater(price, 4.5)  # Should be close to intrinsic value

    def test_to_strategy_id_consistency(self):
        """Test strategy ID hashing consistency"""
        id1 = math_utils.to_strategy_id("my_strategy")
        id2 = math_utils.to_strategy_id("my_strategy")
        self.assertEqual(id1, id2)
        self.assertEqual(len(id1), 32)

    def test_to_strategy_id_uniqueness(self):
        """Test strategy ID uniqueness"""
        id1 = math_utils.to_strategy_id("strategy_1")
        id2 = math_utils.to_strategy_id("strategy_2")
        self.assertNotEqual(id1, id2)

    def test_tick_to_sqrt_price_x96_positive(self):
        """Test tick conversion with positive tick"""
        sqrt_price = math_utils.tick_to_sqrt_price_x96(1000)
        self.assertGreater(sqrt_price, 2**96)

    def test_tick_to_sqrt_price_x96_negative(self):
        """Test tick conversion with negative tick"""
        sqrt_price = math_utils.tick_to_sqrt_price_x96(-1000)
        self.assertLess(sqrt_price, 2**96)

    def test_calculate_amounts_symmetric_range(self):
        """Test amounts calculation with symmetric range"""
        liquidity = 1000000
        sqrt_price = 2**96
        amount0, amount1 = math_utils.calculate_amounts_from_liquidity(
            liquidity, sqrt_price, -1000, 1000
        )
        self.assertGreater(amount0, 0)
        self.assertGreater(amount1, 0)

    def test_calculate_amounts_different_ranges(self):
        """Test amounts calculation with different price ranges"""
        liquidity = 1000000
        sqrt_price = 2**96

        # Test with wide range
        amount0_wide, amount1_wide = math_utils.calculate_amounts_from_liquidity(
            liquidity, sqrt_price, -5000, 5000
        )

        # Test with narrow range
        amount0_narrow, amount1_narrow = math_utils.calculate_amounts_from_liquidity(
            liquidity, sqrt_price, -100, 100
        )

        # Both should have positive amounts
        self.assertGreater(amount0_wide, 0)
        self.assertGreater(amount1_wide, 0)
        self.assertGreater(amount0_narrow, 0)
        self.assertGreater(amount1_narrow, 0)

    def test_calculate_amounts_edge_cases(self):
        """Test amounts calculation edge cases"""
        liquidity = 1000000
        sqrt_price = 2**96

        # Test with small ticks
        amount0, amount1 = math_utils.calculate_amounts_from_liquidity(
            liquidity, sqrt_price, -10, 10
        )
        self.assertGreater(amount0, 0)
        self.assertGreater(amount1, 0)


class TestConversionUtilsComprehensive(unittest.TestCase):
    """Comprehensive tests for conversion_utils - targeting 100% coverage"""

    def test_convert_via_fixed_ratio_default(self):
        """Test fixed ratio with default 1:1"""
        result = conversion_utils.convert_via_fixed_ratio(
            amount=10**18,
            config={}
        )
        self.assertEqual(result, 10**18)

    def test_convert_via_fixed_ratio_custom(self):
        """Test fixed ratio with custom ratio"""
        result = conversion_utils.convert_via_fixed_ratio(
            amount=10**18,
            config={'ratio': int(0.9 * 10**18)}
        )
        self.assertEqual(result, int(0.9 * 10**18))

    def test_convert_via_fixed_ratio_invalid(self):
        """Test fixed ratio with invalid ratio"""
        result = conversion_utils.convert_via_fixed_ratio(
            amount=10**18,
            config={'ratio': -100}
        )
        self.assertEqual(result, 10**18)  # Should fallback to 1:1

    def test_convert_via_fixed_ratio_zero(self):
        """Test fixed ratio with zero ratio"""
        result = conversion_utils.convert_via_fixed_ratio(
            amount=10**18,
            config={'ratio': 0}
        )
        self.assertEqual(result, 10**18)  # Should fallback to 1:1


class TestPricingUtilsComprehensive(unittest.TestCase):
    """Comprehensive tests for pricing_utils - targeting 100% coverage"""

    @patch('utils.pricing_utils.logger')
    def test_fetch_rysk_market_data(self, mock_logger):
        """Test Rysk market data fetching"""
        data = pricing_utils.fetch_rysk_market_data()
        self.assertIn('volatility', data)
        self.assertIn('risk_free_rate', data)
        self.assertEqual(data['volatility'], 0.80)
        self.assertEqual(data['risk_free_rate'], 0.03)


class TestOptionsUtilsComprehensive(unittest.TestCase):
    """Comprehensive tests for options_utils - targeting 100% coverage"""

    def test_value_options_otoken_no_config(self):
        """Test options valuation with empty config"""
        mock_w3 = Mock()
        strategy_config = Mock()
        strategy_config.extras = None

        result = options_utils.value_options_otoken(
            w3=mock_w3,
            otoken_abi=[],
            erc20_abi=[],
            strategy_config=strategy_config,
            black_scholes_func=math_utils.black_scholes,
            get_asset_price_func=lambda x, y: 100.0,
            fetch_rysk_data_func=lambda: {},
            convert_to_wrapper_func=lambda x: x
        )

        self.assertEqual(result, 0)

    def test_value_options_otoken_empty_options(self):
        """Test options valuation with empty options list"""
        mock_w3 = Mock()
        strategy_config = Mock()
        strategy_config.extras = {'options': []}

        result = options_utils.value_options_otoken(
            w3=mock_w3,
            otoken_abi=[],
            erc20_abi=[],
            strategy_config=strategy_config,
            black_scholes_func=math_utils.black_scholes,
            get_asset_price_func=lambda x, y: 100.0,
            fetch_rysk_data_func=lambda: {},
            convert_to_wrapper_func=lambda x: x
        )

        self.assertEqual(result, 0)


class TestIntegrationComprehensive(unittest.TestCase):
    """Comprehensive integration tests"""

    def test_math_utils_integration(self):
        """Test math utils work together"""
        # Calculate option price
        price = math_utils.black_scholes(100, 100, 1, 0.2, 0.05, False)
        self.assertGreater(price, 0)

        # Convert to strategy ID
        strategy_id = math_utils.to_strategy_id("test")
        self.assertEqual(len(strategy_id), 32)

        # Calculate tick
        sqrt_price = math_utils.tick_to_sqrt_price_x96(0)
        self.assertGreater(sqrt_price, 0)

    def test_conversion_utils_chain(self):
        """Test conversion utils can be chained"""
        # Fixed ratio conversion
        amount1 = conversion_utils.convert_via_fixed_ratio(
            10**18, {'ratio': int(0.95 * 10**18)}
        )

        # Chain another conversion
        amount2 = conversion_utils.convert_via_fixed_ratio(
            amount1, {'ratio': int(0.9 * 10**18)}
        )

        # Should be ~85.5% of original
        self.assertAlmostEqual(amount2 / 10**18, 0.855, places=6)


class TestEdgeCases(unittest.TestCase):
    """Test edge cases for 100% coverage"""

    def test_black_scholes_zero_time(self):
        """Test Black-Scholes at expiry"""
        # ITM call at expiry
        price = math_utils.black_scholes(110, 100, 0, 0.2, 0.05, False)
        self.assertAlmostEqual(price, 10, places=1)

        # OTM call at expiry
        price = math_utils.black_scholes(90, 100, 0, 0.2, 0.05, False)
        self.assertAlmostEqual(price, 0, places=1)

    def test_black_scholes_very_long_time(self):
        """Test Black-Scholes with very long time"""
        price = math_utils.black_scholes(100, 100, 10, 0.2, 0.05, False)
        self.assertGreater(price, 20)  # Should have significant time value

    def test_norm_cdf_extreme_values(self):
        """Test norm_cdf with extreme values"""
        # Very negative
        result = math_utils.norm_cdf(-5.0)
        self.assertLess(result, 0.001)

        # Very positive
        result = math_utils.norm_cdf(5.0)
        self.assertGreater(result, 0.999)

    def test_tick_conversion_extreme_ticks(self):
        """Test tick conversion with extreme values"""
        # Very negative tick
        sqrt_price = math_utils.tick_to_sqrt_price_x96(-100000)
        self.assertGreater(sqrt_price, 0)

        # Very positive tick
        sqrt_price = math_utils.tick_to_sqrt_price_x96(100000)
        self.assertGreater(sqrt_price, 2**96)


def run_comprehensive_tests():
    """Run all comprehensive tests"""
    loader = unittest.TestLoader()
    suite = unittest.TestSuite()

    # Add all test classes
    suite.addTests(loader.loadTestsFromTestCase(TestMathUtilsComprehensive))
    suite.addTests(loader.loadTestsFromTestCase(TestConversionUtilsComprehensive))
    suite.addTests(loader.loadTestsFromTestCase(TestPricingUtilsComprehensive))
    suite.addTests(loader.loadTestsFromTestCase(TestOptionsUtilsComprehensive))
    suite.addTests(loader.loadTestsFromTestCase(TestIntegrationComprehensive))
    suite.addTests(loader.loadTestsFromTestCase(TestEdgeCases))

    # Run tests
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)

    # Print summary
    print("\n" + "=" * 70)
    print("COMPREHENSIVE TEST SUMMARY")
    print("=" * 70)
    print(f"Tests run: {result.testsRun}")
    print(f"Successes: {result.testsRun - len(result.failures) - len(result.errors)}")
    print(f"Failures: {len(result.failures)}")
    print(f"Errors: {len(result.errors)}")

    if result.wasSuccessful():
        print("\n✅ ALL TESTS PASSED!")
        return 0
    else:
        print("\n❌ SOME TESTS FAILED")
        return 1


if __name__ == '__main__':
    sys.exit(run_comprehensive_tests())
