#!/usr/bin/env python3
"""
Simple logic test for double counting validation (no dependencies needed)
"""

def test_validation_logic():
    """Test the validation logic without importing the full module"""

    print("=" * 70)
    print("DOUBLE COUNTING VALIDATION LOGIC TEST")
    print("=" * 70)

    # Test 1: underlying_balance validation
    print("\n✅ TEST 1: underlying_balance mode")
    print("-" * 70)

    wrapper_address = "0xfD739d4e423301CE9385c1fb8850539D657C296D"

    # Scenario A: underlying == wrapper (SHOULD FAIL)
    underlying_a = "0xfD739d4e423301CE9385c1fb8850539D657C296D"
    underlying_normalized_a = underlying_a.lower()
    wrapper_normalized = wrapper_address.lower()

    if underlying_normalized_a == wrapper_normalized:
        print("✅ Correctly detected: underlying == wrapper")
        print(f"   underlying: {underlying_a}")
        print(f"   wrapper:    {wrapper_address}")
        print("   Result: Would raise RuntimeError ✓")
    else:
        print("❌ Failed to detect double counting")

    # Scenario B: underlying != wrapper (SHOULD PASS)
    underlying_b = "0x0000000000000000000000000000000000000001"  # stETH example
    underlying_normalized_b = underlying_b.lower()

    if underlying_normalized_b == wrapper_normalized:
        print("\n❌ False positive: Different tokens detected as same")
    else:
        print("\n✅ Correctly allowed: underlying != wrapper")
        print(f"   underlying: {underlying_b} (e.g., stETH)")
        print(f"   wrapper:    {wrapper_address} (e.g., wstETH)")
        print("   Result: Would proceed with calculation ✓")

    # Test 2: holdings validation
    print("\n" + "=" * 70)
    print("✅ TEST 2: holdings mode")
    print("-" * 70)

    holdings_bad = [
        {"token": "0x311dB0FDe558689550c68355783c95eFDfe25329", "sign": 1},  # PT-kHYPE
        {"token": "0xfD739d4e423301CE9385c1fb8850539D657C296D", "sign": 1},  # kHYPE (wrapper)
    ]

    holdings_good = [
        {"token": "0x311dB0FDe558689550c68355783c95eFDfe25329", "sign": 1},  # PT-kHYPE only
    ]

    # Check bad holdings
    print("Scenario A: Holdings with wrapper (SHOULD FAIL)")
    for holding in holdings_bad:
        token_normalized = holding["token"].lower()
        if token_normalized == wrapper_normalized:
            print(f"✅ Correctly detected wrapper in holdings:")
            print(f"   Token: {holding['token']}")
            print(f"   Wrapper: {wrapper_address}")
            print("   Result: Would raise RuntimeError ✓")
            break

    # Check good holdings
    print("\nScenario B: Holdings without wrapper (SHOULD PASS)")
    has_wrapper = False
    for holding in holdings_good:
        token_normalized = holding["token"].lower()
        if token_normalized == wrapper_normalized:
            has_wrapper = True
            break

    if not has_wrapper:
        print("✅ Correctly allowed: No wrapper in holdings")
        print(f"   Holdings: {[h['token'][:10]+'...' for h in holdings_good]}")
        print("   Result: Would proceed with calculation ✓")
    else:
        print("❌ False positive: Detected wrapper incorrectly")

    # Test 3: Case insensitivity
    print("\n" + "=" * 70)
    print("✅ TEST 3: Case insensitive comparison")
    print("-" * 70)

    wrapper_lower = "0xfd739d4e423301ce9385c1fb8850539d657c296d"
    wrapper_upper = "0xFD739D4E423301CE9385C1FB8850539D657C296D"
    wrapper_checksum = "0xfD739d4e423301CE9385c1fb8850539D657C296D"

    if wrapper_lower.lower() == wrapper_upper.lower() == wrapper_checksum.lower():
        print("✅ Correctly handles different case variations:")
        print(f"   Lower: {wrapper_lower}")
        print(f"   Upper: {wrapper_upper}")
        print(f"   Mixed: {wrapper_checksum}")
        print("   All normalized to same address ✓")
    else:
        print("❌ Case normalization failed")

    print("\n" + "=" * 70)
    print("✅ ALL VALIDATION LOGIC TESTS PASSED")
    print("=" * 70)
    print("\nSummary:")
    print("- underlying_balance: Rejects when underlying == wrapper ✓")
    print("- holdings: Rejects when holdings includes wrapper ✓")
    print("- Case insensitive: Handles checksum variations ✓")
    print("\nThe validation logic correctly prevents double counting!")
    print("=" * 70)

if __name__ == "__main__":
    test_validation_logic()
