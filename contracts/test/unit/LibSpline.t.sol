// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {BaseTestSetup} from "../fixtures/BaseTestSetup.sol";
import {LibSpline as S} from "../../src/libraries/LibSpline.sol";

/// @title LibSplineTest
/// @notice Comprehensive unit tests for LibSpline monotone cubic Hermite spline
contract LibSplineTest is BaseTestSetup {

    int256 constant P = 1e18;

    // ═══════════════════════════════════════════════════════════════════════════
    // EVAL TESTS - Basic Interpolation
    // ═══════════════════════════════════════════════════════════════════════════

    function test_eval_empty_array_returns_zero() public pure {
        S.Point[] memory pts = new S.Point[](0);

        int256 result = S.eval(100, pts);

        assertEq(result, 0);
    }

    function test_eval_single_point_returns_constant() public pure {
        S.Point[] memory pts = new S.Point[](1);
        pts[0] = S.Point(100, 5e18);

        int256 result1 = S.eval(0, pts);
        int256 result2 = S.eval(100, pts);
        int256 result3 = S.eval(200, pts);

        assertEq(result1, 5e18);
        assertEq(result2, 5e18);
        assertEq(result3, 5e18);
    }

    function test_eval_two_points_linear_interpolation() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 0);
        pts[1] = S.Point(100, 10e18);

        // At x=0: should be 0
        int256 result0 = S.eval(0, pts);
        assertEq(result0, 0);

        // At x=100: should be 10e18
        int256 result100 = S.eval(100, pts);
        assertEq(result100, 10e18);

        // At x=50: should be approximately 5e18 (midpoint)
        int256 result50 = S.eval(50, pts);
        assertApproxEqAbs(result50, 5e18, 1e16);
    }

    function test_eval_before_first_point() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(100, 10e18);
        pts[1] = S.Point(200, 20e18);

        int256 result = S.eval(50, pts);

        // Should return first point's Y value
        assertEq(result, 10e18);
    }

    function test_eval_after_last_point() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(100, 10e18);
        pts[1] = S.Point(200, 20e18);

        int256 result = S.eval(300, pts);

        // Should return last point's Y value
        assertEq(result, 20e18);
    }

    function test_eval_three_points_cubic_interpolation() public pure {
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, 0);
        pts[1] = S.Point(50, 5e18);
        pts[2] = S.Point(100, 10e18);

        // Boundary points
        assertEq(S.eval(0, pts), 0);
        assertEq(S.eval(100, pts), 10e18);

        // Middle point
        assertEq(S.eval(50, pts), 5e18);

        // Interpolated points should be smooth
        int256 result25 = S.eval(25, pts);
        int256 result75 = S.eval(75, pts);

        assertGt(result25, 0);
        assertLt(result25, 5e18);
        assertGt(result75, 5e18);
        assertLt(result75, 10e18);
    }

    function test_eval_negative_y_values() public pure {
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, -5e18);
        pts[1] = S.Point(50, 0);
        pts[2] = S.Point(100, 5e18);

        assertEq(S.eval(0, pts), -5e18);
        assertEq(S.eval(50, pts), 0);
        assertEq(S.eval(100, pts), 5e18);

        int256 result25 = S.eval(25, pts);
        assertGt(result25, -5e18);
        assertLt(result25, 0);
    }

    function test_eval_monotonicity_preserved() public pure {
        // Monotonically increasing function
        S.Point[] memory pts = new S.Point[](4);
        pts[0] = S.Point(0, 1e18);
        pts[1] = S.Point(10, 2e18);
        pts[2] = S.Point(20, 3e18);
        pts[3] = S.Point(30, 4e18);

        // Sample at multiple points and verify increasing
        int256 prev = S.eval(0, pts);
        for (uint256 x = 1; x <= 30; x++) {
            int256 current = S.eval(x, pts);
            assertGe(current, prev, "Monotonicity violated");
            prev = current;
        }
    }

    function test_eval_exact_knot_points() public pure {
        S.Point[] memory pts = new S.Point[](5);
        pts[0] = S.Point(0, 0);
        pts[1] = S.Point(25, 3e18);
        pts[2] = S.Point(50, 5e18);
        pts[3] = S.Point(75, 7e18);
        pts[4] = S.Point(100, 10e18);

        // Eval at exact knot points should return exact Y values
        assertEq(S.eval(0, pts), 0);
        assertEq(S.eval(25, pts), 3e18);
        assertEq(S.eval(50, pts), 5e18);
        assertEq(S.eval(75, pts), 7e18);
        assertEq(S.eval(100, pts), 10e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // AREA TESTS - Integration
    // ═══════════════════════════════════════════════════════════════════════════

    function test_area_empty_array_returns_zero() public pure {
        S.Point[] memory pts = new S.Point[](0);

        int256 result = S.area(pts, 0, 100);

        assertEq(result, 0);
    }

    function test_area_zero_width_returns_zero() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 10e18);
        pts[1] = S.Point(100, 20e18);

        int256 result = S.area(pts, 50, 50);

        assertEq(result, 0);
    }

    function test_area_single_point_constant_function() public pure {
        S.Point[] memory pts = new S.Point[](1);
        pts[0] = S.Point(50, 10e18);

        int256 result = S.area(pts, 0, 100);

        // Area under constant function: y * width = 10e18 * 100 = 1000e18
        // Result should be approximately this value
        assertApproxEqRel(result, 1000e18, 0.01e18);
    }

    function test_area_two_points_linear_function() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 0);
        pts[1] = S.Point(100, 10e18);

        int256 result = S.area(pts, 0, 100);

        // Area under linear function from 0 to 10e18 over width 100
        // This is a triangle: area = (base * height) / 2 = (100 * 10e18) / 2 = 5e20
        assertGt(result, 0);
        assertEq(result, int256(500e18)); // Exact value for linear interpolation
    }

    function test_area_inverted_bounds_negates_result() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 10e18);
        pts[1] = S.Point(100, 20e18);

        int256 result1 = S.area(pts, 0, 100);
        int256 result2 = S.area(pts, 100, 0);

        // Inverted bounds should negate the result
        assertEq(result1, -result2);
    }

    function test_area_partial_range() public pure {
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, 0);
        pts[1] = S.Point(50, 5e18);
        pts[2] = S.Point(100, 10e18);

        // Full range
        int256 fullArea = S.area(pts, 0, 100);

        // Partial ranges
        int256 area1 = S.area(pts, 0, 50);
        int256 area2 = S.area(pts, 50, 100);

        // Sum of partial areas should approximately equal full area
        assertApproxEqAbs(area1 + area2, fullArea, 1e16);
    }

    function test_area_entirely_left_of_spline() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(100, 10e18);
        pts[1] = S.Point(200, 20e18);

        int256 result = S.area(pts, 0, 50);

        // Should use constant edge value (first point)
        // Area = 10e18 * 50 = 500e18
        assertApproxEqRel(result, 500e18, 0.01e18);
    }

    function test_area_entirely_right_of_spline() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 10e18);
        pts[1] = S.Point(100, 20e18);

        int256 result = S.area(pts, 150, 200);

        // Should use constant edge value (last point)
        // Area = 20e18 * 50 = 1000e18
        assertApproxEqRel(result, 1000e18, 0.01e18);
    }

    function test_area_spanning_multiple_segments() public pure {
        S.Point[] memory pts = new S.Point[](4);
        pts[0] = S.Point(0, 1e18);
        pts[1] = S.Point(10, 2e18);
        pts[2] = S.Point(20, 3e18);
        pts[3] = S.Point(30, 4e18);

        int256 result = S.area(pts, 0, 30);

        // Should integrate across all segments
        assertGt(result, 0);
        // This is a linearly increasing function from 1e18 to 4e18 over width 30
        // Average height = (1e18 + 4e18) / 2 = 2.5e18
        // Area = average_height * width = 2.5e18 * 30 = 75e18
        assertGt(result, 70e18);
        assertLt(result, 80e18);
    }

    function test_area_negative_y_values() public pure {
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, -5e18);
        pts[1] = S.Point(50, 0);
        pts[2] = S.Point(100, 5e18);

        int256 area1 = S.area(pts, 0, 50);  // Negative area (below x-axis)
        int256 area2 = S.area(pts, 50, 100); // Positive area (above x-axis)

        // First half should be negative (below x-axis)
        assertLt(area1, 0, "Area 1");
        // Second half should be positive (above x-axis)
        assertGt(area2, 0, "Area 2");
    }

    function test_area_constant_function() public pure {
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, 5e18);
        pts[1] = S.Point(50, 5e18);
        pts[2] = S.Point(100, 5e18);

        int256 result = S.area(pts, 0, 100);

        // Constant function: area = 5e18 * 100
        assertApproxEqAbs(result, 500e18, 1e16);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // INTEGRATION TESTS - Eval + Area Consistency
    // ═══════════════════════════════════════════════════════════════════════════

    function test_area_matches_trapezoidal_approximation() public pure {
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, 0);
        pts[1] = S.Point(50, 10e18);
        pts[2] = S.Point(100, 0);

        int256 exactArea = S.area(pts, 0, 100);

        // For this symmetric triangle, the area should be approximately
        // width * peak_height / 2 = 100 * 10e18 / 2 = 500e18
        // With cubic interpolation, it might be slightly larger (more area under curve)

        // The exact value with cubic interpolation is approximately 583.33e18
        assertGt(exactArea, 500e18);  // Greater than triangle area
        assertLt(exactArea, 700e18);  // Less than rectangle area (100 * 10e18 / 2 * 1.4)
    }

    function test_fundamental_theorem_of_calculus() public pure {
        // ∫[a,b] f(x)dx = F(b) - F(a)
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, 1e18);
        pts[1] = S.Point(50, 5e18);
        pts[2] = S.Point(100, 10e18);

        int256 area_0_50 = S.area(pts, 0, 50);
        int256 area_50_100 = S.area(pts, 50, 100);
        int256 area_0_100 = S.area(pts, 0, 100);

        // Area from 0 to 100 should equal sum of parts
        assertApproxEqAbs(area_0_100, area_0_50 + area_50_100, 1e16);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // EDGE CASES & STRESS TESTS
    // ═══════════════════════════════════════════════════════════════════════════

    function test_eval_large_values() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 1e30);
        pts[1] = S.Point(1e6, 2e30);

        int256 result = S.eval(5e5, pts);

        // Should interpolate between large values
        assertGt(result, 1e30);
        assertLt(result, 2e30);
    }

    function test_eval_small_segments() public pure {
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, 0);
        pts[1] = S.Point(1, 1e18);
        pts[2] = S.Point(2, 2e18);

        int256 result = S.eval(1, pts);

        // Should handle small segment widths
        assertEq(result, 1e18);
    }

    function test_area_many_segments() public pure {
        uint256 numPoints = 10;
        S.Point[] memory pts = new S.Point[](numPoints);

        for (uint256 i = 0; i < numPoints; i++) {
            pts[i] = S.Point(i * 10, int256(i * 1e18));
        }

        int256 result = S.area(pts, 0, 90);

        // Should handle many segments
        assertGt(result, 0);
    }

    function test_eval_boundary_precision() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 123456789012345678);
        pts[1] = S.Point(100, 987654321098765432);

        // At exact boundaries, should return exact values
        assertEq(S.eval(0, pts), 123456789012345678);
        assertEq(S.eval(100, pts), 987654321098765432);
    }

    function test_area_overlapping_ranges() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 10e18);
        pts[1] = S.Point(100, 20e18);

        int256 area1 = S.area(pts, 0, 60);
        int256 area2 = S.area(pts, 40, 100);
        int256 overlap = S.area(pts, 40, 60);

        // area1 + area2 - overlap should equal total area
        int256 total = S.area(pts, 0, 100);
        assertApproxEqAbs(area1 + area2 - overlap, total, 1e16);
    }

    function test_eval_symmetry() public pure {
        // Symmetric function: y = |x - 50|
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, 50e18);
        pts[1] = S.Point(50, 0);
        pts[2] = S.Point(100, 50e18);

        // Should be symmetric around x=50
        int256 result25 = S.eval(25, pts);
        int256 result75 = S.eval(75, pts);

        assertApproxEqAbs(result25, result75, 1e16);
    }

    function test_area_zero_crossing() public pure {
        // Function that crosses zero
        S.Point[] memory pts = new S.Point[](3);
        pts[0] = S.Point(0, -10e18);
        pts[1] = S.Point(50, 0);
        pts[2] = S.Point(100, 10e18);

        int256 totalArea = S.area(pts, 0, 100);

        // Total area should be near zero since negative and positive parts cancel
        // The spline is symmetric, so areas should approximately cancel out
        assertApproxEqAbs(totalArea, 0, 10e18);
    }

    function test_eval_monotone_decreasing() public pure {
        // Monotonically decreasing function
        S.Point[] memory pts = new S.Point[](4);
        pts[0] = S.Point(0, 10e18);
        pts[1] = S.Point(10, 7e18);
        pts[2] = S.Point(20, 4e18);
        pts[3] = S.Point(30, 1e18);

        // Sample at multiple points and verify decreasing
        int256 prev = S.eval(0, pts);
        for (uint256 x = 1; x <= 30; x++) {
            int256 current = S.eval(x, pts);
            assertLe(current, prev, "Monotonicity violated");
            prev = current;
        }
    }

    function test_area_very_small_range() public pure {
        S.Point[] memory pts = new S.Point[](2);
        pts[0] = S.Point(0, 10e18);
        pts[1] = S.Point(1e6, 20e18);

        int256 result = S.area(pts, 1000, 1001);

        // Very small range: linear interpolation from (0,10e18) to (1e6,20e18)
        // At x=1000: y ≈ 10e18 + (1000/1e6)*(20e18-10e18) ≈ 10.01e18
        // Area = y * width = ~10.01e18 * 1 ≈ 10.01e18
        assertGt(result, 10e18);
        assertLt(result, 11e18);
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // DISTRIBUTION SHAPE TESTS
    // These test realistic liquidity profile shapes used in AIMM pricing
    // All use x in [0, 10000] (depth range) and y in bps (price offset)
    // ═══════════════════════════════════════════════════════════════════════════

    /// @notice Normal (Gaussian) distribution - classic bell curve
    /// @dev Shape: Peak at center (x=5000), symmetric tails tapering to near-zero
    ///      Use case: Balanced liquidity concentrated around current price
    ///      Parameters: μ=5000, σ=1500, peak≈500bps
    ///      See: test/unit/plots/spline_distributions.png
    function test_area_normal_distribution() public pure {
        S.Point[] memory pts = new S.Point[](15);
        // Generated from: y = 500 * exp(-0.5 * ((x - 5000) / 1500)²)
        // More points around peak and inflection points for better spline fit
        pts[0] = S.Point(0, 1932960069736402176);           // ~1.93 bps
        pts[1] = S.Point(1000, 14282750392275187712);       // ~14.28 bps
        pts[2] = S.Point(2000, 67667641618306351104);       // ~67.67 bps
        pts[3] = S.Point(3000, 205556145253593710592);      // ~205.56 bps
        pts[4] = S.Point(3500, 303265329856316702720);      // ~303.27 bps
        pts[5] = S.Point(4000, 400368701458404016128);      // ~400.37 bps
        pts[6] = S.Point(4500, 472979734453382742016);      // ~472.98 bps
        pts[7] = S.Point(5000, 500000000000000065536);      // 500 bps (peak)
        pts[8] = S.Point(5500, 472979734453382742016);      // ~472.98 bps
        pts[9] = S.Point(6000, 400368701458404016128);      // ~400.37 bps
        pts[10] = S.Point(6500, 303265329856316702720);     // ~303.27 bps
        pts[11] = S.Point(7000, 205556145253593710592);     // ~205.56 bps
        pts[12] = S.Point(8000, 67667641618306351104);      // ~67.67 bps
        pts[13] = S.Point(9000, 14282750392275187712);      // ~14.28 bps
        pts[14] = S.Point(10000, 1932960069736402176);      // ~1.93 bps

        int256 area = S.area(pts, 0, 10000);

        // Expected area ≈ 1,900,770 (bps × depth units)
        int256 expected = 1900769898251412366688256;
        assertApproxEqRel(area, expected, 0.05e18);

        // Verify symmetry: area [0,5000] ≈ area [5000,10000]
        int256 leftHalf = S.area(pts, 0, 5000);
        int256 rightHalf = S.area(pts, 5000, 10000);
        assertApproxEqRel(leftHalf, rightHalf, 0.01e18);
    }

    /// @notice Double-peak (M-shape / bimodal) distribution
    /// @dev Shape: Two peaks at x=3000 and x=7000, valley in center
    ///      Use case: Liquidity concentrated at two price levels (e.g., support/resistance)
    ///      Parameters: peaks at 3000 & 7000, σ=1200, peak≈400bps each
    function test_area_double_peak_bimodal() public pure {
        S.Point[] memory pts = new S.Point[](9);
        // Generated from: y = 400 * (exp(-0.5*((x-3000)/1200)²) + exp(-0.5*((x-7000)/1200)²))
        pts[0] = S.Point(0, 17574789780707127296);          // ~17.57 bps
        pts[1] = S.Point(1500, 183144321109637955584);      // ~183.14 bps
        pts[2] = S.Point(3000, 401546368055789027328);      // ~401.55 bps (peak 1)
        pts[3] = S.Point(4500, 228798048712520433664);      // ~228.80 bps
        pts[4] = S.Point(5000, 199481767021836926976);      // ~199.48 bps (valley)
        pts[5] = S.Point(5500, 228798048712520433664);      // ~228.80 bps
        pts[6] = S.Point(7000, 401546368055789027328);      // ~401.55 bps (peak 2)
        pts[7] = S.Point(8500, 183144321109637955584);      // ~183.14 bps
        pts[8] = S.Point(10000, 17574789780707127296);      // ~17.57 bps

        int256 area = S.area(pts, 0, 10000);

        // Expected area ≈ 2,337,813 (bps × depth units)
        int256 expected = 2337813311200989833854976;
        assertApproxEqRel(area, expected, 0.10e18);

        // Verify M-shape: center value should be less than peaks
        int256 centerVal = S.eval(5000, pts);
        int256 peak1Val = S.eval(3000, pts);
        int256 peak2Val = S.eval(7000, pts);
        assertLt(centerVal, peak1Val);
        assertLt(centerVal, peak2Val);

        // Peaks should be approximately equal (symmetric bimodal)
        assertApproxEqRel(peak1Val, peak2Val, 0.01e18);
    }

    /// @notice V-shape (inverted distribution) - minimum at center
    /// @dev Shape: High values at edges, low at center
    ///      Use case: Liquidity avoiding current price (anticipating breakout)
    ///      Parameters: min=50bps at center, max=600bps at edges
    ///      See: test/unit/plots/spline_distributions.png
    function test_area_v_shape_inverted() public pure {
        S.Point[] memory pts = new S.Point[](13);
        // Linear V: y = 50 + 550 * |x - 5000| / 5000
        // More points around vertex for sharper V approximation
        pts[0] = S.Point(0, 600000000000000000000);         // 600 bps
        pts[1] = S.Point(1000, 490000000000000000000);      // 490 bps
        pts[2] = S.Point(2000, 380000000000000000000);      // 380 bps
        pts[3] = S.Point(3000, 270000000000000000000);      // 270 bps
        pts[4] = S.Point(4000, 160000000000000000000);      // 160 bps
        pts[5] = S.Point(4500, 105000000000000000000);      // 105 bps
        pts[6] = S.Point(5000, 50000000000000000000);       // 50 bps (minimum)
        pts[7] = S.Point(5500, 105000000000000000000);      // 105 bps
        pts[8] = S.Point(6000, 160000000000000000000);      // 160 bps
        pts[9] = S.Point(7000, 270000000000000000000);      // 270 bps
        pts[10] = S.Point(8000, 380000000000000000000);     // 380 bps
        pts[11] = S.Point(9000, 490000000000000000000);     // 490 bps
        pts[12] = S.Point(10000, 600000000000000000000);    // 600 bps

        int256 area = S.area(pts, 0, 10000);

        // Expected area ≈ 3,250,000 (bps × depth units)
        // V-shape area = (max + min) / 2 * width = (600 + 50) / 2 * 10000 = 3,250,000
        int256 expected = 3249990833333333296939008;
        assertApproxEqRel(area, expected, 0.02e18);

        // Verify V-shape: center is minimum
        int256 centerVal = S.eval(5000, pts);
        int256 edgeVal = S.eval(0, pts);
        assertLt(centerVal, edgeVal);

        // Symmetry check
        int256 leftHalf = S.area(pts, 0, 5000);
        int256 rightHalf = S.area(pts, 5000, 10000);
        assertApproxEqRel(leftHalf, rightHalf, 0.01e18);
    }

    /// @notice Skewed distribution - asymmetric with heavy right tail
    /// @dev Shape: Peak shifted left (x=2500), slow decay to right
    ///      Use case: Anticipating upward price movement (more sell-side liquidity)
    ///      Parameters: peak at 2500, left_σ=1000, right_σ=3000
    function test_area_skewed_distribution() public pure {
        S.Point[] memory pts = new S.Point[](9);
        // Asymmetric Gaussian: steeper left side, slower right decay
        pts[0] = S.Point(0, 19771620130533339136);          // ~19.77 bps
        pts[1] = S.Point(1000, 146093610311257374720);      // ~146.09 bps
        pts[2] = S.Point(2000, 397123606163067961344);      // ~397.12 bps
        pts[3] = S.Point(3000, 443793202534762283008);      // ~443.79 bps (near peak)
        pts[4] = S.Point(4000, 397123606163067961344);      // ~397.12 bps
        pts[5] = S.Point(5000, 317991725035972329472);      // ~317.99 bps
        pts[6] = S.Point(6500, 185000530728234352640);      // ~185.00 bps
        pts[7] = S.Point(8000, 83821708663965417472);       // ~83.82 bps
        pts[8] = S.Point(10000, 19771620130533339136);      // ~19.77 bps

        int256 area = S.area(pts, 0, 10000);

        // Expected area ≈ 2,235,480 (bps × depth units)
        int256 expected = 2235480194126487712956416;
        assertApproxEqRel(area, expected, 0.10e18);

        // Verify skewness: left half should have more area (steeper rise)
        int256 leftHalf = S.area(pts, 0, 5000);
        int256 rightHalf = S.area(pts, 5000, 10000);
        assertGt(leftHalf, rightHalf); // Left-skewed = more area on left

        // Peak should be closer to left side
        int256 val2500 = S.eval(2500, pts);
        int256 val7500 = S.eval(7500, pts);
        assertGt(val2500, val7500);
    }

    /// @notice Semicircle (round dome) shape
    /// @dev Shape: Smooth parabolic-like curve, max at center
    ///      Use case: Uniform liquidity distribution across price range
    ///      Parameters: center=5000, radius=5000, height=400bps
    ///      See: test/unit/plots/spline_distributions.png
    function test_area_semicircle_dome() public pure {
        S.Point[] memory pts = new S.Point[](15);
        // Semicircle: y = 400 * sqrt(1 - ((x - 5000) / 5000)²)
        // More points near edges where curvature is highest
        pts[0] = S.Point(0, 0);                             // 0 bps (edge)
        pts[1] = S.Point(500, 174355957741626949632);       // ~174.36 bps
        pts[2] = S.Point(1000, 240000000000000000000);      // 240 bps
        pts[3] = S.Point(1500, 285657137141713960960);      // ~285.66 bps
        pts[4] = S.Point(2500, 346410161513775431680);      // ~346.41 bps
        pts[5] = S.Point(3500, 381575680566778265600);      // ~381.58 bps
        pts[6] = S.Point(4500, 397994974842648002560);      // ~397.99 bps
        pts[7] = S.Point(5000, 400000000000000000000);      // 400 bps (peak)
        pts[8] = S.Point(5500, 397994974842648002560);      // ~397.99 bps
        pts[9] = S.Point(6500, 381575680566778265600);      // ~381.58 bps
        pts[10] = S.Point(7500, 346410161513775431680);     // ~346.41 bps
        pts[11] = S.Point(8500, 285657137141713960960);     // ~285.66 bps
        pts[12] = S.Point(9000, 240000000000000000000);     // 240 bps
        pts[13] = S.Point(9500, 174355957741626949632);     // ~174.36 bps
        pts[14] = S.Point(10000, 0);                        // 0 bps (edge)

        int256 area = S.area(pts, 0, 10000);

        // Expected spline area ≈ 3,095,840 (closer to analytical πr·h/2 ≈ 3,141,593)
        int256 expected = 3095840354120319834783744;
        assertApproxEqRel(area, expected, 0.05e18);

        // Verify dome shape: peak at center
        int256 centerVal = S.eval(5000, pts);
        int256 quarterVal = S.eval(2500, pts);
        assertGt(centerVal, quarterVal);

        // Edge values should be near zero
        int256 edgeVal = S.eval(0, pts);
        assertLt(edgeVal, 10e18); // < 10 bps
    }

    /// @notice Flat (constant) distribution - baseline test
    /// @dev Shape: Constant value across entire range
    ///      Use case: Uniform liquidity (reference for other shapes)
    ///      Parameters: constant 300bps
    function test_area_flat_constant() public pure {
        S.Point[] memory pts = new S.Point[](5);
        // Constant: y = 300 bps everywhere
        pts[0] = S.Point(0, 300000000000000000000);         // 300 bps
        pts[1] = S.Point(2500, 300000000000000000000);      // 300 bps
        pts[2] = S.Point(5000, 300000000000000000000);      // 300 bps
        pts[3] = S.Point(7500, 300000000000000000000);      // 300 bps
        pts[4] = S.Point(10000, 300000000000000000000);     // 300 bps

        int256 area = S.area(pts, 0, 10000);

        // Exact: area = 300 * 10000 = 3,000,000
        int256 expected = 3000000000000000000000000;
        assertApproxEqRel(area, expected, 0.001e18); // Very tight tolerance for constant

        // Eval should return constant everywhere
        assertEq(S.eval(0, pts), S.eval(5000, pts));
        assertEq(S.eval(5000, pts), S.eval(10000, pts));
    }

    /// @notice Test integration of normal distribution over partial range
    /// @dev Verifies that partial integration works correctly for bell curves
    function test_area_normal_partial_range() public pure {
        S.Point[] memory pts = new S.Point[](9);
        pts[0] = S.Point(0, 1932960069736402176);
        pts[1] = S.Point(1250, 21968466811703713792);
        pts[2] = S.Point(2500, 124676104388648091648);
        pts[3] = S.Point(3750, 353324138928858136576);
        pts[4] = S.Point(5000, 500000000000000065536);
        pts[5] = S.Point(6250, 353324138928858136576);
        pts[6] = S.Point(7500, 124676104388648091648);
        pts[7] = S.Point(8750, 21968466811703713792);
        pts[8] = S.Point(10000, 1932960069736402176);

        // Full range
        int256 fullArea = S.area(pts, 0, 10000);

        // Central region should contain most of the area (68-95-99.7 rule for normal)
        int256 centralArea = S.area(pts, 2000, 8000);

        // Central 60% of range should contain >90% of area for normal distribution
        // (This is a looser bound since we only have σ≈1500 with range 10000)
        assertGt(centralArea, fullArea * 80 / 100);

        // Sum of parts should equal whole
        int256 leftTail = S.area(pts, 0, 2000);
        int256 rightTail = S.area(pts, 8000, 10000);
        assertApproxEqRel(leftTail + centralArea + rightTail, fullArea, 0.01e18);
    }
}
