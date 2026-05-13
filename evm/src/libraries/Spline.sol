// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title Spline -Monotone Cubic Hermite spline (1e18 fixed-point)
library Spline {
    struct Point { uint256 x; int256 y; }

    int256 internal constant P = 1e18;

    /// @notice Interpolate Y at X.
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
            // Hermite coeffs (Y*P)
            int256 c2 = 3 * dyP - 2 * k0 - k1;
            int256 c3 = -2 * dyP + k0 + k1;
            int256 t = (int256(x - p0.x) * P) / h;
            // Horner: v = k0*t + c2*t^2 + c3*t^3
            int256 v = (c3 * t) / P;
            v = ((c2 + v) * t) / P;
            v = ((k0 + v) * t) / P;

            return p0.y + v / P;
        }
    }

    /// @notice Exact integral of spline over [x1, x2].
    function area(Point[] memory pts, uint256 x1, uint256 x2) internal pure returns (int256 res) {
        uint256 n = pts.length;
        if (x1 == x2 || n == 0) return 0;
        bool inv = x1 > x2;
        if (inv) (x1, x2) = (x2, x1);
        unchecked {
            if (n == 1) { res = pts[0].y * int256(x2 - x1); return inv ? -res : res; }
            if (x2 <= pts[0].x) { res = pts[0].y * int256(x2 - x1); return inv ? -res : res; }
            if (x1 >= pts[n - 1].x) { res = pts[n - 1].y * int256(x2 - x1); return inv ? -res : res; }
            uint256 i = _search(x1, pts, n);
            while (i < n - 1 && x1 < x2) {
                Point memory p0 = pts[i];
                Point memory p1 = pts[i + 1];
                uint256 segEnd = p1.x;
                uint256 start = x1 > p0.x ? x1 : p0.x;
                uint256 end = x2 < segEnd ? x2 : segEnd;
                if (end > start) {
                    int256 h = int256(p1.x - p0.x);
                    (int256 m0, int256 m1) = _tangents(pts, i, n);
                    int256 k0 = m0 * h;
                    int256 k1 = m1 * h;
                    int256 dy = p1.y - p0.y;
                    int256 A = k0 + k1 - 2 * dy;
                    int256 B = 3 * dy - 2 * k0 - k1;
                    int256 F2 = _primitive(int256(end - p0.x), h, p0.y, k0, A, B);
                    int256 F1 = _primitive(int256(start - p0.x), h, p0.y, k0, A, B);
                    res += (F2 - F1) * h / P;
                }

                if (segEnd >= x2) break;
                x1 = segEnd;
                ++i;
            }
        }

        if (inv) res = -res;
    }

    function _search(uint256 x, Point[] memory pts, uint256 n) private pure returns (uint256 low) {
        if (x <= pts[0].x) return 0;
        uint256 high = n - 2;
        while (low < high) {
            uint256 mid = (low + high + 1) >> 1;
            if (x < pts[mid].x) high = mid - 1;
            else low = mid;
        }
    }

    function _tangents(Point[] memory pts, uint256 i, uint256 n) private pure returns (int256 m0, int256 m1) {
        unchecked {
            Point memory p0 = pts[i];
            Point memory p1 = pts[i + 1];
            int256 s = (p1.y - p0.y) / int256(p1.x - p0.x);
            if (i == 0) m0 = s;
            else {
                Point memory pm = pts[i - 1];
                int256 sp = (p0.y - pm.y) / int256(p0.x - pm.x);
                int256 mask = (sp ^ s) >> 255;
                m0 = ((sp + s) >> 1) & ~mask;
            }
            if (i == n - 2) m1 = s;
            else {
                Point memory p2 = pts[i + 2];
                int256 sn = (p2.y - p1.y) / int256(p2.x - p1.x);
                int256 mask2 = (s ^ sn) >> 255;
                m1 = ((s + sn) >> 1) & ~mask2;
            }
        }
    }

    /// @dev Primitive F(t) of the Hermite cubic; output Y*P.
    function _primitive(int256 dx, int256 h, int256 y0, int256 k0, int256 A, int256 B) private pure returns (int256 F) {
        unchecked {
            int256 t = dx * P / h;
            int256 t2 = (t * t) / P;
            int256 t3 = (t2 * t) / P;
            int256 t4 = (t3 * t) / P;
            F = y0 * t + (k0 * t2) / 2 + (B * t3) / 3 + (A * t4) / 4;
        }
    }
}
