// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {NUQuartic as NUQ} from "./NUQuartic.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

/// @dev Minimal ERC-20 decimals read for listing bind (A4-01).
interface IERC20Decimals {
  function decimals() external view returns (uint8);
}

/// @title PoolAdmin -admin-side validation + initialization helpers for Pool.
/// @notice Phase 42H.D · Round 2 · G1 LOC reduction -extracts oracle/risk/profile
///         setup and validation from `Pool.sol`. Pure storage transforms; no auth
///         (caller must gate via `onlyAdmin`).
library PoolAdmin {
  /// @dev Dispersion ceiling (pbps) = 90% PBPS. At worst inventory skew (±100) the no-profile / empty-
  ///      curve offset is ±dispersion pbps (skew·disp/100); a dispersion ≥ PBPS drives _offsetToPrice's
  ///      mark multiplier to 0 → a degenerate/zero fallback quote with NO positivity guard (presetId 0
  ///      skips validatePresetAssign). Bounding max dispersion here (shared by init + recalibration)
  ///      makes the fallback midPrice honor the same −90% offset floor the spline path enforces. Wide
  ///      volatile bands (≤ 500000 = 50% PBPS) are unaffected.
  uint32 private constant MAX_DISPERSION_PBPS = 900_000;

  /// @notice Validate a preset assignment: the curve must exist, a wall-gated preset (hyper tiers)
  ///         may only price a coverage-walled asset (κ>0 ⇒ haircutSuppressor==0 held by risk config),
  ///         and the curve's minimum offset — wQ[0], scaled to the max dispersion — must keep a
  ///         strictly positive price multiplier (the Hermite-era knots[0] bound, quartic form).
  ///         presetId 0 = explicit no-shape (fallback quote), always valid.
  function validatePresetAssign(
    IPool.PoolStorage storage $,
    address token,
    uint16 presetId,
    uint32 maxDispersion
  ) internal view {
    if (presetId == 0) return;
    uint256 header = $.curves[presetId].header;
    if (header == 0) revert Err.NotConfigured(Err.Resource.ASSET, token);
    if ((header >> 248) & NUQ.FLAG_REQUIRES_WALL != 0 && $.riskConfigs[token].kappaCovBps == 0) {
      revert Err.BadConfig();
    }
    uint32 mx = maxDispersion == 0 ? 100000 : maxDispersion;
    uint256 dispRef = (header >> 232) & 0xffff;
    // min offset (pbps) at max dispersion: monotone ⇒ min = y(0) = wQ[0].
    int256 minOffset =
      (NUQ.evalQ($.curves[presetId], header, 0) * int256(uint256(mx))) / (int256(dispRef) * NUQ.Q);
    if (int256(SC.PBPS) + minOffset <= 0) revert Err.BadConfig();
  }

  /// @notice Validate risk config: κ>0 (convex coverage wall) forbids depthAmplifier>0. The
  ///         calculateDepth c<1 branch SUBSIDIZES a draining trade (extra virtual depth), which fights
  ///         the wall it is meant to erect — mutually exclusive by construction, enforced here.
  function validateRiskConfig(IPool.RiskConfig memory cfg) internal pure {
    if (cfg.kappaCovBps > 0 && cfg.depthAmplifier > 0) revert Err.BadConfig();
    // PRC-02: the coverage band (0.01% units) MUST straddle parity (1.0 = BPS). coverageMax ≤ BPS
    // makes a HEALTHY leg (c ≥ 1) fall into computeInventorySkew's max-DISCOUNT branch — a skew
    // sign-reversal that quotes a premium-to-the-trader and drains a healthy pool; coverageMin ≥ BPS
    // pins a permanent +100 premium. Enforce coverageMin < parity < coverageMax.
    if (cfg.coverageMin >= SC.BPS || cfg.coverageMax <= SC.BPS) revert Err.BadConfig();
  }

  /// @notice Normalize dispersion bounds: 0 → protocol default (min 1000, max 100000). Enforces the
  ///         R44-7 (Pass-44B) ordering invariant — without min≤max, `_calculateDispersion`'s clamp
  ///         branches collapse to a single bound and produce an undefined dispersion band. Shared by
  ///         asset init and profile recalibration so the bound semantics can never diverge.
  function sanitizeDispersion(uint32 minDispersion, uint32 maxDispersion)
    internal
    pure
    returns (uint32 mn, uint32 mx)
  {
    mn = minDispersion == 0 ? 1000 : minDispersion;
    mx = maxDispersion == 0 ? 100000 : maxDispersion;
    if (mn > mx || mx > MAX_DISPERSION_PBPS) revert Err.BadConfig();
  }

  /// @notice Validate oracle config: primary set + reachable, plus per-mode breaker gating.
  /// @dev INTERNAL (constant-peg) mode requires: pegB64>0; a live gate feed (primary+feedId); a depeg
  ///      breaker (`requireExternalSpokeBound`: ref band OR a TWO-SIDED absolute reservation band);
  ///      and — the on-chain ELIGIBILITY rule — any ref band be TIGHT (≤ MAX_STABLE_DEPEG_BAND_BPS),
  ///      so a loosely/variable-pegged unit (which cannot hold so tight a band) is rejected and must
  ///      use EXTERNAL mode. EXTERNAL non-base spokes carry the same breaker mandate (M-1) via the
  ///      shared predicate. The INTERNAL tightness cap does NOT apply to EXTERNAL ref bands (volatile
  ///      refs need ~300 bps cross-oracle tolerance).
  ///      Base is exempt: it is the numeraire, priced via _readBasePriceOrHalt's own depeg band.
  function validateOracleMode(
    IPool.PoolStorage storage $,
    address token,
    IPool.OracleConfig memory cfg
  ) internal view {
    if (cfg.mode == C.ORACLE_MODE_EXTERNAL) {
      if (token != $.baseToken) {
        requireExternalSpokeBound($, token, cfg);
      } else if (cfg.usdQuoted) {
        // DEN-01: the base IS the USD reference (its mark is <BASE>-USD by construction and is the
        // divisor). Flagging it would ask the pool to divide the base mark by itself ⇒ constant 1
        // and a silently disarmed denomination correction on the one feed that defines it.
        revert Err.BadConfig();
      }
      return;
    }
    if (cfg.mode != C.ORACLE_MODE_INTERNAL) revert Err.BadConfig();
    // DEN-01: INTERNAL quotes off Asset.pegB64, a constant already expressed in BASE units. There is
    // no USD mark to convert, so the flag would be a no-op that lies about the config.
    if (cfg.usdQuoted) revert Err.BadConfig();
    // Base is the numeraire, priced via _readBasePriceOrHalt's EXTERNAL depeg band. An INTERNAL base
    // would make that reader quote the frozen peg (const ~1.0) and no-op the depeg breaker on every
    // base hop. Forbid it: base must be EXTERNAL so its mark is real and its depeg halt bites.
    if (token == $.baseToken) revert Err.BadConfig();
    if ($.assets[token].pegB64 == 0) revert Err.BadConfig();
    if (cfg.primary == address(0) || cfg.feedId == bytes32(0)) {
      revert Err.NotConfigured(Err.Resource.ORACLE, token);
    }
    // ONE bound predicate for both modes (M-1a fork prevention) + the INTERNAL-only tightness cap.
    requireExternalSpokeBound($, token, cfg);
    if (cfg.refFeedId != bytes32(0) && cfg.refBandBps > C.MAX_STABLE_DEPEG_BAND_BPS) {
      revert Err.BadConfig();
    }
  }

  /// @notice Cumulative-bound mandate (M-1): per-push maxDeviation bounds each step only — a walked
  ///         mark needs an independent ref band (refFeedId+refBandBps) or an absolute reservation
  ///         band. M-1a: the abs band must be TWO-SIDED — one side alone leaves the other price
  ///         direction unbounded (a compromised quorum walks the mark the open way, e.g. a stable
  ///         spoke depegged downward draining at a collapsing mark); the ref band is symmetric
  ///         (|p−refP|) by construction. Shared by setOracleConfig/setAssetParams validation and
  ///         base migration (the demoted old base re-enters spoke-hood and must be armed).
  function requireExternalSpokeBound(
    IPool.PoolStorage storage $,
    address token,
    IPool.OracleConfig memory cfg
  ) internal view {
    IPool.Asset storage a = $.assets[token];
    bool bound = (cfg.refFeedId != bytes32(0) && cfg.refBandBps != 0)
      || (a.reservationPrice != 0 && a.reservationPriceMax != 0);
    if (!bound) revert Err.NotConfigured(Err.Resource.ORACLE, token);
  }

  /// @notice Validate oracle config: primary set + reachable; an armed ref band (refBandBps != 0)
  ///         requires refFeedId AND an explicit, reachable refPrimary distinct from primary. A
  ///         same-address reference cannot bound a walked primary mark. Separate signer/admin
  ///         failure domains are additionally required at deployment; address inequality alone
  ///         cannot prove operational independence.
  function validateOracleConfig(IPool.OracleConfig memory cfg) internal view {
    if (cfg.primary == address(0)) revert Err.InvalidInput();
    try IOracle(cfg.primary).getFeed(cfg.feedId) returns (IOracle.FeedData memory) {}
    catch {
      revert Err.InvalidInput();
    }
    if (cfg.refBandBps != 0) {
      if (
        cfg.refFeedId == bytes32(0) || cfg.refPrimary == address(0) || cfg.refPrimary == cfg.primary
      ) revert Err.InvalidInput();
      try IOracle(cfg.refPrimary).getFeed(cfg.refFeedId) returns (IOracle.FeedData memory) {}
      catch {
        revert Err.InvalidInput();
      }
    }
  }

  /// @notice Initialize per-asset slot with defaults + caller-supplied params.
  function initAsset(
    IPool.PoolStorage storage $,
    address t,
    uint8 decimals,
    uint16 minFeePbps,
    uint32 minDispersion,
    uint32 maxDispersion,
    uint16 gamma,
    uint16 vega
  ) internal {
    // CFG-01: decimals==0 collides with the not-configured sentinel (the asset would read as absent
    // everywhere `decimals==0` gates); decimals>18 underflows 10**(18-decimals) in _legExecPriceB64 /
    // _legScaleOut → every quote reverts (asset accepted-but-unquotable). Bound at config time.
    if (decimals == 0 || decimals > 18) revert Err.InvalidDecimals();
    // A4-01 / A6-01: listed decimals MUST equal IERC20Metadata(token).decimals(). A wrong listing
    // silently mis-scales every quote, dead-seed, and B64 path (Arc USDC 6d listed as 18).
    if (decimals != IERC20Decimals(t).decimals()) revert Err.InvalidDecimals();
    IPool.Asset storage asset = $.assets[t];
    asset.decimals = decimals;
    asset.minFeePbps = minFeePbps;
    asset.maxFeePbps = uint16(SC.ONE_PCT_PBPS);
    asset.minLiquidity = 0;
    (asset.minDispersion, asset.maxDispersion) = sanitizeDispersion(minDispersion, maxDispersion);
    asset.gamma = gamma == 0 ? uint16(SC.BPS) : gamma;
    asset.vega = vega == 0 ? uint16(SC.BPS) : vega;
    asset.haircutSuppressor = uint16(SC.BPS);
    asset.pegB64 = M.encodeB64(SC.WAD, 18); // INTERNAL-mode default peg (1.0 base-per-asset)
    asset.liquidityIndex = uint96(C.LIQUIDITY_INDEX_INIT); // explicit: 0 now means "wiped", not "unset"
    asset.lastUpdate = uint32(block.timestamp); // A2-1: seed so first decay enable has no retroactive dt

    asset.anchor = t == $.baseToken ? address(0) : $.baseToken;
  }

  /// @notice Wire oracle/risk/preset slots. The mark now lives in the external oracle (primary);
  ///         no per-asset feed is seeded on-chain (internal-TWAP discovery removed).
  function setupOracleAndConfig(
    IPool.PoolStorage storage $,
    address t,
    IPool.OracleConfig memory oracleCfg,
    IPool.RiskConfig memory riskCfg,
    uint16 presetId
  ) internal {
    $.oracleConfigs[t] = oracleCfg;
    $.riskConfigs[t] = riskCfg;
    $.assets[t].presetId = presetId;
    // Coverage-wall invariant (AIMM_PROOFS Lemma B): initAsset defaults haircutSuppressor to BPS, so a
    // walled asset (κ>0) added here would violate κ>0 ⇒ haircutSuppressor==0 by default — zero it.
    if (riskCfg.kappaCovBps > 0) $.assets[t].haircutSuppressor = 0;
  }
}
