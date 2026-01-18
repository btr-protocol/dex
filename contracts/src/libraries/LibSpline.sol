// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

/// @title LibSpline
/// @notice Monotone Cubic Hermite Spline (fixed-point, 1e18)
library LibSpline {
    struct Point {
        uint256 x;
        int256 y;
    }

    int256 internal constant P = 1e18; // Fixed-point scale

    /// @notice Interpolate Y value for a given X
    function eval(uint256 x, Point[] memory pts) internal pure returns (int256) {
        uint256 n = pts.length;
        if (n == 0) return 0;

        unchecked {
            if (n == 1 || x <= pts[0].x) return pts[0].y;
            if (x >= pts[n - 1].x) return pts[n - 1].y;

            uint256 i = _search(x, pts, n);
            Point memory p0 = pts[i];
            Point memory p1 = pts[i + 1];

            int256 h = int256(p1.x - p0.x);
            (int256 m0, int256 m1) = _tangents(pts, i, n);

            int256 dyP = (p1.y - p0.y) * P;
            int256 k0 = m0 * h;
            int256 k1 = m1 * h;

            // Hermite coefficients in units Y * P
            int256 c2 = 3 * dyP - 2 * k0 - k1;
            int256 c3 = -2 * dyP + k0 + k1;

            // t in [0, P]
            int256 t = (int256(x - p0.x) * P) / h;

            // Horner in fixed point:
            // v = k0*t + c2*t^2 + c3*t^3  (all scaled by P)
            int256 v = (c3 * t) / P;
            v = ((c2 + v) * t) / P;
            v = ((k0 + v) * t) / P;

            return p0.y + v / P;
        }
    }

    /// @notice Exact integral of the spline between x1 and x2
    function area(
        Point[] memory pts,
        uint256 x1,
        uint256 x2
    ) internal pure returns (int256 res) {
        uint256 n = pts.length;
        if (x1 == x2 || n == 0) return 0;

        bool inv = x1 > x2;
        if (inv) (x1, x2) = (x2, x1);

        unchecked {
            // Single-point: constant function
            if (n == 1) {
                res = pts[0].y * int256(x2 - x1);
                return inv ? -res : res;
            }

            // Entirely left or right of the spline domain => constant edge value
            if (x2 <= pts[0].x) {
                res = pts[0].y * int256(x2 - x1);
                return inv ? -res : res;
            }
            if (x1 >= pts[n - 1].x) {
                res = pts[n - 1].y * int256(x2 - x1);
                return inv ? -res : res;
            }

            uint256 i = _search(x1, pts, n);

            while (i < n - 1 && x1 < x2) {
                Point memory p0 = pts[i];
                Point memory p1 = pts[i + 1];

                uint256 segStart = p0.x;
                uint256 segEnd = p1.x;

                uint256 start = x1 > segStart ? x1 : segStart;
                uint256 end = x2 < segEnd ? x2 : segEnd;

                if (end > start) {
                    int256 h = int256(p1.x - p0.x);
                    (int256 m0, int256 m1) = _tangents(pts, i, n);

                    int256 k0 = m0 * h;
                    int256 k1 = m1 * h;
                    int256 dy = p1.y - p0.y; // No P scaling

                    // A, B in units Y (no P scaling)
                    int256 A = k0 + k1 - 2 * dy;
                    int256 B = 3 * dy - 2 * k0 - k1;

                    int256 F2 = _primitive(
                        int256(end - p0.x),
                        h,
                        p0.y,
                        k0,
                        A,
                        B
                    );
                    int256 F1 = _primitive(
                        int256(start - p0.x),
                        h,
                        p0.y,
                        k0,
                        A,
                        B
                    );

                    // (F2 - F1) in Y * P; multiply by h (X) and divide by P to get Y * X
                    res += (F2 - F1) * h / P;
                }

                if (segEnd >= x2) break;
                x1 = segEnd;
                ++i;
            }
        }

        if (inv) res = -res;
    }

    // --- Helpers ---

    function _search(
        uint256 x,
        Point[] memory pts,
        uint256 n
    ) private pure returns (uint256 low) {
        if (x <= pts[0].x) return 0;
        uint256 high = n - 2;
        while (low < high) {
            uint256 mid = (low + high + 1) >> 1;
            if (x < pts[mid].x) high = mid - 1;
            else low = mid;
        }
    }

    function _tangents(
        Point[] memory pts,
        uint256 i,
        uint256 n
    ) private pure returns (int256 m0, int256 m1) {
        unchecked {
            Point memory p0 = pts[i];
            Point memory p1 = pts[i + 1];
            int256 s = (p1.y - p0.y) / int256(p1.x - p0.x); // secant (no P scaling)

            // m0
            if (i == 0) {
                m0 = s;
            } else {
                Point memory pm = pts[i - 1];
                int256 sp = (p0.y - pm.y) / int256(p0.x - pm.x); // No P scaling
                int256 mask = (sp ^ s) >> 255; // sign differs => zero
                m0 = ((sp + s) >> 1) & ~mask;
            }

            // m1
            if (i == n - 2) {
                m1 = s;
            } else {
                Point memory p2 = pts[i + 2];
                int256 sn = (p2.y - p1.y) / int256(p2.x - p1.x); // No P scaling
                int256 mask2 = (s ^ sn) >> 255;
                m1 = ((s + sn) >> 1) & ~mask2;
            }
        }
    }

    /// @dev Primitive F(t) of the Hermite cubic over dx in the segment
    function _primitive(
        int256 dx,
        int256 h,
        int256 y0,
        int256 k0,
        int256 A,
        int256 B
    ) private pure returns (int256 F) {
        unchecked {
            // t in [0, P]
            int256 t = dx * P / h;

            // Powers of t with fixed-point normalization
            int256 t2 = (t * t) / P;
            int256 t3 = (t2 * t) / P;
            int256 t4 = (t3 * t) / P;

            // All terms in units Y * P
            int256 term1 = y0 * t;
            int256 term2 = (k0 * t2) / 2;
            int256 term3 = (B * t3) / 3;
            int256 term4 = (A * t4) / 4;

            F = term1 + term2 + term3 + term4;
        }
    }
}
