// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {CurveStableSwapMath as M} from "./vendor/CurveStableSwapMath.sol";

/// @title CurveStableSwap — lean n-coin StableSwap using official Curve NG math.
/// @notice `get_D`/`get_y` from CurveStableSwapNGMath. Fee path = classic plain pool with
///         `admin_fee = 0` (gross fee = net LP fee). 2–4 coins, equal 18-dec rates.
contract CurveStableSwap {
  uint256 public constant FEE_DENOMINATOR = 1e10;
  uint256 public constant A_PRECISION = 100;

  uint256 public immutable N;
  uint256 public immutable fee;
  uint256 public immutable adminFee; // 0

  address[] public coins;
  uint256[] public balances;

  uint256 public initialA; // A * A_PRECISION
  uint256 public totalSupply;
  mapping(address => uint256) public lpBalances;

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
    if (n < 2 || n > 4) revert BadN();
    N = n;
    fee = fee_;
    adminFee = 0;
    coins = coins_;
    balances = new uint256[](n);
    initialA = A_ * A_PRECISION;
  }

  function A() public view returns (uint256) {
    return initialA;
  }

  function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
    return _getDy(uint256(uint128(i)), uint256(uint128(j)), dx);
  }

  function exchange(int128 i_, int128 j_, uint256 dx, uint256 minDy) external returns (uint256 dy) {
    uint256 i = uint256(uint128(i_));
    uint256 j = uint256(uint128(j_));
    if (i >= N || j >= N || i == j) revert BadIndex();
    if (dx == 0) revert ZeroAmount();

    SafeTransferLib.safeTransferFrom(coins[i], msg.sender, address(this), dx);

    uint256[] memory xp = _xp();
    uint256 amp = A();
    uint256 D = M.getD(xp, amp, N);
    uint256 y = M.getY(i, j, xp[i] + dx, xp, amp, D, N);
    dy = xp[j] - y - 1;
    uint256 dyFee = (dy * fee) / FEE_DENOMINATOR;
    // admin_fee=0 → dy_admin_fee=0; full fee remains in balances[j]
    dy = dy - dyFee;
    if (dy < minDy) revert Slippage();

    balances[i] = xp[i] + dx;
    balances[j] = xp[j] - dy; // keeps dyFee in the pool for LPs

    SafeTransferLib.safeTransfer(coins[j], msg.sender, dy);
    emit TokenExchange(msg.sender, i_, dx, j_, dy);
  }

  function add_liquidity(uint256[] calldata amounts, uint256 minMint)
    external
    returns (uint256 mintAmount)
  {
    if (amounts.length != N) revert BadN();
    uint256 amp = A();
    uint256[] memory oldBalances = _xp();
    uint256 D0 = totalSupply == 0 ? 0 : M.getD(oldBalances, amp, N);

    uint256[] memory newBalances = new uint256[](N);
    for (uint256 i; i < N; i++) {
      if (amounts[i] > 0) {
        SafeTransferLib.safeTransferFrom(coins[i], msg.sender, address(this), amounts[i]);
      }
      newBalances[i] = oldBalances[i] + amounts[i];
    }
    uint256 D1 = M.getD(newBalances, amp, N);
    require(D1 > D0, "D");

    if (totalSupply > 0) {
      // Classic imbalance fee; admin_fee=0 → fee stays in balances
      uint256 _fee = (fee * N) / (4 * (N - 1));
      uint256[] memory afterFee = new uint256[](N);
      for (uint256 i; i < N; i++) {
        uint256 ideal = (D1 * oldBalances[i]) / D0;
        uint256 difference =
          ideal > newBalances[i] ? ideal - newBalances[i] : newBalances[i] - ideal;
        uint256 f = (_fee * difference) / FEE_DENOMINATOR;
        afterFee[i] = newBalances[i] - f;
      }
      uint256 D2 = M.getD(afterFee, amp, N);
      mintAmount = (totalSupply * (D2 - D0)) / D0;
    } else {
      mintAmount = D1;
    }

    for (uint256 i; i < N; i++) {
      balances[i] = newBalances[i]; // admin_fee=0: no skim
    }

    if (mintAmount < minMint) revert Slippage();
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

  function nCoins() external view returns (uint256) {
    return N;
  }

  function getCoin(uint256 i) external view returns (address) {
    return coins[i];
  }

  function _xp() internal view returns (uint256[] memory xp) {
    xp = new uint256[](N);
    for (uint256 i; i < N; i++) {
      xp[i] = balances[i];
    }
  }

  function _getDy(uint256 i, uint256 j, uint256 dx) internal view returns (uint256 dy) {
    uint256[] memory xp = _xp();
    uint256 amp = A();
    uint256 D = M.getD(xp, amp, N);
    uint256 y = M.getY(i, j, xp[i] + dx, xp, amp, D, N);
    dy = xp[j] - y - 1;
    dy -= (dy * fee) / FEE_DENOMINATOR;
  }
}
