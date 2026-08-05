// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "./Constants.sol";
import {Oracle} from "./Oracle.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {CdpConstants} from "./CdpConstants.sol";
import {ICdp} from "../interfaces/ICdp.sol";
import {ICdpPoolView} from "../interfaces/ICdpPoolView.sol";

library CdpValuation {
  function isHalted(address pool, address asset) internal view returns (bool) {
    return (ICdpPoolView(pool).getRiskFlags(asset) & C.HALT_MASK) != 0;
  }

  function isWiped(address pool, address asset) internal view returns (bool) {
    if (ICdpPoolView(pool).liquidityIndex(asset) == 0) return true;
    (uint256 R,) = ICdpPoolView(pool).previewWithdrawFresh(asset, SC.WAD);
    return R == 0;
  }

  function isLiveHooked(address pool, address asset) internal view returns (bool) {
    (address target,) = ICdpPoolView(pool).getAssetHook(asset);
    return target != address(0);
  }

  function isCapacityShort(address pool, address asset, address holder, uint256 lpShares)
    internal
    view
    returns (bool)
  {
    if (lpShares == 0) return false;
    return ICdpPoolView(pool).maxRedeem(holder, asset) < lpShares;
  }

  function toDebtDecimals(uint256 amount, uint8 assetDec) internal pure returns (uint256) {
    uint8 d = CdpConstants.DEBT_DECIMALS;
    if (assetDec == d) return amount;
    if (assetDec < d) return amount * (10 ** uint256(d - assetDec));
    return amount / (10 ** uint256(assetDec - d));
  }

  function clampBasis(uint256 basisWad) internal pure returns (uint256) {
    if (basisWad == 0) return SC.WAD;
    return basisWad > SC.WAD ? SC.WAD : basisWad;
  }

  function resolveBasis(address pool, address asset, uint256 overrideWad, bool liq)
    internal
    view
    returns (uint256)
  {
    if (overrideWad != 0) return clampBasis(overrideWad);

    (address primary, bytes32 feedId, uint8 mode) = ICdpPoolView(pool).markFeed(asset);
    if (mode == C.ORACLE_MODE_INTERNAL) return SC.WAD;
    if (primary == address(0) || feedId == bytes32(0)) revert ICdp.MarkUnavailable(asset);

    IOracle.FeedData memory feed = IOracle(primary).getFeed(feedId);
    if (!liq) return Oracle.gate(feed);

    if ((feed.flags & C.FEED_PAUSED_BIT) != 0) revert Err.FeedPaused();
    uint256 m = Oracle.mark(feed);
    if (m == 0) revert Err.ZeroValue();
    return m > SC.WAD ? SC.WAD : m;
  }

  function applyFactors(uint256 R, ICdp.ValueParams memory p) internal pure returns (uint256 V) {
    uint256 haircutSum = uint256(p.hlBps) + uint256(p.hoBps);
    if (haircutSum >= SC.BPS) revert ICdp.IncompleteValuation();
    uint256 pb = clampBasis(p.basisWad);
    V = (R * pb) / SC.WAD;
    V = (V * (SC.BPS - haircutSum)) / SC.BPS;
  }

  function collateralValue(
    address pool,
    address asset,
    uint256 lpShares,
    ICdp.ValueParams memory p
  ) internal view returns (uint256 V) {
    if (lpShares == 0) return 0;
    if (isWiped(pool, asset)) return 0;
    (uint256 R,) = ICdpPoolView(pool).previewWithdrawFresh(asset, lpShares);
    uint8 dec = ICdpPoolView(pool).assetDecimals(asset);
    if (dec == 0) revert ICdp.IncompleteValuation();
    return applyFactors(toDebtDecimals(R, dec), p);
  }

  function effectiveLtv(
    address pool,
    address asset,
    uint16 ltvBps,
    bool hooked,
    address holder,
    uint256 lpShares,
    bool includeCapacity
  ) internal view returns (uint16) {
    if (hooked || isLiveHooked(pool, asset)) return 0;
    if (isHalted(pool, asset) || isWiped(pool, asset)) return 0;
    if (includeCapacity && isCapacityShort(pool, asset, holder, lpShares)) return 0;
    return ltvBps;
  }

  function requireMintable(
    address pool,
    address asset,
    address lpToken,
    bool hooked,
    address holder,
    uint256 lpShares
  ) internal view {
    if (hooked || isLiveHooked(pool, asset)) revert ICdp.HookedCollateralForbidden(lpToken);
    if (isHalted(pool, asset)) revert ICdp.CollateralHalted(lpToken);
    if (isWiped(pool, asset)) revert ICdp.CollateralWiped(lpToken);
    if (isCapacityShort(pool, asset, holder, lpShares)) {
      revert ICdp.CapacityShortfall(lpToken);
    }
  }

  function maxLtvForBonus(uint16 bonusBps) internal pure returns (uint16) {
    uint256 num = uint256(SC.BPS) - CdpConstants.TIER_S_BPS - CdpConstants.TIER_M_BPS;
    uint256 den = uint256(SC.BPS) + uint256(bonusBps);
    return uint16((num * SC.BPS) / den);
  }

  function maxDebt(uint256 V, uint16 ltvBps) internal pure returns (uint256) {
    if (ltvBps == 0) return 0;
    return (V * uint256(ltvBps)) / SC.BPS;
  }

  function healthFactorWad(uint256 V, uint256 D, uint16 ltBps) internal pure returns (uint256) {
    if (D == 0) return type(uint256).max;
    return (V * uint256(ltBps) * SC.WAD) / (D * SC.BPS);
  }

  function closeFactorBps(uint256 hfWad) internal pure returns (uint16) {
    if (hfWad >= SC.WAD) return 0;
    if (hfWad >= CdpConstants.HF_FULL_LIQ_THRESHOLD_WAD) {
      return CdpConstants.CLOSE_FACTOR_PARTIAL_BPS;
    }
    return uint16(SC.BPS);
  }

  function closeFactorBpsWithDust(uint256 hfWad, uint256 debt) internal pure returns (uint16) {
    uint16 cf = closeFactorBps(hfWad);
    if (cf == 0) return 0;
    if (cf == uint16(SC.BPS)) return cf;
    uint256 maxPartial = (debt * uint256(cf)) / SC.BPS;
    if (debt - maxPartial <= CdpConstants.DUST_DEBT) return uint16(SC.BPS);
    if (debt <= CdpConstants.DUST_DEBT) return uint16(SC.BPS);
    return cf;
  }

  function splitSeizeValue(uint256 debtRepaid, uint16 bonusBps)
    internal
    pure
    returns (uint256 liquidatorValue, uint256 backstopValue)
  {
    uint256 total = (debtRepaid * (SC.BPS + uint256(bonusBps)) + SC.BPS - 1) / SC.BPS;
    uint256 bonus = total - debtRepaid;
    backstopValue = (bonus * uint256(CdpConstants.BACKSTOP_BONUS_SHARE_BPS)) / SC.BPS;
    liquidatorValue = total - backstopValue;
  }

  function lpForValue(
    address pool,
    address asset,
    uint256 targetValue,
    uint256 maxLp,
    ICdp.ValueParams memory p
  ) internal view returns (uint256) {
    if (targetValue == 0 || maxLp == 0) return 0;
    uint256 Vmax = collateralValue(pool, asset, maxLp, p);
    if (Vmax == 0 || targetValue >= Vmax) return maxLp;
    uint256 lo = 1;
    uint256 hi = maxLp;
    while (lo < hi) {
      uint256 mid = (lo + hi) / 2;
      if (collateralValue(pool, asset, mid, p) >= targetValue) hi = mid;
      else lo = mid + 1;
    }
    return lo;
  }
}
