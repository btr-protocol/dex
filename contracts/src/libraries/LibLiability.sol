// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {IInternalOracle} from "../interfaces/IInternalOracle.sol";
import {LibStorage as S} from "./LibStorage.sol";
import {LibPricing as P} from "./LibPricing.sol";
import {LibMaths as M} from "./LibMaths.sol";
import {FPMaths as FPMath} from "solady/utils/FixedPointMathLib.sol";

/// @title LibLiability
/// @notice Unified liability management: time-based decay + LP swaps
/// @dev Manages both automated decay (time-triggered) and manual swaps (user-triggered)
library LibLiability {
    using FPMath for uint256;
    using FPMath for int256;

    // ========== CONSTANTS ==========

    uint256 constant BPS_PRECISION = M.BPS_PRECISION;
    uint256 constant WAD = 1e18;
    uint256 constant AMPLIFICATION_PRECISION = 10000;

    // ========== EVENTS ==========

    event LiabilityDecayStarted(address indexed token, uint256 liabilityAtStart, uint256 coverageAtStart, uint256 timestamp);
    event LiabilityDecayStopped(address indexed token, uint256 finalLiability, uint256 finalCoverage, uint256 timestamp);
    event LiabilityDecayApplied(address indexed token, uint256 oldLiability, uint256 newLiability, uint256 coverage, uint256 elapsed);

    // ========== DECAY FUNCTIONS ==========

    /// @notice Update liability decay for an asset (call on every pool interaction)
    /// @param token Asset address
    /// @dev MUST be called before any operation that reads/writes reserves or liabilities
    function updateDecay(address token) internal {
        IBAMM.BAMMStorage storage $ = S.bamm();
        IBAMM.Asset storage asset = $.assets[token];
        IBAMM.RiskConfig storage config = $.riskConfigs[token];
        IBAMM.LPState storage state = $.lpStates[token];

        // Skip if decay not configured
        if (config.decayStartRatioBps == 0) return;

        // Calculate current coverage ratio
        uint256 currentCoverage = calculateCoverage(asset.reserves, asset.liabilities);
        uint256 threshold = (uint256(config.decayStartRatioBps) * WAD) / BPS_PRECISION;

        // STATE MACHINE
        if (state.decayStartTime == 0) {
            // NOT DECAYING: Check if should start
            if (currentCoverage < threshold) {
                _startDecay(token, asset, state, currentCoverage);
            }
            return;
        }

        // CURRENTLY DECAYING: Check recovery
        if (currentCoverage >= threshold) {
            uint256 coverageAtStart = (uint256(state.coverageAtStart) * WAD) / BPS_PRECISION;

            if (currentCoverage > coverageAtStart) {
                _stopDecay(token, asset, state);
                return;
            }
        }

        // APPLY DECAY
        _applyDecay(token, asset, config, state);
    }

    function _startDecay(
        address token,
        IBAMM.Asset storage asset,
        IBAMM.LPState storage state,
        uint256 currentCoverage
    ) private {
        state.decayStartTime = uint32(block.timestamp);
        state.coverageAtStart = uint32((currentCoverage * BPS_PRECISION) / WAD);
        state.lastUpdateTime = uint32(block.timestamp);

        emit LiabilityDecayStarted(token, asset.liabilities, currentCoverage, block.timestamp);
    }

    function _stopDecay(
        address token,
        IBAMM.Asset storage asset,
        IBAMM.LPState storage state
    ) private {
        uint256 finalCoverage = calculateCoverage(asset.reserves, asset.liabilities);

        emit LiabilityDecayStopped(token, asset.liabilities, finalCoverage, block.timestamp);

        // Reset state
        state.decayStartTime = 0;
        state.lastUpdateTime = 0;
        state.coverageAtStart = 0;
    }

    function _applyDecay(
        address token,
        IBAMM.Asset storage asset,
        IBAMM.RiskConfig storage config,
        IBAMM.LPState storage state
    ) private {
        uint256 elapsed = block.timestamp - state.lastUpdateTime;
        if (elapsed == 0) return;

        uint256 oldLiability = asset.liabilities;
        if (oldLiability == 0) return;

        // Calculate time-weighted decay
        uint256 decaySlope = config.decaySlope;
        uint256 amplification = config.decayAmplification;

        // Formula: L' = L - (slope × elapsed × amplification)
        // decaySlope is per-second reduction, amplification scales the curve
        uint256 decay = (decaySlope * elapsed * amplification) / AMPLIFICATION_PRECISION;

        uint256 newLiability = oldLiability > decay ? oldLiability - decay : 0;

        // Terminal state: cannot decay below reserves
        if (newLiability < asset.reserves) {
            newLiability = asset.reserves;
        }

        asset.liabilities = uint128(newLiability);
        state.lastUpdateTime = uint32(block.timestamp);

        uint256 currentCoverage = calculateCoverage(asset.reserves, asset.liabilities);
        emit LiabilityDecayApplied(token, oldLiability, newLiability, currentCoverage, elapsed);
    }

    /// @notice Exponential decay using binary exponentiation
    function _scaledPow(uint256 base, uint256 exp) private pure returns (uint256 result) {
        result = WAD;
        while (exp > 0) {
            if (exp & 1 == 1) {
                result = (result * base) / WAD;
            }
            base = (base * base) / WAD;
            exp >>= 1;
        }
    }

    // ========== SWAP FUNCTIONS ==========

    /// @notice Execute liability swap with value-weighted coverage delta haircut
    function executeSwap(
        address tokenIn,
        address tokenOut,
        uint256 lpAmountIn,
        IBAMM.Asset storage assetIn,
        IBAMM.Asset storage assetOut,
        IBAMM.Asset storage assetBase,
        IBAMM.LiquidityProfile storage profIn,
        IBAMM.LiquidityProfile storage profOut,
        IBAMM.LiquidityProfile storage profBase,
        IInternalOracle.InternalFeedData storage oracleIn,
        IInternalOracle.InternalFeedData storage oracleOut,
        IInternalOracle.InternalFeedData storage oracleBase,
        IBAMM.DynamicFeeConfig storage feeParams,
        address baseToken
    ) internal returns (uint256 lpAmountOut, uint256 haircut) {
        // 1. Get quote using LibPricing
        P.RouteQuote memory quote = P.quoteRoute(
            tokenIn, tokenOut, baseToken, lpAmountIn,
            assetIn, assetOut, assetBase,
            profIn, profOut, profBase,
            oracleIn, oracleOut, oracleBase,
            feeParams
        );

        // 2. Cache pre-swap coverage
        uint256 C_in_pre = calculateCoverage(assetIn.reserves, assetIn.liabilities);
        uint256 C_out_pre = calculateCoverage(assetOut.reserves, assetOut.liabilities);

        // 3. Compute post-swap coverage
        uint128 L_in_post = uint128(assetIn.liabilities - lpAmountIn);
        uint128 L_out_post = uint128(assetOut.liabilities + quote.amountOut);

        uint256 C_in_post = L_in_post == 0 ? type(uint256).max : calculateCoverage(assetIn.reserves, L_in_post);
        uint256 C_out_post = calculateCoverage(assetOut.reserves, L_out_post);

        // 4. Value-weighted coverage delta
        int256 deltaNet = _valueWeightedDelta(
            tokenIn, tokenOut, baseToken,
            assetIn.reserves, assetOut.reserves,
            C_in_pre, C_out_pre, C_in_post, C_out_post,
            oracleIn, oracleOut
        );

        // 5. Apply haircut if net coverage worsens
        lpAmountOut = quote.amountOut;
        if (deltaNet < 0) {
            uint256 priceIn = _getPrice(tokenIn, baseToken, oracleIn);
            uint256 priceOut = _getPrice(tokenOut, baseToken, oracleOut);
            uint256 valueIn = uint256(assetIn.reserves).mulWad(priceIn);
            uint256 valueOut = uint256(assetOut.reserves).mulWad(priceOut);
            uint256 totalValue = valueIn + valueOut;

            uint256 haircutRatio = uint256(-deltaNet).divWad(totalValue);
            haircut = lpAmountOut.mulWad(haircutRatio);

            // Write off haircut on worse coverage asset (no cap - follows coverage ratio)
            if (C_in_post < C_out_post) {
                assetIn.liabilities -= uint128(haircut);
            } else {
                assetOut.liabilities -= uint128(haircut);
                lpAmountOut -= haircut;
            }
        }

        // 6. Execute liability transfer
        assetIn.liabilities -= uint128(lpAmountIn);
        assetOut.liabilities += uint128(quote.amountOut);
    }

    function _valueWeightedDelta(
        address tokenIn,
        address tokenOut,
        address baseToken,
        uint128 reservesIn,
        uint128 reservesOut,
        uint256 C_in_pre,
        uint256 C_out_pre,
        uint256 C_in_post,
        uint256 C_out_post,
        IInternalOracle.InternalFeedData storage oracleIn,
        IInternalOracle.InternalFeedData storage oracleOut
    ) private view returns (int256 deltaNet) {
        uint256 priceIn = _getPrice(tokenIn, baseToken, oracleIn);
        uint256 priceOut = _getPrice(tokenOut, baseToken, oracleOut);

        uint256 valueIn = uint256(reservesIn).mulWad(priceIn);
        uint256 valueOut = uint256(reservesOut).mulWad(priceOut);

        int256 deltaIn = int256(C_in_post) - int256(C_in_pre);
        int256 deltaOut = int256(C_out_post) - int256(C_out_pre);

        deltaNet = (deltaIn * int256(valueIn) + deltaOut * int256(valueOut)) / 1e18;
    }

    function _getPrice(
        address token,
        address baseToken,
        IInternalOracle.InternalFeedData storage oracle
    ) private view returns (uint256 price) {
        if (token == baseToken) return 1e18;

        uint256 elapsed = block.timestamp - oracle.base.updatedAt;
        uint256 accum = oracle.priceAccumulator + uint256(oracle.currentPrice) * elapsed;
        uint256 dtSlow = block.timestamp - oracle.slowSnapshotTime;

        if (dtSlow == 0) {
            price = M.b64ToPrice(oracle.currentPrice);
        } else {
            uint64 slowTWAP = uint64((accum - oracle.slowAccumSnapshot) / dtSlow);
            price = M.b64ToPrice(slowTWAP);
        }
    }

    // ========== SHARED HELPERS ==========

    /// @notice Calculate coverage ratio (used by both decay + swap)
    function calculateCoverage(uint128 reserves, uint128 liabilities) internal pure returns (uint256) {
        return liabilities == 0 ? type(uint256).max : (uint256(reserves) * WAD) / uint256(liabilities);
    }
}
