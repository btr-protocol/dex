// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title LiteCLPool — UniV4/PCS-Infinity-style pairwise stable pool (full-range CPMM).
/// @notice Fee in hundredths of a bip (UniV4 units): fee=5 → 0.0005%, fee=100 → 0.01%.
///         Clean-room lean fork for Chapel benchmarks — not a full PoolManager.
contract LiteCLPool {
  uint24 public immutable fee; // hundredths of a bip
  int24 public immutable tickSpacing;
  address public immutable token0;
  address public immutable token1;

  uint128 public liquidity;
  uint256 public reserve0;
  uint256 public reserve1;

  error BadTokens();
  error ZeroAmount();
  error Slippage();

  event Swap(
    address indexed sender,
    address indexed recipient,
    int256 amount0,
    int256 amount1,
    uint24 feePaid
  );
  event Mint(address indexed sender, uint128 liquidityMinted, uint256 amount0, uint256 amount1);

  constructor(address tokenA, address tokenB, uint24 fee_, int24 tickSpacing_) {
    if (tokenA == tokenB || tokenA == address(0) || tokenB == address(0)) revert BadTokens();
    (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    fee = fee_;
    tickSpacing = tickSpacing_;
  }

  /// @notice Seed / add full-range liquidity (1:1 stables assumed).
  function mint(uint256 amount0, uint256 amount1, address to) external returns (uint128 liq) {
    if (amount0 == 0 || amount1 == 0) revert ZeroAmount();
    SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), amount0);
    SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), amount1);
    // Geometric mean liquidity for full-range CPMM.
    liq = uint128(_sqrt(amount0 * amount1));
    if (liq == 0) revert ZeroAmount();
    liquidity += liq;
    reserve0 += amount0;
    reserve1 += amount1;
    emit Mint(to, liq, amount0, amount1);
  }

  function swap(bool zeroForOne, uint256 amountIn, uint256 minOut, address recipient)
    external
    returns (uint256 amountOut)
  {
    if (amountIn == 0) revert ZeroAmount();
    address tin = zeroForOne ? token0 : token1;
    address tout = zeroForOne ? token1 : token0;
    SafeTransferLib.safeTransferFrom(tin, msg.sender, address(this), amountIn);

    // fee in hundredths of a bip: amountIn * fee / 1_000_000
    uint256 amountInLessFee = amountIn - (amountIn * uint256(fee)) / 1_000_000;
    (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
    // x*y=k
    amountOut = (amountInLessFee * rOut) / (rIn + amountInLessFee);
    if (amountOut < minOut) revert Slippage();

    if (zeroForOne) {
      reserve0 += amountIn;
      reserve1 -= amountOut;
      emit Swap(msg.sender, recipient, int256(amountIn), -int256(amountOut), fee);
    } else {
      reserve1 += amountIn;
      reserve0 -= amountOut;
      emit Swap(msg.sender, recipient, -int256(amountOut), int256(amountIn), fee);
    }
    SafeTransferLib.safeTransfer(tout, recipient, amountOut);
  }

  function quote(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
    if (amountIn == 0) return 0;
    uint256 amountInLessFee = amountIn - (amountIn * uint256(fee)) / 1_000_000;
    (uint256 rIn, uint256 rOut) = zeroForOne ? (reserve0, reserve1) : (reserve1, reserve0);
    if (rIn == 0 || rOut == 0) return 0;
    amountOut = (amountInLessFee * rOut) / (rIn + amountInLessFee);
  }

  function _sqrt(uint256 x) private pure returns (uint256 z) {
    if (x == 0) return 0;
    z = x;
    uint256 y = (x + 1) / 2;
    while (y < z) {
      z = y;
      y = (x / y + y) / 2;
    }
  }
}

/// @title LiteCLFactory — deploys LiteCLPool pairs at given fee tiers.
contract LiteCLFactory {
  mapping(address => mapping(address => mapping(uint24 => address))) public getPool;
  address[] public allPools;

  event PoolCreated(address indexed token0, address indexed token1, uint24 fee, address pool);

  function createPool(address tokenA, address tokenB, uint24 fee, int24 tickSpacing)
    external
    returns (address pool)
  {
    (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    require(getPool[t0][t1][fee] == address(0), "EXISTS");
    LiteCLPool p = new LiteCLPool(t0, t1, fee, tickSpacing);
    pool = address(p);
    getPool[t0][t1][fee] = pool;
    getPool[t1][t0][fee] = pool;
    allPools.push(pool);
    emit PoolCreated(t0, t1, fee, pool);
  }

  function allPoolsLength() external view returns (uint256) {
    return allPools.length;
  }
}
