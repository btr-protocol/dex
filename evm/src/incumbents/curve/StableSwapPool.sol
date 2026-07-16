// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title StableSwapPool — lean Curve-style n-coin StableSwap (2 or 3 coins).
/// @notice Clean-room fork for Chapel benchmarks. A=1000 (fiat stables), fee in 1e10 units
///         (1e6 = 1 bp = 0.01%). Same tokens as BTR mocks.
contract StableSwapPool {
  uint256 public constant FEE_DENOM = 1e10;
  uint256 public immutable N;
  uint256 public immutable A; // amplification
  uint256 public immutable fee; // FEE_DENOM units
  address public immutable lpToken;

  address[] public coins;
  uint256[] public balances;
  uint256 public totalSupply;

  error BadN();
  error ZeroAmount();
  error Slippage();
  error BadIndex();

  event TokenExchange(
    address indexed buyer, int128 soldId, uint256 tokensSold, int128 boughtId, uint256 tokensBought
  );
  event AddLiquidity(address indexed provider, uint256[] amounts, uint256 mintAmount);
  event RemoveLiquidity(address indexed provider, uint256[] amounts, uint256 burnAmount);

  constructor(address[] memory coins_, uint256 A_, uint256 fee_) {
    uint256 n = coins_.length;
    if (n < 2 || n > 3) revert BadN();
    N = n;
    A = A_;
    fee = fee_;
    coins = coins_;
    balances = new uint256[](n);
    lpToken = address(this); // internal LP ledger (balances via totalSupply + mapping)
  }

  mapping(address => uint256) public lpBalances;

  function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
    return _getDy(uint256(uint128(i)), uint256(uint128(j)), dx);
  }

  function exchange(int128 i_, int128 j_, uint256 dx, uint256 minDy) external returns (uint256 dy) {
    uint256 i = uint256(uint128(i_));
    uint256 j = uint256(uint128(j_));
    if (i >= N || j >= N || i == j) revert BadIndex();
    if (dx == 0) revert ZeroAmount();

    SafeTransferLib.safeTransferFrom(coins[i], msg.sender, address(this), dx);
    dy = _getDy(i, j, dx);
    if (dy < minDy) revert Slippage();

    balances[i] += dx;
    balances[j] -= dy;
    SafeTransferLib.safeTransfer(coins[j], msg.sender, dy);
    emit TokenExchange(msg.sender, i_, dx, j_, dy);
  }

  function add_liquidity(uint256[] calldata amounts, uint256 minMint)
    external
    returns (uint256 mintAmount)
  {
    if (amounts.length != N) revert BadN();
    uint256 d0 = totalSupply == 0 ? 0 : _getD(balances);
    uint256[] memory newBalances = new uint256[](N);
    for (uint256 i; i < N; i++) {
      if (amounts[i] > 0) {
        SafeTransferLib.safeTransferFrom(coins[i], msg.sender, address(this), amounts[i]);
      }
      newBalances[i] = balances[i] + amounts[i];
    }
    uint256 d1 = _getD(newBalances);
    if (totalSupply == 0) {
      mintAmount = d1;
    } else {
      mintAmount = (totalSupply * (d1 - d0)) / d0;
    }
    if (mintAmount < minMint) revert Slippage();
    for (uint256 i; i < N; i++) {
      balances[i] = newBalances[i];
    }
    totalSupply += mintAmount;
    lpBalances[msg.sender] += mintAmount;
    emit AddLiquidity(msg.sender, amounts, mintAmount);
  }

  function remove_liquidity(uint256 amount, uint256[] calldata minAmounts)
    external
    returns (uint256[] memory out)
  {
    if (amount == 0) revert ZeroAmount();
    if (lpBalances[msg.sender] < amount) revert Slippage();
    out = new uint256[](N);
    for (uint256 i; i < N; i++) {
      out[i] = (balances[i] * amount) / totalSupply;
      if (out[i] < minAmounts[i]) revert Slippage();
      balances[i] -= out[i];
      SafeTransferLib.safeTransfer(coins[i], msg.sender, out[i]);
    }
    totalSupply -= amount;
    lpBalances[msg.sender] -= amount;
    emit RemoveLiquidity(msg.sender, out, amount);
  }

  function _getDy(uint256 i, uint256 j, uint256 dx) internal view returns (uint256 dy) {
    uint256[] memory xp = balances;
    uint256 d = _getD(xp);
    xp[i] += dx;
    uint256 y = _getY(i, j, xp[i], xp, d);
    dy = xp[j] - y - 1; // -1 for rounding
    uint256 feeDy = (dy * fee) / FEE_DENOM;
    dy -= feeDy;
  }

  function _getD(uint256[] memory xp) internal view returns (uint256 d) {
    uint256 s;
    for (uint256 i; i < N; i++) {
      s += xp[i];
    }
    if (s == 0) return 0;
    d = s;
    // Ann = A · N^N (Curve StableSwap)
    uint256 ann = A;
    for (uint256 i; i < N; i++) {
      ann *= N;
    }
    for (uint256 iter; iter < 255; iter++) {
      uint256 dP = d;
      for (uint256 i; i < N; i++) {
        dP = (dP * d) / (xp[i] * N);
      }
      uint256 dPrev = d;
      d = ((ann * s + dP * N) * d) / ((ann - 1) * d + (N + 1) * dP);
      if (d > dPrev) {
        if (d - dPrev <= 1) return d;
      } else if (dPrev - d <= 1) {
        return d;
      }
    }
    revert();
  }

  function _getY(uint256 i, uint256 j, uint256 x, uint256[] memory xp, uint256 d)
    internal
    view
    returns (uint256 y)
  {
    uint256 ann = A;
    for (uint256 k; k < N; k++) {
      ann *= N;
    }
    uint256 c = d;
    uint256 s;
    for (uint256 k; k < N; k++) {
      if (k == j) continue;
      uint256 xk = k == i ? x : xp[k];
      s += xk;
      c = (c * d) / (xk * N);
    }
    c = (c * d) / (ann * N);
    uint256 b = s + d / ann;
    y = d;
    for (uint256 iter; iter < 255; iter++) {
      uint256 yPrev = y;
      y = (y * y + c) / (2 * y + b - d);
      if (y > yPrev) {
        if (y - yPrev <= 1) return y;
      } else if (yPrev - y <= 1) {
        return y;
      }
    }
    revert();
  }

  function nCoins() external view returns (uint256) {
    return N;
  }

  function getCoin(uint256 i) external view returns (address) {
    return coins[i];
  }
}
