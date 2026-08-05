// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./interfaces/IPool.sol";
import {ILPToken} from "./LPToken.sol";
import {IAdmin} from "./interfaces/IAdmin.sol";
import {IPoolAuxWiring} from "./interfaces/IPoolAuxWiring.sol";
import {Err} from "@btr-shared/Errors.sol";
import {ReentrancyGuardTransient} from "solady/utils/ReentrancyGuardTransient.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Pricing} from "./libraries/Pricing.sol";
import {Constants as C} from "./libraries/Constants.sol";
import {PoolBatch} from "./libraries/PoolBatch.sol";
import {PoolLiquidity} from "./libraries/PoolLiquidity.sol";
import {PoolSwap} from "./libraries/PoolSwap.sol";
import {PoolView} from "./libraries/PoolView.sol";
import {PoolIO} from "./libraries/PoolIO.sol";

/// @title Pool - standalone AIMM (ERC1967 beacon proxy; cold paths → PoolAux).
/// @dev `$` at slot 0; PoolAux mirrors the same layout for DELEGATECALL.
contract Pool is ReentrancyGuardTransient {
  // ────────────────────────────────────────────────────────────────
  // STORAGE (slot 0; mirrored in PoolAux)
  // ────────────────────────────────────────────────────────────────

  IPool.PoolStorage internal $;

  // ────────────────────────────────────────────────────────────────
  // IMMUTABLES
  // ────────────────────────────────────────────────────────────────

  /// @notice Shared singleton AccessControl.
  address public immutable AC;
  /// @notice Singleton Admin contract gating restricted setters.
  address public immutable admin;
  /// @notice Singleton Flash contract.
  address public immutable flash;
  /// @notice Singleton PoolAux contract (cold-path dispatcher target).
  address public immutable poolAux;

  constructor(address ac_, address admin_, address flash_, address poolAux_) {
    if (ac_ == address(0) || admin_ == address(0) || flash_ == address(0) || poolAux_ == address(0))
    {
      revert Err.ZeroAddr();
    }
    if (
      ac_.code.length == 0 || admin_.code.length == 0 || flash_.code.length == 0
        || poolAux_.code.length == 0
    ) {
      revert Err.NotCode();
    }
    if (IAdmin(admin_).AC() != ac_) revert Err.BadConfig();
    if (IPoolAuxWiring(poolAux_).AC() != ac_ || IPoolAuxWiring(poolAux_).admin() != admin_ || IPoolAuxWiring(poolAux_).flash() != flash_) revert Err.BadConfig();
    AC = ac_;
    admin = admin_;
    flash = flash_;
    poolAux = poolAux_;
  }

  modifier whenInitialized() {
    if (!$.initialized) revert Err.InvalidState();
    _;
  }

  /// @dev L-10: inclusive deadline (ts == deadline succeeds); opt-out = type(uint256).max, no 0-sentinel.
  modifier beforeDeadline(uint256 deadline) {
    if (block.timestamp > deadline) revert Err.Expired();
    _;
  }

  /// @dev `wnative_ == address(0)` is allowed on chains with no WETH9-style wrapper (e.g. Arc:
  ///      native USDC has no deposit/withdraw). Native sentinel paths then revert in PoolIO.
  function initialize(address baseToken_, address wnative_, IPool.FeeParams calldata feeParams)
    external
  {
    if ($.initialized) revert Err.InvalidState();
    if (feeParams.protoShare > 100) revert Err.InvalidInput();
    if (feeParams.flashFeePbps > C.MAX_FLASH_FEE_PBPS) revert Err.InvalidInput();
    $.baseToken = baseToken_;
    $.wnative = wnative_;
    $.feeParams = feeParams;
    $.flowCooldownSeconds = C.DEFAULT_FLOW_COOLDOWN;
    $.factory = msg.sender;
    $.initialized = true;
    emit IPool.PoolInitialized(_owner(), baseToken_, wnative_);
  }

  function _owner() internal view returns (address) {
    return AccessControl(AC).owner();
  }


  // ────────────────────────────────────────────────────────────────
  // LIQUIDITY DOMAIN (hot)
  // ────────────────────────────────────────────────────────────────

  function deposit(address token, uint256 amount)
    external
    payable
    nonReentrant
    whenInitialized
    returns (IPool.DepositResult memory)
  {
    return PoolLiquidity.deposit($, token, amount);
  }

  function donate(address token, uint256 amount) external payable nonReentrant whenInitialized {
    PoolLiquidity.donate($, token, amount);
  }

  // deposit/donate carry no deadline: no minOut, LP minted at current mark — nothing stale to protect.
  function withdraw(address token, uint256 lpAmount, uint256 minAmountOut, uint256 deadline)
    external
    nonReentrant
    whenInitialized
    beforeDeadline(deadline)
    returns (IPool.WithdrawResult memory)
  {
    return PoolLiquidity.withdrawTo($, token, token, lpAmount, minAmountOut);
  }

  function withdrawTo(
    address tokenFrom,
    address tokenTo,
    uint256 lpAmount,
    uint256 minAmountOut,
    uint256 deadline
  )
    external
    nonReentrant
    whenInitialized
    beforeDeadline(deadline)
    returns (IPool.WithdrawResult memory)
  {
    return PoolLiquidity.withdrawTo($, tokenFrom, tokenTo, lpAmount, minAmountOut);
  }

  function swapLiability(
    address tokenIn,
    address tokenOut,
    uint256 lpAmountIn,
    uint256 minLpAmountOut,
    uint256 deadline
  ) external nonReentrant whenInitialized beforeDeadline(deadline) returns (uint256 lpAmountOut) {
    return PoolLiquidity.swapLiability($, tokenIn, tokenOut, lpAmountIn, minLpAmountOut);
  }

  // ────────────────────────────────────────────────────────────────
  // EXCHANGE DOMAIN (hot)
  // ────────────────────────────────────────────────────────────────

  function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient,
    uint256 deadline
  ) external payable nonReentrant whenInitialized beforeDeadline(deadline) returns (uint256 out) {
    return PoolSwap.swap($, tokenIn, tokenOut, amountIn, minAmountOut, recipient);
  }

  function getSwapQuote(address tokenIn, address tokenOut, uint256 amountIn)
    external
    view
    returns (IPool.SwapQuote memory)
  {
    return Pricing.getAnchorPathQuoteView(
      $, PoolIO.wrap($, tokenIn), PoolIO.wrap($, tokenOut), amountIn
    );
  }

  function batchSwap(
    bytes calldata inputs,
    bytes calldata outputs,
    address recipient,
    uint256 deadline
  )
    external
    payable
    nonReentrant
    whenInitialized
    beforeDeadline(deadline)
    returns (uint256[] memory amountsOut)
  {
    return PoolBatch.batchSwap($, inputs, outputs, recipient);
  }

  // ── Views (hot) — on-chain consumers + computational previews only ──
  // Storage dumps for off-chain (profile/risk/oracle) → SDK slot readers, not getters.
  function owner() external view returns (address) {
    return _owner();
  }

  function baseToken() external view returns (address) {
    return $.baseToken;
  }

  function wnative() external view returns (address) {
    return $.wnative;
  }

  function treasury() external view returns (address) {
    return $.treasury;
  }

  function getAsset(address tk) external view returns (IPool.Asset memory) {
    return $.assets[PoolIO.wrap($, tk)];
  }

  /// @dev Thin view for CDP wipe gate / integrators. No storage layout change.
  function liquidityIndex(address tk) external view returns (uint256) {
    return $.assets[PoolIO.wrap($, tk)].liquidityIndex;
  }

  /// @dev Capacity view for CDP / integrators. No storage layout change. See PoolView.maxRedeem.
  function maxRedeem(address owner, address tk) external view returns (uint256) {
    return PoolView.maxRedeem($, owner, tk);
  }

  function withdrawUnlockTime(address owner, address tk) external view returns (uint32) {
    return PoolView.withdrawUnlockTime($, owner, tk);
  }

  /// @dev On-chain oracle config read for CDP mark basis. No storage layout change.
  function getOracleConfig(address tk) external view returns (IPool.OracleConfig memory) {
    return $.oracleConfigs[PoolIO.wrap($, tk)];
  }

  function previewWithdraw(address tk, uint256 lp) external view returns (uint256, uint256) {
    return PoolView.previewWithdraw($, tk, lp);
  }

  /// @dev Decay-aware preview (virtual pending decay). Prefer for CDP valuation.
  function previewWithdrawFresh(address tk, uint256 lp) external view returns (uint256, uint256) {
    return PoolView.previewWithdrawFresh($, tk, lp);
  }

  function pendingDecay(address tk) external view returns (uint128) {
    return PoolView.pendingDecay($, tk);
  }

  /// @dev Thin tuple for CDP mark basis (avoids decoding full OracleConfig memory).
  function markFeed(address tk)
    external
    view
    returns (address primary, bytes32 feedId, uint8 mode)
  {
    IPool.OracleConfig storage oc = $.oracleConfigs[PoolIO.wrap($, tk)];
    return (oc.primary, oc.feedId, oc.mode);
  }

  function assetDecimals(address tk) external view returns (uint8) {
    return $.assets[PoolIO.wrap($, tk)].decimals;
  }

  /// @dev Proxying view over the leg receipt, kept so the SDK, front and keepers are zero-diff.
  function getLPBalance(address u, address tk) external view returns (uint256) {
    address lp = $.lpTokens[PoolIO.wrap($, tk)];
    return lp == address(0) ? 0 : ILPToken(lp).balanceOf(u);
  }

  function lpToken(address tk) external view returns (address) {
    return $.lpTokens[PoolIO.wrap($, tk)];
  }

  /// @dev Read by every leg receipt on mint and on a transfer inside the anti-JIT window. Kept off
  ///      `nonReentrant` deliberately: a guarded getter would make a transfer revert whenever the
  ///      pool is mid-call, which is exactly the non-deterministic failure an ERC-20 must not have.
  function flowCooldownSeconds() external view returns (uint16) {
    return $.flowCooldownSeconds;
  }

  function getProtocolFees(address tk) external view returns (uint256) {
    return $.protocolFees[PoolIO.wrap($, tk)];
  }

  function getRiskFlags(address tk) external view returns (uint16) {
    return $.riskConfigs[PoolIO.wrap($, tk)].flags;
  }

  function getFeeParams() external view returns (IPool.FeeParams memory) {
    return $.feeParams;
  }

  /// @dev Convenience R/L WAD — prefer deriving off-chain from getAsset (or slots). Kept for Flash-era tooling.
  function getCoverageRatio(address tk) external view returns (uint256) {
    return PoolView.getCoverageRatio($, tk);
  }

  // ────────────────────────────────────────────────────────────────
  // FALLBACK DISPATCHER (cold paths → PoolAux)
  // ────────────────────────────────────────────────────────────────

  /// @notice Forwards any unhandled selector to PoolAux via DELEGATECALL.
  /// @dev    PoolAux storage layout mirrors Pool ($ at slot 0); auth + reentrancy
  ///         checks live in PoolAux. msg.sender is preserved transparently.
  fallback() external payable {
    address target = poolAux;
    assembly {
      calldatacopy(0, 0, calldatasize())
      let result := delegatecall(gas(), target, 0, calldatasize(), 0, 0)
      let size := returndatasize()
      returndatacopy(0, 0, size)
      switch result
      case 0 { revert(0, size) }
      default { return(0, size) }
    }
  }

  /// @dev WETH9 unwrap lands ETH here. No-wrapper chains (wnative=0) reject stray value.
  receive() external payable {
    if ($.wnative == address(0)) revert Err.InvalidInput();
  }
}
