// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {FixedPointMathLib as F} from "solady/utils/FixedPointMathLib.sol";

/// @title SqrtPrice — lean Q64.96 helpers for single-range CLAMM (Uni V3/V4-compatible encoding).
/// @dev Prices are token1/token0 in 1e18 (both legs 18 decimals on Chapel mocks).
library SqrtPrice {
  uint256 internal constant Q96 = 1 << 96;

  /// @notice Encode token1/token0 price (1e18) → sqrtPriceX96.
  function encode(uint256 price1e18) internal pure returns (uint160) {
    if (price1e18 == 0) return 0;
    // sqrtPriceX96 = √(price1e18) · 2^96 / 1e9
    return uint160((F.sqrt(price1e18) << 96) / 1e9);
  }

  /// @notice Decode sqrtPriceX96 → token1/token0 price (1e18).
  function decode(uint160 sqrtPriceX96) internal pure returns (uint256) {
    if (sqrtPriceX96 == 0) return 0;
    // price1e18 = (sqrtP / 2^96)^2 · 1e18 = sqrtP² · 1e18 / 2^192
    return F.fullMulDiv(F.fullMulDiv(uint256(sqrtPriceX96), uint256(sqrtPriceX96), Q96), 1e18, Q96);
  }

  /// @notice ±`rangeBps` bounds around `center1e18` (1000 = 10%).
  function rangeBounds(uint256 center1e18, uint256 rangeBps)
    internal
    pure
    returns (uint160 sqrtLower, uint160 sqrtUpper)
  {
    uint256 lo = (center1e18 * (10_000 - rangeBps)) / 10_000;
    uint256 hi = (center1e18 * (10_000 + rangeBps)) / 10_000;
    sqrtLower = encode(lo);
    sqrtUpper = encode(hi);
    if (sqrtLower >= sqrtUpper) revert Bounds();
  }

  /// @notice Arithmetic mid of lower/upper prices (1e18).
  function midPrice(uint160 sqrtLower, uint160 sqrtUpper) internal pure returns (uint256) {
    return (decode(sqrtLower) + decode(sqrtUpper)) / 2;
  }

  /// @notice |spot − mid| / mid in bps.
  function driftBps(uint256 spot1e18, uint256 mid1e18) internal pure returns (uint256) {
    if (mid1e18 == 0) return type(uint256).max;
    uint256 diff = spot1e18 > mid1e18 ? spot1e18 - mid1e18 : mid1e18 - spot1e18;
    return (diff * 10_000) / mid1e18;
  }

  /// @notice token0 owed for liquidity L between sqrtA and sqrtB (A < B).
  function amount0(uint160 sqrtA, uint160 sqrtB, uint128 L) internal pure returns (uint256) {
    if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
    // fullMulDiv: (L·Q96)·(sqrtB−sqrtA)/sqrtB may exceed 256-bit intermediate
    return F.fullMulDiv(uint256(L) << 96, sqrtB - sqrtA, sqrtB) / sqrtA;
  }

  /// @notice token1 owed for liquidity L between sqrtA and sqrtB (A < B).
  function amount1(uint160 sqrtA, uint160 sqrtB, uint128 L) internal pure returns (uint256) {
    if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
    return F.fullMulDiv(L, sqrtB - sqrtA, Q96);
  }

  /// @notice Next sqrt price after adding `amount0In` (zeroForOne / price down).
  function nextSqrtFromAmount0(uint160 sqrtP, uint128 L, uint256 amount0In)
    internal
    pure
    returns (uint160)
  {
    if (amount0In == 0) return sqrtP;
    uint256 numerator1 = uint256(L) << 96;
    uint256 product;
    unchecked {
      product = amount0In * uint256(sqrtP);
    }
    if (product / amount0In == uint256(sqrtP)) {
      uint256 denom = numerator1 + product;
      if (denom >= numerator1) {
        return uint160(F.fullMulDivUp(numerator1, sqrtP, denom));
      }
    }
    return uint160(F.divUp(numerator1, numerator1 / sqrtP + amount0In));
  }

  /// @notice Next sqrt price after adding `amount1In` (oneForZero / price up).
  function nextSqrtFromAmount1(uint160 sqrtP, uint128 L, uint256 amount1In)
    internal
    pure
    returns (uint160)
  {
    if (amount1In == 0) return sqrtP;
    return uint160(uint256(sqrtP) + F.fullMulDiv(amount1In, Q96, L));
  }

  error Bounds();
}
