// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAdmin} from "./interfaces/IAdmin.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IHasTreasury} from "./interfaces/IHasTreasury.sol";
import {AccessControl} from "@btr-shared/access/AccessControl.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {Timelock as TL} from "@btr-shared/Timelock.sol";
import {AdminTimelock as ATL} from "./libraries/AdminTimelock.sol";
import {AdminHooks as AH} from "./libraries/AdminHooks.sol";
import {AdminRisk as AR} from "./libraries/AdminRisk.sol";
import {AdminRiskSteward as ARS} from "./libraries/AdminRiskSteward.sol";

/// @title Admin
/// @notice Standalone singleton governance contract. Replaces the former Admin Diamond module.
/// @dev Phase 42H.B.3a -Admin no longer delegatecalls into Pool. It calls Pool's restricted
///      setters via standard external calls. Each public function takes `address pool` as the
///      first arg. Pending timelock ops are stored locally (per-pool keyed) instead of in
///      PoolStorage. Owner check goes through the shared singleton AccessControl.
contract Admin is IAdmin {
  /// @notice Shared singleton AccessControl -single source of truth for owner.
  address public immutable override AC;

  /// @dev pendingOps[keccak256(pool, opId)] => packed Timelock value.
  ///      Wave-1: demoted public→internal (indexer reads via events; no on-chain consumer).
  mapping(bytes32 => uint96) internal pendingOps;
  /// @dev pendingData[keccak256(pool, opId)] => abi-encoded payload.
  ///      Wave-1: demoted public→internal (consumed only by `_consume`/`_cancel`).
  mapping(bytes32 => bytes) internal pendingData;

  /// @notice GOV-03: per-pool bootstrap seal. The direct (untimelocked) `addAsset` is a listing
  ///         convenience for the pre-liquidity bootstrap window ONLY; once `sealBootstrap` is called it
  ///         is permanently closed and ALL later listings must go through the timelocked
  ///         requestAddAsset/executeAddAsset path (LP exit notice). Sealing is a one-way latch.
  mapping(address pool => bool) public bootstrapSealed;

  /// @notice Steward-lite fences for `setAssetParamsBounded` (owner sets; steward consumes).
  mapping(address pool => mapping(address token => IAdmin.RiskFences)) public riskFences;

  // ── op-id namespaces (per-pool) ──
  bytes32 private constant OP_ADD_ASSET = keccak256("ADD_ASSET");
  bytes32 private constant OP_UPDATE_RISK = keccak256("UPDATE_RISK");
  bytes32 private constant OP_UPDATE_FEES = keccak256("UPDATE_FEES");
  bytes32 private constant OP_UPDATE_BRIDGE = keccak256("UPDATE_BRIDGE");
  bytes32 private constant OP_UPDATE_TREASURY = keccak256("UPDATE_TREASURY");
  bytes32 private constant OP_BASE_MIGRATION = keccak256("BASE_MIGRATION");
  bytes32 private constant OP_UPDATE_ORACLE = keccak256("UPDATE_ORACLE");
  bytes32 private constant OP_UPDATE_PROFILE = keccak256("UPDATE_PROFILE");

  constructor(address ac_) {
    if (ac_ == address(0)) revert Err.ZeroAddr();
    if (ac_.code.length == 0) revert Err.NotCode();
    AC = ac_;
  }

  /// @dev Inlined as internal (not modifiers) — EIP-170: modifiers duplicate jumpdests per use site.
  function _onlyAdmin() internal view {
    if (msg.sender != AccessControl(AC).owner()) revert Ownable.Unauthorized();
  }

  function _onlyGuardianOrAdmin() internal view {
    AccessControl ac_ = AccessControl(AC);
    if (msg.sender != ac_.owner() && !ac_.isGuardian(msg.sender)) revert Ownable.Unauthorized();
  }

  function _onlyRiskStewardOrAdmin() internal view {
    AccessControl ac_ = AccessControl(AC);
    if (msg.sender != ac_.owner() && !ac_.isRiskSteward(msg.sender)) revert Ownable.Unauthorized();
  }

  function _key(address pool, bytes32 opId) internal pure returns (bytes32) {
    return keccak256(abi.encode(pool, opId));
  }

  function _keyToken(address pool, bytes32 opId, address token) internal pure returns (bytes32) {
    return keccak256(abi.encode(pool, opId, token));
  }

  function _emitQueued(bytes32 key, uint48 delay, bytes memory data, address pool, uint8 opType)
    internal
  {
    pendingOps[key] = TL.pack(delay, SC.GRACE_PERIOD);
    pendingData[key] = data;
    uint48 eta;
    unchecked {
      eta = uint48(block.timestamp) + delay;
    }
    emit TimelockRequested(pool, key, opType, eta);
  }

  function _consume(bytes32 key) internal returns (bytes memory data) {
    TL.validate(pendingOps[key]);
    data = pendingData[key];
    delete pendingOps[key];
    delete pendingData[key];
  }

  function _cancel(address pool, bytes32 key, uint8 opType) internal {
    if (pendingOps[key] == 0) revert Err.InvalidState();
    delete pendingOps[key];
    delete pendingData[key];
    emit TimelockCancelled(pool, key, opType);
  }

  // ─── one-shot setters ───

  function freezeAsset(address pool, address token) external {
    _onlyGuardianOrAdmin();
    AR.freeze(pool, token);
  }

  function unfreezeAsset(address pool, address token) external {
    _onlyAdmin();
    AR.unfreeze(pool, token);
  }

  /// @notice Guardian/owner emergency halt (bit6). Separate from FROZEN so unpausing never
  ///         clobbers an independent risk freeze. Unpause remains owner-only (asymmetric).
  function pauseAsset(address pool, address token) external {
    _onlyGuardianOrAdmin();
    AR.pause(pool, token);
  }

  function unpauseAsset(address pool, address token) external {
    _onlyAdmin();
    AR.unpause(pool, token);
  }

  /// @notice Batch freeze/pause (guardian or owner) / unfreeze/unpause (owner only).
  ///         Per-leg try/catch: a bad leg is skipped so one failure never bricks a sweep.
  function batchRiskOp(address[] calldata pools, address[] calldata tokens, BatchOp op) external {
    AccessControl ac_ = AccessControl(AC);
    bool isOwner = msg.sender == ac_.owner();
    if (!isOwner && !ac_.isGuardian(msg.sender)) revert Ownable.Unauthorized();
    if (!isOwner && (op == BatchOp.Unfreeze || op == BatchOp.Unpause)) {
      revert Ownable.Unauthorized();
    }
    AR.batch(pools, tokens, op);
  }

  function addAsset(
    address pool,
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
    _onlyAdmin();
    // GOV-03: after seal, only the timelocked path remains.
    ATL.addAssetBootstrap(
      bootstrapSealed,
      pool,
      token,
      oracleCfg,
      riskCfg,
      profile,
      minFeeBps,
      decimals,
      minDispersion,
      maxDispersion,
      gamma,
      vega
    );
  }

  /// @notice GOV-03: permanently close the direct `addAsset` bootstrap path for a pool. Call once
  ///         BEFORE opening the pool to public liquidity; afterwards every listing is timelocked.
  function sealBootstrap(address pool) external {
    _onlyAdmin();
    bootstrapSealed[pool] = true;
    emit BootstrapSealed(pool);
  }

  function collectProtocolFees(address pool, address token, address recipient) external {
    // Gate: caller must be the pool's treasury (preserves prior semantics from
    // the former Admin module which checked `msg.sender == $.treasury`).
    if (msg.sender != IHasTreasury(pool).treasury()) revert Ownable.Unauthorized();
    uint256 amount = IPool(pool).adminCollectProtocolFees(token, recipient);
    emit ProtocolFeesCollected(pool, token, recipient, amount);
  }

  function setFlowCooldown(address pool, uint16 cooldownSeconds) external {
    _onlyAdmin();
    AR.setFlowCooldown(pool, cooldownSeconds);
  }

  function setAnchor(address pool, address token, address anchor) external {
    _onlyAdmin();
    AR.setAnchor(pool, token, anchor);
  }

  function setAssetParams(
    address pool,
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
    _onlyAdmin();
    ATL.setAssetParams(
      pool,
      token,
      minLiquidity,
      minFeeBps,
      maxFeeBps,
      gamma,
      vega,
      haircutSuppressor,
      reservationPrice,
      reservationPriceMax
    );
  }

  /// @notice Owner sets hard fences + relative maxDelta for the steward-bounded path.
  function setRiskFences(address pool, address token, IAdmin.RiskFences calldata f) external {
    _onlyAdmin();
    ARS.setFences(riskFences, pool, token, f);
  }

  /// @notice Risk steward (or owner): setAssetParams under hard fences + relative risk-up clamp.
  ///         Tighten (more defensive) is exempt from the relative clamp. Owner unbounded path
  ///         remains `setAssetParams`.
  function setAssetParamsBounded(
    address pool,
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
    _onlyRiskStewardOrAdmin();
    ARS.setAssetParamsBounded(
      riskFences,
      pool,
      token,
      minLiquidity,
      minFeeBps,
      maxFeeBps,
      gamma,
      vega,
      haircutSuppressor,
      reservationPrice,
      reservationPriceMax
    );
  }

  // ─── timelocked governance ───

  function requestAddAsset(
    address pool,
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
    _onlyAdmin();
    bytes32 key = _keyToken(pool, OP_ADD_ASSET, token);
    ATL.AddAssetPayload memory p = ATL.AddAssetPayload({
      token: token,
      oracleCfg: oracleCfg,
      riskCfg: riskCfg,
      profile: profile,
      minFeeBps: minFeeBps,
      decimals: decimals,
      minDispersion: minDispersion,
      maxDispersion: maxDispersion,
      gamma: gamma,
      vega: vega
    });
    _emitQueued(
      key, SC.govDelay(SC.LOW_TIMELOCK), ATL.encodeAddAsset(p), pool, uint8(IPool.OpType.ADD_ASSET)
    );
  }

  function executeAddAsset(address pool, address token) external {
    _onlyAdmin();
    bytes32 key = _keyToken(pool, OP_ADD_ASSET, token);
    uint8 decimals = ATL.applyAddAsset(pool, token, _consume(key));
    emit AssetAdded(pool, token, decimals, 0);
  }

  function requestUpdateRiskConfig(address pool, address token, IPool.RiskConfig calldata cfg)
    external
  {
    _onlyAdmin();
    bytes32 key = _keyToken(pool, OP_UPDATE_RISK, token);
    _emitQueued(
      key,
      SC.govDelay(SC.LOW_TIMELOCK),
      abi.encode(token, cfg),
      pool,
      uint8(IPool.OpType.UPDATE_RISK)
    );
  }

  function executeUpdateRiskConfig(address pool, address token) external {
    _onlyAdmin();
    bytes32 key = _keyToken(pool, OP_UPDATE_RISK, token);
    (address storedToken, IPool.RiskConfig memory cfg) =
      abi.decode(_consume(key), (address, IPool.RiskConfig));
    if (storedToken != token) revert Err.InvalidInput();
    IPool(pool).adminSetRiskConfig(token, cfg);
    emit RiskConfigUpdated(pool, token, cfg.flags, 0);
  }

  /// @notice Queue a perpetual profile recalibration: new Hermite shape (weights/knots) + dispersion
  ///         band for an already-listed asset. Same LOW_TIMELOCK tier as risk-config — it retunes the
  ///         depth-concentration curve, not custody. Validation (weights sum / knot span / min≤max)
  ///         runs at execute via `adminSetProfile`, matching the risk/oracle queue idiom.
  function requestUpdateProfile(
    address pool,
    address token,
    IPool.LiquidityProfile calldata newProfile,
    uint32 minDispersion,
    uint32 maxDispersion
  ) external {
    _onlyAdmin();
    bytes32 key = _keyToken(pool, OP_UPDATE_PROFILE, token);
    _emitQueued(
      key,
      SC.govDelay(SC.LOW_TIMELOCK),
      abi.encode(token, newProfile, minDispersion, maxDispersion),
      pool,
      uint8(IPool.OpType.UPDATE_PROFILE)
    );
  }

  function executeUpdateProfile(address pool, address token) external {
    _onlyAdmin();
    bytes32 key = _keyToken(pool, OP_UPDATE_PROFILE, token);
    (address storedToken, IPool.LiquidityProfile memory profile, uint32 minDisp, uint32 maxDisp) =
      abi.decode(_consume(key), (address, IPool.LiquidityProfile, uint32, uint32));
    if (storedToken != token) revert Err.InvalidInput();
    IPool(pool).adminSetProfile(token, profile, minDisp, maxDisp);
    emit ProfileUpdated(pool, token);
  }

  function cancelUpdateProfile(address pool, address token) external {
    _onlyGuardianOrAdmin();
    _cancel(pool, _keyToken(pool, OP_UPDATE_PROFILE, token), uint8(IPool.OpType.UPDATE_PROFILE));
  }

  function requestUpdateFeeParams(address pool, IPool.FeeParams calldata params) external {
    _onlyAdmin();
    bytes32 key = _key(pool, OP_UPDATE_FEES);
    _emitQueued(
      key, SC.govDelay(SC.LOW_TIMELOCK), abi.encode(params), pool, uint8(IPool.OpType.UPDATE_FEES)
    );
  }

  function executeUpdateFeeParams(address pool) external {
    _onlyAdmin();
    bytes32 key = _key(pool, OP_UPDATE_FEES);
    IPool.FeeParams memory params = abi.decode(_consume(key), (IPool.FeeParams));
    if (params.protoShare > 100) revert Err.InvalidInput();
    IPool(pool).adminSetFeeParams(params);
    emit FeeParamsUpdated(pool, params.protoShare, params.flashFeeBps);
  }

  function requestBridgeUpdate(address pool, address newBridge) external {
    _onlyAdmin();
    _emitQueued(
      _key(pool, OP_UPDATE_BRIDGE),
      SC.govDelay(SC.HIGH_TIMELOCK),
      abi.encode(newBridge),
      pool,
      uint8(IPool.OpType.UPDATE_BRIDGE)
    );
  }

  function executeBridgeUpdate(address pool) external {
    _onlyAdmin();
    address newBridge = abi.decode(_consume(_key(pool, OP_UPDATE_BRIDGE)), (address));
    IPool(pool).adminSetBridge(newBridge);
    emit BridgeUpdated(pool, address(0), newBridge);
  }

  function requestTreasuryUpdate(address pool, address newTreasury) external {
    _onlyAdmin();
    if (newTreasury == address(0)) revert Err.ZeroValue();
    _emitQueued(
      _key(pool, OP_UPDATE_TREASURY),
      SC.govDelay(SC.HIGH_TIMELOCK),
      abi.encode(newTreasury),
      pool,
      uint8(IPool.OpType.UPDATE_TREASURY)
    );
  }

  function executeTreasuryUpdate(address pool) external {
    _onlyAdmin();
    address newTreasury = abi.decode(_consume(_key(pool, OP_UPDATE_TREASURY)), (address));
    IPool(pool).adminSetTreasury(newTreasury);
    emit TreasuryUpdated(pool, address(0), newTreasury);
  }

  function requestBaseMigration(address pool, address newBase) external {
    _onlyAdmin();
    _emitQueued(
      _key(pool, OP_BASE_MIGRATION),
      SC.govDelay(SC.CRITICAL_TIMELOCK),
      abi.encode(newBase),
      pool,
      uint8(IPool.OpType.MIGRATE_BASE_TOKEN)
    );
  }

  function executeBaseMigration(address pool) external {
    _onlyAdmin();
    address newBase = abi.decode(_consume(_key(pool, OP_BASE_MIGRATION)), (address));
    IPool(pool).adminSetBaseToken(newBase);
    emit BaseTokenMigrated(pool, address(0), newBase);
  }

  function requestOracleUpdate(address pool, address token, IPool.OracleConfig calldata cfg)
    external
  {
    _onlyAdmin();
    bytes32 key = _keyToken(pool, OP_UPDATE_ORACLE, token);
    _emitQueued(
      key,
      SC.govDelay(SC.BASE_TIMELOCK),
      abi.encode(token, cfg),
      pool,
      uint8(IPool.OpType.UPDATE_ORACLE)
    );
  }

  function executeOracleUpdate(address pool, address token) external {
    _onlyAdmin();
    bytes32 key = _keyToken(pool, OP_UPDATE_ORACLE, token);
    (address storedToken, IPool.OracleConfig memory cfg) =
      abi.decode(_consume(key), (address, IPool.OracleConfig));
    if (storedToken != token) revert Err.InvalidInput();
    IPool(pool).adminSetOracleConfig(token, cfg);
    emit OracleUpdated(pool, token);
  }

  function cancelOracleUpdate(address pool, address token) external {
    _onlyGuardianOrAdmin();
    _cancel(pool, _keyToken(pool, OP_UPDATE_ORACLE, token), uint8(IPool.OpType.UPDATE_ORACLE));
  }

  function cancelAddAsset(address pool, address token) external {
    _onlyGuardianOrAdmin();
    _cancel(pool, _keyToken(pool, OP_ADD_ASSET, token), uint8(IPool.OpType.ADD_ASSET));
  }

  function cancelUpdateRiskConfig(address pool, address token) external {
    _onlyGuardianOrAdmin();
    _cancel(pool, _keyToken(pool, OP_UPDATE_RISK, token), uint8(IPool.OpType.UPDATE_RISK));
  }

  function requestSetAssetHook(address pool, address token, address hook, uint32 flags) external {
    _onlyAdmin();
    AH.request(pendingOps, pendingData, pool, token, hook, flags);
  }

  function executeSetAssetHook(address pool, address token) external {
    _onlyAdmin();
    AH.execute(pendingOps, pendingData, pool, token);
  }

  function cancelSetAssetHook(address pool, address token) external {
    _onlyGuardianOrAdmin();
    AH.cancel(pendingOps, pendingData, pool, token);
  }

  /// @notice Immediate clear: fail-closed if invested > 0 (recall first).
  function clearAssetHook(address pool, address token) external {
    _onlyAdmin();
    AH.clear(pool, token);
  }

  function cancelTimelock(address pool, uint8 opType) external {
    _onlyGuardianOrAdmin();
    bytes32 key;
    if (opType == uint8(IPool.OpType.MIGRATE_BASE_TOKEN)) key = _key(pool, OP_BASE_MIGRATION);
    else if (opType == uint8(IPool.OpType.UPDATE_BRIDGE)) key = _key(pool, OP_UPDATE_BRIDGE);
    else if (opType == uint8(IPool.OpType.UPDATE_TREASURY)) key = _key(pool, OP_UPDATE_TREASURY);
    else if (opType == uint8(IPool.OpType.UPDATE_FEES)) key = _key(pool, OP_UPDATE_FEES);
    else revert Err.InvalidInput();
    _cancel(pool, key, opType);
  }
}
