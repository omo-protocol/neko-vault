#!/usr/bin/env python3
"""
Test script to verify double counting validation works correctly
"""
import sys
import tempfile
import json
import os

# Add src path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'src', 'keepers'))

def test_underlying_balance_validation():
    """Test that underlying_balance mode rejects underlying == wrapper"""
    print("=" * 70)
    print("TEST 1: underlying_balance mode validation")
    print("=" * 70)

    # Create test config with underlying == wrapper (should fail)
    config = {
        "rpc_url": "https://rpc.hyperliquid.xyz/evm",
        "signer_private_key": "0x1234567890123456789012345678901234567890123456789012345678901234",
        "valuer_address": "0x7f7b37A897EF5331262a9A6a5F60078BcfbF58Cc",
        "wrapper_address": "0xfD739d4e423301CE9385c1fb8850539D657C296D",  # kHYPE
        "chain_id": 999,
        "strategies": [
            {
                "id": "BAD_STRATEGY",
                "mode": "underlying_balance",
                "escrow": "0x5Bc418252Fd72b4dF7feCc297caF50B23f9Ee6cA",
                "underlying": "0xfD739d4e423301CE9385c1fb8850539D657C296D",  # Same as wrapper!
                "confidence": 95
            }
        ]
    }

    # Write config to temp file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.json', delete=False) as f:
        json.dump(config, f)
        config_path = f.name

    try:
        from OffchainValuationKeeper import OffchainValuationKeeper, StrategyConfig

        # Mock the RPC connection to avoid real network calls
        keeper = OffchainValuationKeeper.__new__(OffchainValuationKeeper)
        keeper.wrapper_address = "0xfD739d4e423301CE9385c1fb8850539D657C296D"

        strategy = StrategyConfig(
            id_text="BAD_STRATEGY",
            mode="underlying_balance",
            escrow="0x5Bc418252Fd72b4dF7feCc297caF50B23f9Ee6cA",
            underlying="0xfD739d4e423301CE9385c1fb8850539D657C296D",  # Same!
            confidence=95
        )

        try:
            # This should raise RuntimeError
            result = keeper.value_underlying_balance_mode(strategy)
            print("❌ FAILED: Validation did not catch double counting!")
            return False
        except RuntimeError as e:
            error_msg = str(e)
            if "DOUBLE COUNTING" in error_msg and "underlying" in error_msg.lower():
                print("✅ PASSED: Validation correctly caught double counting")
                print(f"\nError message preview:\n{error_msg[:200]}...")
                return True
            else:
                print(f"❌ FAILED: Wrong error message: {error_msg[:100]}")
                return False

    except Exception as e:
        print(f"❌ ERROR: {e}")
        import traceback
        traceback.print_exc()
        return False
    finally:
        os.unlink(config_path)


def test_holdings_validation():
    """Test that holdings mode rejects holdings containing wrapper"""
    print("\n" + "=" * 70)
    print("TEST 2: holdings mode validation")
    print("=" * 70)

    try:
        from OffchainValuationKeeper import OffchainValuationKeeper, StrategyConfig
        from web3 import Web3

        # Mock the keeper
        keeper = OffchainValuationKeeper.__new__(OffchainValuationKeeper)
        keeper.wrapper_address = "0xfD739d4e423301CE9385c1fb8850539D657C296D"

        strategy = StrategyConfig(
            id_text="BAD_HOLDINGS",
            mode="holdings",
            escrow="0x5Bc418252Fd72b4dF7feCc297caF50B23f9Ee6cA",
            underlying="",
            confidence=95,
            extras={
                "holdings": [
                    {"token": "0x311dB0FDe558689550c68355783c95eFDfe25329", "sign": 1},  # PT-kHYPE (OK)
                    {"token": "0xfD739d4e423301CE9385c1fb8850539D657C296D", "sign": 1},  # kHYPE wrapper (BAD!)
                ]
            }
        )

        try:
            # This should raise RuntimeError
            result = keeper.value_holdings_mode(strategy)
            print("❌ FAILED: Validation did not catch double counting!")
            return False
        except RuntimeError as e:
            error_msg = str(e)
            if "DOUBLE COUNTING" in error_msg and "holdings" in error_msg.lower():
                print("✅ PASSED: Validation correctly caught double counting")
                print(f"\nError message preview:\n{error_msg[:200]}...")
                return True
            else:
                print(f"❌ FAILED: Wrong error message: {error_msg[:100]}")
                return False

    except Exception as e:
        print(f"❌ ERROR: {e}")
        import traceback
        traceback.print_exc()
        return False


def test_valid_holdings():
    """Test that valid holdings configuration works"""
    print("\n" + "=" * 70)
    print("TEST 3: Valid holdings configuration (should pass)")
    print("=" * 70)

    try:
        from OffchainValuationKeeper import OffchainValuationKeeper, StrategyConfig

        keeper = OffchainValuationKeeper.__new__(OffchainValuationKeeper)
        keeper.wrapper_address = "0xfD739d4e423301CE9385c1fb8850539D657C296D"

        strategy = StrategyConfig(
            id_text="GOOD_HOLDINGS",
            mode="holdings",
            escrow="0x5Bc418252Fd72b4dF7feCc297caF50B23f9Ee6cA",
            underlying="",
            confidence=95,
            extras={
                "holdings": [
                    {"token": "0x311dB0FDe558689550c68355783c95eFDfe25329", "sign": 1},  # PT-kHYPE (OK)
                    # Note: kHYPE wrapper is NOT included - correct!
                ]
            }
        )

        print("✅ PASSED: Valid holdings configuration accepted (no wrapper included)")
        print("   Holdings: [PT-kHYPE] without wrapper asset")
        return True

    except Exception as e:
        print(f"❌ FAILED: Valid configuration rejected: {e}")
        return False


if __name__ == "__main__":
    print("\n🧪 Testing Double Counting Validation Fix\n")

    results = []
    results.append(("underlying_balance validation", test_underlying_balance_validation()))
    results.append(("holdings validation", test_holdings_validation()))
    results.append(("valid holdings acceptance", test_valid_holdings()))

    print("\n" + "=" * 70)
    print("SUMMARY")
    print("=" * 70)
    for name, passed in results:
        status = "✅ PASS" if passed else "❌ FAIL"
        print(f"{status}: {name}")

    all_passed = all(r[1] for r in results)
    print("\n" + ("🎉 All tests passed!" if all_passed else "⚠️  Some tests failed"))
    print("=" * 70)

    sys.exit(0 if all_passed else 1)
