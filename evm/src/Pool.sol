// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./interfaces/IPool.sol";
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

/// @title Pool — standalone AIMM (ERC1967 beacon proxy; cold paths → PoolAux).
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
    IPoolAuxWiring aux = IPoolAuxWiring(poolAux_);
    if (aux.AC() != ac_ || aux.admin() != admin_ || aux.flash() != flash_) revert Err.BadConfig();
    AC = ac_;
    admin = admin_;
    flash = flash_;
    poolAux = poolAux_;
  }

  modifier whenInitialized() {
    if (!$.initialized) revert Err.InvalidState();
    _;
  }

  function initialize(address baseToken_, address wnative_, IPool.FeeParams calldata feeParams)
    external
  {
    if ($.initialized) revert Err.InvalidState();
    if (wnative_ == address(0)) revert Err.ZeroAddr();
    if (feeParams.protoShare > 100) revert Err.InvalidInput();
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

  /// @notice ERC7802 bridge auth -bridgeable tokens query this.
  function getAuthorizedBridge() external view returns (address) {
    return $.bridge;
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

  function withdraw(address token, uint256 lpAmount, uint256 minAmountOut)
    external
    nonReentrant
    whenInitialized
    returns (IPool.WithdrawResult memory)
  {
    return PoolLiquidity.withdrawTo($, token, token, lpAmount, minAmountOut);
  }

  function withdrawTo(address tokenFrom, address tokenTo, uint256 lpAmount, uint256 minAmountOut)
    external
    nonReentrant
    whenInitialized
    returns (IPool.WithdrawResult memory)
  {
    return PoolLiquidity.withdrawTo($, tokenFrom, tokenTo, lpAmount, minAmountOut);
  }

  function swapLiability(
    address tokenIn,
    address tokenOut,
    uint256 lpAmountIn,
    uint256 minLpAmountOut
  ) external nonReentrant whenInitialized returns (uint256 lpAmountOut) {
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
    address recipient
  ) external payable nonReentrant whenInitialized returns (uint256 out) {
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

  function batchSwap(bytes calldata inputs, bytes calldata outputs, address recipient)
    external
    payable
    nonReentrant
    whenInitialized
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

  function previewWithdraw(address tk, uint256 lp) external view returns (uint256, uint256) {
    return PoolView.previewWithdraw($, tk, lp);
  }

  function getLPBalance(address u, address tk) external view returns (uint256) {
    return $.lpBalances[u][PoolIO.wrap($, tk)];
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

  receive() external payable {}
}
