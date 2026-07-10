// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Test, console2} from "forge-std/Test.sol";
import {Spline as S} from "../../src/libraries/Spline.sol";

/// @notice Empirical dump harness for cross-checking Spline.sol against the TS port
///         (dex/research/stable-core/spline_shape.ts) after the c6d9516 _tangents fix
///         (Fritsch-Carlson clamp now ALWAYS runs, even on a flat/zero-secant segment).
///         Dumps raw eval()/area() numerics to stdout for pointwise diffing against a
///         TS run of the exact same algorithm. Real Pricing.sol unit convention:
///         y = knot*dispersion/100 (PBPS), x = cumWeight*10000/200 (BPS domain).
contract SplineDumpTest is Test {
    uint256 constant BPS = 10_000;
    uint256 constant WEIGHT_SUM = 200;

    function _buildPoints(int16[] memory knots, uint16[] memory weights, uint32 disp)
        internal
        pure
        returns (S.Point[] memory pts)
    {
        pts = new S.Point[](weights.length + 1);
        pts[0] = S.Point({x: 0, y: (int256(knots[0]) * int256(uint256(disp))) / 100});
        uint256 cumW;
        for (uint256 i; i < weights.length; ++i) {
            cumW += weights[i];
            pts[i + 1] = S.Point({
                x: (cumW * BPS) / WEIGHT_SUM,
                y: (int256(knots[i + 1]) * int256(uint256(disp))) / 100
            });
        }
    }

    function _dump(string memory label, S.Point[] memory pts) internal view {
        for (uint256 i; i < pts.length; ++i) {
            console2.log(string.concat(
                "KNOT,", label, ",", vm.toString(pts[i].x), ",", vm.toString(pts[i].y)
            ));
        }
        // Fine grid over the WHOLE domain, step=25 (401 points).
        for (uint256 x; x <= BPS; x += 25) {
            int256 v = S.eval(x, pts);
            console2.log(string.concat(
                "EVAL,", label, ",", vm.toString(x), ",", vm.toString(v)
            ));
        }
        // area() ranges: pure-flat-segment, straddling-flat, and full domain.
        int256 aFlat = S.area(pts, 2500, 5000);
        int256 aStraddle = S.area(pts, 1000, 6000);
        int256 aFull = S.area(pts, 0, BPS);
        console2.log(string.concat("AREA,", label, ",2500,5000,", vm.toString(aFlat)));
        console2.log(string.concat("AREA,", label, ",1000,6000,", vm.toString(aStraddle)));
        console2.log(string.concat("AREA,", label, ",0,10000,", vm.toString(aFull)));
    }

    /// @notice DELIBERATE flat segment: knots[1]==knots[2]==-200 -> y1==y2==-2000 (segment [2500,5000]).
    ///         Flanked by rising segments on both sides (Pricing.sol's exact scaling).
    function test_dump_flat_segment_disp1000() public view {
        int16[] memory knots = new int16[](5);
        knots[0] = -500; knots[1] = -200; knots[2] = -200; knots[3] = 200; knots[4] = 500;
        uint16[] memory weights = new uint16[](4);
        weights[0] = 50; weights[1] = 50; weights[2] = 50; weights[3] = 50;
        S.Point[] memory pts = _buildPoints(knots, weights, 1000);
        _dump("flat", pts);

        // Explicit no-overshoot/no-undershoot assertion at multiple interior points of the flat segment.
        int256 flatY = -2000;
        assertEq(S.eval(2500, pts), flatY, "left edge");
        assertEq(S.eval(3000, pts), flatY, "interior 3000");
        assertEq(S.eval(3750, pts), flatY, "interior midpoint");
        assertEq(S.eval(4500, pts), flatY, "interior 4500");
        assertEq(S.eval(4999, pts), flatY, "interior near-right-edge");
        assertEq(S.eval(5000, pts), flatY, "right edge");
        // Flat segment integrates to EXACTLY the rectangle y*width -- no overshoot/undershoot leakage.
        assertEq(S.area(pts, 2500, 5000), flatY * int256(5000 - 2500), "flat segment area must equal exact rectangle");
    }

    /// @notice Regression: "smoothtaper6" profile (the exact knots/weights used by the earlier
    ///         SplineDump.t.sol reproducer / spline_search_lib.ts's search-space default), strictly
    ///         monotone knots, NO flat segment (all 6 secants nonzero). Fix must not perturb this case.
    function test_dump_smoothtaper6_disp1000() public view {
        int16[] memory knots = new int16[](7);
        knots[0] = -50; knots[1] = -22; knots[2] = -8; knots[3] = 0; knots[4] = 8; knots[5] = 22; knots[6] = 50;
        uint16[] memory weights = new uint16[](6);
        weights[0] = 18; weights[1] = 30; weights[2] = 52; weights[3] = 52; weights[4] = 30; weights[5] = 18;
        S.Point[] memory pts = _buildPoints(knots, weights, 1000);
        _dump("smoothtaper6", pts);
    }
}
