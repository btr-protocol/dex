// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

/// @title IUniSpot - minimal Uni V3/V4-style spot read for parasitic oracles.
/// @dev `sqrtPriceX96` encodes √(token1/token0) in Q64.96 (same as Uniswap).
interface IUniSpot {
  function token0() external view returns (address);
  function token1() external view returns (address);
  function slot0() external view returns (uint160 sqrtPriceX96, int24 tick, uint128 liquidity);
}
