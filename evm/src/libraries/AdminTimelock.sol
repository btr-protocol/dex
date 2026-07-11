// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IAdmin} from "../interfaces/IAdmin.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";

/// @title AdminTimelock
/// @notice Encode/decode helpers for Admin timelock payloads (isolates stack depth).
library AdminTimelock {
    struct AddAssetPayload {
        address token;
        IPool.OracleConfig oracleCfg;
        IPool.RiskConfig riskCfg;
        IPool.LiquidityProfile profile;
        uint16 minFeeBps;
        uint8 decimals;
        uint32 minDispersion;
        uint32 maxDispersion;
        uint16 gamma;
        uint16 vega;
    }

    /// @dev Two-blob encode keeps `abi.decode` off the via_ir stack-too-deep edge as IPool structs grow.
    function encodeAddAsset(AddAssetPayload memory p) internal pure returns (bytes memory) {
        bytes memory head = abi.encode(p.token, p.oracleCfg, p.riskCfg, p.profile);
        bytes memory tail = abi.encode(p.minFeeBps, p.decimals, p.minDispersion, p.maxDispersion, p.gamma, p.vega);
        return abi.encode(head, tail);
    }

    function decodeAddAsset(bytes memory raw) internal pure returns (AddAssetPayload memory p) {
        bytes memory head;
        bytes memory tail;
        (head, tail) = abi.decode(raw, (bytes, bytes));
        (p.token, p.oracleCfg, p.riskCfg, p.profile) =
            abi.decode(head, (address, IPool.OracleConfig, IPool.RiskConfig, IPool.LiquidityProfile));
        (p.minFeeBps, p.decimals, p.minDispersion, p.maxDispersion, p.gamma, p.vega) =
            abi.decode(tail, (uint16, uint8, uint32, uint32, uint16, uint16));
    }

    /// @dev External entry gets a fresh stack frame (avoids stack-too-deep on the pool call).
    function applyAddAsset(address pool, address token, bytes memory raw) external returns (uint8 decimals) {
        AddAssetPayload memory p = decodeAddAsset(raw);
        if (p.token != token) revert Err.InvalidInput();
        IPool(pool).adminInitAsset(
            p.token,
            p.oracleCfg,
            p.riskCfg,
            p.profile,
            p.minFeeBps,
            p.decimals,
            p.minDispersion,
            p.maxDispersion,
            p.gamma,
            p.vega
        );
        return p.decimals;
    }

    /// @dev Bootstrap listing (untimelocked). Fail-closed if `bootstrapSealed[pool]`.
    function addAssetBootstrap(
        mapping(address => bool) storage bootstrapSealed,
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
        if (bootstrapSealed[pool]) revert Err.InvalidState();
        IPool(pool).adminInitAsset(
            token, oracleCfg, riskCfg, profile, minFeeBps, decimals, minDispersion, maxDispersion, gamma, vega
        );
        emit IAdmin.AssetAdded(pool, token, decimals, 0);
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
        IPool(pool).adminSetAssetParams(
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
        emit IAdmin.AssetParamsUpdated(pool, token, minLiquidity, reservationPrice);
    }
}
