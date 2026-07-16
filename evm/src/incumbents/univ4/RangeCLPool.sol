// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {IUniSpot} from "../../interfaces/IUniSpot.sol";
import {IRecenterHook} from "../../interfaces/IRecenterHook.sol";
import {SqrtPrice} from "./SqrtPrice.sol";

/// @title RangeCLPool — lean single-range CLAMM (Uni V4-shaped, no PoolManager).
/// @notice One active ±range position; optional shared `RecenterHook` recenters on drift.
///         Chapel testnet piggyback — not a full Uniswap V4 PoolManager deploy.
/// @dev Bunni-inspired: afterSwap may shift the active range when spot drifts from mid.
contract RangeCLPool is IUniSpot {
  using SqrtPrice for uint160;

  uint24 public immutable fee; // hundredths of a bip (Uni units): 3000 = 0.3%
  address public immutable override token0;
  address public immutable override token1;
  address public immutable hook;

  uint160 public sqrtPriceX96;
  uint160 public sqrtLowerX96;
  uint160 public sqrtUpperX96;
  uint128 public liquidity;
  uint256 public reserve0;
  uint256 public reserve1;

  uint256 private _locked = 1;

  error BadTokens();
  error ZeroAmount();
  error Slippage();
  error NotHook();
  error OutOfRange();
  error Reentrancy();
  error NotInit();
  error AlreadyInit();

  event Swap(
    address indexed sender,
    address indexed recipient,
    bool zeroForOne,
    uint256 amountIn,
    uint256 amountOut,
    uint160 sqrtPriceX96After
  );
  event Mint(address indexed sender, uint128 liquidityMinted, uint256 amount0, uint256 amount1);
  event Recentered(uint160 sqrtLower, uint160 sqrtUpper, uint160 sqrtPrice, uint128 liquidity);

  modifier nonReentrant() {
    if (_locked != 1) revert Reentrancy();
    _locked = 2;
    _;
    _locked = 1;
  }

  constructor(address tokenA, address tokenB, uint24 fee_, address hook_) {
    if (tokenA == tokenB || tokenA == address(0) || tokenB == address(0)) revert BadTokens();
    (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    fee = fee_;
    hook = hook_;
  }

  /// @inheritdoc IUniSpot
  function slot0() external view returns (uint160 sqrtP, int24 tick, uint128 liq) {
    sqrtP = sqrtPriceX96;
    tick = 0; // single-range demo — tick unused
    liq = liquidity;
  }

  /// @notice Seed price + ±`rangeBps` bounds, then mint liquidity from `msg.sender`.
  /// @param price1e18 token1/token0 in 1e18
  /// @param rangeBps half-width in bps (1000 = ±10%)
  /// @param amount0Desired / amount1Desired pulled; unused remainder stays with caller after mint sizing
  function seed(uint256 price1e18, uint256 rangeBps, uint256 amount0Desired, uint256 amount1Desired)
    external
    nonReentrant
    returns (uint128 liq)
  {
    if (sqrtPriceX96 != 0) revert AlreadyInit();
    if (price1e18 == 0 || amount0Desired == 0 || amount1Desired == 0) revert ZeroAmount();

    sqrtPriceX96 = SqrtPrice.encode(price1e18);
    (sqrtLowerX96, sqrtUpperX96) = SqrtPrice.rangeBounds(price1e18, rangeBps);

    liq = _maxLiquidityForAmounts(amount0Desired, amount1Desired);
    if (liq == 0) revert ZeroAmount();
    (uint256 a0, uint256 a1) = _amountsForLiquidity(liq);
    SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), a0);
    SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), a1);
    reserve0 = a0;
    reserve1 = a1;
    liquidity = liq;
    emit Mint(msg.sender, liq, a0, a1);
  }

  function swap(bool zeroForOne, uint256 amountIn, uint256 minOut, address recipient)
    external
    nonReentrant
    returns (uint256 amountOut)
  {
    if (amountIn == 0) revert ZeroAmount();
    if (liquidity == 0 || sqrtPriceX96 == 0) revert NotInit();

    uint256 amountInLessFee = amountIn - (amountIn * uint256(fee)) / 1_000_000;
    uint160 sqrtP = sqrtPriceX96;
    uint128 L = liquidity;

    if (zeroForOne) {
      uint160 sqrtNext = SqrtPrice.nextSqrtFromAmount0(sqrtP, L, amountInLessFee);
      if (sqrtNext < sqrtLowerX96) revert OutOfRange();
      amountOut = SqrtPrice.amount1(sqrtNext, sqrtP, L);
      if (amountOut < minOut) revert Slippage();
      SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), amountIn);
      reserve0 += amountIn;
      reserve1 -= amountOut;
      sqrtPriceX96 = sqrtNext;
      SafeTransferLib.safeTransfer(token1, recipient, amountOut);
    } else {
      uint160 sqrtNext = SqrtPrice.nextSqrtFromAmount1(sqrtP, L, amountInLessFee);
      if (sqrtNext > sqrtUpperX96) revert OutOfRange();
      amountOut = SqrtPrice.amount0(sqrtP, sqrtNext, L);
      if (amountOut < minOut) revert Slippage();
      SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), amountIn);
      reserve1 += amountIn;
      reserve0 -= amountOut;
      sqrtPriceX96 = sqrtNext;
      SafeTransferLib.safeTransfer(token0, recipient, amountOut);
    }

    emit Swap(msg.sender, recipient, zeroForOne, amountIn, amountOut, sqrtPriceX96);

    if (hook != address(0)) {
      IRecenterHook(hook).afterSwap(address(this));
    }
  }

  /// @notice Hook-only: if |spot−mid|/mid > `driftBps`, burn + remint ±`rangeBps` around spot.
  /// @dev Conceptual Bunni recenter: shift active liquidity distribution when spot drifts.
  function recenterIfNeeded(uint256 rangeBps, uint256 driftBps) external {
    if (msg.sender != hook) revert NotHook();
    if (liquidity == 0) return;

    uint256 spot = SqrtPrice.decode(sqrtPriceX96);
    uint256 mid = SqrtPrice.midPrice(sqrtLowerX96, sqrtUpperX96);
    if (SqrtPrice.driftBps(spot, mid) <= driftBps) return;

    // Shift range around spot; recompute L from balances (idle remainder stays — Bunni-like).
    (sqrtLowerX96, sqrtUpperX96) = SqrtPrice.rangeBounds(spot, rangeBps);
    if (sqrtPriceX96 < sqrtLowerX96) sqrtPriceX96 = sqrtLowerX96;
    if (sqrtPriceX96 > sqrtUpperX96) sqrtPriceX96 = sqrtUpperX96;

    reserve0 = SafeTransferLib.balanceOf(token0, address(this));
    reserve1 = SafeTransferLib.balanceOf(token1, address(this));
    uint128 newL = _maxLiquidityForAmounts(reserve0, reserve1);
    if (newL == 0) revert ZeroAmount();
    liquidity = newL;

    emit Recentered(sqrtLowerX96, sqrtUpperX96, sqrtPriceX96, liquidity);
  }

  function quote(bool zeroForOne, uint256 amountIn) external view returns (uint256 amountOut) {
    if (amountIn == 0 || liquidity == 0) return 0;
    uint256 amountInLessFee = amountIn - (amountIn * uint256(fee)) / 1_000_000;
    uint160 sqrtP = sqrtPriceX96;
    uint128 L = liquidity;
    if (zeroForOne) {
      uint160 sqrtNext = SqrtPrice.nextSqrtFromAmount0(sqrtP, L, amountInLessFee);
      if (sqrtNext < sqrtLowerX96) return 0;
      return SqrtPrice.amount1(sqrtNext, sqrtP, L);
    } else {
      uint160 sqrtNext = SqrtPrice.nextSqrtFromAmount1(sqrtP, L, amountInLessFee);
      if (sqrtNext > sqrtUpperX96) return 0;
      return SqrtPrice.amount0(sqrtP, sqrtNext, L);
    }
  }

  function _amountsForLiquidity(uint128 L) internal view returns (uint256 a0, uint256 a1) {
    uint160 sp = sqrtPriceX96;
    uint160 lo = sqrtLowerX96;
    uint160 hi = sqrtUpperX96;
    if (sp <= lo) {
      a0 = SqrtPrice.amount0(lo, hi, L);
    } else if (sp >= hi) {
      a1 = SqrtPrice.amount1(lo, hi, L);
    } else {
      a0 = SqrtPrice.amount0(sp, hi, L);
      a1 = SqrtPrice.amount1(lo, sp, L);
    }
  }

  function _maxLiquidityForAmounts(uint256 amount0Desired, uint256 amount1Desired)
    internal
    view
    returns (uint128)
  {
    uint160 sp = sqrtPriceX96;
    uint160 lo = sqrtLowerX96;
    uint160 hi = sqrtUpperX96;
    if (sp <= lo) {
      return _liqForAmount0(lo, hi, amount0Desired);
    }
    if (sp >= hi) {
      return _liqForAmount1(lo, hi, amount1Desired);
    }
    uint128 l0 = _liqForAmount0(sp, hi, amount0Desired);
    uint128 l1 = _liqForAmount1(lo, sp, amount1Desired);
    return l0 < l1 ? l0 : l1;
  }

  function _liqForAmount0(uint160 sqrtA, uint160 sqrtB, uint256 amount0_)
    internal
    pure
    returns (uint128)
  {
    if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
    uint256 intermediate = (uint256(sqrtA) * uint256(sqrtB)) / SqrtPrice.Q96;
    return uint128((amount0_ * intermediate) / (sqrtB - sqrtA));
  }

  function _liqForAmount1(uint160 sqrtA, uint160 sqrtB, uint256 amount1_)
    internal
    pure
    returns (uint128)
  {
    if (sqrtA > sqrtB) (sqrtA, sqrtB) = (sqrtB, sqrtA);
    return uint128((amount1_ << 96) / (sqrtB - sqrtA));
  }
}

  /// @title RangeCLFactory — deploys RangeCLPool pairs sharing one RecenterHook.
  contract RangeCLFactory {
    address public immutable hook;
    mapping(address => mapping(address => mapping(uint24 => address))) public getPool;
    address[] public allPools;

    event PoolCreated(address indexed token0, address indexed token1, uint24 fee, address pool);

    constructor(address hook_) {
      hook = hook_;
    }

    function createPool(address tokenA, address tokenB, uint24 fee)
      external
      returns (address pool)
    {
      (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
      require(getPool[t0][t1][fee] == address(0), "EXISTS");
      RangeCLPool p = new RangeCLPool(t0, t1, fee, hook);
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
