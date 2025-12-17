// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FixedPointMathLib as FPMath} from "solady/utils/FixedPointMathLib.sol";
import {IErrors} from "../interfaces/IErrors.sol";

/// @title LibMaths
/// @notice Optimized library for mathematical operations and B64 (52/5/7) floating point encoding
library LibMaths {
    // ========== CONSTANTS ==========

    /// @notice Fee precision: 1,000,000 base (1 unit = 0.0001% = 0.01 bps)
    uint256 internal constant BPS_PRECISION = 1_000_000;
    uint256 internal constant MAX_FEE_BPS = 65_000; // 6.5% hard cap
    uint256 internal constant PRECISION = 1e18;
    uint256 internal constant PRICE_PRECISION = 1e18;

    /// @notice Liquidity index initial value (lower than PRECISION for overflow protection)
    uint256 internal constant INDEX_PRECISION = 1e12;

    uint256 internal constant B64_MANTISSA_BITS = 52;
    uint256 internal constant B64_EXPONENT_BITS = 5;
    uint256 internal constant B64_DECIMAL_BITS = 7;

    uint256 internal constant B64_MANTISSA_MASK = (1 << B64_MANTISSA_BITS) - 1;
    uint256 internal constant B64_EXPONENT_MASK = (1 << B64_EXPONENT_BITS) - 1;
    uint256 internal constant B64_DECIMAL_MASK = (1 << B64_DECIMAL_BITS) - 1;

    uint256 internal constant B64_EXPONENT_SHIFT = B64_DECIMAL_BITS;
    uint256 internal constant B64_MANTISSA_SHIFT = B64_DECIMAL_BITS + B64_EXPONENT_BITS;

    uint256 internal constant B64_MAX_EXPONENT = (1 << B64_EXPONENT_BITS) - 1;

    // B64 52/5/7 encoding constants
    uint256 internal constant MAX_MANTISSA = (1 << B64_MANTISSA_BITS) - 1;
    int256 internal constant EXPONENT_BIAS = 64;
    int256 internal constant MIN_EXP = -64;
    int256 internal constant MAX_EXP = 63;

    uint256 internal constant MIN_SEGMENTS = 3;
    uint256 internal constant MAX_SEGMENTS = 32;

    uint256 internal constant WEIGHT_SUM = 255;

    uint8 internal constant BREADTH_PRECISION_DECIMALS = 2;

    // Safe bounds for totalShift in decodeB64 to prevent overflow
    int256 internal constant MAX_SAFE_POSITIVE_SHIFT = 61;  // log10((2^256-1) / MAX_MANTISSA)
    int256 internal constant MAX_SAFE_NEGATIVE_SHIFT = 77;  // Safe for division

    // ========== ERRORS ==========

    error Overflow();
    error InvalidDecimals();

    // ========== B64 ENCODING ==========

    /// @notice Encode x to B64 52/5/7 format
    /// @param x Price in native token decimals
    /// @param decimals Token decimal count (0-31)
    /// @return packed Encoded uint64
    function encodeB64(uint256 x, uint8 decimals) internal pure returns (uint64 packed) {
        if (x == 0) revert IErrors.ZeroValue();
        if (decimals > 31) revert InvalidDecimals();

        unchecked {
            uint256 mant = x;
            int256 exponent = 0;

            // Normalize mantissa to 52 bits (iterative rounding for B64 precision)
            while (mant > MAX_MANTISSA) {
                mant = (mant + 5) / 10;
                exponent++;
            }

            // Scale up if small (threshold: MAX_MANTISSA / 10)
            uint256 minMantissa = MAX_MANTISSA / 10;
            while (mant < minMantissa && exponent > MIN_EXP) {
                mant *= 10;
                exponent--;
            }

            if (exponent < MIN_EXP || exponent > MAX_EXP) revert Overflow();
            if (mant > MAX_MANTISSA) revert Overflow();

            // Pack: mant (52) | dec (5) | exponent+bias (7)
            assembly {
                let biased := add(exponent, EXPONENT_BIAS)
                packed := or(shl(12, mant), or(shl(7, decimals), biased))
            }
        }
    }

    // ========== B64 DECODING ==========

    /// @notice Decode B64 float to uint256 with target decimals
    /// @param packed Encoded B64 float
    /// @param tarb64Decimals Target decimal precision
    /// @return x Decoded uint256 in target decimals
    function decodeB64(uint64 packed, uint8 tarb64Decimals) internal pure returns (uint256 x) {
        if (packed == 0) revert IErrors.ZeroValue();

        unchecked {
            // Unpack using assembly
            uint256 mant;
            uint256 storedDecimals;
            int256 exponent;

            assembly {
                mant := shr(12, packed)
                storedDecimals := and(shr(7, packed), 0x1F)
                exponent := sub(and(packed, 0x7F), EXPONENT_BIAS)
            }

            if (mant == 0) revert IErrors.ZeroValue();

            // totalShift = exponent + target - stored
            int256 totalShift = exponent + int256(uint256(tarb64Decimals)) - int256(storedDecimals);

            // Bounds check: MAX_MANTISSA * 10^61 safely fits in uint256
            // For division, -77 is safe
            if (totalShift < -MAX_SAFE_NEGATIVE_SHIFT || totalShift > MAX_SAFE_POSITIVE_SHIFT) revert Overflow();

            if (totalShift >= 0) {
                uint256 multiplier = 10 ** uint256(totalShift);

                // Explicit overflow check BEFORE multiplication
                if (mant > type(uint256).max / multiplier) revert Overflow();

                x = mant * multiplier;
            } else {
                x = mant / (10 ** uint256(-totalShift));
            }
        }
    }

    /// @notice Decode B64 price to 1e18
    function b64To1e18(uint64 packed) internal pure returns (uint256 price) {
        return decodeB64(packed, 18);
    }

    /// @notice Get decimals from B64 encoded price
    function b64Decimals(uint64 packed) internal pure returns (uint8 decimals) {
        assembly {
            decimals := and(shr(7, packed), 0x1F)
        }
    }


    // ========== B64 ARITHMETIC (Pure Yul) ==========

    /// @notice Add two B64 encoded values
    /// @dev Direct arithmetic in Yul avoiding decode/re-encode
    /// @dev REQUIRES: Both values must have same decimal encoding
    /// @param a First B64 value
    /// @param b Second B64 value
    /// @return c Sum as B64
    function add64(uint64 a, uint64 b) internal pure returns (uint64 c) {
        assembly {
            function doAdd(x, y) -> result {
                // Constants (must be defined in assembly)
                let maxMant := 0xFFFFFFFFFFFFF  // (1 << 52) - 1
                // Mask to clean dirty bits (ensure 64-bit)
                let mask64 := 0xFFFFFFFFFFFFFFFF
                x := and(x, mask64)
                y := and(y, mask64)

                // Early exit if either is zero
                if iszero(x) { result := y leave }
                if iszero(y) { result := x leave }

                // Extract components
                let mantX := shr(12, x)
                let mantY := shr(12, y)
                let decX := and(shr(7, x), 0x1F)
                let decY := and(shr(7, y), 0x1F)
                let expX := sub(and(x, 0x7F), 64)
                let expY := sub(and(y, 0x7F), 64)

                // Use X's decimals for result
                let resultDec := decX

                // Require matching decimals - mixed decimal arithmetic is unsafe
                if iszero(eq(decX, decY)) {
                    revert(0, 0)  // DecimalMismatch
                }

                // Align mantissas to same exponent
                let resultExp := expX
                if gt(expY, expX) {
                    // Y has larger exponent, scale X down
                    let diff := sub(expY, expX)
                    if gt(diff, 18) {
                        // X is negligible compared to Y
                        result := y
                        leave
                    }
                    // Scale mantX down by 10^diff
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } {
                        mantX := div(mantX, 10)
                    }
                    resultExp := expY
                }
                if gt(expX, expY) {
                    // X has larger exponent, scale Y down
                    let diff := sub(expX, expY)
                    if gt(diff, 18) {
                        // Y is negligible compared to X
                        result := x
                        leave
                    }
                    // Scale mantY down by 10^diff
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } {
                        mantY := div(mantY, 10)
                    }
                }

                // Add mantissas
                let mantResult := add(mantX, mantY)

                // Normalize if overflow
                for { } gt(mantResult, maxMant) { } {
                    mantResult := div(add(mantResult, 5), 10)
                    resultExp := add(resultExp, 1)
                }

                // Check exponent bounds
                if or(slt(resultExp, sub(0, 64)), sgt(resultExp, 63)) {
                    revert(0, 0) // ExponentOverflow
                }

                // Pack result
                let biasedExp := add(resultExp, 64)
                result := or(shl(12, mantResult), or(shl(7, resultDec), biasedExp))
                result := and(result, mask64)
            }

            c := doAdd(a, b)
        }
    }

    /// @notice Subtract two B64 encoded values
    /// @dev Returns 0 if b > a
    /// @dev REQUIRES: Both values must have same decimal encoding
    /// @param a First B64 value
    /// @param b Second B64 value
    /// @return c Difference as B64 (or 0 if underflow)
    function sub64(uint64 a, uint64 b) internal pure returns (uint64 c) {
        assembly {
            function doSub(x, y) -> result {
                // Constants
                let maxMant := 0xFFFFFFFFFFFFF  // (1 << 52) - 1
                // Mask to clean dirty bits
                let mask64 := 0xFFFFFFFFFFFFFFFF
                x := and(x, mask64)
                y := and(y, mask64)

                // Early exits
                if iszero(y) { result := x leave }
                if iszero(x) { result := 0 leave }

                // Extract components
                let mantX := shr(12, x)
                let mantY := shr(12, y)
                let decX := and(shr(7, x), 0x1F)
                let decY := and(shr(7, y), 0x1F)
                let expX := sub(and(x, 0x7F), 64)
                let expY := sub(and(y, 0x7F), 64)

                // Use X's decimals for result
                let resultDec := decX

                // Require matching decimals - mixed decimal arithmetic is unsafe
                if iszero(eq(decX, decY)) {
                    revert(0, 0)  // DecimalMismatch
                }

                // Align mantissas
                if gt(expY, expX) {
                    let diff := sub(expY, expX)
                    if gt(diff, 18) {
                        // Y is much larger than X
                        result := 0
                        leave
                    }
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } {
                        mantX := div(mantX, 10)
                    }
                }
                if gt(expX, expY) {
                    let diff := sub(expX, expY)
                    if gt(diff, 18) {
                        // X is much larger, Y negligible
                        result := x
                        leave
                    }
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } {
                        mantY := div(mantY, 10)
                    }
                }

                // Check underflow
                if gt(mantY, mantX) {
                    result := 0
                    leave
                }

                // Subtract mantissas
                let mantResult := sub(mantX, mantY)
                if iszero(mantResult) {
                    result := 0
                    leave
                }

                // Use larger exponent
                let resultExp := expX
                if gt(expY, expX) { resultExp := expY }

                // Normalize if needed (scale up small results)
                for { } lt(mantResult, div(maxMant, 10)) { } {
                    if slt(resultExp, sub(0, 63)) { break }
                    mantResult := mul(mantResult, 10)
                    resultExp := sub(resultExp, 1)
                }

                // Check exponent bounds
                if or(slt(resultExp, sub(0, 64)), sgt(resultExp, 63)) {
                    revert(0, 0)
                }

                // Pack result
                let biasedExp := add(resultExp, 64)
                result := or(shl(12, mantResult), or(shl(7, resultDec), biasedExp))
                result := and(result, mask64)
            }

            c := doSub(a, b)
        }
    }

    // ========== SAFE B64 ARITHMETIC (With Decimal Normalization) ==========

    /// @notice Safely add two B64 values, normalizing decimals if needed
    /// @param a First B64 value
    /// @param b Second B64 value
    /// @return Sum as B64 (uses decimals from a)
    function safeAdd64(uint64 a, uint64 b) internal pure returns (uint64) {
        if (a == 0) return b;
        if (b == 0) return a;

        uint8 decA = b64Decimals(a);
        uint8 decB = b64Decimals(b);

        if (decA == decB) {
            return add64(a, b);
        }

        // Normalize b to match a's decimals
        uint256 bDecoded = decodeB64(b, decB);
        uint64 bNormalized = encodeB64(bDecoded, decA);
        return add64(a, bNormalized);
    }

    /// @notice Safely subtract two B64 values, normalizing decimals if needed
    /// @param a First B64 value
    /// @param b Second B64 value to subtract
    /// @return Difference as B64 (uses decimals from a)
    function safeSub64(uint64 a, uint64 b) internal pure returns (uint64) {
        if (b == 0) return a;

        uint8 decA = b64Decimals(a);
        uint8 decB = b64Decimals(b);

        if (decA == decB) {
            return sub64(a, b);
        }

        // Normalize b to match a's decimals
        uint256 bDecoded = decodeB64(b, decB);
        uint64 bNormalized = encodeB64(bDecoded, decA);
        return sub64(a, bNormalized);
    }

    // ========== B64 COMPARISON ==========

    /// @notice Compare two B64 values (greater than)
    /// @param a First B64 value
    /// @param b Second B64 value
    /// @return result True if a > b
    function gt64(uint64 a, uint64 b) internal pure returns (bool result) {
        assembly {
            function doGt(x, y) -> res {
                // Clean inputs
                x := and(x, 0xFFFFFFFFFFFFFFFF)
                y := and(y, 0xFFFFFFFFFFFFFFFF)

                // Handle zeros
                if iszero(x) { res := 0 leave }
                if iszero(y) { res := 1 leave }

                // Extract components
                let mantX := shr(12, x)
                let mantY := shr(12, y)
                let decX := and(shr(7, x), 0x1F)
                let decY := and(shr(7, y), 0x1F)
                let expX := sub(and(x, 0x7F), 64)
                let expY := sub(and(y, 0x7F), 64)

                // Require matching decimals for comparison
                if iszero(eq(decX, decY)) {
                    revert(0, 0)  // DecimalMismatch
                }

                // Compare by effective exponent first
                let effExpX := expX
                let effExpY := expY

                // Rough magnitude comparison
                for { let m := mantX } gt(m, 9999999999999) { } {
                    m := div(m, 10)
                    effExpX := add(effExpX, 1)
                }
                for { let m := mantY } gt(m, 9999999999999) { } {
                    m := div(m, 10)
                    effExpY := add(effExpY, 1)
                }

                if gt(effExpX, effExpY) { res := 1 leave }
                if lt(effExpX, effExpY) { res := 0 leave }

                // Same effective exponent, align and compare mantissas
                if gt(expX, expY) {
                    let diff := sub(expX, expY)
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } {
                        mantY := div(mantY, 10)
                    }
                }
                if gt(expY, expX) {
                    let diff := sub(expY, expX)
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } {
                        mantX := div(mantX, 10)
                    }
                }

                res := gt(mantX, mantY)
            }

            result := doGt(a, b)
        }
    }

    /// @notice Compare two B64 values (less than)
    /// @param a First B64 value
    /// @param b Second B64 value
    /// @return result True if a < b
    function lt64(uint64 a, uint64 b) internal pure returns (bool result) {
        assembly {
            function doLt(x, y) -> res {
                // Clean inputs
                x := and(x, 0xFFFFFFFFFFFFFFFF)
                y := and(y, 0xFFFFFFFFFFFFFFFF)

                // Handle zeros
                if iszero(x) {
                    if iszero(y) { res := 0 }
                    if iszero(iszero(y)) { res := 1 }
                    leave
                }
                if iszero(y) { res := 0 leave }

                // Extract components
                let mantX := shr(12, x)
                let mantY := shr(12, y)
                let decX := and(shr(7, x), 0x1F)
                let decY := and(shr(7, y), 0x1F)
                let expX := sub(and(x, 0x7F), 64)
                let expY := sub(and(y, 0x7F), 64)

                // Require matching decimals for comparison
                if iszero(eq(decX, decY)) {
                    revert(0, 0)  // DecimalMismatch
                }

                // Compare by effective exponent first
                let effExpX := expX
                let effExpY := expY

                // Rough magnitude comparison
                for { let m := mantX } gt(m, 9999999999999) { } {
                    m := div(m, 10)
                    effExpX := add(effExpX, 1)
                }
                for { let m := mantY } gt(m, 9999999999999) { } {
                    m := div(m, 10)
                    effExpY := add(effExpY, 1)
                }

                if lt(effExpX, effExpY) { res := 1 leave }
                if gt(effExpX, effExpY) { res := 0 leave }

                // Same effective exponent, align and compare mantissas
                if gt(expX, expY) {
                    let diff := sub(expX, expY)
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } {
                        mantY := div(mantY, 10)
                    }
                }
                if gt(expY, expX) {
                    let diff := sub(expY, expX)
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } {
                        mantX := div(mantX, 10)
                    }
                }

                res := lt(mantX, mantY)
            }

            result := doLt(a, b)
        }
    }

    /// @notice Multiply two B64 encoded values (fixed-point multiplication)
    /// @dev Result inherits decimals from first operand (like wadMul)
    /// @dev For price × amount calculations where price has target decimals
    /// @param a First B64 value (result inherits its decimals)
    /// @param b Second B64 value (treated as fixed-point multiplier)
    /// @return c Product as B64 with a's decimals
    function mul64(uint64 a, uint64 b) internal pure returns (uint64 c) {
        assembly {
            function doMul(x, y) -> result {
                // Constants
                let maxMant := 0xFFFFFFFFFFFFF  // (1 << 52) - 1
                // Clean inputs
                x := and(x, 0xFFFFFFFFFFFFFFFF)
                y := and(y, 0xFFFFFFFFFFFFFFFF)

                // Handle zeros
                if or(iszero(x), iszero(y)) {
                    result := 0
                    leave
                }

                // Extract components
                let mantX := shr(12, x)
                let mantY := shr(12, y)
                let decX := and(shr(7, x), 0x1F)
                let decY := and(shr(7, y), 0x1F)
                let expX := sub(and(x, 0x7F), 64)
                let expY := sub(and(y, 0x7F), 64)

                // Multiply mantissas (may overflow uint64)
                let mantResult := mul(mantX, mantY)
                let resultExp := add(expX, expY)
                let resultDec := decX  // Use first operand's decimals

                // Normalize mantissa
                for { } gt(mantResult, maxMant) { } {
                    mantResult := div(add(mantResult, 5), 10)
                    resultExp := add(resultExp, 1)
                }

                // Check exponent bounds
                if or(slt(resultExp, sub(0, 64)), sgt(resultExp, 63)) {
                    revert(0, 0)
                }

                // Pack result
                let biasedExp := add(resultExp, 64)
                result := or(shl(12, mantResult), or(shl(7, resultDec), biasedExp))
                result := and(result, 0xFFFFFFFFFFFFFFFF)
            }

            c := doMul(a, b)
        }
    }

    /// @notice Divide two B64 encoded values (fixed-point division)
    /// @dev Result inherits decimals from numerator
    /// @dev For value / price calculations where result needs specific decimals
    /// @param a Numerator B64 value (result inherits its decimals)
    /// @param b Denominator B64 value (treated as divisor)
    /// @return c Quotient as B64 with a's decimals
    function div64(uint64 a, uint64 b) internal pure returns (uint64 c) {
        assembly {
            function doDiv(x, y) -> result {
                // Constants
                let maxMant := 0xFFFFFFFFFFFFF  // (1 << 52) - 1
                // Clean inputs
                x := and(x, 0xFFFFFFFFFFFFFFFF)
                y := and(y, 0xFFFFFFFFFFFFFFFF)

                // Check for division by zero
                if iszero(y) { revert(0, 0) }

                // Handle zero numerator
                if iszero(x) {
                    result := 0
                    leave
                }

                // Extract components
                let mantX := shr(12, x)
                let mantY := shr(12, y)
                let decX := and(shr(7, x), 0x1F)
                let decY := and(shr(7, y), 0x1F)
                let expX := sub(and(x, 0x7F), 64)
                let expY := sub(and(y, 0x7F), 64)

                // Scale up numerator for precision
                let scaledMantX := mantX
                let scaleExp := 0

                // Scale up mantX to preserve precision during division
                for { } lt(scaledMantX, mul(maxMant, 1000)) { } {
                    if sgt(scaleExp, 18) { break }
                    scaledMantX := mul(scaledMantX, 10)
                    scaleExp := add(scaleExp, 1)
                }

                // Divide mantissas
                let mantResult := div(scaledMantX, mantY)
                let resultExp := sub(sub(expX, expY), scaleExp)
                let resultDec := decX  // Use numerator's decimals

                // Normalize if needed
                for { } gt(mantResult, maxMant) { } {
                    mantResult := div(add(mantResult, 5), 10)
                    resultExp := add(resultExp, 1)
                }

                // Scale up if too small
                for { } lt(mantResult, div(maxMant, 10)) { } {
                    if slt(resultExp, sub(0, 63)) { break }
                    mantResult := mul(mantResult, 10)
                    resultExp := sub(resultExp, 1)
                }

                // Check exponent bounds
                if or(slt(resultExp, sub(0, 64)), sgt(resultExp, 63)) {
                    revert(0, 0)
                }

                // Pack result
                let biasedExp := add(resultExp, 64)
                result := or(shl(12, mantResult), or(shl(7, resultDec), biasedExp))
                result := and(result, 0xFFFFFFFFFFFFFFFF)
            }

            c := doDiv(a, b)
        }
    }

    /// @notice Calculate volatility between two prices
    /// @param a64 Old price (B64)
    /// @param b64 New price (B64)
    /// @return Volatility in 1e6 base (1_000_000 = 1%)
    function diff1e6(uint64 a64, uint64 b64) internal pure returns (uint32) {
        if (a64 == 0 || b64 == 0) return 10_000_000; // 10% default
        unchecked {
            (uint256 a, uint256 b) = (b64To1e18(a64), b64To1e18(b64));

            if (a == 0) return 10_000_000;

            // Branchless abs diff
            uint256 diff = a > b ? a - b : b - a;
            uint256 vol = (diff * 1_000_000) / a;
            return vol > type(uint32).max ? type(uint32).max : uint32(vol);
        }
    }
}
