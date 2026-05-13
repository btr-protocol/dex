// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {PoolOracle} from "./PoolOracle.sol";

/// @title PoolAdmin -admin-side validation + initialization helpers for Pool.
/// @notice Phase 42H.D · Round 2 · G1 LOC reduction -extracts oracle/risk/profile
///         setup and validation from `Pool.sol`. Pure storage transforms; no auth
///         (caller must gate via `onlyAdmin`).
library PoolAdmin {
    /// @notice Validate liquidity profile (weights sum=200, knots monotonic, span=100).
    function validateProfileMemory(IPool.LiquidityProfile memory profile) internal pure {
        if (profile.weights[0] == 0) revert Err.InvalidInput();

        uint256 sum = 0;
        uint256 segmentCount = 0;
        unchecked {
            for (uint256 i = 0; i < 16; ++i) {
                if (profile.weights[i] == 0) { segmentCount = i; break; }
                sum += profile.weights[i];
                if (i == 15) segmentCount = 16;
            }
        }
        if (segmentCount == 0 || sum != 200) revert Err.InvalidInput();

        uint256 knotCount = segmentCount + 1;
        unchecked {
            for (uint256 i = 1; i < knotCount; ++i) {
                if (profile.knots[i] < profile.knots[i - 1]) revert Err.InvalidInput();
            }
        }
        if (int16(profile.knots[knotCount - 1]) - int16(profile.knots[0]) != 100) {
            revert Err.InvalidInput();
        }
    }

    /// @notice Validate oracle config: primary set + reachable; secondary reachable if set.
    /// @dev `self` = the calling Pool address; allows internal-oracle wiring without try/catch.
    function validateOracleConfig(IPool.OracleConfig memory cfg, address self) internal view {
        if (cfg.primary == address(0)) revert Err.InvalidInput();
        if (cfg.primary != self) {
            try IOracle(cfg.primary).getFeed(cfg.feedId) returns (IOracle.FeedData memory) {} catch {
                revert Err.InvalidInput();
            }
        }
        if (cfg.secondary != address(0) && cfg.secondary != self) {
            try IOracle(cfg.secondary).getFeed(cfg.feedId) returns (IOracle.FeedData memory) {} catch {
                revert Err.InvalidInput();
            }
        }
    }

    /// @notice Initialize per-asset slot with defaults + caller-supplied params.
    function initAsset(
        IPool.PoolStorage storage $,
        address t,
        uint8 decimals,
        uint16 minFeeBps,
        uint32 minDispersion,
        uint32 maxDispersion,
        uint16 gamma,
        uint16 vega,
        uint16 lambda
    ) internal {
        IPool.Asset storage asset = $.assets[t];
        asset.decimals = decimals;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = 10000;
        asset.minLiquidity = 0;
        asset.minDispersion = minDispersion == 0 ? 1000 : minDispersion;
        asset.maxDispersion = maxDispersion == 0 ? 100000 : maxDispersion;
        asset.gamma = gamma == 0 ? 10000 : gamma;
        asset.vega = vega == 0 ? 10000 : vega;
        asset.lambda = lambda == 0 ? 10000 : lambda;
        asset.haircutSuppressor = 10000;

        if (t == $.baseToken) {
            asset.anchor = address(0);
            asset.anchorDepth = 0;
        } else {
            asset.anchor = $.baseToken;
            asset.anchorDepth = 1;
        }
    }

    /// @notice Wire oracle/risk/profile slots + seed internal accumulator if self-oracle.
    function setupOracleAndConfig(
        IPool.PoolStorage storage $,
        address self,
        address t,
        IPool.OracleConfig memory oracleCfg,
        IPool.RiskConfig memory riskCfg,
        IPool.LiquidityProfile memory profile,
        uint64 initialPrice,
        uint32 initialFastVolEMA,
        uint32 initialSlowVolEMA
    ) internal {
        $.oracleConfigs[t] = oracleCfg;
        $.riskConfigs[t] = riskCfg;
        $.profiles[t] = profile;

        if (oracleCfg.primary == self) {
            uint8 accDec = oracleCfg.accDecimals == 0 ? 6 : oracleCfg.accDecimals;
            PoolOracle.initFeed($, t, initialPrice, accDec, initialFastVolEMA, initialSlowVolEMA);
            emit IOracle.OracleUpdated(t, initialPrice, initialFastVolEMA, initialSlowVolEMA);
        }
    }
}
