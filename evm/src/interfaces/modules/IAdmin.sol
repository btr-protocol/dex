// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "../IPool.sol";

/// @title IAdmin
/// @notice Unified admin module interface: non-timelocked ops + timelocked governance.
/// @dev Replaces former IAdminConfig + IAdminTimelock split. Sub-interfaces preserved
///      below for selective re-import / event-namespace stability.
interface IAdminConfig {
    function getModule(bytes4 selector) external view returns (address);

    /// @notice Path α: set peripheral AccessControl singleton. ac=0 → legacy per-pool owner.
    function setAc(address ac) external;
    /// @notice Read configured peripheral AccessControl (0 = legacy mode).
    function getAc() external view returns (address);

    function freezeAsset(address token) external;
    function unfreezeAsset(address token) external;

    function addAsset(
        address token,
        IPool.OracleConfig calldata oracleCfg,
        IPool.RiskConfig calldata riskCfg,
        IPool.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega,
        uint16 lambda
    ) external;

    function collectProtocolFees(address token, address recipient) external;

    function setAnchor(address token, address anchor) external;

    /// @param reservationPrice B64 floor vs anchor (0 = disabled)
    function setAssetParams(
        address token,
        uint128 minLiquidity,
        uint16 minFeeBps,
        uint16 maxFeeBps,
        uint16 gamma,
        uint16 vega,
        uint16 lambda,
        uint16 haircutSuppressor,
        uint64 reservationPrice
    ) external;

    /// @notice JIT cooldown (deposit→withdraw, stake→unstake). 0=off, max ~18h.
    function setFlowCooldown(uint16 cooldownSeconds) external;

    event AssetParamsUpdated(address indexed token, uint128 minLiquidity, uint64 reservationPrice);
    event AssetAdded(address indexed token, uint8 decimals, uint128 minLiquidity);
    event AnchorUpdated(address indexed asset, address indexed anchor, uint8 depth);
    event ProtocolFeesCollected(address indexed token, address indexed recipient, uint256 amount);
    event EmergencyFreeze(address indexed token);
    event EmergencyUnfreeze(address indexed token);
    event FlowCooldownUpdated(uint16 oldCooldown, uint16 newCooldown);
    event AcUpdated(address indexed oldAc, address indexed newAc);
}

interface IAdminTimelock {
    /// @dev EIP-2535 DiamondCut. impl=address(0) removes selectors.
    struct Module {
        address implementation;
        bytes4[] selectors;
        bytes initData;
    }

    function requestAddAsset(
        address token,
        IPool.OracleConfig calldata oracleCfg,
        IPool.RiskConfig calldata riskCfg,
        IPool.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA
    ) external;
    function executeAddAsset(address token) external;

    function requestUpdateRiskConfig(address token, IPool.RiskConfig calldata cfg) external;
    function executeUpdateRiskConfig(address token) external;
    function requestUpdateFeeParams(IPool.FeeParams calldata params) external;
    function executeUpdateFeeParams() external;

    function requestOwnershipTransfer(address newOwner) external;
    function executeOwnershipTransfer() external;
    function requestModuleUpdate(address impl, bytes4[] calldata selectors, bytes calldata initData) external;
    function executeModuleUpdate() external;
    function requestBaseMigration(address newBase) external;
    function executeBaseMigration() external;
    function requestOracleUpdate(address token, IPool.OracleConfig calldata cfg) external;
    function executeOracleUpdate(address token) external;
    function cancelOracleUpdate(address token) external;
    function requestBridgeUpdate(address newBridge) external;
    function executeBridgeUpdate() external;
    function requestTreasuryUpdate(address newTreasury) external;
    function executeTreasuryUpdate() external;
    function cancelTimelock(uint8 opType) external;

    event ModulesUpdated(address indexed impl, bytes4[] selectors);
    event TimelockRequested(bytes32 indexed id, uint8 opType, uint48 executableAt);
    event TimelockCancelled(bytes32 indexed id, uint8 opType);
    event BaseTokenMigrated(address indexed oldBase, address indexed newBase);
    event OracleUpdated(address indexed token);
    event RiskConfigUpdated(address indexed token, uint128 minLiquidity, uint16 flags);
    event LiquidityProfileUpdated(address indexed token, uint8 segmentCount);
    event HooksUpdated(address indexed token, address indexed hook);
    event FeeParamsUpdated(uint16 protoShare, uint16 flashFeeBps);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event BridgeUpdated(address indexed oldBridge, address indexed newBridge);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
}

/// @title IAdmin
/// @notice Composite — union of IAdminConfig + IAdminTimelock.
interface IAdmin is IAdminConfig, IAdminTimelock {}
