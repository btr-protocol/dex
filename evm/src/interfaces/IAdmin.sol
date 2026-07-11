// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "./IPool.sol";

/// @title IAdmin
/// @notice Singleton Admin governance contract -Phase 42H.B.3a.
/// @dev Admin is no longer a Diamond module. It is a standalone contract that holds
///      its own pendingOps state and calls Pool's restricted setters via standard external
///      calls. All public functions take `address pool` as the first arg.
interface IAdmin {
    // ── one-shot setters (no timelock) ──
    function freezeAsset(address pool, address token) external;
    function unfreezeAsset(address pool, address token) external;
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
    ) external;
    function collectProtocolFees(address pool, address token, address recipient) external;
    function sealBootstrap(address pool) external;
    function bootstrapSealed(address pool) external view returns (bool);
    function setFlowCooldown(address pool, uint16 cooldownSeconds) external;
    function setAnchor(address pool, address token, address anchor) external;
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
    ) external;

    // ── timelocked governance ──
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
    ) external;
    function executeAddAsset(address pool, address token) external;

    function requestUpdateRiskConfig(address pool, address token, IPool.RiskConfig calldata cfg) external;
    function executeUpdateRiskConfig(address pool, address token) external;
    function requestUpdateProfile(
        address pool,
        address token,
        IPool.LiquidityProfile calldata newProfile,
        uint32 minDispersion,
        uint32 maxDispersion
    ) external;
    function executeUpdateProfile(address pool, address token) external;
    function cancelUpdateProfile(address pool, address token) external;
    function requestUpdateFeeParams(address pool, IPool.FeeParams calldata params) external;
    function executeUpdateFeeParams(address pool) external;

    function requestBridgeUpdate(address pool, address newBridge) external;
    function executeBridgeUpdate(address pool) external;
    function requestTreasuryUpdate(address pool, address newTreasury) external;
    function executeTreasuryUpdate(address pool) external;
    function requestBaseMigration(address pool, address newBase) external;
    function executeBaseMigration(address pool) external;
    function requestOracleUpdate(address pool, address token, IPool.OracleConfig calldata cfg) external;
    function executeOracleUpdate(address pool, address token) external;
    function cancelOracleUpdate(address pool, address token) external;
    function cancelAddAsset(address pool, address token) external;
    function cancelUpdateRiskConfig(address pool, address token) external;
    function cancelTimelock(address pool, uint8 opType) external;

    function requestSetAssetHook(address pool, address token, address hook, uint32 flags) external;
    function executeSetAssetHook(address pool, address token) external;
    function cancelSetAssetHook(address pool, address token) external;
    function clearAssetHook(address pool, address token) external;

    // ── events (pool-keyed) ──
    event AssetAdded(address indexed pool, address indexed token, uint8 decimals, uint128 minLiquidity);
    event AssetParamsUpdated(address indexed pool, address indexed token, uint128 minLiquidity, uint64 reservationPrice);
    event AnchorUpdated(address indexed pool, address indexed asset, address indexed anchor, uint8 depth);
    event ProtocolFeesCollected(address indexed pool, address indexed token, address indexed recipient, uint256 amount);
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
    enum BatchOp { Freeze, Unfreeze, Pause, Unpause }
    event FlowCooldownUpdated(address indexed pool, uint16 oldCooldown, uint16 newCooldown);

    event TimelockRequested(address indexed pool, bytes32 indexed id, uint8 opType, uint48 executableAt);
    event TimelockCancelled(address indexed pool, bytes32 indexed id, uint8 opType);
    event RiskConfigUpdated(address indexed pool, address indexed token, uint128 minLiquidity, uint16 flags);
    /// @dev Emitted on profile recalibration execute — indexer re-reads the new shape from Pool state.
    event ProfileUpdated(address indexed pool, address indexed token);
    event FeeParamsUpdated(address indexed pool, uint16 protoShare, uint16 flashFeeBps);
    event BridgeUpdated(address indexed pool, address indexed oldBridge, address indexed newBridge);
    event TreasuryUpdated(address indexed pool, address indexed oldTreasury, address indexed newTreasury);
    event BaseTokenMigrated(address indexed pool, address indexed oldBase, address indexed newBase);
    event OracleUpdated(address indexed pool, address indexed token);
    /// @dev GOV-03: direct bootstrap listing path permanently sealed for `pool`.
    event BootstrapSealed(address indexed pool);
    /// @dev OBS-03: base-token depeg oracle (re-)pinned — untimelocked SAFETY config, now observable.
    event BaseTokenOracleSet(address indexed pool, address indexed oracle, bytes32 feedId);
    event AssetHookUpdated(address indexed pool, address indexed token, address hook, uint32 flags);
}
