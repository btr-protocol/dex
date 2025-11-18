// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {FPMaths as FPMath} from "solady/utils/FixedPointMathLib.sol";

/// @title LibMakima - Makima cubic spline evaluation for liquidity profiles
/// @notice Implements cubic Hermite interpolation with pre-computed Makima slopes
/// @dev All slopes computed off-chain, only evaluation happens on-chain
library LibMakima {
    using FPMath for uint256;
    using FPMath for int256;

    // ========== CONSTANTS ==========

    uint256 private constant WAD = 1e18;
    uint256 private constant HALF_WAD = 0.5e18;

    // Slope scaling: slopes stored as int32, scaled by SLOPE_SCALE
    // SLOPE_SCALE = 1e9 gives range ±2.147 for unscaled slopes
    int256 private constant SLOPE_SCALE = 1e9;

    // For integration: normalize t to [0, 1e9] to prevent t^4 overflow
    uint256 private constant T_SCALE = 1e9;

    // ========== ERRORS ==========

    error InvalidSegmentBounds();
    error DivisionByZero();

    // ========== CUBIC HERMITE EVALUATION ==========

    /// @notice Evaluate cubic Hermite polynomial at parameter t
    /// @dev p(t) = y0×h00(t) + slope0×h10(t)×Δx + y1×h01(t) + slope1×h11(t)×Δx
    /// @param t Parameter in [0, 1e18] (normalized position within segment)
    /// @param y0 Left knot value (1e18 precision)
    /// @param y1 Right knot value (1e18 precision)
    /// @param slope0 Left knot slope (int32, scaled by SLOPE_SCALE)
    /// @param slope1 Right knot slope (int32, scaled by SLOPE_SCALE)
    /// @param segmentWidth Physical width of segment (for slope scaling)
    /// @return value Interpolated value at t (1e18 precision)
    function evaluateCubicHermite(
        uint256 t,
        uint256 y0,
        uint256 y1,
        int32 slope0,
        int32 slope1,
        uint256 segmentWidth
    )
        internal
        pure
        returns (uint256 value)
    {
        unchecked {
            // Normalize t to [0,1] in WAD precision
            if (t > WAD) t = WAD;

            // Compute Hermite basis functions
            // h00(t) = 2t³ - 3t² + 1
            // h10(t) = t³ - 2t² + t
            // h01(t) = -2t³ + 3t²
            // h11(t) = t³ - t²

            uint256 t2 = t.mulWad(t);
            uint256 t3 = t2.mulWad(t);

            // h00 = 2t³ - 3t² + 1
            int256 h00 = int256(2 * t3) - int256(3 * t2) + int256(WAD);

            // h10 = t³ - 2t² + t
            int256 h10 = int256(t3) - int256(2 * t2) + int256(t);

            // h01 = -2t³ + 3t²
            int256 h01 = -int256(2 * t3) + int256(3 * t2);

            // h11 = t³ - t²
            int256 h11 = int256(t3) - int256(t2);

            // Unscale slopes
            int256 d0 = int256(slope0) * int256(WAD) / SLOPE_SCALE;
            int256 d1 = int256(slope1) * int256(WAD) / SLOPE_SCALE;

            // Evaluate: p(t) = y0×h00 + d0×h10×Δx + y1×h01 + d1×h11×Δx
            int256 result =
                (int256(y0) * h00) / int256(WAD)
                + (d0 * h10 * int256(segmentWidth)) / int256(WAD) / int256(WAD)
                + (int256(y1) * h01) / int256(WAD)
                + (d1 * h11 * int256(segmentWidth)) / int256(WAD) / int256(WAD);

            // Clamp to non-negative
            value = result > 0 ? uint256(result) : 0;
        }
    }

    /// @notice Integrate cubic Hermite polynomial from t0 to t1
    /// @dev ∫p(t)dt = (a/4)(t1⁴-t0⁴) + (b/3)(t1³-t0³) + (c/2)(t1²-t0²) + d(t1-t0)
    /// @dev Uses normalized t in [0, 1e9] to prevent overflow on t^4
    /// @param t0 Start parameter (0 ≤ t0 < t1 ≤ 1e18)
    /// @param t1 End parameter
    /// @param y0 Left knot value (1e18)
    /// @param y1 Right knot value (1e18)
    /// @param slope0 Left slope (int32 scaled)
    /// @param slope1 Right slope (int32 scaled)
    /// @param segmentWidth Physical width
    /// @return integral Definite integral (1e18 precision)
    function integrateCubicHermite(
        uint256 t0,
        uint256 t1,
        uint256 y0,
        uint256 y1,
        int32 slope0,
        int32 slope1,
        uint256 segmentWidth
    )
        internal
        pure
        returns (uint256 integral)
    {
        unchecked {
            if (t0 >= t1) return 0;
            if (t1 > WAD) t1 = WAD;

            // Derive cubic coefficients from Hermite form
            // a = 2(y0 - y1) + (slope0 + slope1)×Δx
            // b = 3(y1 - y0) - (2×slope0 + slope1)×Δx
            // c = slope0×Δx
            // d = y0

            int256 d0 = int256(slope0) * int256(WAD) / SLOPE_SCALE;
            int256 d1 = int256(slope1) * int256(WAD) / SLOPE_SCALE;

            int256 dx = int256(segmentWidth);

            int256 a = 2 * (int256(y0) - int256(y1)) + ((d0 + d1) * dx) / int256(WAD);
            int256 b = 3 * (int256(y1) - int256(y0)) - ((2 * d0 + d1) * dx) / int256(WAD);
            int256 c = (d0 * dx) / int256(WAD);
            int256 d = int256(y0);

            // Normalize t to [0, T_SCALE] to prevent t^4 overflow
            // t in [0, 1e18] → t_norm in [0, 1e9]
            uint256 t0_norm = (t0 * T_SCALE) / WAD;
            uint256 t1_norm = (t1 * T_SCALE) / WAD;

            // Compute powers
            uint256 t0_2 = t0_norm * t0_norm;
            uint256 t0_3 = (t0_2 * t0_norm) / T_SCALE;
            uint256 t0_4 = (t0_3 * t0_norm) / T_SCALE;

            uint256 t1_2 = t1_norm * t1_norm;
            uint256 t1_3 = (t1_2 * t1_norm) / T_SCALE;
            uint256 t1_4 = (t1_3 * t1_norm) / T_SCALE;

            // Integral = (a/4)(t1⁴-t0⁴) + (b/3)(t1³-t0³) + (c/2)(t1²-t0²) + d(t1-t0)
            // Note: t^n in T_SCALE^n units, must scale appropriately

            int256 term1 = (a * int256(t1_4 - t0_4)) / 4 / int256(T_SCALE * T_SCALE * T_SCALE * T_SCALE);
            int256 term2 = (b * int256(t1_3 - t0_3)) / 3 / int256(T_SCALE * T_SCALE * T_SCALE);
            int256 term3 = (c * int256(t1_2 - t0_2)) / 2 / int256(T_SCALE * T_SCALE);
            int256 term4 = (d * int256(t1_norm - t0_norm)) / int256(T_SCALE);

            int256 result = term1 + term2 + term3 + term4;

            // Clamp to non-negative
            integral = result > 0 ? uint256(result) : 0;
        }
    }

    /// @notice Compute cost of consuming liquidity from t0 to t1 in a segment
    /// @dev Integrates cubic price curve over [t0, t1] and multiplies by amount
    /// @param t0 Start parameter [0, 1e18]
    /// @param t1 End parameter [0, 1e18]
    /// @param y0 Left knot price (1e18)
    /// @param y1 Right knot price (1e18)
    /// @param slope0 Left slope (int32)
    /// @param slope1 Right slope (int32)
    /// @param segmentWidth Width in price units
    /// @param amountConsumed Amount of liquidity consumed in this segment
    /// @return cost Total cost in quote token (1e18 precision)
    function computeSegmentCost(
        uint256 t0,
        uint256 t1,
        uint256 y0,
        uint256 y1,
        int32 slope0,
        int32 slope1,
        uint256 segmentWidth,
        uint256 amountConsumed
    )
        internal
        pure
        returns (uint256 cost)
    {
        unchecked {
            if (amountConsumed == 0) return 0;

            // Average price via integration
            uint256 avgPrice = integrateCubicHermite(t0, t1, y0, y1, slope0, slope1, segmentWidth);

            // Cost = avgPrice × amount
            // avgPrice is already per-unit, multiply by amount
            // Scale: (1e18 × amount) / (t1-t0 in WAD) → gives total cost
            uint256 dt = t1 - t0;
            if (dt == 0) return 0;

            cost = (avgPrice * amountConsumed) / dt;
        }
    }
}
