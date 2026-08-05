// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./IPool.sol";

/// @title IAdmin
/// @notice Singleton Admin governance contract -Phase 42H.B.3a.
/// @dev Admin is no longer a Diamond module. It is a standalone contract that holds
///      its own pendingOps state and calls Pool's restricted setters via standard external
///      calls. All public functions take `address pool` as the first arg.
interface IAdmin {
  function AC() external view returns (address);

  // ── one-shot setters (no timelock) ──
  function freezeAsset(address pool, address token) external;
  function unfreezeAsset(address pool, address token) external;
  function addAsset(
    address pool,
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
  ) external;
  function collectProtocolFees(address pool, address token, address recipient) external;
  function setCurve(
    address pool,
    uint16 presetId,
    uint256[] calldata interior,
    int256[] calldata wQ,
    uint16 dispRef,
    uint8 flags
  ) external;
  function sealBootstrap(address pool) external;
  function bootstrapSealed(address pool) external view returns (bool);
  function setFlowCooldown(address pool, uint16 cooldownSeconds) external;
  function setAnchor(address pool, address token, address anchor) external;
  function setAssetParams(
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
  ) external;

  /// @notice Steward-lite fences (owner-set). See AdminRiskSteward.RiskFences.
  struct RiskFences {
    uint16 minFeeHardMin;
    uint16 minFeeHardMax;
    uint16 maxFeeHardMax;
    uint16 gammaHardMin;
    uint16 gammaHardMax;
    uint16 vegaHardMin;
    uint16 vegaHardMax;
    uint16 haircutHardMax;
    uint16 maxDeltaBps;
    // 0 = off, but a fence is MANDATORY whenever the matching band side is live on the steward path
    // (setAssetParamsBounded fails closed) — without it the relative ratchet is unbounded.
    uint64 reservationHardLoMin; // floor a steward may never set the reservation price below.
    uint64 reservationHardHiMax; // ceiling a steward may never set reservationPriceMax above.
  }

  function setRiskFences(address pool, address token, RiskFences calldata f) external;

  function setAssetParamsBounded(
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
  ) external;

  // ── timelocked governance ──
  function requestAddAsset(
    address pool,
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
  ) external;
  function executeAddAsset(address pool, address token) external;

  function requestUpdateRiskConfig(address pool, address token, IPool.RiskConfig calldata cfg)
    external;
  function executeUpdateRiskConfig(address pool, address token) external;
  function requestUpdateProfile(
    address pool,
    address token,
    uint16 presetId,
    uint32 minDispersion,
    uint32 maxDispersion
  ) external;
  function executeUpdateProfile(address pool, address token) external;
  function cancelUpdateProfile(address pool, address token) external;
  function requestSetCurve(
    address pool,
    uint16 presetId,
    uint256[] calldata interior,
    int256[] calldata wQ,
    uint16 dispRef,
    uint8 flags
  ) external;
  function executeSetCurve(address pool, uint16 presetId) external;
  function cancelSetCurve(address pool, uint16 presetId) external;
  function requestUpdateFeeParams(address pool, IPool.FeeParams calldata params) external;
  function executeUpdateFeeParams(address pool) external;

  function requestTreasuryUpdate(address pool, address newTreasury) external;
  function executeTreasuryUpdate(address pool) external;
  function requestBaseMigration(address pool, address newBase) external;
  function executeBaseMigration(address pool, address[] calldata spokes) external;
  function requestOracleUpdate(address pool, address token, IPool.OracleConfig calldata cfg)
    external;
  function executeOracleUpdate(address pool, address token) external;
  function cancelOracleUpdate(address pool, address token) external;
  function cancelAddAsset(address pool, address token) external;
  function cancelUpdateRiskConfig(address pool, address token) external;
  function executeSetAssetParams(address pool, address token) external;
  function cancelSetAssetParams(address pool, address token) external;
  function cancelTimelock(address pool, uint8 opType) external;

  function requestSetAssetHook(address pool, address token, address hook, uint32 flags) external;
  function executeSetAssetHook(address pool, address token) external;
  function cancelSetAssetHook(address pool, address token) external;
  function clearAssetHook(address pool, address token) external;

  // ── events (pool-keyed) ──
  event AssetAdded(
    address indexed pool, address indexed token, uint8 decimals, uint128 minLiquidity
  );
  event AssetParamsUpdated(
    address indexed pool, address indexed token, uint128 minLiquidity, uint64 reservationPrice
  );
  event AnchorUpdated(address indexed pool, address indexed asset, address indexed anchor);
  event ProtocolFeesCollected(
    address indexed pool, address indexed token, address indexed recipient, uint256 amount
  );
  event EmergencyFreeze(address indexed pool, address indexed token);
  event EmergencyUnfreeze(address indexed pool, address indexed token);
  event ProtocolPause(address indexed pool, address indexed token);
  event ProtocolUnpause(address indexed pool, address indexed token);
  /// @dev Batch op applied to one (pool,token) leg; `op` = IAdmin.BatchOp.
  event BatchRiskOp(address indexed pool, address indexed token, uint8 op);
  /// @dev A batch leg that reverted (uninit pool / unlisted asset) and was SKIPPED, not reverted —
  ///      one bad leg must never brick an emergency sweep. Operator reconciles from these.
  event BatchLegSkipped(address indexed pool, address indexed token);

  /// @notice Risk-op selector for `Admin.batchRiskOp`.
  enum BatchOp {
    Freeze,
    Unfreeze,
    Pause,
    Unpause
  }
  event FlowCooldownUpdated(address indexed pool, uint16 newCooldown);

  event TimelockRequested(
    address indexed pool, bytes32 indexed id, uint8 opType, uint48 executableAt
  );
  event TimelockCancelled(address indexed pool, bytes32 indexed id, uint8 opType);
  event RiskConfigUpdated(address indexed pool, address indexed token, uint16 flags);
  /// @dev Emitted on profile recalibration execute — indexer re-reads the new shape from Pool state.
  event ProfileUpdated(address indexed pool, address indexed token);
  /// @dev Emitted on preset-curve install/recalibration execute (shared shape table).
  event CurveUpdated(address indexed pool, uint16 indexed presetId);
  event FeeParamsUpdated(address indexed pool, uint8 protoShare, uint16 flashFeePbps);
  event TreasuryUpdated(
    address indexed pool, address indexed oldTreasury, address indexed newTreasury
  );
  event BaseTokenMigrated(address indexed pool, address indexed oldBase, address indexed newBase);
  event OracleUpdated(address indexed pool, address indexed token);
  /// @dev GOV-03: direct bootstrap listing path permanently sealed for `pool`.
  event BootstrapSealed(address indexed pool);
  /// @dev Per-asset yield hook (re)installed or cleared (`hook == 0`).
  event AssetHookUpdated(address indexed pool, address indexed token, address hook, uint32 flags);
  /// @dev Steward-lite: owner set hard fences + relative maxDelta for bounded param path.
  event RiskFencesSet(address indexed pool, address indexed token, uint16 maxDeltaBps);
  /// @dev Steward-lite: bounded setAssetParams applied (`tighten` = relative clamp skipped).
  event AssetParamsBoundedSet(
    address indexed pool, address indexed token, uint16 minFeePbps, uint16 gamma, bool tighten
  );
}
