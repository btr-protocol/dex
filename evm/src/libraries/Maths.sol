// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";

/// @title Maths -B64 (52/5/7) float ops + helpers.
/// @dev Constants WAD/PBPS @ Constants. B64 layout: mantissa(52)|decimals(5)|exp+bias(7).
library Maths {
    // --- B64 constants ---
    uint256 internal constant B64_MANTISSA_BITS = 52;
    uint256 internal constant B64_EXPONENT_BITS = 5;
    uint256 internal constant B64_DECIMAL_BITS = 7;
    uint256 internal constant MAX_MANTISSA = (1 << B64_MANTISSA_BITS) - 1;
    int256 internal constant EXPONENT_BIAS = 64;
    int256 internal constant MIN_EXP = -64;
    int256 internal constant MAX_EXP = 63;
    // Bounds for decodeB64 totalShift (overflow safety).
    int256 internal constant MAX_SAFE_POSITIVE_SHIFT = 61;
    int256 internal constant MAX_SAFE_NEGATIVE_SHIFT = 77;

    // --- Encode / decode ---

    /// @notice Encode x (in `decimals`) → B64.
    function encodeB64(uint256 x, uint8 decimals) internal pure returns (uint64 packed) {
        if (x == 0) revert Err.ZeroValue();
        if (decimals > 31) revert Err.InvalidDecimals();
        unchecked {
            uint256 mant = x;
            int256 exponent = 0;
            while (mant > MAX_MANTISSA) { mant = (mant + 5) / 10; exponent++; }
            uint256 minMantissa = MAX_MANTISSA / 10;
            while (mant < minMantissa && exponent > MIN_EXP) { mant *= 10; exponent--; }
            if (exponent < MIN_EXP || exponent > MAX_EXP) revert Err.Overflow();
            if (mant > MAX_MANTISSA) revert Err.Overflow();
            assembly {
                let biased := add(exponent, EXPONENT_BIAS)
                packed := or(shl(12, mant), or(shl(7, decimals), biased))
            }
        }
    }

    /// @notice Decode B64 → uint256 in `tarb64Decimals`.
    function decodeB64(uint64 packed, uint8 tarb64Decimals) internal pure returns (uint256 x) {
        if (packed == 0) revert Err.ZeroValue();
        unchecked {
            uint256 mant;
            uint256 storedDecimals;
            int256 exponent;
            assembly {
                mant := shr(12, packed)
                storedDecimals := and(shr(7, packed), 0x1F)
                exponent := sub(and(packed, 0x7F), EXPONENT_BIAS)
            }
            if (mant == 0) revert Err.ZeroValue();
            int256 totalShift = exponent + int256(uint256(tarb64Decimals)) - int256(storedDecimals);
            if (totalShift < -MAX_SAFE_NEGATIVE_SHIFT || totalShift > MAX_SAFE_POSITIVE_SHIFT) revert Err.Overflow();
            if (totalShift >= 0) {
                uint256 mul = 10 ** uint256(totalShift);
                if (mant > type(uint256).max / mul) revert Err.Overflow();
                x = mant * mul;
            } else {
                x = mant / (10 ** uint256(-totalShift));
            }
        }
    }

    /// @notice Decode B64 → 1e18 fixed-point.
    function b64To1e18(uint64 packed) internal pure returns (uint256) {
        return decodeB64(packed, 18);
    }

    /// @notice Extract decimals from B64.
    function b64Decimals(uint64 packed) internal pure returns (uint8 decimals) {
        assembly { decimals := and(shr(7, packed), 0x1F) }
    }

    // --- B64 arithmetic (Yul) ---
    // Both operands MUST share decimals.

    /// @notice a + b (B64). Reverts on decimal mismatch / exp overflow.
    function add64(uint64 a, uint64 b) internal pure returns (uint64 c) {
        assembly {
            function doAdd(x, y) -> result {
                let maxMant := 0xFFFFFFFFFFFFF
                let mask64 := 0xFFFFFFFFFFFFFFFF
                x := and(x, mask64)
                y := and(y, mask64)
                if iszero(x) { result := y leave }
                if iszero(y) { result := x leave }
                let mantX := shr(12, x)
                let mantY := shr(12, y)
                let decX := and(shr(7, x), 0x1F)
                let decY := and(shr(7, y), 0x1F)
                let expX := sub(and(x, 0x7F), 64)
                let expY := sub(and(y, 0x7F), 64)
                if iszero(eq(decX, decY)) { revert(0, 0) }
                let resultExp := expX
                if gt(expY, expX) {
                    let diff := sub(expY, expX)
                    if gt(diff, 18) { result := y leave }
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } { mantX := div(mantX, 10) }
                    resultExp := expY
                }
                if gt(expX, expY) {
                    let diff := sub(expX, expY)
                    if gt(diff, 18) { result := x leave }
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } { mantY := div(mantY, 10) }
                }
                let mantR := add(mantX, mantY)
                for { } gt(mantR, maxMant) { } { mantR := div(add(mantR, 5), 10) resultExp := add(resultExp, 1) }
                if or(slt(resultExp, sub(0, 64)), sgt(resultExp, 63)) { revert(0, 0) }
                let biased := add(resultExp, 64)
                result := and(or(shl(12, mantR), or(shl(7, decX), biased)), mask64)
            }
            c := doAdd(a, b)
        }
    }

    /// @notice a > b (B64). Reverts on decimal mismatch.
    function gt64(uint64 a, uint64 b) internal pure returns (bool result) {
        assembly {
            function doGt(x, y) -> res {
                x := and(x, 0xFFFFFFFFFFFFFFFF)
                y := and(y, 0xFFFFFFFFFFFFFFFF)
                if iszero(x) { leave }
                if iszero(y) { res := 1 leave }
                let mantX := shr(12, x)
                let mantY := shr(12, y)
                let decX := and(shr(7, x), 0x1F)
                let decY := and(shr(7, y), 0x1F)
                let expX := sub(and(x, 0x7F), 64)
                let expY := sub(and(y, 0x7F), 64)
                if iszero(eq(decX, decY)) { revert(0, 0) }
                let effExpX := expX
                let effExpY := expY
                for { let m := mantX } gt(m, 9999999999999) { } { m := div(m, 10) effExpX := add(effExpX, 1) }
                for { let m := mantY } gt(m, 9999999999999) { } { m := div(m, 10) effExpY := add(effExpY, 1) }
                if gt(effExpX, effExpY) { res := 1 leave }
                if lt(effExpX, effExpY) { leave }
                if gt(expX, expY) {
                    let diff := sub(expX, expY)
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } { mantY := div(mantY, 10) }
                }
                if gt(expY, expX) {
                    let diff := sub(expY, expX)
                    for { let i := 0 } lt(i, diff) { i := add(i, 1) } { mantX := div(mantX, 10) }
                }
                res := gt(mantX, mantY)
            }
            result := doGt(a, b)
        }
    }

    /// @notice |b - a| / a in 1e6 (1_000_000 = 1%). 10% on zero/invalid input.
    function diff1e6(uint64 a64, uint64 b64) internal pure returns (uint32) {
        if (a64 == 0 || b64 == 0) return 10_000_000;
        unchecked {
            (uint256 a, uint256 b) = (b64To1e18(a64), b64To1e18(b64));
            if (a == 0) return 10_000_000;
            uint256 diff = a > b ? a - b : b - a;
            uint256 vol = (diff * 1_000_000) / a;
            return vol > type(uint32).max ? type(uint32).max : uint32(vol);
        }
    }

}
