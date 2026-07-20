// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IPoolHooks} from "../interfaces/IPoolHooks.sol";
import {Constants as C} from "./Constants.sol";
import {Err} from "@btr-shared/Errors.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title PoolHooks — lean dispatch: preOutflow + postInflow only.
/// @dev Dual ledger: `Asset.reserves = R_liq + R_inv`; `invested[token] = R_inv`.
///      Recall/deploy permute R_inv↔R_liq (reserves constant). Book updates via balance-delta
///      after the hook CALL so the hook never reenters Pool state writers.
///      Hot path: liquidReserves check BEFORE HookSlot SLOAD; 0 CALL if R_liq ≥ need.
library PoolHooks {
  function liquidReserves(IPool.PoolStorage storage $, address token)
    internal
    view
    returns (uint256)
  {
    uint256 r = $.assets[token].reserves;
    uint256 inv = $.invested[token];
    return r > inv ? r - inv : 0;
  }

  /// @dev Approve hook up to deployable = R_liq − minLiquidity, call, revoke, book Δbalance.
  function postInflow(
    IPool.PoolStorage storage $,
    address token,
    address sender,
    uint256 amountIn,
    uint256 lpMinted
  ) internal {
    // Hookless assets are the common case: check the HookSlot FIRST so they pay one warm-path SLOAD
    // instead of the invested+reserves reads liquidReserves costs.
    IPool.HookSlot memory h = $.assetHooks[token];
    if (h.target == address(0) || (h.flags & C.HOOK_POST_INFLOW) == 0) return;

    uint256 liq = liquidReserves($, token);
    if (liq == 0) return;

    // Never approve past the liquid floor (malicious hooks cannot drain R_liq < minLiquidity).
    uint256 minLiq = $.assets[token].minLiquidity;
    uint256 deployable = liq > minLiq ? liq - minLiq : 0;
    if (deployable == 0) return;

    uint256 balBefore = SafeTransferLib.balanceOf(token, address(this));
    SafeTransferLib.safeApproveWithRetry(token, h.target, deployable);
    IPoolHooks(h.target).postInflow(address(this), sender, token, amountIn, lpMinted);
    SafeTransferLib.safeApproveWithRetry(token, h.target, 0);

    uint256 balAfter = SafeTransferLib.balanceOf(token, address(this));
    if (balAfter < balBefore) {
      // Invested capital needs a recall path: refuse deploy without PRE_OUTFLOW.
      if ((h.flags & C.HOOK_PRE_OUTFLOW) == 0) revert Err.InvalidState();
      uint256 deployed = balBefore - balAfter;
      uint256 inv = $.invested[token];
      uint256 cap = $.assets[token].reserves;
      if (inv + deployed > cap) revert Err.ExcessiveAmount(inv + deployed, cap);
      $.invested[token] = uint128(inv + deployed);
    }
    // Post-callback floor: invested increase cannot leave R_liq below minLiquidity.
    liq = liquidReserves($, token);
    if (liq < minLiq) revert Err.InsufficientAmount(liq, minLiq);
  }

  /// @dev Unified pre-outflow recall (swap-out / withdraw / flash). Never deploys.
  function preOutflow(
    IPool.PoolStorage storage $,
    address token,
    address sender,
    uint256 amountNeeded
  ) internal {
    // Gas: liquid check before HookSlot SLOAD (typical path: buffer OK → 0 CALL).
    uint256 liq = liquidReserves($, token);
    if (liq >= amountNeeded) return;

    IPool.HookSlot memory h = $.assetHooks[token];
    if (h.target == address(0) || (h.flags & C.HOOK_PRE_OUTFLOW) == 0) {
      revert Err.InsufficientAmount(liq, amountNeeded);
    }

    uint256 balBefore = SafeTransferLib.balanceOf(token, address(this));
    IPoolHooks(h.target).preOutflow(address(this), sender, token, amountNeeded);
    uint256 balAfter = SafeTransferLib.balanceOf(token, address(this));
    if (balAfter > balBefore) {
      uint256 recalled = balAfter - balBefore;
      uint256 inv = $.invested[token];
      if (recalled > inv) recalled = inv;
      unchecked {
        $.invested[token] = uint128(inv - recalled);
      }
    }

    liq = liquidReserves($, token);
    if (liq < amountNeeded) revert Err.InsufficientAmount(liq, amountNeeded);
  }
}
