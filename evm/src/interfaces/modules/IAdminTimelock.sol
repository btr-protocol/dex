// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "../IPool.sol";

/// @title IAdminTimelock
/// @notice Timelocked governance ops: 9 request/execute triplets + module updates.
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
