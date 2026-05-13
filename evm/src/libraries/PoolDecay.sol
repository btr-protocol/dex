// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {Constants as C} from "./Constants.sol";

/// @title PoolDecay -liability decay math + storage update for Pool.
/// @notice Phase 42H.D · Round 2 · G1 LOC reduction -extracted from `Pool.sol`
///         (was `_applyDecay` + `_calculateDecay`). Keeps Pool focused on user-flow
///         orchestration and isolates the time-decay rule for audit clarity.
/// @dev    Same delegatecall-free model as `Pricing` / `PoolOracle`. Internal lib
///         calls inline at the call-site → identical gas vs prior private helpers.
library PoolDecay {
    /// @notice Apply liability decay to a single asset slot in-place.
    /// @dev    Reads `riskConfigs[token]` for slope/threshold, writes `asset.lastUpdate`
    ///         + decremented `asset.liabilities`. No-op when DECAY disabled or slope=0.
    function applyDecay(IPool.PoolStorage storage $, address token, IPool.Asset storage asset) internal {
        IPool.RiskConfig storage rc = $.riskConfigs[token];
        if ((rc.flags & C.DECAY_ENABLED_BIT) == 0 || rc.decaySlope == 0) {
            asset.lastUpdate = uint32(block.timestamp);
            return;
        }

        uint32 dt = uint32(block.timestamp) - asset.lastUpdate;
        if (dt == 0) return;

        uint128 decayAmount = calculateDecay(
            asset.liabilities, asset.reserves, rc.decayStartRatioBps, rc.decaySlope, dt
        );

        if (decayAmount > 0) asset.liabilities -= decayAmount;
        asset.lastUpdate = uint32(block.timestamp);
    }

    /// @notice Pure decay calculation -coverage-gated linear amortization.
    /// @dev    Returns 0 when coverage (reserves/liabilities) ≥ threshold OR dt=0.
    ///         Cap = `liabilities − reserves` (cannot decay below the deficit).
    function calculateDecay(
        uint128 liabilities,
        uint128 reserves,
        uint16 decayStartRatioBps,
        uint32 decaySlope,
        uint32 dt
    ) internal pure returns (uint128) {
        if (dt == 0 || decaySlope == 0 || liabilities == 0) return 0;
        uint256 coverage = liabilities == 0 ? type(uint256).max : (uint256(reserves) * 1e18) / uint256(liabilities);
        uint256 threshold = (uint256(decayStartRatioBps) * 1e18) / 1_000_000;
        if (coverage >= threshold) return 0;
        uint256 rawDecay = (uint256(liabilities) * uint256(decaySlope) * uint256(dt)) / 1e18;
        uint256 maxDecay = liabilities > reserves ? liabilities - reserves : 0;
        return uint128(rawDecay > maxDecay ? maxDecay : rawDecay);
    }
}
