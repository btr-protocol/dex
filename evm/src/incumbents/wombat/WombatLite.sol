// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title WombatLite — lean multi-asset coverage CSMM (Wombat-style).
/// @notice Invariant D = Σ L_i · (r_i − k/r_i), r = A/L. Stables assumed pegged 1:1 (no oracle scale).
///         Clean-room fork for Chapel; 4-token pool (USDC/USDT/USD1/USDE).
contract WombatLite {
  uint256 public constant WAD = 1e18;
  /// @dev Amplification k in WAD (e.g. 0.0001e18 ≈ flat stables). Higher k → flatter.
  uint256 public immutable ampK;
  /// @dev Swap haircut in BPS (e.g. 2 = 0.02%).
  uint256 public immutable feeBps;

  address[] public tokens;
  mapping(address => uint256) public cash; // asset A
  mapping(address => uint256) public liability; // L
  mapping(address => uint256) public lpOf; // user → aggregate LP shares (simplified single-asset mint)
  mapping(address => mapping(address => uint256)) public lpBalances; // user → token → shares
  mapping(address => bool) public isToken;

  error UnknownToken();
  error ZeroAmount();
  error Slippage();
  error BadLen();

  event Swap(
    address indexed sender,
    address fromToken,
    address toToken,
    uint256 fromAmount,
    uint256 toAmount,
    address indexed to
  );
  event Deposit(address indexed user, address indexed token, uint256 amount, uint256 lpMinted);
  event Withdraw(address indexed user, address indexed token, uint256 lpBurned, uint256 amount);

  constructor(address[] memory tokens_, uint256 ampK_, uint256 feeBps_) {
    if (tokens_.length < 2 || tokens_.length > 8) revert BadLen();
    ampK = ampK_;
    feeBps = feeBps_;
    tokens = tokens_;
    for (uint256 i; i < tokens_.length; i++) {
      isToken[tokens_[i]] = true;
    }
  }

  function nTokens() external view returns (uint256) {
    return tokens.length;
  }

  function deposit(address token, uint256 amount, uint256 minLp)
    external
    returns (uint256 lpMinted)
  {
    if (!isToken[token]) revert UnknownToken();
    if (amount == 0) revert ZeroAmount();
    SafeTransferLib.safeTransferFrom(token, msg.sender, address(this), amount);
    uint256 L = liability[token];
    if (L == 0) {
      lpMinted = amount;
    } else {
      lpMinted = (amount * L) / cash[token];
    }
    if (lpMinted < minLp) revert Slippage();
    cash[token] += amount;
    liability[token] += amount;
    lpBalances[msg.sender][token] += lpMinted;
    emit Deposit(msg.sender, token, amount, lpMinted);
  }

  function withdraw(address token, uint256 lpAmount, uint256 minOut)
    external
    returns (uint256 amountOut)
  {
    if (!isToken[token]) revert UnknownToken();
    if (lpAmount == 0) revert ZeroAmount();
    if (lpBalances[msg.sender][token] < lpAmount) revert Slippage();
    uint256 L = liability[token];
    amountOut = (lpAmount * cash[token]) / L;
    if (amountOut < minOut) revert Slippage();
    cash[token] -= amountOut;
    liability[token] = L - lpAmount;
    lpBalances[msg.sender][token] -= lpAmount;
    SafeTransferLib.safeTransfer(token, msg.sender, amountOut);
    emit Withdraw(msg.sender, token, lpAmount, amountOut);
  }

  function swap(address fromToken, address toToken, uint256 fromAmount, uint256 minTo, address to)
    external
    returns (uint256 toAmount)
  {
    if (!isToken[fromToken] || !isToken[toToken] || fromToken == toToken) revert UnknownToken();
    if (fromAmount == 0) revert ZeroAmount();
    SafeTransferLib.safeTransferFrom(fromToken, msg.sender, address(this), fromAmount);

    toAmount = quote(fromToken, toToken, fromAmount);
    if (toAmount < minTo) revert Slippage();

    cash[fromToken] += fromAmount;
    cash[toToken] -= toAmount;
    SafeTransferLib.safeTransfer(toToken, to, toAmount);
    emit Swap(msg.sender, fromToken, toToken, fromAmount, toAmount, to);
  }

  function quote(address fromToken, address toToken, uint256 fromAmount)
    public
    view
    returns (uint256 toAmount)
  {
    uint256 Lin = liability[fromToken];
    uint256 Lout = liability[toToken];
    uint256 Ain = cash[fromToken];
    uint256 Aout = cash[toToken];
    if (Lin == 0 || Lout == 0 || Ain == 0 || Aout == 0) return 0;

    uint256 k = ampK;
    uint256 rIn0 = (Ain * WAD) / Lin;
    uint256 rIn1 = ((Ain + fromAmount) * WAD) / Lin;
    int256 dIn = int256(_term(rIn1, k) * Lin / WAD) - int256(_term(rIn0, k) * Lin / WAD);

    uint256 rOut0 = (Aout * WAD) / Lout;
    // m1 = term(rOut0) - dIn/Lout
    int256 m1 = int256(_term(rOut0, k)) - (dIn * int256(WAD)) / int256(Lout);
    uint256 rOut1 = _invTerm(m1, k);
    uint256 newAout = (rOut1 * Lout) / WAD;
    if (newAout >= Aout) return 0;
    toAmount = Aout - newAout;
    toAmount = (toAmount * (10_000 - feeBps)) / 10_000;
  }

  function _term(uint256 r, uint256 k) private pure returns (uint256) {
    // r - k/r in WAD space: (r² - k) / r
    return (r * r - k) / r;
  }

  function _invTerm(int256 m, uint256 k) private pure returns (uint256) {
    // r = (m + sqrt(m² + 4k)) / 2
    int256 disc = m * m + int256(4 * k);
    require(disc >= 0, "disc");
    uint256 s = _sqrt(uint256(disc));
    int256 r = (m + int256(s)) / 2;
    require(r > 0, "r");
    return uint256(r);
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
