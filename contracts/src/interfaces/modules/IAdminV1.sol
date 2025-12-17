// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPoolV1} from "../IPoolV1.sol";

interface IAdminV1 {
    // ========== TYPES ==========

    /// @notice Module update operation (EIP-2535 DiamondCut inspired)
    struct Module {
        address implementation;  // Set to address(0) to remove selectors
        bytes4[] selectors;
        bytes initData;          // Delegatecall to implementation with this data after registration
    }

    // ========== MODULE MANAGEMENT ==========

    // C-02 FIX: These functions removed - use timelock instead
    // function updateModule(address impl, bytes4[] calldata selectors, bytes calldata initData) external;
    // function updateModules(Module[] calldata mods) external;
    function getModule(bytes4 selector) external view returns (address);

    // ========== EMERGENCY FUNCTIONS (NO TIMELOCK) ==========
    function freezeAsset(address token) external;
    function unfreezeAsset(address token) external;

    // ========== TIMELOCKED ADMIN FUNCTIONS ==========
    function requestAddAsset(
        address token,
        IPoolV1.OracleConfig calldata oracleCfg,
        IPoolV1.RiskConfig calldata riskCfg,
        IPoolV1.LiquidityProfile calldata profile,
        uint16 minFeeBps,
        uint8 decimals,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA
    ) external;
    function executeAddAsset(address token) external;

    function requestUpdateRiskConfig(address token, IPoolV1.RiskConfig calldata cfg) external;
    function executeUpdateRiskConfig(address token) external;

    function requestUpdateFeeParams(IPoolV1.FeeParams calldata params) external;
    function executeUpdateFeeParams() external;

    function collectProtocolFees(address token, address recipient) external;

    // Timelock governance
    function requestOwnershipTransfer(address newOwner) external;
    function executeOwnershipTransfer() external;
    function requestModuleUpdate(address impl, bytes4[] calldata selectors, bytes calldata initData) external;
    function executeModuleUpdate() external;
    function requestBaseMigration(address newBase) external;
    function executeBaseMigration() external;
    function requestOracleUpdate(address token, IPoolV1.OracleConfig calldata cfg) external;
    function executeOracleUpdate(address token) external;
    function requestBridgeUpdate(address newBridge) external;
    function executeBridgeUpdate() external;
    function requestTreasuryUpdate(address newTreasury) external;
    function executeTreasuryUpdate() external;
    function cancelTimelock(uint8 opType) external;

    // ========== ANCHOR TREE MANAGEMENT ==========
    function setAnchor(address token, address anchor) external;

    // ========== ASSET PARAMETER MANAGEMENT ==========
    /// @notice Update asset pricing parameters (no timelock - moderate risk)
    /// @param token Asset token address
    /// @param minLiquidity Minimum liquidity floor (reserves cannot go below this)
    /// @param minFeeBps Minimum fee in 0.0001% units
    /// @param maxFeeBps Maximum fee in 0.0001% units
    /// @param gamma Inventory sensitivity (basis 10000)
    /// @param vega Volatility sensitivity (basis 10000)
    /// @param lambda Deviation sensitivity (basis 10000)
    /// @param haircutSuppressor Withdrawal haircut suppressor (basis 10000)
    /// @param reservationPrice Price floor vs anchor (B64 format, 0 = disabled)
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

    event AssetParamsUpdated(address indexed token, uint128 minLiquidity, uint64 reservationPrice);

    // ========== FLOW GUARD (JIT PROTECTION) ==========
    /// @notice Set flow cooldown for deposit→withdraw and stake→unstake protection
    /// @param cooldownSeconds Cooldown duration in seconds (0 to disable, max 65535 = ~18 hours)
    function setFlowCooldown(uint16 cooldownSeconds) external;

    // ========== EVENTS ==========

    event ModulesUpdated(address indexed impl, bytes4[] selectors);
    event TimelockRequested(bytes32 indexed id, uint8 opType, uint48 executableAt);
    event TimelockCancelled(bytes32 indexed id, uint8 opType);
    event BaseTokenMigrated(address indexed oldBase, address indexed newBase);
    event OracleUpdated(address indexed token);
    event AssetAdded(address indexed token, uint8 decimals, uint128 minLiquidity);
    event AnchorUpdated(address indexed asset, address indexed anchor, uint8 depth);
    event RiskConfigUpdated(address indexed token, uint128 minLiquidity, uint16 flags);
    event LiquidityProfileUpdated(address indexed token, uint8 segmentCount);
    event HooksUpdated(address indexed token, address indexed hook);
    event FeeParamsUpdated(uint16 protoShare, uint16 flashFeeBps);
    event ProtocolFeesCollected(address indexed token, address indexed recipient, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event EmergencyFreeze(address indexed token);
    event EmergencyUnfreeze(address indexed token);
    event BridgeUpdated(address indexed oldBridge, address indexed newBridge);
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event FlowCooldownUpdated(uint16 oldCooldown, uint16 newCooldown);
}
