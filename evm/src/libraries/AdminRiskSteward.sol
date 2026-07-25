// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAdmin} from "../interfaces/IAdmin.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Err} from "@btr-shared/Errors.sol";
import {AdminTimelock as ATL} from "./AdminTimelock.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";

/// @title AdminRiskSteward - Steward-lite fences for setAssetParamsBounded (EIP-170 relief).
/// @notice Hard min/max + single relative `maxDeltaBps` on risk-increasing changes.
///         Tighten (more defensive) is exempt from the relative clamp. No per-param matrix,
///         no EIP-712 injector, no param-write circuit breaker.
library AdminRiskSteward {
  function setFences(
    mapping(address => mapping(address => IAdmin.RiskFences)) storage fences,
    address pool,
    address token,
    IAdmin.RiskFences calldata f
  ) external {
    if (pool == address(0) || token == address(0)) revert Err.ZeroAddr();
    if (f.maxDeltaBps == 0 || f.maxDeltaBps > SC.BPS) revert Err.BadConfig();
    if (f.minFeeHardMin == 0 || f.minFeeHardMin > f.minFeeHardMax) revert Err.BadConfig();
    if (f.maxFeeHardMax < f.minFeeHardMin) revert Err.BadConfig();
    if (f.gammaHardMin > f.gammaHardMax) revert Err.BadConfig();
    if (f.vegaHardMin > f.vegaHardMax) revert Err.BadConfig();
    // R-1: decoded compare — raw packed B64 `>` is non-monotonic across a decade boundary.
    if (M.gt64Wad(f.reservationHardLoMin, f.reservationHardHiMax)) revert Err.BadConfig();
    fences[pool][token] = f;
    emit IAdmin.RiskFencesSet(pool, token, f.maxDeltaBps);
  }

  /// @dev Validate then forward to the same untimelocked Pool write path as owner setAssetParams.
  function setAssetParamsBounded(
    mapping(address => mapping(address => IAdmin.RiskFences)) storage fences,
    address pool,
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
    IAdmin.RiskFences memory f = fences[pool][token];
    if (f.maxDeltaBps == 0) revert Err.NotConfigured(Err.Resource.ASSET, token);

    // dex-core-sec-01 (M-2): a live reservation band on the steward path REQUIRES the matching
    // absolute fence — with the fence off (0), the relative clamp alone lets repeated steward calls
    // ratchet the band arbitrarily far (unbounded walk). Fail closed until the owner sets fences.
    if (
      (reservationPrice != 0 && f.reservationHardLoMin == 0)
        || (reservationPriceMax != 0 && f.reservationHardHiMax == 0)
    ) {
      revert Err.NotConfigured(Err.Resource.ASSET, token);
    }

    IPool.Asset memory cur = IPool(pool).getAsset(token);
    if (minLiquidity != cur.minLiquidity) revert Err.BadConfig();

    _enforceHard(
      f,
      minFeePbps,
      maxFeePbps,
      gamma,
      vega,
      haircutSuppressor,
      reservationPrice,
      reservationPriceMax
    );

    // maxFee ceiling caps stress spread — raising it is defensive; lowering is risk-up.
    bool paramTighten = minFeePbps >= cur.minFeePbps && maxFeePbps >= cur.maxFeePbps
      && gamma >= cur.gamma && vega >= cur.vega && haircutSuppressor <= cur.haircutSuppressor;

    if (!paramTighten) {
      _relOk(cur.minFeePbps, minFeePbps, f.maxDeltaBps);
      _relOk(cur.maxFeePbps, maxFeePbps, f.maxDeltaBps);
      _relOk(cur.gamma, gamma, f.maxDeltaBps);
      _relOk(cur.vega, vega, f.maxDeltaBps);
      _relOk(cur.haircutSuppressor, haircutSuppressor, f.maxDeltaBps);
    }

    // dex-core-sec-01: the reservation (depeg-breaker) band is ALWAYS relatively clamped, even when
    // the param bundle tightens — so a single call can neither disable it, over-widen it, nor narrow
    // it to exclude the live mark (a `PriceOutsideReservation` swap-DoS). The hard fence above bounds it
    // absolutely (mandatory whenever a band is live — see the fail-closed fence check above); this
    // bounds each step.
    bool resTighten = _narrowsReservation(
      cur.reservationPrice, cur.reservationPriceMax, reservationPrice, reservationPriceMax
    );
    _relOkReservation(cur.reservationPrice, reservationPrice, f.maxDeltaBps);
    _relOkReservation(cur.reservationPriceMax, reservationPriceMax, f.maxDeltaBps);

    bool tighten = paramTighten && resTighten;

    ATL.setAssetParams(
      pool,
      token,
      minLiquidity,
      minFeePbps,
      maxFeePbps,
      gamma,
      vega,
      haircutSuppressor,
      reservationPrice,
      reservationPriceMax
    );
    emit IAdmin.AssetParamsBoundedSet(pool, token, minFeePbps, gamma, tighten);
  }

  function _enforceHard(
    IAdmin.RiskFences memory f,
    uint16 minFeePbps,
    uint16 maxFeePbps,
    uint16 gamma,
    uint16 vega,
    uint16 haircutSuppressor,
    uint64 reservationPrice,
    uint64 reservationPriceMax
  ) private pure {
    if (minFeePbps < f.minFeeHardMin || minFeePbps > f.minFeeHardMax) {
      revert Err.ThresholdViolation(minFeePbps, f.minFeeHardMax);
    }
    if (maxFeePbps > f.maxFeeHardMax) revert Err.ThresholdViolation(maxFeePbps, f.maxFeeHardMax);
    if (gamma < f.gammaHardMin || gamma > f.gammaHardMax) {
      revert Err.ThresholdViolation(gamma, f.gammaHardMax);
    }
    if (vega < f.vegaHardMin || vega > f.vegaHardMax) {
      revert Err.ThresholdViolation(vega, f.vegaHardMax);
    }
    if (haircutSuppressor > f.haircutHardMax) {
      revert Err.ThresholdViolation(haircutSuppressor, f.haircutHardMax);
    }
    // Absolute depeg-band fence: floor may not drop below hardLoMin, ceiling may not rise above
    // hardHiMax (0 = fence off). A steward can never over-widen the reservation band past these.
    // R-1: decoded compares — raw packed B64 `<`/`>` is non-monotonic across a decade boundary.
    if (
      f.reservationHardLoMin != 0 && reservationPrice != 0
        && M.gt64Wad(f.reservationHardLoMin, reservationPrice)
    ) {
      revert Err.ThresholdViolation(reservationPrice, f.reservationHardLoMin);
    }
    if (f.reservationHardHiMax != 0 && M.gt64Wad(reservationPriceMax, f.reservationHardHiMax)) {
      revert Err.ThresholdViolation(reservationPriceMax, f.reservationHardHiMax);
    }
  }

  /// @dev Narrower depeg band = defensive. Disabling an active band is risk-up.
  function _narrowsReservation(uint64 oldLo, uint64 oldHi, uint64 newLo, uint64 newHi)
    private
    pure
    returns (bool)
  {
    if (oldLo == 0 && oldHi == 0) return newLo == 0 && newHi == 0;
    if (newLo == 0 && newHi == 0) return false;
    // Zeroing a single live bound disables that side of the breaker = risk-up, not narrowing.
    if (oldLo != 0 && newLo == 0) return false;
    if (oldHi != 0 && newHi == 0) return false;
    if (oldLo != 0 && newLo != 0 && newLo < oldLo) return false;
    if (oldHi != 0 && newHi != 0 && newHi > oldHi) return false;
    return true;
  }

  /// @dev Steward cannot seed reservation from zero (owner sets the initial band) NOR zero a live
  ///      bound: newV==0 disables that side of the depeg breaker regardless of maxDeltaBps (at 100%
  ///      the relative clamp alone lets oldV→0 through), so only the owner's unbounded path may.
  function _relOkReservation(uint256 oldV, uint256 newV, uint16 maxDeltaBps) private pure {
    if (newV == oldV) return;
    if (oldV == 0 || newV == 0) revert Err.BadConfig();
    _relOk(oldV, newV, maxDeltaBps);
  }

  function _relOk(uint256 oldV, uint256 newV, uint16 maxDeltaBps) private pure {
    if (newV == oldV) return;
    // Steward cannot move a param off zero — owner seeds first.
    if (oldV == 0) revert Err.BadConfig();
    uint256 diff = newV > oldV ? newV - oldV : oldV - newV;
    if (diff * SC.BPS > oldV * uint256(maxDeltaBps)) {
      revert Err.ThresholdViolation(diff, (oldV * maxDeltaBps) / SC.BPS);
    }
  }
}
