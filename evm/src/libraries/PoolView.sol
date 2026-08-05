// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {ILPToken} from "../LPToken.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Constants as C} from "./Constants.sol";
import {PoolLiquidity} from "./PoolLiquidity.sol";
import {PoolIO} from "./PoolIO.sol";
import {PoolHooks} from "./PoolHooks.sol";
import {PoolDecay} from "./PoolDecay.sol";
import {Pricing} from "./Pricing.sol";

/// @dev LP receipt lock surface (Solady public mapping getter).
interface ILPTokenLocks {
  function locks(address account) external view returns (uint32 stamp, uint224 frozen);
}

/// @title PoolView - non-trivial read helpers extracted from Pool.sol
library PoolView {
  function previewWithdraw(IPool.PoolStorage storage $, address tk, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut)
  {
    IPool.Asset storage a = $.assets[PoolIO.wrap($, tk)];
    uint256 wv = (lp * uint256(a.liquidityIndex)) / SC.WAD;
    (amountOut, haircut) =
      PoolLiquidity.applyHaircut(wv, a.reserves, a.liabilities, a.haircutSuppressor);
  }

  function getCoverageRatio(IPool.PoolStorage storage $, address tk)
    external
    view
    returns (uint256)
  {
    IPool.Asset storage a = $.assets[PoolIO.wrap($, tk)];
    if (a.decimals == 0) revert Err.NotFound(Err.Resource.ASSET, tk);
    return Pricing.calculateCoverage(a.reserves, a.liabilities);
  }

  /// @notice Max LP shares `owner` can redeem now (capacity, not value).
  /// @dev Folds: HALT, wipe (index 0), anti-JIT frozen shares, R_liq − minLiquidity.
  ///      Uses decay-adjusted index for share↔underlying conversion (same as previewWithdrawFresh).
  ///      Face conversion avail→shares is conservative when coverage haircut > 0 (understates).
  ///      Intentional omissions (not capacity-zeroed here):
  ///        - hook recall: does NOT assume invested can be pulled via preOutflow; only R_liq
  ///        - oracle stale / depeg bands (same-asset withdraw is not band-gated on-chain)
  ///        - requireNoFlash (intra-tx only)
  function maxRedeem(IPool.PoolStorage storage $, address owner, address token)
    external
    view
    returns (uint256)
  {
    address t = PoolIO.wrap($, token);
    if (($.riskConfigs[t].flags & C.HALT_MASK) != 0) return 0;

    (uint256 index,,) = _decayAdjusted($, t);
    if (index == 0) return 0;

    IPool.Asset storage a = $.assets[t];
    if (a.decimals == 0) return 0;

    address lp = $.lpTokens[t];
    if (lp == address(0)) return 0;

    uint256 unlocked = _unlockedShares(lp, owner, $.flowCooldownSeconds);
    if (unlocked == 0) return 0;

    uint256 Rliq = PoolHooks.liquidReserves($, t);
    uint256 minLiq = a.minLiquidity;
    if (Rliq <= minLiq) return 0;
    uint256 avail = Rliq - minLiq;

    uint256 byLiq = (avail * SC.WAD) / index;
    return unlocked < byLiq ? unlocked : byLiq;
  }

  /// @notice Like previewWithdraw but applies pending liability decay virtually (no SSTORE).
  /// @dev CDP / integrators must prefer this over previewWithdraw when decay may be live.
  function previewWithdrawFresh(IPool.PoolStorage storage $, address tk, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut)
  {
    address t = PoolIO.wrap($, tk);
    (uint256 index, uint256 reserves, uint256 liab) = _decayAdjusted($, t);
    if (index == 0 || lp == 0) return (0, 0);
    uint256 wv = (lp * index) / SC.WAD;
    return PoolLiquidity.applyHaircut(
      wv, uint128(reserves), uint128(liab), $.assets[t].haircutSuppressor
    );
  }

  /// @notice Pending decay amount that would apply now (0 if decay off / no dt / above threshold).
  function pendingDecay(IPool.PoolStorage storage $, address tk) external view returns (uint128) {
    address t = PoolIO.wrap($, tk);
    IPool.Asset storage a = $.assets[t];
    IPool.RiskConfig storage rc = $.riskConfigs[t];
    if ((rc.flags & C.DECAY_ENABLED_BIT) == 0 || rc.decaySlope == 0) return 0;
    uint32 dt = uint32(block.timestamp) - a.lastUpdate;
    return PoolDecay.calculateDecay(
      a.liabilities, a.reserves, rc.decayStartRatioBps, rc.decaySlope, dt
    );
  }

  /// @return index reserves liabilities after virtual pending decay
  function _decayAdjusted(IPool.PoolStorage storage $, address t)
    private
    view
    returns (uint256 index, uint256 reserves, uint256 liab)
  {
    IPool.Asset storage a = $.assets[t];
    index = a.liquidityIndex;
    reserves = a.reserves;
    liab = a.liabilities;
    if (index == 0 || liab == 0) return (index, reserves, liab);

    IPool.RiskConfig storage rc = $.riskConfigs[t];
    if ((rc.flags & C.DECAY_ENABLED_BIT) == 0 || rc.decaySlope == 0) return (index, reserves, liab);

    uint32 dt = uint32(block.timestamp) - a.lastUpdate;
    uint128 decayAmt =
      PoolDecay.calculateDecay(uint128(liab), uint128(reserves), rc.decayStartRatioBps, rc.decaySlope, dt);
    if (decayAmt == 0) return (index, reserves, liab);
    if (decayAmt >= liab) return (0, reserves, 0);
    uint256 newLiab = liab - uint256(decayAmt);
    index = (index * newLiab) / liab;
    liab = newLiab;
  }

  /// @notice Unix ts when owner's frozen mint parcel clears; 0 if already clear / no freeze.
  function withdrawUnlockTime(IPool.PoolStorage storage $, address owner, address token)
    external
    view
    returns (uint32)
  {
    address t = PoolIO.wrap($, token);
    address lp = $.lpTokens[t];
    if (lp == address(0)) return 0;
    (uint32 stamp, uint224 frozen) = ILPTokenLocks(lp).locks(owner);
    if (frozen == 0) return 0;
    uint256 unlock = uint256(stamp) + uint256($.flowCooldownSeconds);
    if (block.timestamp >= unlock) return 0;
    return uint32(unlock);
  }

  function _unlockedShares(address lp, address owner, uint256 cooldown)
    private
    view
    returns (uint256)
  {
    uint256 bal = ILPToken(lp).balanceOf(owner);
    if (bal == 0) return 0;
    (uint32 stamp, uint224 frozen) = ILPTokenLocks(lp).locks(owner);
    if (frozen == 0) return bal;
    if (block.timestamp >= uint256(stamp) + cooldown) return bal;
    if (bal <= frozen) return 0;
    return bal - uint256(frozen);
  }
}
