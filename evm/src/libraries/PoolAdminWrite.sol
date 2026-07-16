// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IPoolFactory} from "../interfaces/IPoolFactory.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {AnchorTree} from "./AnchorTree.sol";
import {Oracle} from "./Oracle.sol";
import {PoolAdmin} from "./PoolAdmin.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolAdminWrite -admin-side state setters extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Pure refactor; behavior preserved.
///         All fns are `external` → DELEGATECALL'd from Pool's onlyAdmin
///         trampolines. ~700 gas/call extra but admin paths are cold so
///         the trade-off is favorable for ~250 bytes/fn bytecode savings.
library PoolAdminWrite {
  function _requireAsset(IPool.PoolStorage storage $, address t) private view {
    if ($.assets[t].decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
  }

  function freezeAsset(IPool.PoolStorage storage $, address token) external {
    address t = PoolIO.wrap($, token);
    _requireAsset($, t);
    $.riskConfigs[t].flags |= C.FROZEN_BIT;
  }

  function unfreezeAsset(IPool.PoolStorage storage $, address token) external {
    address t = PoolIO.wrap($, token);
    _requireAsset($, t);
    $.riskConfigs[t].flags &= ~C.FROZEN_BIT;
  }

  function pauseAsset(IPool.PoolStorage storage $, address token) external {
    address t = PoolIO.wrap($, token);
    _requireAsset($, t);
    $.riskConfigs[t].flags |= C.ASSET_PAUSED_BIT;
  }

  function unpauseAsset(IPool.PoolStorage storage $, address token) external {
    address t = PoolIO.wrap($, token);
    _requireAsset($, t);
    $.riskConfigs[t].flags &= ~C.ASSET_PAUSED_BIT; // clears ONLY bit6 — an independent FROZEN survives
  }

  function initAsset(
    IPool.PoolStorage storage $,
    address token,
    IPool.OracleConfig calldata oracleCfg,
    IPool.RiskConfig calldata riskCfg,
    IPool.LiquidityProfile calldata profile,
    uint16 minFeeBps,
    uint8 decimals,
    uint32 minDispersion,
    uint32 maxDispersion,
    uint16 gamma,
    uint16 vega
  ) external {
    address t = PoolIO.wrap($, token);
    if ($.assets[t].decimals != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, t);

    PoolAdmin.validateProfileMemory(profile);
    PoolAdmin.validateProfileDispersion(profile, maxDispersion);
    PoolAdmin.validateOracleConfig(oracleCfg);
    PoolAdmin.validateRiskConfig(riskCfg);
    // Base = the pool numeraire (price ≡ 1, priced via its own depeg breaker). The coverage wall
    // must never apply to it — a walled base breaks the cross-leg round-trip-neutrality argument
    // (AIMM_PROOFS Thm 2) and collides with _readBasePriceOrHalt. Enforce κ_base == 0.
    if (t == $.baseToken && riskCfg.kappaCovBps != 0) revert Err.BadConfig();
    if (minFeeBps < C.MIN_FEE_PBPS) revert Err.InvalidInput();
    PoolAdmin.initAsset($, t, decimals, minFeeBps, minDispersion, maxDispersion, gamma, vega);
    PoolAdmin.setupOracleAndConfig($, t, oracleCfg, riskCfg, profile);
    PoolAdmin.validateInternalMode($, t, oracleCfg); // after asset init: reads reservation band
    // REG-02: mirror the newly-listed asset into the factory discovery index so SafetyOps enumeration
    // (pauseAsset/freezeAll over getPoolsForToken/getPoolTokens) finds assets added AFTER createPool.
    // Runs in the pool's context (delegatecall), so msg.sender to the factory is this pool (isPool).
    address f = $.factory;
    if (f != address(0)) {
      address[] memory one = new address[](1);
      one[0] = t;
      IPoolFactory(f).registerTokens(one);
    }
  }

  function setFlowCooldown(IPool.PoolStorage storage $, uint16 cooldownSeconds) external {
    $.flowCooldownSeconds = cooldownSeconds;
  }

  function setAnchor(IPool.PoolStorage storage $, address token, address anchor) external {
    address t = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[t];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    uint8 depth = AnchorTree.validateAnchor($, t, anchor);
    asset.anchor = anchor;
    asset.anchorDepth = depth;
  }

  function setAssetParams(
    IPool.PoolStorage storage $,
    address token,
    uint128 minLiquidity,
    uint16 minFeeBps,
    uint16 maxFeeBps,
    uint16 gamma,
    uint16 vega,
    uint16 haircutSuppressor,
    uint64 reservationPrice,
    uint64 reservationPriceMax
  ) external {
    address t = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[t];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    if (minFeeBps > maxFeeBps) revert Err.InvalidInput();
    if (minFeeBps < C.MIN_FEE_PBPS) revert Err.InvalidInput();
    // haircutSuppressor ≥ 20000 zeroes the haircut (applyHaircut) → an under-covered leg pays face
    // value → first-mover bank-run drains coverage. Cap below the disabling threshold so the deficit
    // is always at least partially socialized (walled/stable assets should run 0 = full haircut).
    if (haircutSuppressor >= 20000) revert Err.InvalidInput();
    // Coverage-wall invariant (AIMM_PROOFS Lemma B): a walled asset (κ>0) MUST run haircutSuppressor==0,
    // else same-asset withdrawal is a toll-exempt coverage-declining path that bypasses the wall.
    if ($.riskConfigs[t].kappaCovBps > 0 && haircutSuppressor != 0) revert Err.InvalidInput();
    if (reservationPriceMax != 0 && reservationPriceMax < reservationPrice) {
      revert Err.InvalidInput();
    }

    asset.minLiquidity = minLiquidity;
    asset.minFeeBps = minFeeBps;
    asset.maxFeeBps = maxFeeBps;
    asset.gamma = gamma;
    asset.vega = vega;
    asset.haircutSuppressor = haircutSuppressor;
    asset.reservationPrice = reservationPrice;
    asset.reservationPriceMax = reservationPriceMax;
    // ORC-01: setAssetParams can zero the absolute reservation band, which for an INTERNAL-mode asset
    // IS the depeg breaker (it quotes off a frozen peg, gating only on this band / a refBand). Re-assert
    // the INTERNAL eligibility so an operator cannot silently strip the breaker and leave a depegged
    // stable draining at 1:1. No-op for EXTERNAL mode (validateInternalMode returns early).
    PoolAdmin.validateInternalMode($, t, $.oracleConfigs[t]);
  }

  function setRiskConfig(IPool.PoolStorage storage $, address token, IPool.RiskConfig calldata cfg)
    external
  {
    address t = PoolIO.wrap($, token);
    _requireAsset($, t);
    PoolAdmin.validateRiskConfig(cfg); // κ>0 ⇒ depthAmplifier==0
    if (t == $.baseToken && cfg.kappaCovBps != 0) revert Err.BadConfig(); // base numeraire never walled (Thm 2)
    // Coverage-wall invariant (Lemma B): raising the wall on an asset that still socializes deficit
    // via a haircut would leave the toll-exempt withdrawal bypass open — require haircutSuppressor==0.
    if (cfg.kappaCovBps > 0 && $.assets[t].haircutSuppressor != 0) revert Err.BadConfig();
    // Halt bits survive config writes: a freeze/pause raised during the timelock window must not
    // be cleared (nor sneaked in) by executing a queued RiskConfig — only the explicit
    // unfreeze/unpause ops touch HALT_MASK.
    uint16 halt = $.riskConfigs[t].flags & C.HALT_MASK;
    IPool.RiskConfig storage prev = $.riskConfigs[t];
    bool wasDecay = (prev.flags & C.DECAY_ENABLED_BIT) != 0 && prev.decaySlope != 0;
    bool nowDecay = (cfg.flags & C.DECAY_ENABLED_BIT) != 0 && cfg.decaySlope != 0;
    $.riskConfigs[t] = cfg;
    $.riskConfigs[t].flags = (cfg.flags & ~C.HALT_MASK) | halt;
    // A2-1: do not charge dt accrued while decay was off — reset the clock on (re)enable.
    if (nowDecay && !wasDecay) $.assets[t].lastUpdate = uint32(block.timestamp);
  }

  /// @notice Perpetual profile recalibration: rewrite an asset's Hermite liquidity-profile SHAPE
  ///         (weights/knots) + dispersion band after listing. Pricing-shape only — reserves,
  ///         liabilities and coverage are untouched, so live LP positions are not repriced by fiat.
  ///         Gated by the LOW_TIMELOCK request/execute path (see Admin.requestUpdateProfile).
  function setProfile(
    IPool.PoolStorage storage $,
    address token,
    IPool.LiquidityProfile calldata profile,
    uint32 minDispersion,
    uint32 maxDispersion
  ) external {
    address t = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[t];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    PoolAdmin.validateProfileMemory(profile);
    PoolAdmin.validateProfileDispersion(profile, maxDispersion);
    (asset.minDispersion, asset.maxDispersion) =
      PoolAdmin.sanitizeDispersion(minDispersion, maxDispersion);
    $.profiles[t] = profile;
  }

  function setOracleConfig(
    IPool.PoolStorage storage $,
    address token,
    IPool.OracleConfig calldata cfg
  ) external {
    address t = PoolIO.wrap($, token);
    _requireAsset($, t);
    PoolAdmin.validateOracleConfig(cfg);
    PoolAdmin.validateInternalMode($, t, cfg);
    $.oracleConfigs[t] = cfg;
  }

  function setFeeParams(IPool.PoolStorage storage $, IPool.FeeParams calldata params) external {
    if (params.protoShare > 100) revert Err.InvalidInput();
    $.feeParams = params;
  }

  function setBridge(IPool.PoolStorage storage $, address newBridge) external {
    $.bridge = newBridge;
  }

  function setTreasury(IPool.PoolStorage storage $, address newTreasury) external {
    if (newTreasury == address(0)) revert Err.ZeroValue();
    $.treasury = newTreasury;
  }

  function setBaseToken(IPool.PoolStorage storage $, address newBase) external {
    address oldBase = $.baseToken;
    if (newBase == oldBase || newBase == address(0)) revert Err.InvalidInput();
    IPool.Asset storage newA = $.assets[newBase];
    IPool.Asset storage oldA = $.assets[oldBase];
    // The new base must be a LISTED asset — you cannot numeraire (price ≡ 1) an unconfigured token.
    if (newA.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, newBase);
    // Base-numeraire invariant (AIMM_PROOFS P3 / Thm 2): the coverage wall must never apply to the base.
    if ($.riskConfigs[newBase].kappaCovBps != 0) revert Err.BadConfig();
    // PRC-01: setBaseToken re-numeraires the pool — after migration the base is priced ≡ 1
    // unit-of-account. The prior naked pointer swap added ONLY the κ check, leaving the repricing hole
    // wide open: pointing base at an asset that does NOT currently trade at ~1 (e.g. WETH at ~3000)
    // means 1 unit of it instantly quotes as 1 unit-of-account ⇒ its reserve drains. Require the new
    // base to already sit within the base-depeg band of parity (a $1-pegged asset), so the numeraire
    // swap opens no repricing gap. The old base becomes a ~$1 spoke — its LP value (denominated in $1
    // units) is unchanged, and live inventory on both hubs stays consistently priced.
    IPool.OracleConfig storage noc = $.oracleConfigs[newBase];
    uint256 nMark = Oracle.gate(IOracle(noc.primary).getFeed(noc.feedId)); // fresh + certain + nonzero
    uint256 dev = nMark > SC.WAD ? nMark - SC.WAD : SC.WAD - nMark;
    if (dev * SC.BPS > SC.WAD * uint256(C.BASE_DEPEG_HALT_BPS)) revert Err.BadConfig();
    // Reroot the star: promote the new base to root (anchor 0); demote the old base to a direct spoke
    // of it so the anchor graph stays a well-formed depth-1 star for AnchorTree. (Operators re-anchor
    // the remaining spokes to the new base over the CRITICAL_TIMELOCK window.)
    newA.anchor = address(0);
    newA.anchorDepth = 0;
    oldA.anchor = newBase;
    oldA.anchorDepth = 1;
    $.baseToken = newBase;
    // REG-02: keep the factory's cached base in sync (best-effort; skipped for a non-factory clone).
    address f = $.factory;
    if (f != address(0)) IPoolFactory(f).setPoolBaseToken(newBase);
  }

  /// @notice Install/replace per-asset hook. `hook == address(0)` clears (same as clearAssetHook).
  /// @dev Requires invested == 0 when changing target away from the current hook (no stranded R_inv).
  ///      With invested != 0: cannot soft-clear (flags=0) or drop HOOK_PRE_OUTFLOW.
  ///      Unknown flag bits rejected.
  function setAssetHook(IPool.PoolStorage storage $, address token, address hook, uint32 flags)
    external
  {
    address t = PoolIO.wrap($, token);
    _requireAsset($, t);
    if (flags & ~C.HOOK_FLAGS_MASK != 0) revert Err.InvalidInput();
    address prev = $.assetHooks[t].target;
    uint256 inv = $.invested[t];
    if (hook != prev && inv != 0) revert Err.InvalidState();
    if (hook == address(0)) {
      if (inv != 0) revert Err.InvalidState();
      delete $.assetHooks[t];
      return;
    }
    // Invested capital needs a recall path: PRE_OUTFLOW must stay on.
    if (inv != 0 && (flags & C.HOOK_PRE_OUTFLOW) == 0) revert Err.InvalidState();
    $.assetHooks[t] = IPool.HookSlot({target: hook, flags: flags});
  }

  function clearAssetHook(IPool.PoolStorage storage $, address token) external {
    address t = PoolIO.wrap($, token);
    _requireAsset($, t);
    if ($.invested[t] != 0) revert Err.InvalidState();
    delete $.assetHooks[t];
  }
}
