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
}
