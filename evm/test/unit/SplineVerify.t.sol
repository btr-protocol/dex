// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;
import {Test} from "forge-std/Test.sol";
import {Spline as S} from "../../src/libraries/Spline.sol";

contract SplineVerifyTest is Test {
  // collinear default (knots -50..50, equal weights) at disp=1000 → y = knot*10.
  function _collinear() internal pure returns (S.Point[] memory p) {
    p = new S.Point[](5);
    p[0] = S.Point(0, -500);
    p[1] = S.Point(2500, -250);
    p[2] = S.Point(5000, 0);
    p[3] = S.Point(7500, 250);
    p[4] = S.Point(10000, 500);
  }

  // collinear MUST eval to EXACT linear interpolation (slope 0.1/unit): y(x) = x*0.1 - 500.
  function test_collinear_is_linear() public pure {
    S.Point[] memory p = _collinear();
    for (uint256 x = 0; x <= 10000; x += 625) {
      int256 want = int256(x) / 10 - 500; // linear
      int256 got = S.eval(x, p);
      assertApproxEqAbs(got, want, 2, "collinear must be linear"); // ≤2 rounding
    }
  }

  // area over the whole span must equal the linear integral = 0 (symmetric about 0), and each half.
  function test_collinear_area_matches_linear_integral() public pure {
    S.Point[] memory p = _collinear();
    // ∫ (x/10 - 500) dx from 0..10000 = [x^2/20 - 500x] = 5e6 - 5e6 = 0
    assertApproxEqAbs(S.area(p, 0, 10000), 0, 10, "full area != linear integral 0");
    // left half 0..5000: [x^2/20 - 500x]_0^5000 = 1.25e6 - 2.5e6 = -1.25e6
    assertApproxEqAbs(S.area(p, 0, 5000), -1_250_000, 200, "left-half area != linear integral");
  }

  // monotone increasing across the span (post-fix live tangents, FC-clamped).
  function test_collinear_monotone() public pure {
    S.Point[] memory p = _collinear();
    int256 prev = type(int256).min;
    for (uint256 x = 0; x <= 10000; x += 250) {
      int256 v = S.eval(x, p);
      assertGe(v, prev, "not monotone");
      prev = v;
    }
  }
}
