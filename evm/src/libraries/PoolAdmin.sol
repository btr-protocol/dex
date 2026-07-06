// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IPool} from "../interfaces/IPool.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Maths as M} from "./Maths.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";

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

    /// @notice Validate risk config: κ>0 (convex coverage wall) forbids depthAmplifier>0. The
    ///         calculateDepth c<1 branch SUBSIDIZES a draining trade (extra virtual depth), which fights
    ///         the wall it is meant to erect — mutually exclusive by construction, enforced here.
    function validateRiskConfig(IPool.RiskConfig memory cfg) internal pure {
        if (cfg.kappaCovBps > 0 && cfg.depthAmplifier > 0) revert Err.BadConfig();
    }

    /// @notice Validate oracle config: primary set + reachable, plus INTERNAL-mode gating.
    /// @dev INTERNAL (constant-peg) mode requires: pegB64>0; a live gate feed (primary+feedId); a depeg
    ///      breaker (absolute reservation band on the asset OR refFeedId+refBandBps); and — the on-chain
    ///      ELIGIBILITY rule — any ref band be TIGHT (≤ MAX_STABLE_DEPEG_BAND_BPS), so a loosely/variable-
    ///      pegged unit (which cannot hold so tight a band) is rejected and must use EXTERNAL mode.
    function validateInternalMode(IPool.PoolStorage storage $, address token, IPool.OracleConfig memory cfg)
        internal view
    {
        if (cfg.mode == C.ORACLE_MODE_EXTERNAL) return;
        if (cfg.mode != C.ORACLE_MODE_INTERNAL) revert Err.BadConfig();
        IPool.Asset storage a = $.assets[token];
        if (a.pegB64 == 0) revert Err.BadConfig();
        if (cfg.primary == address(0) || cfg.feedId == bytes32(0)) revert Err.NotConfigured(Err.Resource.ORACLE, token);
        bool refBand = cfg.refFeedId != bytes32(0) && cfg.refBandBps != 0;
        bool absBand = a.reservationPrice != 0 || a.reservationPriceMax != 0;
        if (!refBand && !absBand) revert Err.NotConfigured(Err.Resource.ORACLE, token);
        if (refBand && cfg.refBandBps > C.MAX_STABLE_DEPEG_BAND_BPS) revert Err.BadConfig();
    }

    /// @notice Validate oracle config: primary set + reachable.
    /// @dev `self` = the calling Pool address; allows internal-oracle wiring without try/catch.
    function validateOracleConfig(IPool.OracleConfig memory cfg, address self) internal view {
        if (cfg.primary == address(0)) revert Err.InvalidInput();
        if (cfg.primary != self) {
            try IOracle(cfg.primary).getFeed(cfg.feedId) returns (IOracle.FeedData memory) {} catch {
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
        uint16 vega
    ) internal {
        IPool.Asset storage asset = $.assets[t];
        asset.decimals = decimals;
        asset.minFeeBps = minFeeBps;
        asset.maxFeeBps = uint16(SC.BPS);
        asset.minLiquidity = 0;
        uint32 mn = minDispersion == 0 ? 1000 : minDispersion;
        uint32 mx = maxDispersion == 0 ? 100000 : maxDispersion;
        // R44-7 (Pass-44B): enforce ordering invariant. Without it, `_calculateDispersion`
        // clamp branches collapse to a single bound and produce undefined dispersion bands.
        if (mn > mx) revert Err.BadConfig();
        asset.minDispersion = mn;
        asset.maxDispersion = mx;
        asset.gamma = gamma == 0 ? uint16(SC.BPS) : gamma;
        asset.vega = vega == 0 ? uint16(SC.BPS) : vega;
        asset.haircutSuppressor = uint16(SC.BPS);
        asset.pegB64 = M.encodeB64(SC.WAD, 18); // INTERNAL-mode default peg (1.0 base-per-asset)

        if (t == $.baseToken) {
            asset.anchor = address(0);
            asset.anchorDepth = 0;
        } else {
            asset.anchor = $.baseToken;
            asset.anchorDepth = 1;
        }
    }

    /// @notice Wire oracle/risk/profile slots. The mark now lives in the external oracle (primary);
    ///         no per-asset feed is seeded on-chain (internal-TWAP discovery removed).
    function setupOracleAndConfig(
        IPool.PoolStorage storage $,
        address t,
        IPool.OracleConfig memory oracleCfg,
        IPool.RiskConfig memory riskCfg,
        IPool.LiquidityProfile memory profile
    ) internal {
        $.oracleConfigs[t] = oracleCfg;
        $.riskConfigs[t] = riskCfg;
        $.profiles[t] = profile;
    }
}
