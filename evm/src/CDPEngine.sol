// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {CollateralRegistry} from "./CollateralRegistry.sol";
import {ICdp} from "./interfaces/ICdp.sol";
import {IDebtToken} from "./interfaces/IDebtToken.sol";
import {CdpConstants} from "./libraries/CdpConstants.sol";
import {CdpTimelock} from "./libraries/CdpTimelock.sol";
import {CdpValuation} from "./libraries/CdpValuation.sol";

contract CDPEngine is ReentrancyGuard {
  using SafeTransferLib for address;

  address public immutable AC;
  CollateralRegistry public immutable registry;

  mapping(address => mapping(address => ICdp.Position)) public positions;
  mapping(address => uint256) public totalDebtByCollateral;
  mapping(address => uint256) public totalDebtBySynthetic;
  mapping(address => uint256) public syntheticCeiling;
  mapping(address => uint256) public badDebt;
  mapping(address => bool) public mintFrozen;
  mapping(address => uint256) public basisWad;

  mapping(bytes32 => uint96) public pendingOps;
  mapping(bytes32 => bytes) public pendingData;

  uint16 public hlBps = CdpConstants.DEFAULT_HL_BPS;
  uint16 public hoBps = CdpConstants.DEFAULT_HO_BPS;

  event HaircutsSet(uint16 hlBps, uint16 hoBps);
  event BasisSet(address indexed lpToken, uint256 basisWad);

  constructor(address ac_, address registry_) {
    if (ac_ == address(0) || registry_ == address(0)) revert Err.ZeroAddr();
    AC = ac_;
    registry = CollateralRegistry(registry_);
  }

  modifier onlyOwner() {
    if (msg.sender != AccessControl(AC).owner()) revert Err.NotOwner();
    _;
  }

  function setMintFrozen(address debtToken, bool frozen) external {
    AccessControl ac_ = AccessControl(AC);
    if (frozen) {
      if (!ac_.isGuardianOrAuth(msg.sender, ac_.owner())) revert Err.NotAuth();
    } else if (msg.sender != ac_.owner()) {
      revert Err.NotOwner();
    }
    mintFrozen[debtToken] = frozen;
    emit ICdp.MintFrozen(debtToken, frozen);
  }

  function setHaircuts(uint16 hlBps_, uint16 hoBps_) external onlyOwner {
    if (uint256(hlBps_) + uint256(hoBps_) >= SC.BPS) revert ICdp.IncompleteValuation();
    if (!CdpTimelock.isHaircutTighten(hlBps, hoBps, hlBps_, hoBps_)) revert ICdp.MustQueue();
    hlBps = hlBps_;
    hoBps = hoBps_;
    emit HaircutsSet(hlBps_, hoBps_);
  }

  function requestSetHaircuts(uint16 hlBps_, uint16 hoBps_) external onlyOwner {
    if (uint256(hlBps_) + uint256(hoBps_) >= SC.BPS) revert ICdp.IncompleteValuation();
    if (CdpTimelock.isHaircutTighten(hlBps, hoBps, hlBps_, hoBps_)) revert ICdp.NotTighten();
    CdpTimelock.queue(
      pendingOps,
      pendingData,
      CdpTimelock.keyHaircuts(),
      CdpTimelock.OP_SET_HAIRCUTS,
      address(0),
      abi.encode(hlBps_, hoBps_)
    );
  }

  function executeSetHaircuts() external onlyOwner {
    bytes memory data = CdpTimelock.consume(
      pendingOps,
      pendingData,
      CdpTimelock.keyHaircuts(),
      CdpTimelock.OP_SET_HAIRCUTS,
      address(0)
    );
    (uint16 hl, uint16 ho) = abi.decode(data, (uint16, uint16));
    hlBps = hl;
    hoBps = ho;
    emit HaircutsSet(hl, ho);
  }

  function setBasisWad(address lpToken, uint256 basisWad_) external onlyOwner {
    if (!CdpTimelock.isBasisTighten(basisWad[lpToken], basisWad_)) revert ICdp.MustQueue();
    basisWad[lpToken] = basisWad_;
    emit BasisSet(lpToken, basisWad_);
  }

  function requestSetBasisWad(address lpToken, uint256 basisWad_) external onlyOwner {
    if (CdpTimelock.isBasisTighten(basisWad[lpToken], basisWad_)) revert ICdp.NotTighten();
    CdpTimelock.queueOp(
      pendingOps, pendingData, CdpTimelock.OP_SET_BASIS, lpToken, abi.encode(basisWad_)
    );
  }

  function executeSetBasisWad(address lpToken) external onlyOwner {
    bytes memory data =
      CdpTimelock.consumeOp(pendingOps, pendingData, CdpTimelock.OP_SET_BASIS, lpToken);
    uint256 b = abi.decode(data, (uint256));
    basisWad[lpToken] = b;
    emit BasisSet(lpToken, b);
  }

  function setSyntheticCeiling(address debtToken, uint256 ceiling) external onlyOwner {
    if (debtToken == address(0)) revert Err.ZeroAddr();
    if (!CdpTimelock.isCeilingTighten(syntheticCeiling[debtToken], ceiling)) revert ICdp.MustQueue();
    syntheticCeiling[debtToken] = ceiling;
    emit ICdp.SyntheticCeilingSet(debtToken, ceiling);
  }

  function requestSetSyntheticCeiling(address debtToken, uint256 ceiling) external onlyOwner {
    if (debtToken == address(0)) revert Err.ZeroAddr();
    if (CdpTimelock.isCeilingTighten(syntheticCeiling[debtToken], ceiling)) revert ICdp.NotTighten();
    CdpTimelock.queueOp(
      pendingOps, pendingData, CdpTimelock.OP_SET_SYNTH_CEILING, debtToken, abi.encode(ceiling)
    );
  }

  function executeSetSyntheticCeiling(address debtToken) external onlyOwner {
    bytes memory data =
      CdpTimelock.consumeOp(pendingOps, pendingData, CdpTimelock.OP_SET_SYNTH_CEILING, debtToken);
    uint256 ceiling = abi.decode(data, (uint256));
    syntheticCeiling[debtToken] = ceiling;
    emit ICdp.SyntheticCeilingSet(debtToken, ceiling);
  }

  function cancel(uint8 opType, address target) external {
    AccessControl ac_ = AccessControl(AC);
    if (!ac_.isGuardianOrAuth(msg.sender, ac_.owner())) revert Err.NotAuth();
    bytes32 id =
      opType == CdpTimelock.OP_SET_HAIRCUTS ? CdpTimelock.keyHaircuts() : CdpTimelock.key(opType, target);
    CdpTimelock.cancel(pendingOps, pendingData, id, opType, target);
  }

  function repayBadDebt(address debtToken, uint256 amount) external nonReentrant {
    if (debtToken == address(0) || amount == 0) revert ICdp.BadParams();
    uint256 bd = badDebt[debtToken];
    if (bd == 0) revert ICdp.NoBadDebt();
    if (amount > bd) amount = bd;
    IDebtToken(debtToken).burn(msg.sender, amount);
    badDebt[debtToken] = bd - amount;
    emit ICdp.BadDebtRepaid(debtToken, msg.sender, amount);
  }

  function open(address lpToken, uint256 collAmount, uint256 debtAmount) external nonReentrant {
    if (collAmount == 0 || debtAmount == 0) revert ICdp.BadParams();
    ICdp.CollateralConfig memory cfg = _requireEnabled(lpToken);
    if (mintFrozen[cfg.debtToken]) revert ICdp.MintFrozenErr(cfg.debtToken);
    CdpValuation.requireMintable(
      cfg.pool, cfg.asset, lpToken, cfg.hooked, msg.sender, collAmount
    );

    ICdp.Position storage p = positions[msg.sender][lpToken];
    if (p.collateral != 0 || p.debt != 0) revert Err.InvalidState();

    lpToken.safeTransferFrom(msg.sender, address(this), collAmount);

    _enforceLtv(cfg, lpToken, collAmount, debtAmount, true);
    _bookMint(cfg, lpToken, debtAmount);

    p.collateral = _toU128(collAmount);
    p.debt = _toU128(debtAmount);

    IDebtToken(cfg.debtToken).mint(msg.sender, debtAmount);
    emit ICdp.Opened(msg.sender, lpToken, collAmount, debtAmount);
  }

  function adjust(address lpToken, int256 collDelta, int256 debtDelta) external nonReentrant {
    if (collDelta == 0 && debtDelta == 0) revert ICdp.BadParams();
    ICdp.CollateralConfig memory cfg = _requireEnabled(lpToken);
    ICdp.Position storage p = positions[msg.sender][lpToken];
    if (p.collateral == 0 && p.debt == 0) revert ICdp.ZeroPosition();

    uint256 nextColl = p.collateral;
    uint256 nextDebt = p.debt;
    uint256 prevDebt = nextDebt;

    if (collDelta > 0) {
      uint256 add = uint256(collDelta);
      lpToken.safeTransferFrom(msg.sender, address(this), add);
      nextColl += add;
    } else if (collDelta < 0) {
      uint256 sub = uint256(-collDelta);
      if (sub > nextColl) revert Err.InsufficientAmount(nextColl, sub);
      nextColl -= sub;
      lpToken.safeTransfer(msg.sender, sub);
    }

    if (debtDelta > 0) {
      if (mintFrozen[cfg.debtToken]) revert ICdp.MintFrozenErr(cfg.debtToken);
      CdpValuation.requireMintable(
        cfg.pool, cfg.asset, lpToken, cfg.hooked, address(this), nextColl
      );
      uint256 add = uint256(debtDelta);
      nextDebt += add;
      IDebtToken(cfg.debtToken).mint(msg.sender, add);
    } else if (debtDelta < 0) {
      uint256 sub = uint256(-debtDelta);
      if (sub > nextDebt) revert Err.InsufficientAmount(nextDebt, sub);
      nextDebt -= sub;
      IDebtToken(cfg.debtToken).burn(msg.sender, sub);
    }

    if (nextColl == 0 && nextDebt == 0) {
      _bookBurn(cfg.debtToken, lpToken, prevDebt);
      delete positions[msg.sender][lpToken];
    } else {
      _enforceLtv(cfg, lpToken, nextColl, nextDebt, nextDebt > prevDebt);
      if (nextDebt > prevDebt) {
        _bookMint(cfg, lpToken, nextDebt - prevDebt);
      } else if (nextDebt < prevDebt) {
        _bookBurn(cfg.debtToken, lpToken, prevDebt - nextDebt);
      }
      p.collateral = _toU128(nextColl);
      p.debt = _toU128(nextDebt);
    }

    emit ICdp.Adjusted(msg.sender, lpToken, collDelta, debtDelta);
  }

  function repay(address lpToken, uint256 amount) external nonReentrant {
    if (amount == 0) revert ICdp.BadParams();
    ICdp.CollateralConfig memory cfg = registry.get(lpToken);
    if (cfg.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);

    ICdp.Position storage p = positions[msg.sender][lpToken];
    if (p.debt == 0) revert ICdp.ZeroPosition();
    if (amount > p.debt) amount = p.debt;

    IDebtToken(cfg.debtToken).burn(msg.sender, amount);
    p.debt = uint128(uint256(p.debt) - amount);
    _bookBurn(cfg.debtToken, lpToken, amount);
    emit ICdp.Repaid(msg.sender, lpToken, amount);
  }

  function close(address lpToken) external nonReentrant {
    ICdp.CollateralConfig memory cfg = registry.get(lpToken);
    if (cfg.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);

    ICdp.Position storage p = positions[msg.sender][lpToken];
    if (p.collateral == 0 && p.debt == 0) revert ICdp.ZeroPosition();

    uint256 debt = p.debt;
    uint256 coll = p.collateral;
    if (debt > 0) {
      IDebtToken(cfg.debtToken).burn(msg.sender, debt);
      _bookBurn(cfg.debtToken, lpToken, debt);
    }
    delete positions[msg.sender][lpToken];
    if (coll > 0) lpToken.safeTransfer(msg.sender, coll);
    emit ICdp.Closed(msg.sender, lpToken);
  }

  function liquidate(address owner, address lpToken, uint256 debtToCover) external nonReentrant {
    if (owner == address(0) || debtToCover == 0) revert ICdp.BadParams();
    ICdp.CollateralConfig memory cfg = registry.get(lpToken);
    if (cfg.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);

    address backstop = AccessControl(AC).treasury();
    if (backstop == address(0)) revert ICdp.NoBackstop();

    ICdp.Position storage p = positions[owner][lpToken];
    if (p.debt == 0) revert ICdp.ZeroPosition();

    ICdp.ValueParams memory vp = _valueParams(lpToken, true);
    uint256 coll = p.collateral;
    uint256 debt = p.debt;
    uint256 V = CdpValuation.collateralValue(cfg.pool, cfg.asset, coll, vp);
    uint256 hf = CdpValuation.healthFactorWad(V, debt, cfg.ltBps);
    if (hf >= SC.WAD) revert ICdp.Healthy(hf);

    uint16 cf = CdpValuation.closeFactorBpsWithDust(hf, debt);
    uint256 maxRepay = (debt * uint256(cf)) / SC.BPS;
    if (debtToCover > maxRepay) debtToCover = maxRepay;
    if (debtToCover > debt) debtToCover = debt;

    (uint256 liqValue, uint256 backstopValue) =
      CdpValuation.splitSeizeValue(debtToCover, cfg.bonusBps);

    uint256 toLiq;
    uint256 toBackstop;
    if (V == 0) {
      toLiq = coll;
      toBackstop = 0;
    } else {
      toLiq = CdpValuation.lpForValue(cfg.pool, cfg.asset, liqValue, coll, vp);
      uint256 rem = coll - toLiq;
      if (backstopValue > 0 && rem > 0) {
        toBackstop = CdpValuation.lpForValue(cfg.pool, cfg.asset, backstopValue, rem, vp);
      }
      if (toLiq + toBackstop > coll) toBackstop = coll - toLiq;
    }

    uint256 seized = toLiq + toBackstop;
    uint256 collLeft = coll - seized;
    if (collLeft == 0 && debtToCover < maxRepay) {
      revert ICdp.ExhaustRequiresFullCover(debtToCover, maxRepay);
    }

    IDebtToken(cfg.debtToken).burn(msg.sender, debtToCover);

    uint256 debtLeft = debt - debtToCover;

    uint256 writtenOff;
    if (collLeft == 0 && debtLeft > 0) {
      writtenOff = debtLeft;
      badDebt[cfg.debtToken] += writtenOff;
      debtLeft = 0;
    }

    uint256 debtCleared = debt - debtLeft;
    _bookBurn(cfg.debtToken, lpToken, debtCleared);

    if (collLeft == 0 && debtLeft == 0) {
      delete positions[owner][lpToken];
    } else {
      p.collateral = _toU128(collLeft);
      p.debt = _toU128(debtLeft);
    }

    if (toLiq > 0) lpToken.safeTransfer(msg.sender, toLiq);
    if (toBackstop > 0) lpToken.safeTransfer(backstop, toBackstop);

    emit ICdp.Liquidated(owner, lpToken, msg.sender, debtToCover, toLiq, toBackstop);
    if (writtenOff > 0) emit ICdp.BadDebtRealized(cfg.debtToken, lpToken, owner, writtenOff);
  }

  function healthFactor(address owner, address lpToken) external view returns (uint256) {
    ICdp.CollateralConfig memory cfg = registry.get(lpToken);
    ICdp.Position memory p = positions[owner][lpToken];
    if (p.debt == 0) return type(uint256).max;
    uint256 V = _value(cfg, lpToken, p.collateral);
    return CdpValuation.healthFactorWad(V, p.debt, cfg.ltBps);
  }

  function positionValue(address owner, address lpToken)
    external
    view
    returns (uint256 V, uint256 debt, uint256 maxMintable)
  {
    ICdp.CollateralConfig memory cfg = registry.get(lpToken);
    ICdp.Position memory p = positions[owner][lpToken];
    V = _value(cfg, lpToken, p.collateral);
    debt = p.debt;
    uint16 ltv = CdpValuation.effectiveLtv(
      cfg.pool, cfg.asset, cfg.ltvBps, cfg.hooked, address(this), p.collateral, true
    );
    maxMintable = CdpValuation.maxDebt(V, ltv);
  }

  function valueParams(address lpToken) public view returns (ICdp.ValueParams memory) {
    return _valueParams(lpToken, false);
  }

  function _valueParams(address lpToken, bool liq)
    internal
    view
    returns (ICdp.ValueParams memory p)
  {
    ICdp.CollateralConfig memory cfg = registry.get(lpToken);
    p.hlBps = hlBps;
    p.hoBps = hoBps;
    if (cfg.pool == address(0)) {
      p.basisWad = basisWad[lpToken];
    } else {
      p.basisWad = CdpValuation.resolveBasis(cfg.pool, cfg.asset, basisWad[lpToken], liq);
    }
  }

  function _requireEnabled(address lpToken)
    internal
    view
    returns (ICdp.CollateralConfig memory cfg)
  {
    cfg = registry.get(lpToken);
    if (cfg.pool == address(0)) revert Err.NotConfigured(Err.Resource.ASSET, lpToken);
    if (!cfg.enabled) revert ICdp.CollateralDisabled(lpToken);
    if (cfg.hooked) revert ICdp.HookedCollateralForbidden(lpToken);
  }

  function _value(ICdp.CollateralConfig memory cfg, address lpToken, uint256 coll)
    internal
    view
    returns (uint256)
  {
    return CdpValuation.collateralValue(cfg.pool, cfg.asset, coll, valueParams(lpToken));
  }

  function _enforceLtv(
    ICdp.CollateralConfig memory cfg,
    address lpToken,
    uint256 coll,
    uint256 debt,
    bool includeCapacity
  ) internal view {
    address holder =
      SafeTransferLib.balanceOf(lpToken, address(this)) >= coll ? address(this) : msg.sender;
    uint16 ltv = CdpValuation.effectiveLtv(
      cfg.pool, cfg.asset, cfg.ltvBps, cfg.hooked, holder, coll, includeCapacity
    );
    uint256 V = _value(cfg, lpToken, coll);
    uint256 maxD = CdpValuation.maxDebt(V, ltv);
    if (debt > maxD) revert ICdp.LtvExceeded(debt, maxD);
  }

  function _bookMint(ICdp.CollateralConfig memory cfg, address lpToken, uint256 amount) internal {
    uint256 bd = badDebt[cfg.debtToken];
    uint256 nextColl = totalDebtByCollateral[lpToken] + amount + bd;
    if (cfg.ceiling > 0 && nextColl > cfg.ceiling) {
      revert ICdp.CeilingExceeded(nextColl, cfg.ceiling);
    }
    uint256 nextSynth = totalDebtBySynthetic[cfg.debtToken] + amount + bd;
    uint256 sc = syntheticCeiling[cfg.debtToken];
    if (sc > 0 && nextSynth > sc) revert ICdp.SyntheticCeilingExceeded(nextSynth, sc);
    totalDebtByCollateral[lpToken] = totalDebtByCollateral[lpToken] + amount;
    totalDebtBySynthetic[cfg.debtToken] = totalDebtBySynthetic[cfg.debtToken] + amount;
  }

  function _bookBurn(address debtToken, address lpToken, uint256 amount) internal {
    totalDebtByCollateral[lpToken] -= amount;
    totalDebtBySynthetic[debtToken] -= amount;
  }

  function _toU128(uint256 x) internal pure returns (uint128) {
    if (x > type(uint128).max) revert Err.Overflow();
    return uint128(x);
  }
}
