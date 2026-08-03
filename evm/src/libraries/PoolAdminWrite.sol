// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IPoolFactory} from "../interfaces/IPoolFactory.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {LibClone} from "solady/utils/LibClone.sol";
import {MetadataReaderLib as MRL} from "solady/utils/MetadataReaderLib.sol";
import {AnchorTree} from "./AnchorTree.sol";
import {NUQuartic} from "./NUQuartic.sol";
import {Oracle} from "./Oracle.sol";
import {PoolAdmin} from "./PoolAdmin.sol";
import {PoolIO} from "./PoolIO.sol";

/// @title PoolAdminWrite -admin-side state setters extracted from Pool.sol
/// @notice Wave-2 bytecode reduction. Pure refactor; behavior preserved.
///         All fns are `external` → DELEGATECALL'd from Pool's onlyAdmin
///         trampolines. ~700 gas/call extra but admin paths are cold so
///         the trade-off is favorable for ~250 bytes/fn bytecode savings.
library PoolAdminWrite {
  /// @dev wrap→resolve canonical token, then assert it is a listed asset (decimals!=0). Returns the
  ///      wrapped token so the 8 admin halt/config sites collapse the wrap+require pair to one call.
  function _wrapRequire(IPool.PoolStorage storage $, address token)
    private
    view
    returns (address t)
  {
    t = PoolIO.wrap($, token);
    if ($.assets[t].decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
  }

  function freezeAsset(IPool.PoolStorage storage $, address token) external {
    address t = _wrapRequire($, token);
    $.riskConfigs[t].flags |= C.FROZEN_BIT;
  }

  function unfreezeAsset(IPool.PoolStorage storage $, address token) external {
    address t = _wrapRequire($, token);
    $.riskConfigs[t].flags &= ~C.FROZEN_BIT;
  }

  function pauseAsset(IPool.PoolStorage storage $, address token) external {
    address t = _wrapRequire($, token);
    $.riskConfigs[t].flags |= C.ASSET_PAUSED_BIT;
  }

  function unpauseAsset(IPool.PoolStorage storage $, address token) external {
    address t = _wrapRequire($, token);
    $.riskConfigs[t].flags &= ~C.ASSET_PAUSED_BIT; // clears ONLY bit6 — an independent FROZEN survives
  }

  /// @dev `symbol`/`name` are derived from the underlying here rather than passed in: the on-chain
  ///      string is a wallet convenience, and the SDK composes the display string from the leg
  ///      symbol plus the pool's own tag (all three pools list USDC, so the on-chain string alone is
  ///      ambiguous by construction). `MetadataReaderLib` returns "" for a token with no readable
  ///      symbol instead of reverting the listing.
  function _deployLpToken(address impl, address pool, address t, uint8 decimals)
    private
    returns (address)
  {
    bytes32 sym = _b32(string.concat("bLP-", MRL.readSymbol(t, 24)));
    bytes32 nm = _b32(string.concat("BTR LP: ", MRL.readSymbol(t, 24)));
    return LibClone.cloneDeterministic(
      impl, abi.encodePacked(pool, t, decimals, sym, nm), keccak256(abi.encode(pool, t))
    );
  }

  function _b32(string memory s) private pure returns (bytes32 r) {
    bytes memory b = bytes(s);
    uint256 n = b.length > 32 ? 32 : b.length;
    for (uint256 i; i < n; ++i) {
      r |= bytes32(b[i]) >> (i * 8);
    }
  }

  function initAsset(
    IPool.PoolStorage storage $,
    address lpTokenImpl,
    address token,
    IPool.OracleConfig calldata oracleCfg,
    IPool.RiskConfig calldata riskCfg,
    uint16 presetId,
    uint16 minFeePbps,
    uint8 decimals,
    uint32 minDispersion,
    uint32 maxDispersion,
    uint16 gamma,
    uint16 vega
  ) external {
    address t = PoolIO.wrap($, token);
    if ($.assets[t].decimals != 0) revert Err.AlreadyConfigured(Err.Resource.ASSET, t);

    PoolAdmin.validateOracleConfig(oracleCfg);
    PoolAdmin.validateRiskConfig(riskCfg);
    // Base = the pool numeraire (price ≡ 1, priced via its own depeg breaker). The coverage wall
    // must never apply to it — a walled base breaks the cross-leg round-trip-neutrality argument
    // (AIMM_PROOFS Thm 2) and collides with _readBasePriceOrHalt. Enforce κ_base == 0.
    if (t == $.baseToken && riskCfg.kappaCovBps != 0) revert Err.BadConfig();
    if (minFeePbps < C.MIN_FEE_PBPS) revert Err.InvalidInput();
    PoolAdmin.initAsset($, t, decimals, minFeePbps, minDispersion, maxDispersion, gamma, vega);
    // After `initAsset`, which is what bounds `decimals` to 1..18: the receipt bakes decimals into
    // its immutable args and cannot be re-issued. One receipt per WRAPPED leg, so the native
    // sentinel and wnative share a single clone; the duplicate listing is refused above.
    $.lpTokens[t] = _deployLpToken(lpTokenImpl, address(this), t, decimals);
    PoolAdmin.setupOracleAndConfig($, t, oracleCfg, riskCfg, presetId);
    // After risk config lands: wall-flag gating + min-offset bound read curve + riskConfigs.
    PoolAdmin.validatePresetAssign($, t, presetId, maxDispersion);
    PoolAdmin.validateOracleMode($, t, oracleCfg); // after asset init: reads reservation band
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

  /// @dev 0 disables the JIT guard. Load-bearing since #71: swap and flash fees now move the index,
  ///      so with no cooldown an LP can deposit, wait for a known-inbound swap, and withdraw the fee.
  ///      Capped because the guard now gates ERC-20 TRANSFERS of a live receipt, not just withdraw:
  ///      an unbounded uint16 let one untimelocked admin key freeze every holder for 18.2 hours.
  function setFlowCooldown(IPool.PoolStorage storage $, uint16 cooldownSeconds) external {
    if (cooldownSeconds > C.MAX_FLOW_COOLDOWN) revert Err.InvalidInput();
    $.flowCooldownSeconds = cooldownSeconds;
  }

  function setAnchor(IPool.PoolStorage storage $, address token, address anchor) external {
    address t = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[t];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    AnchorTree.validateAnchor($, t, anchor);
    asset.anchor = anchor;
  }

  function setAssetParams(
    IPool.PoolStorage storage $,
    address token,
    uint128 minLiquidity,
    uint16 minFeePbps,
    uint16 maxFeePbps,
    uint16 gamma,
    uint16 vega,
    uint16 haircutSuppressor,
    uint64 reservationPrice,
    uint64 reservationPriceMax
  ) external {
    address t = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[t];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    if (minFeePbps > maxFeePbps) revert Err.InvalidInput();
    if (minFeePbps < C.MIN_FEE_PBPS) revert Err.InvalidInput();
    // haircutSuppressor ≥ 20000 zeroes the haircut (applyHaircut) → an under-covered leg pays face
    // value → first-mover bank-run drains coverage. Cap below the disabling threshold so the deficit
    // is always at least partially socialized (walled/stable assets should run 0 = full haircut).
    if (haircutSuppressor >= C.HAIRCUT_SUPPRESSOR_DISABLE) revert Err.InvalidInput();
    // Coverage-wall invariant (AIMM_PROOFS Lemma B): a walled asset (κ>0) MUST run haircutSuppressor==0,
    // else same-asset withdrawal is a toll-exempt coverage-declining path that bypasses the wall.
    if ($.riskConfigs[t].kappaCovBps > 0 && haircutSuppressor != 0) revert Err.InvalidInput();
    // R-1: compare decoded (1e18), never raw packed B64 — raw `<` orders by mantissa first and is
    // non-monotonic across a decade boundary (min 0.9 / max 0.11 raw-passes inverted → every mark
    // outside the band → asset-wide swap DoS in priceBandGuard).
    if (reservationPriceMax != 0 && M.gt64Wad(reservationPrice, reservationPriceMax)) {
      revert Err.InvalidInput();
    }

    // Asset slot 1 packs minLiquidity into 96 bits so liquidityIndex can hold 96; a raw cast would
    // wrap the keeper reserve floor to a near-zero value and silently unblock every outflow gate.
    if (minLiquidity > type(uint96).max) {
      revert Err.ExcessiveAmount(minLiquidity, type(uint96).max);
    }
    asset.minLiquidity = uint96(minLiquidity);
    asset.minFeePbps = minFeePbps;
    asset.maxFeePbps = maxFeePbps;
    asset.gamma = gamma;
    asset.vega = vega;
    asset.haircutSuppressor = haircutSuppressor;
    asset.reservationPrice = reservationPrice;
    asset.reservationPriceMax = reservationPriceMax;
    // ORC-01: setAssetParams can zero (or one-side, M-1a) the absolute reservation band — for an
    // INTERNAL-mode asset that band IS the depeg breaker, and for an EXTERNAL non-base spoke it may
    // be the only cumulative bound (M-1). Re-assert the mode eligibility so an operator cannot
    // silently strip/half-strip the breaker: without a ref band, a partial band write reverts here.
    PoolAdmin.validateOracleMode($, t, $.oracleConfigs[t]);
  }

  function setRiskConfig(IPool.PoolStorage storage $, address token, IPool.RiskConfig calldata cfg)
    external
  {
    address t = _wrapRequire($, token);
    PoolAdmin.validateRiskConfig(cfg); // κ>0 ⇒ depthAmplifier==0
    if (t == $.baseToken && cfg.kappaCovBps != 0) revert Err.BadConfig(); // base numeraire never walled (Thm 2)
    // Coverage-wall invariant (Lemma B): raising the wall on an asset that still socializes deficit
    // via a haircut would leave the toll-exempt withdrawal bypass open — require haircutSuppressor==0.
    if (cfg.kappaCovBps > 0 && $.assets[t].haircutSuppressor != 0) revert Err.BadConfig();
    // FLAG_REQUIRES_WALL is asserted at preset-assign; stripping κ here would strand a wall-gated
    // (hyper) preset on a now-unwalled asset — its ultra-concentrated tip loses its only drain
    // defense. Re-assert the assign invariant so the wall gate is bidirectional, not assign-only.
    if (cfg.kappaCovBps == 0) {
      uint16 pid = $.assets[t].presetId;
      // Read the preset flag and compare to the NEW kappa directly: validatePresetAssign reads
      // riskConfigs[t].kappaCovBps from storage, which still holds the OLD (pre-write) value here.
      if (pid != 0 && ($.curves[pid].header >> 248) & NUQuartic.FLAG_REQUIRES_WALL != 0) {
        revert Err.BadConfig(); // cannot strip κ from an asset pricing on a wall-gated (hyper) preset
      }
    }
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

  /// @notice Perpetual profile recalibration: repoint an asset at a preset curve + dispersion band
  ///         after listing. Pricing-shape only — reserves, liabilities and coverage are untouched,
  ///         so live LP positions are not repriced by fiat. Gated by the LOW_TIMELOCK
  ///         request/execute path (see Admin.requestUpdateProfile).
  function setProfile(
    IPool.PoolStorage storage $,
    address token,
    uint16 presetId,
    uint32 minDispersion,
    uint32 maxDispersion
  ) external {
    address t = PoolIO.wrap($, token);
    IPool.Asset storage asset = $.assets[t];
    if (asset.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, t);
    PoolAdmin.validatePresetAssign($, t, presetId, maxDispersion);
    (asset.minDispersion, asset.maxDispersion) =
      PoolAdmin.sanitizeDispersion(minDispersion, maxDispersion);
    asset.presetId = presetId;
  }

  /// @notice Install/recalibrate a shared preset curve (validated quartic I-spline). Mutating a
  ///         preset live-referenced by assets IS the weekly-refit path — hence the LOW_TIMELOCK
  ///         request/execute gate (Admin.requestSetCurve). Shape-only: no custody state touched.
  function setCurve(
    IPool.PoolStorage storage $,
    uint16 presetId,
    uint256[] calldata interior,
    int256[] calldata wQ,
    uint16 dispRef,
    uint8 flags
  ) external {
    if (presetId == 0 || dispRef == 0) revert Err.InvalidInput(); // 0 = the no-shape sentinel
    // A live preset's wall-requirement is immutable across refits: assets were assigned against its
    // current FLAG_REQUIRES_WALL. Flipping it on an in-use preset would strand referencing assets
    // (an unwalled asset left on a now-wall-required needle, or vice versa). Changing the wall
    // requirement needs a fresh presetId; a refit keeps the flag byte.
    uint256 existing = $.curves[presetId].header;
    if (existing != 0 && uint8(existing >> 248) != flags) revert Err.BadConfig();
    NUQuartic.set($.curves[presetId], interior, wQ, dispRef, flags);
  }

  function setOracleConfig(
    IPool.PoolStorage storage $,
    address token,
    IPool.OracleConfig calldata cfg
  ) external {
    address t = _wrapRequire($, token);
    PoolAdmin.validateOracleConfig(cfg);
    PoolAdmin.validateOracleMode($, t, cfg);
    $.oracleConfigs[t] = cfg;
  }

  function setFeeParams(IPool.PoolStorage storage $, IPool.FeeParams calldata params) external {
    if (params.protoShare > 100) revert Err.InvalidInput();
    $.feeParams = params;
  }

  function setTreasury(IPool.PoolStorage storage $, address newTreasury) external {
    if (newTreasury == address(0)) revert Err.ZeroValue();
    $.treasury = newTreasury;
  }

  function setBaseToken(IPool.PoolStorage storage $, address newBase, address[] calldata spokes)
    external
  {
    address oldBase = $.baseToken;
    if (newBase == oldBase || newBase == address(0)) revert Err.InvalidInput();
    IPool.Asset storage newA = $.assets[newBase];
    IPool.Asset storage oldA = $.assets[oldBase];
    // The new base must be a LISTED asset — you cannot numeraire (price ≡ 1) an unconfigured token.
    if (newA.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, newBase);
    // Base-numeraire invariant (AIMM_PROOFS P3 / Thm 2): the coverage wall must never apply to the base.
    if ($.riskConfigs[newBase].kappaCovBps != 0) revert Err.BadConfig();
    // Base must quote off a real EXTERNAL mark so its depeg halt bites; an INTERNAL base reads the
    // frozen peg (const ~1.0) and silently disables the breaker (validateOracleMode blocks the
    // config path, but base MIGRATION would otherwise smuggle an INTERNAL spoke into the numeraire).
    if ($.oracleConfigs[newBase].mode != C.ORACLE_MODE_EXTERNAL) revert Err.BadConfig();
    // DEN-01: the base mark is the USD denominator AND is depeg-tested against 1e18 USD parity, so a
    // promoted base MUST attest <TOKEN>-USD. As a spoke that is exactly `usdQuoted`. Promoting a
    // base-denominated spoke (a real <TOKEN>-<oldBase> cross) would make both the divisor and the
    // parity test read a cross rather than a USD price. Require it, then clear it on the promoted
    // slot (the base divides nothing by itself) and SET it on the demoted old base, whose mark was
    // and remains USD-quoted but which is now a spoke that must be re-denominated.
    if (!$.oracleConfigs[newBase].usdQuoted) revert Err.BadConfig();
    // The demoted old base becomes an EXTERNAL spoke and must satisfy the M-1 cumulative-bound
    // mandate (independent ref band or absolute reservation band). As base it was exempt (numeraire,
    // priced via _readBasePriceOrHalt's own depeg band) — without this check migration would smuggle
    // an unbounded EXTERNAL spoke past validateOracleMode.
    PoolAdmin.requireExternalSpokeBound($, oldBase, $.oracleConfigs[oldBase]);
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
    // of it so the anchor graph stays a well-formed depth-1 star for AnchorTree. Atomicity invariant
    // (M-3): after this call returns, NO asset anchors to oldBase — no stale-anchor window.
    newA.anchor = address(0);
    oldA.anchor = newBase;
    $.oracleConfigs[newBase].usdQuoted = false;
    $.oracleConfigs[oldBase].usdQuoted = true;
    $.baseToken = newBase;
    for (uint256 i = 0; i < spokes.length; i++) {
      // Each spoke must still anchor to oldBase: a duplicate (already re-anchored), unlisted,
      // ==newBase (anchor 0) or ==oldBase (anchor newBase) entry all fail this single check.
      if ($.assets[spokes[i]].anchor != oldBase) revert Err.InvalidAnchor(spokes[i], oldBase);
      $.assets[spokes[i]].anchor = newBase;
    }
    // REG-02: keep the factory's cached base in sync (best-effort; skipped for a non-factory clone).
    address f = $.factory;
    // Completeness (M-3, factory pools): after the re-anchor loop no LISTED asset may still anchor
    // to oldBase — scan the factory roster (append-only, ≤ MAX_POOL_TOKENS=32) for one `spokes`
    // missed. Roster entries never initAsset'd (decimals==0: creation-time orphans, raw NATIVE
    // sentinel aliases) skip naturally — the old `spokes.length+2 == roster.length` proxy wedged
    // permanently on them (no per-token roster removal ⇒ setBaseToken bricked for the pool).
    // Factory-less clones: the Safe-batch builder owns completeness.
    if (f != address(0)) {
      address[] memory roster = IPoolFactory(f).getPoolTokens(address(this));
      for (uint256 i = 0; i < roster.length; i++) {
        IPool.Asset storage rA = $.assets[roster[i]];
        if (rA.decimals != 0 && rA.anchor == oldBase) revert Err.InvalidAnchor(roster[i], oldBase);
      }
      IPoolFactory(f).setPoolBaseToken(newBase);
    }
  }

  /// @notice Install/replace per-asset hook. `hook == address(0)` clears (same as clearAssetHook).
  /// @dev Requires invested == 0 when changing target away from the current hook (no stranded R_inv).
  ///      With invested != 0: cannot soft-clear (flags=0) or drop HOOK_PRE_OUTFLOW.
  ///      Unknown flag bits rejected.
  function setAssetHook(IPool.PoolStorage storage $, address token, address hook, uint32 flags)
    external
  {
    address t = _wrapRequire($, token);
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
    address t = _wrapRequire($, token);
    if ($.invested[t] != 0) revert Err.InvalidState();
    delete $.assetHooks[t];
  }
}
