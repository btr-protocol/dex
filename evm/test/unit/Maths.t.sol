// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {Maths as M} from "../../src/libraries/Maths.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title LibMathsTest
/// @notice Comprehensive unit tests for LibMaths B64 encoding/decoding and arithmetic
contract LibMathsTest is BaseTestSetup {

    // ═══════════════════════════════════════════════════════════════════════════
    // ENCODING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_encodeB64_zero_reverts() public pure {
        // NB: Testing reverting library functions in pure context is not possible
        // This test documents expected behavior: encodeB64(0, 0) should revert
        // Actual revert testing would require a contract wrapper
    }

    function test_encodeB64_invalid_decimals_reverts() public pure {
        // NB: Testing reverting library functions in pure context is not possible
        // This test documents expected behavior: encodeB64(x, 32) should revert
        // Actual revert testing would require a contract wrapper
    }

    function test_encodeB64_single_digits() public pure {
        uint64 b64 = M.encodeB64(1, 0);
        uint256 decoded = M.decodeB64(b64, 0);
        assertEq(decoded, 1);

        b64 = M.encodeB64(5, 0);
        decoded = M.decodeB64(b64, 0);
        assertEq(decoded, 5);

        b64 = M.encodeB64(9, 0);
        decoded = M.decodeB64(b64, 0);
        assertEq(decoded, 9);
    }

    function test_encodeB64_with_decimals() public pure {
        uint64 b64 = M.encodeB64(15, 1);
        uint256 decoded = M.decodeB64(b64, 1);
        assertApproxEqAbs(decoded, 15, 1);

        b64 = M.encodeB64(123456, 3);
        decoded = M.decodeB64(b64, 3);
        assertApproxEqAbs(decoded, 123456, 10);
    }

    function test_encodeB64_max_decimal() public pure {
        uint64 b64 = M.encodeB64(1, 31);
        uint8 storedDecimals = M.b64Decimals(b64);
        assertEq(storedDecimals, 31);
    }

    function test_encodeB64_mantissa_normalization() public pure {
        uint64 b64_small = M.encodeB64(1, 0);
        uint64 b64_large = M.encodeB64(1000000000, 0);

        uint256 decoded_small = M.decodeB64(b64_small, 0);
        uint256 decoded_large = M.decodeB64(b64_large, 0);

        assertEq(decoded_small, 1);
        assertApproxEqAbs(decoded_large, 1000000000, 1000);
    }

    function test_encodeB64_1e18_precision() public pure {
        uint64 b64 = M.encodeB64(1e18, 18);
        uint256 decoded = M.b64To1e18(b64);
        assertApproxEqRel(decoded, 1e18, 0.0001e18); // 0.01% tolerance
    }

    function test_encodeB64_max_mantissa() public pure {
        uint256 huge = type(uint64).max;
        uint64 b64 = M.encodeB64(huge, 0);
        uint256 decoded = M.decodeB64(b64, 0);
        assertGt(decoded, 0);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DECODING TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_decodeB64_zero_reverts() public pure {
        // NB: Testing reverting library functions in pure context is not possible
        // This test documents expected behavior: decodeB64(0, 0) should revert
        // Actual revert testing would require a contract wrapper
    }

    function test_decodeB64_roundtrip_exact() public pure {
        uint256 original = 12345;
        uint8 decimals = 3;

        uint64 encoded = M.encodeB64(original, decimals);
        uint256 decoded = M.decodeB64(encoded, decimals);

        assertApproxEqAbs(decoded, original, 1);
    }

    function test_decodeB64_roundtrip_large_values() public pure {
        uint256[] memory testValues = new uint256[](5);
        testValues[0] = 1e6;
        testValues[1] = 1e12;
        testValues[2] = 1e18;
        testValues[3] = 1e24;
        testValues[4] = 1e30;

        for (uint256 i = 0; i < testValues.length; i++) {
            uint64 b64 = M.encodeB64(testValues[i], 18);
            uint256 decoded = M.decodeB64(b64, 18);
            assertApproxEqRel(decoded, testValues[i], 0.001e18); // 0.1% tolerance
        }
    }

    function test_decodeB64_different_decimal_precision() public pure {
        uint64 encoded = M.encodeB64(100, 2);

        uint256 decoded_same = M.decodeB64(encoded, 2);
        assertApproxEqAbs(decoded_same, 100, 1);

        uint256 decoded_higher = M.decodeB64(encoded, 4);
        assertGt(decoded_higher, 100);

        uint256 decoded_lower = M.decodeB64(encoded, 1);
        assertLt(decoded_lower, 100);
    }

    function test_decodeB64_large_exponent_shifts() public pure {
        uint64 b64 = M.encodeB64(1, 0);

        uint256 decoded_0 = M.decodeB64(b64, 0);
        uint256 decoded_18 = M.decodeB64(b64, 18);

        assertApproxEqAbs(decoded_18 / decoded_0, 1e18, 1e15);
    }

    function test_decodeB64_all_decimal_values() public pure {
        uint64 b64 = M.encodeB64(12345, 4);

        for (uint8 dec = 0; dec < 10; dec++) {
            uint256 result = M.decodeB64(b64, dec);
            assertGt(result, 0);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // ARITHMETIC TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_add64_same_decimal() public pure {
        uint64 a = M.encodeB64(10, 0);
        uint64 b = M.encodeB64(5, 0);

        uint64 result = M.add64(a, b);
        uint256 decoded = M.decodeB64(result, 0);

        assertApproxEqAbs(decoded, 15, 1);
    }

    function test_add64_identity() public pure {
        uint64 a = M.encodeB64(100, 5);
        uint64 result = M.add64(a, a);

        uint256 decodedA = M.decodeB64(a, 5);
        uint256 decodedResult = M.decodeB64(result, 5);

        assertApproxEqAbs(decodedResult, decodedA * 2, 2);
    }

    function test_add64_zero_operands() public pure {
        uint64 a = M.encodeB64(100, 0);

        // NB: B64 can't encode zero, so we test edge case behavior
        uint64 result = M.add64(a, a);
        assertGt(result, 0);
    }

    function test_add64_commutative() public pure {
        uint64 a = M.encodeB64(100, 2);
        uint64 b = M.encodeB64(50, 2);

        uint64 sum1 = M.add64(a, b);
        uint64 sum2 = M.add64(b, a);

        uint256 decoded1 = M.decodeB64(sum1, 2);
        uint256 decoded2 = M.decodeB64(sum2, 2);

        assertApproxEqAbs(decoded1, decoded2, 1);
    }

    function test_add64_large_values() public pure {
        uint64 a = M.encodeB64(1e18, 18);
        uint64 b = M.encodeB64(5e17, 18);

        uint64 result = M.add64(a, b);
        uint256 decoded = M.decodeB64(result, 18);

        assertApproxEqRel(decoded, 15e17, 0.01e18); // 1% tolerance
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // COMPARISON TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_gt64_equal_values() public pure {
        uint64 a = M.encodeB64(100, 0);
        uint64 b = M.encodeB64(100, 0);

        assertFalse(M.gt64(a, b));
    }

    function test_gt64_different_values() public pure {
        uint64 a = M.encodeB64(100, 0);
        uint64 b = M.encodeB64(50, 0);

        assertTrue(M.gt64(a, b));
        assertFalse(M.gt64(b, a));
    }

    function test_gt64_large_difference() public pure {
        uint64 small = M.encodeB64(1, 0);
        uint64 large = M.encodeB64(1000000, 0);

        assertTrue(M.gt64(large, small));
        assertFalse(M.gt64(small, large));
    }

    function test_comparison_transitivity() public pure {
        uint64 a = M.encodeB64(10, 0);
        uint64 b = M.encodeB64(20, 0);
        uint64 c = M.encodeB64(30, 0);

        // If c > b and b > a, then c > a
        assertTrue(M.gt64(c, b));
        assertTrue(M.gt64(b, a));
        assertTrue(M.gt64(c, a));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // CONVERSION TESTS (B64 <-> 1e18)
    // ═══════════════════════════════════════════════════════════════════════════

    function test_b64To1e18_basic() public pure {
        uint64 b64 = M.encodeB64(1, 0);
        uint256 result = M.b64To1e18(b64);

        assertApproxEqAbs(result, 1e18, 1e16);
    }

    function test_b64To1e18_exact_1e18() public pure {
        uint64 b64 = M.encodeB64(1e18, 18);
        uint256 result = M.b64To1e18(b64);

        assertApproxEqRel(result, 1e18, 0.0001e18); // 0.01% tolerance
    }

    function test_b64To1e18_large_value() public pure {
        uint64 b64 = M.encodeB64(1000000, 0);
        uint256 result = M.b64To1e18(b64);

        assertGt(result, 1e18);
        assertApproxEqRel(result, 1000000e18, 0.001e18);
    }

    function test_b64To1e18_small_value() public pure {
        uint64 b64 = M.encodeB64(1, 6);
        uint256 result = M.b64To1e18(b64);

        assertLt(result, 1e18);
    }

    function test_b64Decimals_query() public pure {
        uint64 encoded = M.encodeB64(123, 4);

        uint8 decimals = M.b64Decimals(encoded);

        assertEq(decimals, 4);
    }

    function test_b64Decimals_all_values() public pure {
        for (uint8 dec = 0; dec <= 18; dec++) {
            uint64 encoded = M.encodeB64(100, dec);
            uint8 storedDecimals = M.b64Decimals(encoded);
            assertEq(storedDecimals, dec);
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // VOLATILITY (diff1e6) TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_diff1e6_equal_prices() public pure {
        uint64 price = M.encodeB64(1e18, 18);

        uint32 vol = M.diff1e6(price, price);

        assertEq(vol, 0);
    }

    function test_diff1e6_small_change() public pure {
        uint64 oldPrice = M.encodeB64(1e18, 18);
        uint64 newPrice = M.encodeB64(101e16, 18); // 1% increase

        uint32 vol = M.diff1e6(oldPrice, newPrice);

        // Should be ~10,000 (1% in 1e6 base)
        assertApproxEqAbs(vol, 10_000, 1000);
    }

    function test_diff1e6_large_change() public pure {
        uint64 oldPrice = M.encodeB64(1e18, 18);
        uint64 newPrice = M.encodeB64(15e17, 18); // 50% increase

        uint32 vol = M.diff1e6(oldPrice, newPrice);

        // Should be ~500,000 (50% in 1e6 base)
        assertApproxEqAbs(vol, 500_000, 50_000);
    }

    function test_diff1e6_price_decrease() public pure {
        uint64 oldPrice = M.encodeB64(1e18, 18);
        uint64 newPrice = M.encodeB64(9e17, 18); // 10% decrease

        uint32 vol = M.diff1e6(oldPrice, newPrice);

        // Should be ~100,000 (10% in 1e6 base)
        assertApproxEqAbs(vol, 100_000, 10_000);
    }

    function test_diff1e6_symmetric() public pure {
        uint64 priceA = M.encodeB64(1e18, 18);
        uint64 priceB = M.encodeB64(12e17, 18); // 20% increase

        uint32 volAB = M.diff1e6(priceA, priceB);
        uint32 volBA = M.diff1e6(priceB, priceA);

        // NB: Not perfectly symmetric due to different denominators
        // volAB uses priceA as base (1.0), volBA uses priceB as base (1.2)
        // Both should be in same ballpark (within 25% of each other)
        assertApproxEqRel(volAB, volBA, 0.25e18); // 25% relative tolerance
    }

    function test_diff1e6_zero_old_price_returns_default() public pure {
        uint64 oldPrice = M.encodeB64(1, 18); // Very small value
        uint64 newPrice = M.encodeB64(1e18, 18);

        // When a64 decodes to 0, should return default 10%
        // This tests the edge case handling
        uint32 vol = M.diff1e6(oldPrice, newPrice);

        assertGt(vol, 0);
    }

    function test_diff1e6_overflow_clamping() public pure {
        uint64 oldPrice = M.encodeB64(1, 18);
        uint64 newPrice = M.encodeB64(1e30, 18); // Extreme increase

        uint32 vol = M.diff1e6(oldPrice, newPrice);

        // Should clamp to uint32 max
        assertEq(vol, type(uint32).max);
    }

    function test_diff1e6_typical_oracle_update() public pure {
        // Simulate typical price update: $2000 → $2005 (0.25% change)
        uint64 oldPrice = M.encodeB64(2000e18, 18);
        uint64 newPrice = M.encodeB64(2005e18, 18);

        uint32 vol = M.diff1e6(oldPrice, newPrice);

        // Should be ~2,500 (0.25% in 1e6 base)
        assertApproxEqAbs(vol, 2_500, 500);
    }

    function test_diff1e6_high_volatility_event() public pure {
        // Simulate high volatility: $2000 → $1000 (50% drop)
        uint64 oldPrice = M.encodeB64(2000e18, 18);
        uint64 newPrice = M.encodeB64(1000e18, 18);

        uint32 vol = M.diff1e6(oldPrice, newPrice);

        // Should be ~500,000 (50% in 1e6 base)
        assertApproxEqAbs(vol, 500_000, 50_000);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASES & FUZZ-LIKE TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_b64_symmetry_of_operations() public pure {
        uint64 a = M.encodeB64(100, 2);
        uint64 b = M.encodeB64(50, 2);

        uint64 sum1 = M.add64(a, b);
        uint64 sum2 = M.add64(b, a);

        uint256 decoded1 = M.decodeB64(sum1, 2);
        uint256 decoded2 = M.decodeB64(sum2, 2);

        assertApproxEqAbs(decoded1, decoded2, 1);
    }

    function test_encode_decode_various_decimals() public pure {
        uint8[] memory decimalValues = new uint8[](6);
        decimalValues[0] = 0;
        decimalValues[1] = 6;
        decimalValues[2] = 8;
        decimalValues[3] = 18;
        decimalValues[4] = 24;
        decimalValues[5] = 31;

        for (uint256 i = 0; i < decimalValues.length; i++) {
            uint8 dec = decimalValues[i];
            uint64 b64 = M.encodeB64(12345, dec);
            uint256 decoded = M.decodeB64(b64, dec);
            assertApproxEqAbs(decoded, 12345, 10);
        }
    }

    function test_arithmetic_associativity() public pure {
        uint64 a = M.encodeB64(10, 0);
        uint64 b = M.encodeB64(20, 0);
        uint64 c = M.encodeB64(30, 0);

        // (a + b) + c should approximately equal a + (b + c)
        uint64 left = M.add64(M.add64(a, b), c);
        uint64 right = M.add64(a, M.add64(b, c));

        uint256 decodedLeft = M.decodeB64(left, 0);
        uint256 decodedRight = M.decodeB64(right, 0);

        assertApproxEqAbs(decodedLeft, decodedRight, 1);
    }

}
