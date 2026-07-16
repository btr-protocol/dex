// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title CurveStableSwapMath — Solidity port of Curve StableSwapNGMath (curvefi/stableswap-ng).
/// @notice Line-faithful `get_D` / `get_y` / `get_y_D` (A_PRECISION=100, Ann = amp * n).
/// @dev Source: https://github.com/curvefi/stableswap-ng/blob/main/contracts/main/CurveStableSwapNGMath.vy
library CurveStableSwapMath {
  uint256 internal constant A_PRECISION = 100;
  uint256 internal constant MAX_COINS = 8;

  /// @dev Identical to CurveStableSwapNGMath.get_D
  function getD(uint256[] memory xp, uint256 amp, uint256 nCoins) internal pure returns (uint256) {
    uint256 S;
    for (uint256 i; i < nCoins; i++) {
      S += xp[i];
    }
    if (S == 0) return 0;

    uint256 D = S;
    uint256 Ann = amp * nCoins;

    for (uint256 i; i < 255; i++) {
      uint256 D_P = D;
      for (uint256 j; j < nCoins; j++) {
        D_P = (D_P * D) / xp[j];
      }
      // D_P /= n^n  (pow_mod256(n, n) in Vyper)
      uint256 nn = nCoins;
      for (uint256 k = 1; k < nCoins; k++) {
        nn *= nCoins;
      }
      D_P /= nn;

      uint256 Dprev = D;
      D = ((Ann * S / A_PRECISION + D_P * nCoins) * D)
        / ((Ann - A_PRECISION) * D / A_PRECISION + (nCoins + 1) * D_P);

      if (D > Dprev) {
        if (D - Dprev <= 1) return D;
      } else if (Dprev - D <= 1) {
        return D;
      }
    }
    revert("D");
  }

  /// @dev Identical to CurveStableSwapNGMath.get_y
  function getY(
    uint256 i,
    uint256 j,
    uint256 x,
    uint256[] memory xp,
    uint256 amp,
    uint256 D,
    uint256 nCoins
  ) internal pure returns (uint256) {
    require(i != j && j < nCoins && i < nCoins, "ij");

    uint256 S_;
    uint256 _x;
    uint256 c = D;
    uint256 Ann = amp * nCoins;

    for (uint256 _i; _i < nCoins; _i++) {
      if (_i == i) {
        _x = x;
      } else if (_i != j) {
        _x = xp[_i];
      } else {
        continue;
      }
      S_ += _x;
      c = (c * D) / (_x * nCoins);
    }

    c = (c * D * A_PRECISION) / (Ann * nCoins);
    uint256 b = S_ + (D * A_PRECISION) / Ann;
    uint256 y = D;

    for (uint256 _i; _i < 255; _i++) {
      uint256 yPrev = y;
      y = (y * y + c) / (2 * y + b - D);
      if (y > yPrev) {
        if (y - yPrev <= 1) return y;
      } else if (yPrev - y <= 1) {
        return y;
      }
    }
    revert("y");
  }

  /// @dev Identical to CurveStableSwapNGMath.get_y_D
  function getYD(uint256 A, uint256 i, uint256[] memory xp, uint256 D, uint256 nCoins)
    internal
    pure
    returns (uint256)
  {
    require(i < nCoins, "i");

    uint256 S_;
    uint256 _x;
    uint256 c = D;
    uint256 Ann = A * nCoins;

    for (uint256 _i; _i < nCoins; _i++) {
      if (_i != i) {
        _x = xp[_i];
      } else {
        continue;
      }
      S_ += _x;
      c = (c * D) / (_x * nCoins);
    }

    c = (c * D * A_PRECISION) / (Ann * nCoins);
    uint256 b = S_ + (D * A_PRECISION) / Ann;
    uint256 y = D;

    for (uint256 _i; _i < 255; _i++) {
      uint256 yPrev = y;
      y = (y * y + c) / (2 * y + b - D);
      if (y > yPrev) {
        if (y - yPrev <= 1) return y;
      } else if (yPrev - y <= 1) {
        return y;
      }
    }
    revert("yD");
  }
}
