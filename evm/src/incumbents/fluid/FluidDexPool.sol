// SPDX-License-Identifier: BUSL-1.1
pragma solidity =0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {FluidDexMath} from "./FluidDexMath.sol";

/// @title FluidDexPool — Fluid DexT1/DexLite collateral-path AMM (exact math), self-custody.
/// @notice Same pricing as Fluid DEX: centerPrice + range → imaginary reserves → x·y=k swap.
///         Omits Liquidity Layer / smart-debt routing (col-only). For Chapel stables that matches
///         the DexLite correlated-pair path and DexT1 when debt reserves are empty.
///         BUSL-1.1 (Instadapp math) — testnet / educational only until 2027-12-19.
contract FluidDexPool {
  using FluidDexMath for uint256;

  address public immutable token0;
  address public immutable token1;
  /// @dev Fluid fee: 10000 = 1%, 100 = 1 bp.
  uint256 public immutable fee;
  /// @dev Range half-widths in Fluid FOUR_DECIMALS (100 = 1%).
  uint256 public immutable upperPercent;
  uint256 public immutable lowerPercent;
  /// @dev Center price in 1e27 (stables = 1e27).
  uint256 public centerPrice;

  uint256 public reserve0;
  uint256 public reserve1;

  error BadTokens();
  error ZeroAmount();
  error Slippage();
  error AlreadyInit();

  event Swap(
    address indexed sender, bool zeroForOne, uint256 amountIn, uint256 amountOut, address indexed to
  );
  event Initialize(uint256 amount0, uint256 amount1, uint256 centerPrice);

  constructor(
    address tokenA,
    address tokenB,
    uint256 fee_,
    uint256 upperPercent_,
    uint256 lowerPercent_,
    uint256 centerPrice_
  ) {
    if (tokenA == tokenB || tokenA == address(0)) revert BadTokens();
    (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    fee = fee_;
    upperPercent = upperPercent_;
    lowerPercent = lowerPercent_;
    centerPrice = centerPrice_ == 0 ? FluidDexMath.PRICE_PRECISION : centerPrice_;
  }

  function initialize(uint256 amount0, uint256 amount1) external {
    if (reserve0 != 0 || reserve1 != 0) revert AlreadyInit();
    if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
    SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), amount0);
    SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), amount1);
    reserve0 = amount0;
    reserve1 = amount1;
    emit Initialize(amount0, amount1, centerPrice);
  }

  function getImaginaryReserves() public view returns (uint256 i0, uint256 i1) {
    return
      FluidDexMath.imaginaryReserves(centerPrice, upperPercent, lowerPercent, reserve0, reserve1);
  }

  function quote(bool zeroForOne, uint256 amountIn) public view returns (uint256 amountOut) {
    if (amountIn == 0 || reserve0 == 0 || reserve1 == 0) return 0;
    (uint256 i0, uint256 i1) = getImaginaryReserves();
    (uint256 iIn, uint256 iOut) = zeroForOne ? (i0, i1) : (i1, i0);
    amountOut = FluidDexMath.getAmountOut(amountIn, iIn, iOut, fee);
    uint256 rOut = zeroForOne ? reserve1 : reserve0;
    if (amountOut > rOut) amountOut = rOut;
  }

  function swap(bool zeroForOne, uint256 amountIn, uint256 minOut, address to)
    external
    returns (uint256 amountOut)
  {
    if (amountIn == 0) revert ZeroAmount();
    address tin = zeroForOne ? token0 : token1;
    address tout = zeroForOne ? token1 : token0;
    SafeTransferLib.safeTransferFrom(tin, msg.sender, address(this), amountIn);

    amountOut = quote(zeroForOne, amountIn);
    if (amountOut < minOut) revert Slippage();

    if (zeroForOne) {
      reserve0 += amountIn;
      reserve1 -= amountOut;
    } else {
      reserve1 += amountIn;
      reserve0 -= amountOut;
    }
    SafeTransferLib.safeTransfer(tout, to, amountOut);
    emit Swap(msg.sender, zeroForOne, amountIn, amountOut, to);
  }
}

/// @title FluidDexFactory — deploys Fluid-math pools (col-path).
contract FluidDexFactory {
  mapping(address => mapping(address => address)) public getPool;
  address[] public allPools;

  event PoolCreated(
    address indexed token0, address indexed token1, address pool, uint256 fee, uint256 rangePct
  );

  function createPool(
    address tokenA,
    address tokenB,
    uint256 fee,
    uint256 upperPercent,
    uint256 lowerPercent,
    uint256 centerPrice
  ) external returns (address pool) {
    (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    require(getPool[t0][t1] == address(0), "EXISTS");
    FluidDexPool p = new FluidDexPool(t0, t1, fee, upperPercent, lowerPercent, centerPrice);
    pool = address(p);
    getPool[t0][t1] = pool;
    getPool[t1][t0] = pool;
    allPools.push(pool);
    emit PoolCreated(t0, t1, pool, fee, upperPercent);
  }
}
