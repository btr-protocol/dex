// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

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
        uint16 lambda;
    }

    function encodeAddAsset(AddAssetPayload memory p) internal pure returns (bytes memory) {
        return abi.encode(
            p.token,
            p.oracleCfg,
            p.riskCfg,
            p.profile,
            p.minFeeBps,
            p.decimals,
            p.minDispersion,
            p.maxDispersion,
            p.gamma,
            p.vega,
            p.lambda
        );
    }

    function decodeAddAsset(bytes memory raw) internal pure returns (AddAssetPayload memory p) {
        (
            p.token,
            p.oracleCfg,
            p.riskCfg,
            p.profile,
            p.minFeeBps,
            p.decimals,
            p.minDispersion,
            p.maxDispersion,
            p.gamma,
            p.vega,
            p.lambda
        ) = abi.decode(
            raw,
            (
                address,
                IPool.OracleConfig,
                IPool.RiskConfig,
                IPool.LiquidityProfile,
                uint16,
                uint8,
                uint32,
                uint32,
                uint16,
                uint16,
                uint16
            )
        );
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
            p.vega,
            p.lambda
        );
        return p.decimals;
    }
}
