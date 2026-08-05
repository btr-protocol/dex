// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {ICdp} from "./interfaces/ICdp.sol";
import {ICdpPoolView} from "./interfaces/ICdpPoolView.sol";
import {IDebtToken} from "./interfaces/IDebtToken.sol";
import {CdpTimelock} from "./libraries/CdpTimelock.sol";
import {CdpValuation} from "./libraries/CdpValuation.sol";

/// @title CollateralRegistry
contract CollateralRegistry {
  address public immutable AC;

  bool public bootstrapSealed;
  mapping(address => ICdp.CollateralConfig) public collaterals;
  address[] public listed;
  mapping(bytes32 => uint96) public pendingOps;
  mapping(bytes32 => bytes) public pendingData;

  constructor(address ac_) {
    if (ac_ == address(0)) revert Err.ZeroAddr();
    AC = ac_;
  }

  modifier onlyOwner() {
    if (msg.sender != AccessControl(AC).owner()) revert Err.NotOwner();
    _;
  }

  function sealBootstrap() external onlyOwner {
    bootstrapSealed = true;
  }

  function listWithParams(
    address lpToken,
    address pool,
    address asset,
    address debtToken,
    ICdp.Denom denom,
    bool hooked,
    uint128 ceiling,
    uint16 ltvBps,
    uint16 ltBps,
    uint16 bonusBps
  ) external onlyOwner {
    if (bootstrapSealed) revert ICdp.BootstrapSealed();
    _list(lpToken, pool, asset, debtToken, denom, hooked, ceiling, ltvBps, ltBps, bonusBps);
  }

  function requestList(
    address lpToken,
    address pool,
    address asset,
    address debtToken,
    ICdp.Denom denom,
    bool hooked,
    uint128 ceiling,
    uint16 ltvBps,
    uint16 ltBps,
    uint16 bonusBps
  ) external onlyOwner {
    if (!bootstrapSealed) revert ICdp.BootstrapOpen();
    _validateList(
      lpToken, pool, asset, debtToken, denom, hooked, ltvBps, ltBps, bonusBps, true
    );

    CdpTimelock.queueOp(
      pendingOps,
      pendingData,
      CdpTimelock.OP_LIST,
      lpToken,
      abi.encode(pool, asset, debtToken, denom, hooked, ceiling, ltvBps, ltBps, bonusBps)
    );
  }

  function executeList(address lpToken) external onlyOwner {
    bytes memory data =
      CdpTimelock.consumeOp(pendingOps, pendingData, CdpTimelock.OP_LIST, lpToken);
    (
      address pool,
      address asset,
      address debtToken,
      ICdp.Denom denom,
      bool hooked,
      uint128 ceiling,
      uint16 ltvBps,
      uint16 ltBps,
      uint16 bonusBps
    ) = abi.decode(data, (address, address, address, ICdp.Denom, bool, uint128, uint16, uint16, uint16));
    _list(lpToken, pool, asset, debtToken, denom, hooked, ceiling, ltvBps, ltBps, bonusBps);
  }

  function disable(address lpToken) external {
    AccessControl ac_ = AccessControl(AC);
    if (!ac_.isGuardianOrAuth(msg.sender, ac_.owner())) revert Err.NotAuth();
    ICdp.CollateralConfig storage c = collaterals[lpToken];
    if (c.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);
    c.enabled = false;
    emit ICdp.CollateralEnabled(lpToken, false);
  }

  function requestEnable(address lpToken) external onlyOwner {
    ICdp.CollateralConfig storage c = collaterals[lpToken];
    if (c.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);
    if (c.enabled) revert ICdp.BadParams();
    CdpTimelock.queueOp(pendingOps, pendingData, CdpTimelock.OP_ENABLE, lpToken, abi.encode(true));
  }

  function executeEnable(address lpToken) external onlyOwner {
    bytes memory data =
      CdpTimelock.consumeOp(pendingOps, pendingData, CdpTimelock.OP_ENABLE, lpToken);
    (bool en) = abi.decode(data, (bool));
    collaterals[lpToken].enabled = en;
    emit ICdp.CollateralEnabled(lpToken, en);
  }

  function setTier(address lpToken, uint16 ltvBps, uint16 ltBps, uint16 bonusBps)
    external
    onlyOwner
  {
    ICdp.CollateralConfig storage c = collaterals[lpToken];
    if (c.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);
    _validateTier(ltvBps, ltBps, bonusBps);
    if (!CdpTimelock.isTierTighten(c.ltvBps, c.ltBps, c.bonusBps, ltvBps, ltBps, bonusBps)) {
      revert ICdp.MustQueue();
    }
    c.ltvBps = ltvBps;
    c.ltBps = ltBps;
    c.bonusBps = bonusBps;
    emit ICdp.CollateralUpdated(lpToken, ltvBps, ltBps, bonusBps);
  }

  function requestSetTier(address lpToken, uint16 ltvBps, uint16 ltBps, uint16 bonusBps)
    external
    onlyOwner
  {
    ICdp.CollateralConfig storage c = collaterals[lpToken];
    if (c.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);
    _validateTier(ltvBps, ltBps, bonusBps);
    if (CdpTimelock.isTierTighten(c.ltvBps, c.ltBps, c.bonusBps, ltvBps, ltBps, bonusBps)) {
      revert ICdp.NotTighten();
    }
    CdpTimelock.queueOp(
      pendingOps, pendingData, CdpTimelock.OP_SET_TIER, lpToken, abi.encode(ltvBps, ltBps, bonusBps)
    );
  }

  function executeSetTier(address lpToken) external onlyOwner {
    bytes memory data =
      CdpTimelock.consumeOp(pendingOps, pendingData, CdpTimelock.OP_SET_TIER, lpToken);
    (uint16 ltvBps, uint16 ltBps, uint16 bonusBps) = abi.decode(data, (uint16, uint16, uint16));
    ICdp.CollateralConfig storage c = collaterals[lpToken];
    c.ltvBps = ltvBps;
    c.ltBps = ltBps;
    c.bonusBps = bonusBps;
    emit ICdp.CollateralUpdated(lpToken, ltvBps, ltBps, bonusBps);
  }

  function setCeiling(address lpToken, uint128 ceiling) external onlyOwner {
    ICdp.CollateralConfig storage c = collaterals[lpToken];
    if (c.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);
    if (!CdpTimelock.isCeilingTighten(c.ceiling, ceiling)) revert ICdp.MustQueue();
    c.ceiling = ceiling;
    emit ICdp.CeilingSet(lpToken, ceiling);
  }

  function requestSetCeiling(address lpToken, uint128 ceiling) external onlyOwner {
    ICdp.CollateralConfig storage c = collaterals[lpToken];
    if (c.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);
    if (CdpTimelock.isCeilingTighten(c.ceiling, ceiling)) revert ICdp.NotTighten();
    CdpTimelock.queueOp(
      pendingOps, pendingData, CdpTimelock.OP_SET_CEILING, lpToken, abi.encode(ceiling)
    );
  }

  function executeSetCeiling(address lpToken) external onlyOwner {
    bytes memory data =
      CdpTimelock.consumeOp(pendingOps, pendingData, CdpTimelock.OP_SET_CEILING, lpToken);
    uint128 ceiling = abi.decode(data, (uint128));
    collaterals[lpToken].ceiling = ceiling;
    emit ICdp.CeilingSet(lpToken, ceiling);
  }

  function cancel(uint8 opType, address target) external {
    AccessControl ac_ = AccessControl(AC);
    if (!ac_.isGuardianOrAuth(msg.sender, ac_.owner())) revert Err.NotAuth();
    CdpTimelock.cancel(pendingOps, pendingData, CdpTimelock.key(opType, target), opType, target);
  }

  function get(address lpToken) external view returns (ICdp.CollateralConfig memory) {
    return collaterals[lpToken];
  }

  function _validateList(
    address lpToken,
    address pool,
    address asset,
    address debtToken,
    ICdp.Denom denom,
    bool hooked,
    uint16 ltvBps,
    uint16 ltBps,
    uint16 bonusBps,
    bool checkNotConfigured
  ) internal view {
    if (lpToken == address(0) || pool == address(0) || asset == address(0) || debtToken == address(0))
    {
      revert Err.ZeroAddr();
    }
    if (checkNotConfigured && collaterals[lpToken].pool != address(0)) {
      revert Err.AlreadyConfigured(Err.Resource.ASSET, lpToken);
    }
    if (hooked) revert ICdp.HookedCollateralForbidden(lpToken);
    (address hookTarget,) = ICdpPoolView(pool).getAssetHook(asset);
    if (hookTarget != address(0)) revert ICdp.HookedCollateralForbidden(lpToken);
    ICdp.Denom debtDenom = IDebtToken(debtToken).denom();
    if (debtDenom != denom) revert ICdp.SameDenomRequired(denom, debtDenom);
    _validateTier(ltvBps, ltBps, bonusBps);
  }

  function _list(
    address lpToken,
    address pool,
    address asset,
    address debtToken,
    ICdp.Denom denom,
    bool hooked,
    uint128 ceiling,
    uint16 ltvBps,
    uint16 ltBps,
    uint16 bonusBps
  ) internal {
    _validateList(
      lpToken, pool, asset, debtToken, denom, hooked, ltvBps, ltBps, bonusBps, true
    );

    ICdp.CollateralConfig storage c = collaterals[lpToken];
    c.pool = pool;
    c.asset = asset;
    c.debtToken = debtToken;
    c.denom = denom;
    c.ltvBps = ltvBps;
    c.ltBps = ltBps;
    c.bonusBps = bonusBps;
    c.ceiling = ceiling;
    c.hooked = false;
    c.enabled = true;

    listed.push(lpToken);
    emit ICdp.CollateralListed(lpToken, pool, debtToken, denom);
  }

  function _validateTier(uint16 ltvBps, uint16 ltBps, uint16 bonusBps) internal pure {
    if (ltvBps == 0 || ltBps == 0) revert ICdp.BadParams();
    if (ltvBps >= ltBps) revert ICdp.BadParams();
    if (ltBps > SC.BPS) revert ICdp.BadParams();
    if (bonusBps > 2000) revert ICdp.BadParams();
    if (ltvBps > CdpValuation.maxLtvForBonus(bonusBps)) revert ICdp.BadParams();
  }
}
