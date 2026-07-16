// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.35;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title FluidDexMath — exact Fluid DexT1 / DexLite AMM math (imaginary reserves + x·y=k).
/// @notice Ported from Instadapp fluid-contracts-public (DexLite helpers + DexT1 coreHelpers).
///         BUSL-1.1 until 2027-12-19 — Chapel / educational / non-production use only.
/// @dev Price precision = 1e27. Fee units: 1e4 = 1% (same as Fluid `updateFeeAndRevenueCut`).
library FluidDexMath {
  uint256 internal constant PRICE_PRECISION = 1e27;
  uint256 internal constant FOUR_DECIMALS = 1e4;
  uint256 internal constant SIX_DECIMALS = 1e6;

  /// @dev Fluid `_calculateReservesOutsideRange` — outside-range (xa, yb) from real (rx, ry).
  ///      gp = geometricMean(upper, lower), pa = upperRange price (both 1e27).
  function calculateReservesOutsideRange(uint256 gp, uint256 pa, uint256 rx, uint256 ry)
    internal
    pure
    returns (uint256 xa, uint256 yb)
  {
    unchecked {
      uint256 p1 = pa - gp;
      uint256 p2 = ((gp * rx) + (ry * PRICE_PRECISION)) / (2 * p1);
      xa = p2 + FixedPointMathLib.sqrt(((rx * ry * PRICE_PRECISION) / p1) + (p2 * p2));
      yb = (xa * gp) / PRICE_PRECISION;
    }
  }

  /// @notice Imaginary reserves = outside + real (Fluid DexLite `_getPricesAndReserves` tail).
  /// @param centerPrice 1e27 (1.0 = 1e27 for stables)
  /// @param upperPercent 1e2 = 1%, 1e4 = 100% (Fluid FOUR_DECIMALS)
  /// @param lowerPercent same units
  function imaginaryReserves(
    uint256 centerPrice,
    uint256 upperPercent,
    uint256 lowerPercent,
    uint256 token0Real,
    uint256 token1Real
  ) internal pure returns (uint256 token0Imag, uint256 token1Imag) {
    uint256 upperRange =
      (centerPrice * FOUR_DECIMALS) / (FOUR_DECIMALS - upperPercent);
    uint256 lowerRange = (centerPrice * (FOUR_DECIMALS - lowerPercent)) / FOUR_DECIMALS;

    uint256 gp;
    unchecked {
      if (upperRange < 1e38) {
        gp = FixedPointMathLib.sqrt(upperRange * lowerRange);
      } else {
        gp = FixedPointMathLib.sqrt((upperRange / 1e18) * (lowerRange / 1e18)) * 1e18;
      }
    }

    if (gp < PRICE_PRECISION) {
      (token0Imag, token1Imag) =
        calculateReservesOutsideRange(gp, upperRange, token0Real, token1Real);
    } else {
      // invert axes when gp ≥ 1e27 (Fluid DexLite / DexT1)
      unchecked {
        (token1Imag, token0Imag) = calculateReservesOutsideRange(
          PRICE_PRECISION * PRICE_PRECISION / gp,
          PRICE_PRECISION * PRICE_PRECISION / lowerRange,
          token1Real,
          token0Real
        );
      }
    }
    unchecked {
      token0Imag += token0Real;
      token1Imag += token1Real;
    }
  }

  /// @dev Fluid DexLite `_swapIn` fee + CPMM on imaginary reserves.
  ///      fee: 10000 = 1%, 100 = 0.01% (1 bp). Divided by 1e6 per Fluid.
  function getAmountOut(uint256 amountIn, uint256 iReserveIn, uint256 iReserveOut, uint256 fee)
    internal
    pure
    returns (uint256 amountOut)
  {
    uint256 feeAmt = (amountIn * fee) / SIX_DECIMALS;
    uint256 inAfterFee = amountIn - feeAmt;
    amountOut = (inAfterFee * iReserveOut) / (iReserveIn + inAfterFee);
  }

  function getAmountIn(uint256 amountOut, uint256 iReserveIn, uint256 iReserveOut, uint256 fee)
    internal
    pure
    returns (uint256 amountIn)
  {
    // invert: amountOut = ((in - fee) * iOut) / (iIn + in - fee), fee = in * f / 1e6
    // Solve for amountIn (Fluid DexLite _swapOut path).
    uint256 numerator = amountOut * iReserveIn;
    uint256 denominator = iReserveOut - amountOut;
    uint256 inAfterFee = numerator / denominator;
    // gross up by fee: in = inAfterFee * 1e6 / (1e6 - fee)
    amountIn = (inAfterFee * SIX_DECIMALS) / (SIX_DECIMALS - fee);
  }
}
