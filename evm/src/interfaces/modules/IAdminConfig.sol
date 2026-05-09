// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IPool} from "../IPool.sol";

/// @title IAdminConfig
/// @notice Non-timelocked admin ops: setters, emergency, direct addAsset, getters.
interface IAdminConfig {
    function getModule(bytes4 selector) external view returns (address);

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
}
