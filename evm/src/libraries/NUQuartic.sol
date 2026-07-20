// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @title NUQuartic -clamped quartic I-spline on non-uniform knots, packed for the swap hot path.
/// @dev Curve = monotone integral of a C2 density: Δw≥0 on the control weights ⇒ nondecreasing at
///      ANY degree; simple interior knots at degree 4 ⇒ density (y') is C2 — smooth at every knot by
///      construction. Domain x ∈ [0, SC.BPS] (cumulative depth bps), y in pbps·Q fixed point.
///      Storage (hot-path shape): 1 header slot + 2 slots per segment. The header carries the FULL
///      segment directory (boundaries as uint16), so segment lookup costs zero extra SLOADs:
///        header = m(uint8) | b1..b14(14×uint16, b_m = SC.BPS) | dispRef(uint16, pbps) | flags(uint8)
///        segs[2i]   = c0|c1|c2|c3 (4×int64, power basis on local u∈[0,1], pbps·Q)
///        segs[2i+1] = c4(int64) | S(int128, prefix ∫y dx to left edge, pbps·Q·x)
///      eval = 3 cold SLOADs; O(1) area over [x1,x2] = 5 (prefix integrals; only boundary segments).
library NUQuartic {
  int256 internal constant P = 1e18;
  /// @dev pbps fixed point for stored/returned y (pbps·Q).
  int256 internal constant Q = 1e9;
  // Extra fixed-point scale for the derivative pyramids: slope/curvature truncation feeds c2=s0·h²/2,
  // so a 1-unit s0 error costs h²/2 units of y (1.25e7 at a 5000-unit span). D=1e6 caps that at ~13.
  int256 internal constant D = 1e6;
  /// @dev Hard segment cap — 14×uint16 boundaries is all the header holds (W2 tier = 14 segs, max shipped).
  uint256 internal constant MAX_SEGS = 14;
  /// @dev flags bit0: preset only valid on coverage-walled assets (hyper tiers — see setProfile checks).
  uint8 internal constant FLAG_REQUIRES_WALL = 1;

  struct Curve {
    uint256 header;
    uint256[28] segs;
  }

  // --- write path (admin, cold) ---------------------------------------------------------------

  /// @notice Validate + convert a clamped quartic B-spline to packed power basis, overwrite `c`.
  /// @param wQ control weights (pbps·Q), length nInt+5, NONDECREASING (⇔ monotone curve).
  /// @param interior strictly-increasing interior knots in (0, SC.BPS).
  /// @param dispRef reference dispersion (pbps) the fit was built at; quotes scale y by disp/dispRef.
  /// @param flags curve flag bits (FLAG_REQUIRES_WALL).
  function set(
    Curve storage c,
    uint256[] memory interior,
    int256[] memory wQ,
    uint16 dispRef,
    uint8 flags
  ) internal {
    if (dispRef == 0) revert Err.InvalidInput(); // _scaleY divides by dispRef — brick guard at the write
    uint256[] memory t = _validate(interior, wQ);
    uint256 m = wQ.length - 4; // span count (clamped quartic)
    uint256 header = m;
    for (uint256 j = 1; j <= m; ++j) {
      header |= t[j + 4] << (8 + 16 * (j - 1));
    }
    c.header = header | (uint256(dispRef) << 232) | (uint256(flags) << 248);
    int256 S = 0;
    for (uint256 j = 0; j < m; ++j) {
      S = _buildSeg(c, t, wQ, j, S);
    }
  }

  /// @dev Δw≥0 + strictly-increasing interior knots ⇒ clamped degree-4 knot vector:
  ///      5× 0, interior, 5× SC.BPS. Rejects degenerate (all-flat) weight vectors and >MAX_SEGS.
  function _validate(uint256[] memory interior, int256[] memory wQ)
    private
    pure
    returns (uint256[] memory t)
  {
    uint256 n = wQ.length;
    if (n < 5 || n - 4 > MAX_SEGS || interior.length != n - 5) revert Err.InvalidInput();
    if (wQ[n - 1] == wQ[0]) revert Err.InvalidInput(); // flat curve = no price discovery
    for (uint256 i = 1; i < n; ++i) {
      if (wQ[i] < wQ[i - 1]) revert Err.InvalidInput(); // Δw<0 ⇒ non-monotone curve
    }
    t = new uint256[](n + 5);
    uint256 prev = 0;
    for (uint256 j = 0; j < interior.length; ++j) {
      uint256 kx = interior[j];
      if (kx <= prev || kx >= SC.BPS) revert Err.InvalidInput();
      t[5 + j] = kx;
      prev = kx;
    }
    for (uint256 i = n; i < n + 5; ++i) {
      t[i] = SC.BPS;
    }
  }

  /// @dev convert span j to power basis, store packed, return S + exact segment integral.
  function _buildSeg(Curve storage c, uint256[] memory t, int256[] memory wQ, uint256 j, int256 S)
    private
    returns (int256)
  {
    int256[5] memory k = _segCoeffs(t, wQ, j + 4);
    int256 lim = int256(uint256(type(uint64).max) / 2);
    for (uint256 i = 0; i < 5; ++i) {
      if (k[i] > lim || k[i] < -lim) revert Err.Overflow();
    }
    if (S > type(int128).max || S < type(int128).min) revert Err.Overflow();
    c.segs[2 * j] = uint256(uint64(int64(k[0]))) | (uint256(uint64(int64(k[1]))) << 64)
      | (uint256(uint64(int64(k[2]))) << 128) | (uint256(uint64(int64(k[3]))) << 192);
    c.segs[2 * j + 1] = uint256(uint64(int64(k[4]))) | (uint256(uint128(int128(S))) << 64);
    // exact full-segment integral: h·(60c0+30c1+20c2+15c3+12c4)/60
    return S
      + (int256(t[j + 5] - t[j + 4]) * (60 * k[0] + 30 * k[1] + 20 * k[2] + 15 * k[3] + 12 * k[4]))
      / 60;
  }

  /// @dev power basis on local u∈[0,1]: c0..c2 from the left jet, c3/c4 from the right-end (y,d).
  ///      All five straight from de Boor per span — value/slope/y'' are continuous, so evaluating
  ///      the left jet inside this span equals the previous span's right jet (no carry needed).
  function _segCoeffs(uint256[] memory t, int256[] memory wQ, uint256 s)
    private
    pure
    returns (int256[5] memory k)
  {
    int256 ih = int256(t[s + 1] - t[s]);
    int256 c0 = _deBoor4(t, wQ, s, t[s]);
    int256 c1 = (_deBoorD1(t, wQ, s, t[s]) * ih) / D;
    int256 c2 = (_deBoorD2(t, wQ, s, t[s]) * ih * ih) / (2 * D);
    int256 A = _deBoor4(t, wQ, s, t[s + 1]) - c0 - c1 - c2;
    int256 B = (_deBoorD1(t, wQ, s, t[s + 1]) * ih) / D - c1 - 2 * c2;
    k = [c0, c1, c2, 4 * A - B, B - 3 * A];
  }

  /// @dev de Boor degree 4 at x in span s. wQ already pbps·Q.
  function _deBoor4(uint256[] memory t, int256[] memory wQ, uint256 s, uint256 x)
    private
    pure
    returns (int256)
  {
    int256[5] memory d;
    for (uint256 k = 0; k < 5; ++k) {
      d[k] = wQ[s - 4 + k];
    }
    for (uint256 r = 1; r <= 4; ++r) {
      for (uint256 j = 4; j >= r; --j) {
        int256 den = int256(t[j + 1 + s - r] - t[j + s - 4]);
        int256 num = int256(x - t[j + s - 4]);
        d[j] = (d[j - 1] * (den - num) + d[j] * num) / den;
      }
    }
    return d[4];
  }

  /// @dev q_i = 4·(w[i+1]-w[i])·D/(t[i+5]-t[i+1]) — first-derivative ctrl (degree 3), pbps·Q·D per x.
  function _q(uint256[] memory t, int256[] memory wQ, uint256 i) private pure returns (int256) {
    return (4 * (wQ[i + 1] - wQ[i]) * D) / int256(t[i + 5] - t[i + 1]);
  }

  /// @dev first derivative: degree-3 de Boor over q.
  function _deBoorD1(uint256[] memory t, int256[] memory wQ, uint256 s, uint256 x)
    private
    pure
    returns (int256)
  {
    int256[4] memory d;
    for (uint256 k = 0; k < 4; ++k) {
      d[k] = _q(t, wQ, s - 4 + k);
    }
    for (uint256 r = 1; r <= 3; ++r) {
      for (uint256 j = 3; j >= r; --j) {
        int256 den = int256(t[j + s - r + 1] - t[j + s - 3]);
        int256 num = int256(x - t[j + s - 3]);
        d[j] = (d[j - 1] * (den - num) + d[j] * num) / den;
      }
    }
    return d[3];
  }

  /// @dev second derivative: r_i = 3·(q[i+1]-q[i])/(t[i+5]-t[i+2]), degree-2 de Boor.
  function _deBoorD2(uint256[] memory t, int256[] memory wQ, uint256 s, uint256 x)
    private
    pure
    returns (int256)
  {
    int256[3] memory d;
    for (uint256 k = 0; k < 3; ++k) {
      uint256 i = s - 4 + k;
      d[k] = (3 * (_q(t, wQ, i + 1) - _q(t, wQ, i))) / int256(t[i + 5] - t[i + 2]);
    }
    for (uint256 r = 1; r <= 2; ++r) {
      for (uint256 j = 2; j >= r; --j) {
        int256 den = int256(t[j + s - r + 1] - t[j + s - 2]);
        int256 num = int256(x - t[j + s - 2]);
        d[j] = (d[j - 1] * (den - num) + d[j] * num) / den;
      }
    }
    return d[2];
  }

  // --- read path (swap, hot) ------------------------------------------------------------------

  /// @dev Segment index + local frame from the header directory alone (zero SLOADs past the header):
  ///      seg i covers [b_i, b_{i+1}), b_0 = 0. Linear scan — m ≤ 14, pure word ops.
  function _frame(uint256 header, uint256 x)
    private
    pure
    returns (uint256 i, uint256 x0, uint256 h)
  {
    unchecked {
      uint256 m = header & 0xff;
      uint256 b = 0;
      uint256 next = (header >> 8) & 0xffff;
      while (i < m - 1 && x >= next) {
        ++i;
        b = next;
        next = (header >> (8 + 16 * i)) & 0xffff;
      }
      x0 = b;
      h = next - b;
    }
  }

  /// @notice y(x) in pbps·Q. Callers scale by disp/dispRef (linear y-scale preserves monotone + C2).
  function evalQ(Curve storage c, uint256 header, uint256 x) internal view returns (int256) {
    (uint256 i, uint256 x0, uint256 h) = _frame(header, x);
    uint256 a;
    uint256 b;
    assembly ("memory-safe") {
      let base := add(c.slot, 1)
      a := sload(add(base, mul(2, i)))
      b := sload(add(base, add(mul(2, i), 1)))
    }
    unchecked {
      uint256 dx = x > x0 ? x - x0 : 0;
      if (dx > h) dx = h;
      int256 u = int256((dx * uint256(P)) / h);
      int256 v = (int256(int64(uint64(b))) * u) / P; // c4
      v = ((int256(int64(uint64(a >> 192))) + v) * u) / P; // c3
      v = ((int256(int64(uint64(a >> 128))) + v) * u) / P; // c2
      v = ((int256(int64(uint64(a >> 64))) + v) * u) / P; // c1
      return int256(int64(uint64(a))) + v; // c0
    }
  }

  /// @notice O(1) integral over [x1,x2] via prefix S — touches ONLY the 2 boundary segments.
  ///         Returns pbps·Q·x-units.
  function areaQ(Curve storage c, uint256 header, uint256 x1, uint256 x2)
    internal
    view
    returns (int256)
  {
    if (x1 >= x2) return 0;
    return _at(c, header, x2) - _at(c, header, x1);
  }

  /// @dev cumulative integral from 0 to x: S_i + local quintic primitive.
  function _at(Curve storage c, uint256 header, uint256 x) private view returns (int256) {
    (uint256 i, uint256 x0, uint256 h) = _frame(header, x);
    uint256 a;
    uint256 b;
    assembly ("memory-safe") {
      let base := add(c.slot, 1)
      a := sload(add(base, mul(2, i)))
      b := sload(add(base, add(mul(2, i), 1)))
    }
    unchecked {
      uint256 dx = x > x0 ? x - x0 : 0;
      if (dx > h) dx = h;
      int256 u = int256((dx * uint256(P)) / h);
      int256 u2 = (u * u) / P;
      int256 u3 = (u2 * u) / P;
      int256 u4 = (u3 * u) / P;
      int256 u5 = (u4 * u) / P;
      int256 sum = int256(int64(uint64(a))) * u + (int256(int64(uint64(a >> 64))) * u2) / 2
        + (int256(int64(uint64(a >> 128))) * u3) / 3 + (int256(int64(uint64(a >> 192))) * u4) / 4
        + (int256(int64(uint64(b))) * u5) / 5;
      return int128(uint128(b >> 64)) + (int256(h) * sum) / P;
    }
  }
}
