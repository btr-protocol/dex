// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {ERC20} from "solady/tokens/ERC20.sol";
import {ICdp} from "../../../src/interfaces/ICdp.sol";
import {ICdpPoolView} from "../../../src/interfaces/ICdpPoolView.sol";
import {CdpValuation} from "../../../src/libraries/CdpValuation.sol";
import {Constants as C} from "../../../src/libraries/Constants.sol";

contract CdpValuationHarness {
  function maxDebt(uint256 V, uint16 ltvBps) external pure returns (uint256) {
    return CdpValuation.maxDebt(V, ltvBps);
  }

  function healthFactorWad(uint256 V, uint256 D, uint16 ltBps) external pure returns (uint256) {
    return CdpValuation.healthFactorWad(V, D, ltBps);
  }

  function closeFactorBps(uint256 hfWad) external pure returns (uint16) {
    return CdpValuation.closeFactorBps(hfWad);
  }

  function splitSeizeValue(uint256 debtRepaid, uint16 bonusBps)
    external
    pure
    returns (uint256 liquidatorValue, uint256 backstopValue)
  {
    return CdpValuation.splitSeizeValue(debtRepaid, bonusBps);
  }

  function closeFactorBpsWithDust(uint256 hfWad, uint256 debt) external pure returns (uint16) {
    return CdpValuation.closeFactorBpsWithDust(hfWad, debt);
  }

  function lpForValue(
    address pool,
    address asset,
    uint256 targetValue,
    uint256 maxLp,
    ICdp.ValueParams memory p
  ) external view returns (uint256) {
    return CdpValuation.lpForValue(pool, asset, targetValue, maxLp, p);
  }

  function clampBasis(uint256 basisWad) external pure returns (uint256) {
    return CdpValuation.clampBasis(basisWad);
  }

  function applyFactors(uint256 R, ICdp.ValueParams memory p) external pure returns (uint256) {
    return CdpValuation.applyFactors(R, p);
  }

  function toDebtDecimals(uint256 amount, uint8 assetDec) external pure returns (uint256) {
    return CdpValuation.toDebtDecimals(amount, assetDec);
  }

  function collateralValue(
    address pool,
    address asset,
    uint256 lpShares,
    ICdp.ValueParams memory p
  ) external view returns (uint256) {
    return CdpValuation.collateralValue(pool, asset, lpShares, p);
  }

  function isHalted(address pool, address asset) external view returns (bool) {
    return CdpValuation.isHalted(pool, asset);
  }

  function isWiped(address pool, address asset) external view returns (bool) {
    return CdpValuation.isWiped(pool, asset);
  }

  function effectiveLtv(
    address pool,
    address asset,
    uint16 ltvBps,
    bool hooked,
    address holder,
    uint256 lpShares
  ) external view returns (uint16) {
    return CdpValuation.effectiveLtv(pool, asset, ltvBps, hooked, holder, lpShares, true);
  }

  function effectiveLtvNoCapacity(
    address pool,
    address asset,
    uint16 ltvBps,
    bool hooked,
    address holder,
    uint256 lpShares
  ) external view returns (uint16) {
    return CdpValuation.effectiveLtv(pool, asset, ltvBps, hooked, holder, lpShares, false);
  }
}

contract MockLpToken is ERC20 {
  function name() public pure override returns (string memory) {
    return "Mock LP";
  }

  function symbol() public pure override returns (string memory) {
    return "mLP";
  }

  function decimals() public pure override returns (uint8) {
    return 18;
  }

  function mint(address to, uint256 amount) external {
    _mint(to, amount);
  }
}

contract MockCdpPool is ICdpPoolView {
  address public hookTarget;
  uint32 public hookFlags;
  uint16 public riskFlags;
  uint256 public index = 1e18;
  uint256 public rateWad = 1e18;
  uint256 public freshRateWad;
  uint256 public maxRedeemShares = type(uint256).max;
  address public oraclePrimary;
  bytes32 public oracleFeedId;
  uint8 public oracleMode = C.ORACLE_MODE_INTERNAL;
  uint8 public decimals_ = 18;

  function setHook(address target, uint32 flags) external {
    hookTarget = target;
    hookFlags = flags;
  }

  function setRateWad(uint256 r) external {
    rateWad = r;
  }

  function setFreshRateWad(uint256 r) external {
    freshRateWad = r;
  }

  function setRiskFlags(uint16 f) external {
    riskFlags = f;
  }

  function setLiquidityIndex(uint256 i) external {
    index = i;
  }

  function setMaxRedeem(uint256 shares) external {
    maxRedeemShares = shares;
  }

  function setOracleConfig(address primary, bytes32 feedId, uint8 mode) external {
    oraclePrimary = primary;
    oracleFeedId = feedId;
    oracleMode = mode;
  }

  function setDecimals(uint8 d) external {
    decimals_ = d;
  }

  function previewWithdrawFresh(address, uint256 lp)
    external
    view
    returns (uint256 amountOut, uint256 haircut)
  {
    uint256 r = freshRateWad == 0 ? rateWad : freshRateWad;
    amountOut = (lp * r) / 1e18;
    haircut = 0;
  }

  function getAssetHook(address) external view returns (address target, uint32 flags) {
    return (hookTarget, hookFlags);
  }

  function getRiskFlags(address) external view returns (uint16) {
    return riskFlags;
  }

  function liquidityIndex(address) external view returns (uint256) {
    return index;
  }

  function maxRedeem(address, address) external view returns (uint256) {
    return maxRedeemShares;
  }

  function markFeed(address)
    external
    view
    returns (address primary, bytes32 feedId, uint8 mode)
  {
    return (oraclePrimary, oracleFeedId, oracleMode);
  }

  function assetDecimals(address) external view returns (uint8) {
    return decimals_;
  }
}
