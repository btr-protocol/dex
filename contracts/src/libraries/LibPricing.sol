// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IBAMM} from "../interfaces/IBAMM.sol";
import {BAMMErrors as E} from "../bamm/BAMMEvents.sol";
import {LibMaths as M} from "./LibMaths.sol";
import {LibUtils as Cast} from "./LibUtils.sol";
import {LibStorage} from "./LibStorage.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title LibPricing
/// @notice Pure arithmetic library for ALM-style pricing and fee calculations
/// @dev ALL prices in calculations are in PRICE_PRECISION (1e18) format for maximum precision
/// @dev Uses Solady's FixedPointMathLib for precision-critical operations
/// @dev Library functions are pure where possible - caller decodes TWAPs and passes them in
///
/// @dev RECENT ENHANCEMENTS:
/// @dev 1. Midpoint segment averaging: Uses (leftPrice + rightPrice)/2 instead of leftPrice
/// @dev    to reduce systematic undercharging and LVR leakage
/// @dev 2. Two-leg hub routing: For A→B where neither is base, routes A→base→B with
/// @dev    piecewise impact on both legs and notional-weighted fee aggregation
/// @dev 3. Exit-leg inventory divergence: Scales fees based on post-trade weight vs target
/// @dev    to protect against exit asset depletion (penalty) or incentivize rebalancing (rebate)
/// @dev 4. Pool-vs-oracle divergence: Optional additional multiplier comparing hub-implied
/// @dev    cross price to TWAP cross (capped at 2x for stability)
/// @dev 5. Oracle decode helpers: Reusable functions to avoid redundant TWAP calculations
/// @dev    across multiple legs (significant gas savings for hub routes)
library LibPricing {
    using Cast for uint256;

    // ========== FEE PARAMETERS STRUCT ==========

    /// @notice Tri-factor fee model parameters (Wombat-inspired ALM)
    /// @dev All multipliers stored in 1e2 format (100 = 1.0x), all divergences in bps
    /// @dev Three capped linear factors: inventory (coverage), volatility shock, price divergence
    /// @dev Unified volatility: single oracle decode per asset, reused for breadth + fees
    struct FeeParams {
        // Inventory factor (coverage-based: reserves/liabilities)
        uint16 invMinMult;        // m_inv,min in 1e2 (e.g., 20 = 0.2x min rebate)
        uint16 invMaxMult;        // m_inv,max in 1e2 (e.g., 10000 = 100x max penalty)
        uint16 invMaxDivergence;  // x_inv,max in bps (e.g., 5000 = 50% for full scale)

        // Baseline volatility (unified for breadth + fees)
        uint16 volWeight;         // w weight for fast vol in 1e2 (e.g., 70 = 0.7, so 70% fast + 30% slow)
        uint32 volFloor;          // v_floor minimum baseline in vol units (e.g., 100000 = 0.1%)
        uint32 volMax;            // v_max maximum baseline in vol units (e.g., 50000000 = 50%)

        // Volatility shock factor (fast/slow ratio)
        uint16 volBeta;           // β sensitivity in 1e2 (e.g., 150 = 1.5)
        uint16 volRMax;           // r_max cap in 1e2 (e.g., 1000 = 10x)
        uint16 volMaxMult;        // m_vol,max cap in 1e2 (e.g., 10000 = 100x)
        uint16 volEpsilon;        // Minimum denominator for ratio (e.g., 1000 = 0.1% vol)

        // Breadth shock (optional additive term for faster reaction)
        uint16 breadthShockKappa; // κ_shock multiplier in 1e2 (e.g., 10 = 0.1, set 0 to disable)

        // Price divergence factor (spot vs oracle TWAPs)
        uint16 pdD1Max;           // d_1,max in bps: spot-vs-fast (e.g., 1000 = 10%)
        uint16 pdD2Max;           // d_2,max in bps: fast-vs-slow (e.g., 1500 = 15%)
        uint16 pdAlpha;           // α weight for regime shift in 1e2 (e.g., 50 = 0.5)
        uint16 pdMaxMult;         // m_pd,max cap in 1e2 (e.g., 10000 = 100x)

        // Base fee (slow vol-aware)
        uint16 baseK;             // k multiplier in 1e2 (e.g., 100 = 1.0)
        uint16 baseMin;           // f_min in bps (e.g., 1 = 0.01%)
        uint16 baseMax;           // f_max in bps (e.g., 500 = 5%)

        // Global caps
        uint16 minMult;           // m_min overall in 1e2 (e.g., 20 = 0.2x from inventory rebates)
        uint16 maxMult;           // m_max overall in 1e2 (e.g., 10000 = 100x)

        // Legacy
        uint16 maxTWAPChange;     // Max price change per update in bps (circuit breaker)
        uint16 protocolFeeBps;    // Protocol fee split in bps (e.g., 1000 = 10% to treasury)
        uint16 withdrawalFeeBps;  // Withdrawal fee in bps (default 0)
    }

    // ========== ORACLE DATA STRUCT (for stack depth optimization) ==========

    /// @notice Decoded oracle data struct to reduce stack depth
    /// @dev Used internally to avoid "stack too deep" errors in complex functions
    struct OracleData {
        uint64 fastTWAP;         // Fast TWAP in b64 format
        uint64 slowTWAP;         // Slow TWAP in b64 format
        uint256 priceFast1e18;   // Fast TWAP decoded to 1e18
        uint256 priceSlow1e18;   // Slow TWAP decoded to 1e18
        uint32 fastVol;          // Fast volatility
        uint32 slowVol;          // Slow volatility
    }

    // ========== CONSTANTS ==========

    /// @notice Maximum breadth to prevent underflow in segment pricing
    /// @dev Ensures 10000 + breadthBps * offset never goes negative
    uint256 private constant MAX_BREADTH_BPS = 10000;

    /// @notice Maximum segments allowed (prevents DoS and array bounds issues)
    uint8 private constant MAX_SEGMENT_COUNT = 16;


    // ========== PIECEWISE BONDING CURVE PRICING ==========

    /// @notice Calculate execution price using piecewise liquidity distribution with unified volatility
    /// @dev Walks through segments, consuming liquidity and accumulating weighted average price
    /// @dev Uses baseline volatility and shock ratio computed once per asset (gas-efficient, consistent)
    /// @dev IMPORTANT: Always returns price in PRICE_PRECISION (1e18) format
    /// @param twapPrice1e18 TWAP price already decoded to 1e18 format (caller should use slow TWAP)
    /// @param baselineVol Baseline volatility v_base (computed once per asset, reused for fees)
    /// @param shockRatio Shock ratio r (computed once per asset, reused for fees)
    /// @param reserves Total reserves available
    /// @param segmentCount Number of segments in curve
    /// @param offsets Segment offset array
    /// @param weights Segment weight array
    /// @param minBreadth Minimum breadth (1e8 base)
    /// @param maxBreadth Maximum breadth (1e8 base)
    /// @param breadthShockKappa κ_shock multiplier for optional shock term
    /// @param amount Amount to trade (0 = spot price at TWAP)
    /// @return Execution price in PRICE_PRECISION (1e18)
    function getSegmentPricePure(
        uint256 twapPrice1e18,
        uint32 baselineVol,
        uint256 shockRatio,
        uint128 reserves,
        uint8 segmentCount,
        int8[17] memory offsets,
        uint8[16] memory weights,
        uint64 minBreadth,
        uint64 maxBreadth,
        uint16 breadthShockKappa,
        uint256 amount
    ) internal pure returns (uint256) {
        // Validate inputs
        if (twapPrice1e18 == 0) return M.PRICE_PRECISION; // Default to 1.0
        if (segmentCount <= 1 || segmentCount > MAX_SEGMENT_COUNT) return twapPrice1e18;
        if (reserves == 0) return twapPrice1e18;

        // If amount is 0, return spot price (TWAP is the reference)
        if (amount == 0) return twapPrice1e18;

        // Calculate current breadth using unified baseline volatility + optional shock
        uint256 breadthBps = _calculateBreadth(baselineVol, shockRatio, minBreadth, maxBreadth, breadthShockKappa);

        // Calculate weighted average execution price with streaming computation
        return _calculateExecutionPriceStreaming(
            amount,
            reserves,
            twapPrice1e18,
            breadthBps,
            offsets,
            weights,
            segmentCount
        );
    }

    /// @notice View function with unified volatility (decode oracle once, reuse for breadth + fees)
    /// @dev Computes baseline volatility and shock ratio once per asset, passes to pure function
    /// @dev This is the recommended entry point - ensures consistency between breadth and fee calculations
    /// @param asset Asset storage reference
    /// @param profile Liquidity profile with segment configuration
    /// @param feeParams Fee parameters (for baseline volatility and shock calculation)
    /// @param oracle Oracle entry for price and volatility data
    /// @param amount Amount to trade (0 = spot price at TWAP)
    /// @return Execution price in PRICE_PRECISION (1e18)
    function getSegmentPrice(
        IBAMM.Asset storage asset,
        IBAMM.LiquidityProfile storage profile,
        FeeParams storage feeParams,
        LibStorage.OracleEntry storage oracle,
        uint256 amount
    ) internal view returns (uint256) {
        // Calculate slow TWAP (Uniswap V3 style accumulator)
        uint256 timeElapsed = block.timestamp - oracle.lastOracleUpdate;
        uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);
        uint256 timeDelta = block.timestamp - oracle.slowSnapshotTime;
        uint64 slowTWAP = timeDelta == 0 ? oracle.currentPrice : uint64((currentAccum - oracle.slowAccumSnapshot) / timeDelta);

        // Decode to 1e18 and call pure function
        uint256 twapPrice1e18 = M.b64ToPrice(slowTWAP);

        // *** UNIFIED VOLATILITY: Compute once per asset, reuse for breadth + fees ***
        // Baseline volatility: v_base = w * v_f + (1 - w) * v_s, clamped to [v_floor, v_max]
        uint32 baselineVol = _calculateBaselineVolatility(oracle.fastVolatility, oracle.slowVolatility, feeParams);

        // Shock ratio: r = min(r_max, v_f / max(v_s, ε))
        uint256 shockRatio = _calculateShockRatio(oracle.fastVolatility, oracle.slowVolatility, feeParams);

        return getSegmentPricePure(
            twapPrice1e18,
            baselineVol,
            shockRatio,
            asset.reserves,
            asset.segmentCount,
            profile.twapOffsets,
            profile.segmentWeights,
            profile.minBreadth,
            profile.maxBreadth,
            feeParams.breadthShockKappa,
            amount
        );
    }

    /// @notice Calculate breadth (price range width) using unified baseline volatility + optional shock
    /// @dev breadthBps = breadth_0 + κ_breadth * v_base + κ_shock * (r - 1)
    /// @dev Uses baseline volatility (weighted fast/slow) for consistency with fee calculation
    /// @dev Optional shock term allows faster reaction to volatility spikes (set κ_shock = 0 to disable)
    /// @param baselineVol Baseline volatility v_base in 1e6 units (computed once per asset)
    /// @param shockRatio Shock ratio r in 1e2 format (computed once per asset)
    /// @param minBreadth Min breadth at volatility=0 (1e8 base)
    /// @param maxBreadth Max breadth at volatility=100_000_000 (1e8 base)
    /// @param breadthShockKappa κ_shock multiplier in 1e2 (e.g., 10 = 0.1, set 0 to disable shock term)
    /// @return breadthBps Current breadth in basis points (1e4 base), clamped to MAX_BREADTH_BPS
    function _calculateBreadth(
        uint32 baselineVol,
        uint256 shockRatio,
        uint64 minBreadth,
        uint64 maxBreadth,
        uint16 breadthShockKappa
    ) private pure returns (uint256 breadthBps) {
        // Linear interpolation based on baseline volatility
        // breadth = minBreadth + (maxBreadth - minBreadth) * v_base / 100_000_000
        uint256 vol = uint256(baselineVol);
        uint256 interpolated;

        if (vol >= 100_000_000) {
            interpolated = uint256(maxBreadth);
        } else {
            interpolated = M.lerpCustom(
                uint256(minBreadth),
                uint256(maxBreadth),
                vol,
                100_000_000 // Max volatility
            );
        }

        // Convert from 1e8 to 1e4 (basis points)
        breadthBps = interpolated / 10000;

        // Optional: Add shock term κ_shock * (r - 1) for faster reaction
        // shockRatio in 1e2, so (r - 100) gives excess over 1.0x
        // κ_shock in 1e2, so multiply and divide by 100 * 100 = 10000
        if (breadthShockKappa > 0 && shockRatio > 100) {
            uint256 excessRatio = shockRatio - 100; // (r - 1) in 1e2
            uint256 shockTerm = (uint256(breadthShockKappa) * excessRatio) / 10000; // bps
            breadthBps = breadthBps + shockTerm;
        }

        // Clamp to max
        if (breadthBps > MAX_BREADTH_BPS) breadthBps = MAX_BREADTH_BPS;
    }

    /// @notice Calculate execution price with streaming computation (no temporary array)
    /// @dev Computes segment prices on-the-fly and accumulates cost in one pass
    /// @dev Uses Solady's fullMulDiv for maximum precision in cost accumulation
    /// @param amount Amount to trade
    /// @param reserves Total reserves available
    /// @param twapPrice Reference price in 1e18 format
    /// @param breadthBps Current breadth in basis points (1e4)
    /// @param offsets Array of offset percentages (-100 to +100)
    /// @param weights Array of segment weights (sum to WEIGHT_SUM)
    /// @param segmentCount Number of segments
    /// @return executionPrice Weighted average execution price (in 1e8)
    function _calculateExecutionPriceStreaming(
        uint256 amount,
        uint128 reserves,
        uint256 twapPrice,
        uint256 breadthBps,
        int8[17] memory offsets,
        uint8[16] memory weights,
        uint8 segmentCount
    ) private pure returns (uint256 executionPrice) {
        uint256 remainingAmount = amount;
        uint256 totalCost = 0;

        // Cache constants to stack
        uint256 pricePrecision = M.PRICE_PRECISION;
        uint256 weightSum = M.WEIGHT_SUM;

        unchecked {
            // Walk through segments from lowest to highest price (buy direction)
            for (uint256 i = 0; i < segmentCount && remainingAmount > 0; ++i) {
                // Calculate left boundary price on-the-fly
                int256 leftOffset = int256(int8(offsets[i]));
                int256 leftChangeBps = (leftOffset * int256(breadthBps)) / 100;
                int256 leftPriceCalc = (int256(twapPrice) * (10000 + leftChangeBps)) / 10000;
                uint256 leftPrice = leftPriceCalc > 0 ? uint256(leftPriceCalc) : twapPrice;

                // Calculate right boundary price on-the-fly
                int256 rightOffset = int256(int8(offsets[i + 1]));
                int256 rightChangeBps = (rightOffset * int256(breadthBps)) / 100;
                int256 rightPriceCalc = (int256(twapPrice) * (10000 + rightChangeBps)) / 10000;
                uint256 rightPrice = rightPriceCalc > 0 ? uint256(rightPriceCalc) : twapPrice;

                // Skip invalid segments
                if (rightPrice <= leftPrice) continue;

                // Calculate liquidity available in this segment
                // Use fullMulDiv for precision: segmentLiquidity = reserves * weight / weightSum
                uint256 segmentLiquidity = FixedPointMathLib.fullMulDiv(
                    uint256(reserves),
                    uint256(weights[i]),
                    weightSum
                );

                // How much can we fill in this segment?
                uint256 fillAmount = remainingAmount > segmentLiquidity ? segmentLiquidity : remainingAmount;

                // Calculate average price: use midpoint for accurate integral approximation
                // This reduces systematic undercharging and LVR vs left-edge pricing
                uint256 avgPrice = (leftPrice + rightPrice) / 2;

                // Accumulate cost with fullMulDiv for precision: cost = fillAmount * avgPrice / pricePrecision
                totalCost += FixedPointMathLib.fullMulDiv(fillAmount, avgPrice, pricePrecision);
                remainingAmount -= fillAmount;
            }
        }

        // If we couldn't fill everything, use the highest price (final offset)
        if (remainingAmount > 0 && segmentCount > 0) {
            int256 finalOffset = int256(int8(offsets[segmentCount]));
            int256 finalChangeBps = (finalOffset * int256(breadthBps)) / 100;
            int256 finalPriceCalc = (int256(twapPrice) * (10000 + finalChangeBps)) / 10000;
            uint256 highestPrice = finalPriceCalc > 0 ? uint256(finalPriceCalc) : twapPrice;

            totalCost += FixedPointMathLib.fullMulDiv(remainingAmount, highestPrice, pricePrecision);
        }

        // Return weighted average execution price with fullMulDiv
        executionPrice = amount > 0
            ? FixedPointMathLib.fullMulDiv(totalCost, pricePrecision, amount)
            : twapPrice;
    }

    // ========== ORACLE HELPERS ==========

    /// @notice Decode oracle TWAPs and volatilities into memory struct (reduces stack depth)
    /// @dev Calculates fast and slow TWAPs using Uniswap V3 accumulator formula
    /// @param oracle Oracle entry to decode
    /// @return data Decoded oracle data struct
    function _decodeOracleData(LibStorage.OracleEntry storage oracle)
        private view returns (OracleData memory data)
    {
        // Calculate accumulator update
        uint256 timeElapsed = block.timestamp - oracle.lastOracleUpdate;
        uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);

        // Calculate fast TWAP
        uint256 timeDeltaFast = block.timestamp - oracle.fastSnapshotTime;
        data.fastTWAP = timeDeltaFast == 0
            ? oracle.currentPrice
            : uint64((currentAccum - oracle.fastAccumSnapshot) / timeDeltaFast);

        // Calculate slow TWAP
        uint256 timeDeltaSlow = block.timestamp - oracle.slowSnapshotTime;
        data.slowTWAP = timeDeltaSlow == 0
            ? oracle.currentPrice
            : uint64((currentAccum - oracle.slowAccumSnapshot) / timeDeltaSlow);

        // Decode to 1e18
        data.priceFast1e18 = M.b64ToPrice(data.fastTWAP);
        data.priceSlow1e18 = M.b64ToPrice(data.slowTWAP);

        // Copy volatilities
        data.fastVol = oracle.fastVolatility;
        data.slowVol = oracle.slowVolatility;
    }

    // ========== TRI-FACTOR FEE MODEL ==========

    /// @notice Calculate inventory factor based on coverage ratio (Wombat-style ALM)
    /// @dev Linear rebates when under target (v < t), penalties when over target (v > t)
    /// @dev v = asset value share, t = liability share (target allocation)
    /// @param reserves Asset reserves
    /// @param liabilities Asset liabilities (total deposits)
    /// @param price Asset price (1e18 format)
    /// @param totalReserves Sum of all reserve values
    /// @param totalLiabilities Sum of all liability values
    /// @param params Fee parameters
    /// @return mult Multiplier in 1e18 format
    function _calculateInventoryFactor(
        uint128 reserves,
        uint128 liabilities,
        uint256 price,
        uint256 totalReserves,
        uint256 totalLiabilities,
        FeeParams memory params
    ) private pure returns (uint256 mult) {
        if (totalReserves == 0 || totalLiabilities == 0) return M.PRECISION;

        // Calculate asset value and liability value
        uint256 assetValue = FixedPointMathLib.fullMulDiv(uint256(reserves), price, M.PRICE_PRECISION);
        uint256 liabValue = FixedPointMathLib.fullMulDiv(uint256(liabilities), price, M.PRICE_PRECISION);

        // Current share: v = assetValue / totalReserves (in bps)
        uint256 v = FixedPointMathLib.fullMulDiv(assetValue, M.BPS_PRECISION, totalReserves);

        // Target share: t = liabValue / totalLiabilities (in bps)
        uint256 t = FixedPointMathLib.fullMulDiv(liabValue, M.BPS_PRECISION, totalLiabilities);

        // Protect against division by zero with epsilon (0.1% = 10 bps)
        uint256 tSafe = t > 10 ? t : 10;

        // Normalized divergence: x = min(1, |v-t| / t / x_inv,max)
        uint256 divergence = v > t ? v - t : t - v;
        uint256 x = FixedPointMathLib.fullMulDiv(divergence, M.PRECISION, tSafe);
        x = FixedPointMathLib.fullMulDiv(x, M.BPS_PRECISION, uint256(params.invMaxDivergence));
        if (x > M.PRECISION) x = M.PRECISION;

        if (v < t) {
            // Under target: linear rebate
            // m = 1 - (1 - m_min) * x
            uint256 mMin = FixedPointMathLib.fullMulDiv(uint256(params.invMinMult), M.PRECISION, 100);
            uint256 rebateRange = M.PRECISION - mMin;
            uint256 rebate = FixedPointMathLib.fullMulDiv(rebateRange, x, M.PRECISION);
            mult = M.PRECISION - rebate;
        } else {
            // Over target: linear penalty
            // m = 1 + (m_max - 1) * x
            uint256 mMax = FixedPointMathLib.fullMulDiv(uint256(params.invMaxMult), M.PRECISION, 100);
            uint256 penaltyRange = mMax - M.PRECISION;
            uint256 penalty = FixedPointMathLib.fullMulDiv(penaltyRange, x, M.PRECISION);
            mult = M.PRECISION + penalty;
        }
    }

    /// @notice Calculate volatility shock factor from fast/slow ratio
    /// @dev Linear with sensitivity gain β: m = clamp(β * r, 1, m_vol,max)
    /// @param fastVol Fast volatility (oracle uint32, 1e6 base)
    /// @param slowVol Slow volatility (oracle uint32, 1e6 base)
    /// @param params Fee parameters
    /// @return mult Multiplier in 1e18 format
    function _calculateVolatilityShockFactor(
        uint32 fastVol,
        uint32 slowVol,
        FeeParams memory params
    ) private pure returns (uint256 mult) {
        // Protect against division by zero
        uint256 slowSafe = slowVol > params.volEpsilon ? slowVol : params.volEpsilon;

        // Shock ratio: r = min(r_max, v_fast / v_slow) in 1e2 format
        uint256 ratio = (uint256(fastVol) * 100) / slowSafe;
        uint256 rMax = uint256(params.volRMax);
        if (ratio > rMax) ratio = rMax;

        // Linear map: m = β * r (both in 1e2, result in 1e4, scale to 1e18)
        mult = FixedPointMathLib.fullMulDiv(uint256(params.volBeta), ratio, 10000);
        mult = mult * M.PRECISION / 100;  // Scale 1e4 -> 1e18

        // Clamp to [1, m_vol,max]
        if (mult < M.PRECISION) mult = M.PRECISION;
        uint256 maxMult = FixedPointMathLib.fullMulDiv(uint256(params.volMaxMult), M.PRECISION, 100);
        if (mult > maxMult) mult = maxMult;
    }

    /// @notice Calculate price divergence factor
    /// @dev Combines spot-vs-fast (immediate) and fast-vs-slow (regime shift) divergences
    /// @param spotPrice Pool marginal execution price (1e18)
    /// @param fastTWAP Oracle fast TWAP (1e18)
    /// @param slowTWAP Oracle slow TWAP (1e18)
    /// @param params Fee parameters
    /// @return mult Multiplier in 1e18 format
    function _calculatePriceDivergenceFactor(
        uint256 spotPrice,
        uint256 fastTWAP,
        uint256 slowTWAP,
        FeeParams memory params
    ) private pure returns (uint256 mult) {
        // Protect against division by zero (epsilon = 0.001 = 1e15)
        uint256 fastSafe = fastTWAP > M.PRECISION / 1000 ? fastTWAP : M.PRECISION / 1000;
        uint256 slowSafe = slowTWAP > M.PRECISION / 1000 ? slowTWAP : M.PRECISION / 1000;

        // d_1 = |spot - fast| / fast (immediate mispricing)
        uint256 diff1 = spotPrice > fastTWAP ? spotPrice - fastTWAP : fastTWAP - spotPrice;
        uint256 d1Bps = FixedPointMathLib.fullMulDiv(diff1, M.BPS_PRECISION, fastSafe);

        // d_2 = |fast - slow| / slow (regime shift)
        uint256 diff2 = fastTWAP > slowTWAP ? fastTWAP - slowTWAP : slowTWAP - fastTWAP;
        uint256 d2Bps = FixedPointMathLib.fullMulDiv(diff2, M.BPS_PRECISION, slowSafe);

        // Normalize: x_1 = d_1 / d_1,max
        uint256 x1 = FixedPointMathLib.fullMulDiv(d1Bps, M.PRECISION, uint256(params.pdD1Max));

        // Normalize: x_2 = α * d_2 / d_2,max
        uint256 x2 = FixedPointMathLib.fullMulDiv(d2Bps, M.PRECISION, uint256(params.pdD2Max));
        x2 = FixedPointMathLib.fullMulDiv(x2, uint256(params.pdAlpha), 100);

        // Conservative aggregation: x = min(1, max(x_1, x_2))
        uint256 x = x1 > x2 ? x1 : x2;
        if (x > M.PRECISION) x = M.PRECISION;

        // Linear ramp: m = 1 + (m_max - 1) * x
        uint256 mMax = FixedPointMathLib.fullMulDiv(uint256(params.pdMaxMult), M.PRECISION, 100);
        uint256 rampRange = mMax - M.PRECISION;
        uint256 ramp = FixedPointMathLib.fullMulDiv(rampRange, x, M.PRECISION);
        mult = M.PRECISION + ramp;
    }

    /// @notice Combine three factors into single risk multiplier
    /// @dev Multiplicative combination with final clamp to global bounds
    /// @param invMult Inventory multiplier (1e18)
    /// @param volMult Volatility shock multiplier (1e18)
    /// @param pdMult Price divergence multiplier (1e18)
    /// @param params Fee parameters (for min/max bounds)
    /// @return mult Combined risk multiplier in 1e18 format
    function _calculateRiskMultiplier(
        uint256 invMult,
        uint256 volMult,
        uint256 pdMult,
        FeeParams memory params
    ) private pure returns (uint256 mult) {
        // Product: m = (m_inv * m_vol * m_pd) / 1e18^2
        mult = FixedPointMathLib.fullMulDiv(invMult, volMult, M.PRECISION);
        mult = FixedPointMathLib.fullMulDiv(mult, pdMult, M.PRECISION);

        // Clamp to global bounds
        uint256 minMult = FixedPointMathLib.fullMulDiv(uint256(params.minMult), M.PRECISION, 100);
        uint256 maxMult = FixedPointMathLib.fullMulDiv(uint256(params.maxMult), M.PRECISION, 100);

        if (mult < minMult) mult = minMult;
        if (mult > maxMult) mult = maxMult;
    }

    /// @notice Calculate vol-aware base fee from slow volatility
    /// @dev f_base = clamp(k * v_slow, f_min, f_max) where v_slow in 1e6 base
    /// @param slowVol Slow volatility (oracle uint32, 1e6 base: 1M = 1%)
    /// @param params Fee parameters
    /// @return feeBps Base fee in basis points
    function _calculateBaseFee(
        uint32 slowVol,
        FeeParams memory params
    ) private pure returns (uint256 feeBps) {
        // k * v_slow: k in 1e2, v_slow in 1e6 → result in bps
        // Formula: (k * v_slow) / 1e4 to get bps
        feeBps = (uint256(params.baseK) * uint256(slowVol)) / 10000;

        // Clamp to [f_min, f_max]
        if (feeBps < uint256(params.baseMin)) feeBps = uint256(params.baseMin);
        if (feeBps > uint256(params.baseMax)) feeBps = uint256(params.baseMax);
    }

    /// @notice Calculate baseline volatility (unified for breadth + fees)
    /// @dev v_base = w * v_f + (1 - w) * v_s, clamped to [v_floor, v_max]
    /// @dev Computed once per asset per leg, reused for both breadth and fee calculations
    /// @param fastVol Fast volatility in 1e6 units (e.g., 5000000 = 5%)
    /// @param slowVol Slow volatility in 1e6 units
    /// @param params Fee parameters containing weight, floor, and max
    /// @return baselineVol Baseline volatility in 1e6 units
    function _calculateBaselineVolatility(
        uint32 fastVol,
        uint32 slowVol,
        FeeParams memory params
    ) private pure returns (uint32 baselineVol) {
        // Weighted average: v_base = w * v_f + (1 - w) * v_s
        // w is in 1e2 format (e.g., 70 = 0.7)
        uint256 w = uint256(params.volWeight);
        uint256 vf = uint256(fastVol);
        uint256 vs = uint256(slowVol);

        // Calculate: (w * v_f + (100 - w) * v_s) / 100
        uint256 weighted = (w * vf + (100 - w) * vs) / 100;

        // Clamp to [v_floor, v_max]
        if (weighted < uint256(params.volFloor)) weighted = uint256(params.volFloor);
        if (weighted > uint256(params.volMax)) weighted = uint256(params.volMax);

        baselineVol = uint32(weighted);
    }

    /// @notice Calculate shock ratio (unified for fee shock factor + optional breadth shock)
    /// @dev r = min(r_max, v_f / max(v_s, ε))
    /// @dev Captures regime breaks even when absolute volatility is small (critical for stables)
    /// @dev Computed once per asset per leg, reused for volatility shock factor + breadth shock
    /// @param fastVol Fast volatility in 1e6 units
    /// @param slowVol Slow volatility in 1e6 units
    /// @param params Fee parameters containing r_max and epsilon
    /// @return shockRatio Shock ratio in 1e2 format (e.g., 300 = 3.0x)
    function _calculateShockRatio(
        uint32 fastVol,
        uint32 slowVol,
        FeeParams memory params
    ) private pure returns (uint256 shockRatio) {
        // r = v_f / max(v_s, ε)
        uint256 vf = uint256(fastVol);
        uint256 vs = uint256(slowVol);
        uint256 epsilon = uint256(params.volEpsilon);

        // Guard against division by zero
        uint256 vsSafe = vs > epsilon ? vs : epsilon;

        // Ratio in 1e2 format: (v_f * 100) / v_s
        shockRatio = (vf * 100) / vsSafe;

        // Clamp to r_max
        uint256 rMax = uint256(params.volRMax);
        if (shockRatio > rMax) shockRatio = rMax;
    }

    // ========== FEE CALCULATION ==========

    /// @notice Calculate swap fee using tri-factor model (coverage-based ALM with unified volatility)
    /// @dev Uses Wombat-inspired coverage ratio for inventory factor
    /// @dev Unified volatility: decode oracle once, compute baseline vol and shock ratio once, reuse for pricing + fees
    /// @param feeParams Fee parameters with all tri-factor settings
    /// @param totalLiabilities Total pool liabilities (CACHED - O(1), never iterate!)
    function calculateSwapFee(
        IBAMM.Asset storage assetIn,
        IBAMM.Asset storage assetOut,
        IBAMM.LiquidityProfile storage profileIn,
        IBAMM.LiquidityProfile storage profileOut,
        LibStorage.OracleEntry storage oracleIn,
        LibStorage.OracleEntry storage oracleOut,
        FeeParams storage feeParams,
        uint256 amountIn,
        uint256 totalValue,
        uint256 totalLiabilities
    ) internal view returns (IBAMM.FeeComponents memory feeComps) {
        // Decode oracles into structs (reduces stack depth)
        OracleData memory dataIn = _decodeOracleData(oracleIn);
        OracleData memory dataOut = _decodeOracleData(oracleOut);

        // *** TRI-FACTOR MODEL ***

        // 1. Base fee from slow volatility (long-term volatility baseline)
        feeComps.baseFee = _calculateBaseFee(
            (dataIn.slowVol + dataOut.slowVol) / 2,
            feeParams
        );

        // 2. Inventory factor (coverage-based ALM - Wombat style)
        uint256 invMultIn = _calculateInventoryFactor(
            assetIn.reserves,
            assetIn.liabilities,
            dataIn.priceFast1e18,
            totalValue,
            totalLiabilities,
            feeParams
        );
        uint256 invMultOut = _calculateInventoryFactor(
            assetOut.reserves,
            assetOut.liabilities,
            dataOut.priceFast1e18,
            totalValue,
            totalLiabilities,
            feeParams
        );
        uint256 invMult = invMultIn > invMultOut ? invMultIn : invMultOut;

        // 3. Volatility shock factor (fast/slow ratio for regime breaks)
        uint256 volMultIn = _calculateVolatilityShockFactor(
            dataIn.fastVol,
            dataIn.slowVol,
            feeParams
        );
        uint256 volMultOut = _calculateVolatilityShockFactor(
            dataOut.fastVol,
            dataOut.slowVol,
            feeParams
        );
        uint256 volMult = volMultIn > volMultOut ? volMultIn : volMultOut;

        // 4. Price divergence factor (spot vs oracle TWAPs)
        uint256 spotPriceIn = getSegmentPrice(assetIn, profileIn, feeParams, oracleIn, amountIn);
        uint256 spotPriceOut = getSegmentPrice(assetOut, profileOut, feeParams, oracleOut, 0);

        uint256 divMultIn = _calculatePriceDivergenceFactor(
            spotPriceIn,
            dataIn.priceFast1e18,
            dataIn.priceSlow1e18,
            feeParams
        );
        uint256 divMultOut = _calculatePriceDivergenceFactor(
            spotPriceOut,
            dataOut.priceFast1e18,
            dataOut.priceSlow1e18,
            feeParams
        );
        uint256 divMult = divMultIn > divMultOut ? divMultIn : divMultOut;

        // 5. Combine factors multiplicatively
        uint256 riskMult = _calculateRiskMultiplier(invMult, volMult, divMult, feeParams);

        // 6. Apply risk multiplier to base fee
        uint256 fee = FixedPointMathLib.fullMulDiv(feeComps.baseFee, riskMult, M.PRECISION);

        // Enforce asset-specific bounds (use min of both minimums, max of both maximums)
        uint256 minFee = assetIn.minFeeBps < assetOut.minFeeBps ? assetIn.minFeeBps : assetOut.minFeeBps;
        uint256 maxFee = assetIn.maxFeeBps > assetOut.maxFeeBps ? assetIn.maxFeeBps : assetOut.maxFeeBps;

        // Clamp to asset bounds
        fee = fee < minFee ? minFee : (fee > maxFee ? maxFee : fee);

        // Populate fee components (convert to base 100 for display)
        feeComps.totalFeeBps = fee;
        feeComps.volatilityMultiplier = FixedPointMathLib.fullMulDiv(volMult, 100, M.PRECISION);
        feeComps.inventoryMultiplier = FixedPointMathLib.fullMulDiv(invMult, 100, M.PRECISION);
        feeComps.divergenceMultiplier = FixedPointMathLib.fullMulDiv(divMult, 100, M.PRECISION);
        feeComps.exitInventoryDivergence = 100; // Single-leg: no exit divergence
        // Single-leg: no per-leg breakdown
        feeComps.leg1FeeBps = 0;
        feeComps.leg2FeeBps = 0;
        feeComps.leg1Notional = 0;
        feeComps.leg2Notional = 0;
    }

    /// @notice Calculate withdrawal fee (ALM model - flat rate)
    /// @dev In ALM model, withdrawals charged flat fee (if any) for LP arbitrage mitigation
    /// @param asset Asset being withdrawn
    /// @return fee Withdrawal fee in bps
    function calculateWithdrawalFee(
        IBAMM.Asset storage asset
    ) internal view returns (uint256 fee) {
        // ALM model: flat withdrawal fee (default 0)
        // No deviation-based fees - pool balances organically via swap fees
        return asset.withdrawalFeeBps;
    }

    // ========== PORTFOLIO VALUATION ==========

    /// @notice Calculate total portfolio value (O(n) - only for view functions)
    /// @dev Uses fast TWAP computed inline with Uniswap V3 accumulator formula
    /// @dev NOTE: Returns 0 instead of 1 sentinel - caller should handle zero case
    /// @return total Total value in base asset terms (can be 0 if no assets)
    function calculateTotalValue(
        address[] storage registeredAssets,
        mapping(address => IBAMM.Asset) storage assets,
        mapping(bytes32 => LibStorage.OracleEntry) storage oracleEntries
    ) internal view returns (uint256 total) {
        uint256 length = registeredAssets.length;

        for (uint256 i = 0; i < length; i++) {
            address token = registeredAssets[i];
            IBAMM.Asset storage asset = assets[token];
            LibStorage.OracleEntry storage oracle = oracleEntries[asset.oracleId];

            // Calculate fast TWAP inline (Uniswap V3 style)
            uint256 timeElapsed = block.timestamp - oracle.lastOracleUpdate;
            uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);
            uint256 timeDelta = block.timestamp - oracle.fastSnapshotTime;
            uint64 fastTWAP = timeDelta == 0 ? oracle.currentPrice : uint64((currentAccum - oracle.fastAccumSnapshot) / timeDelta);

            if (fastTWAP > 0) {
                // Decode b64 to 1e8 and calculate value with fullMulDiv
                uint256 price1e8 = M.b64ToPrice(fastTWAP);
                uint256 value = FixedPointMathLib.fullMulDiv(uint256(asset.reserves), price1e8, M.PRICE_PRECISION);
                total += value;
            }
        }

        // Return 0 explicitly instead of sentinel - caller should guard against division by zero
        return total;
    }

    /// @notice Calculate value of a single token's reserves (O(1))
    /// @dev Used for delta-based cache updates with inline TWAP calculation
    /// @param asset The asset to value
    /// @param oracle The oracle entry for this asset
    /// @return value Value in base asset terms
    function calculateTokenValue(
        IBAMM.Asset storage asset,
        LibStorage.OracleEntry storage oracle
    ) internal view returns (uint256 value) {
        // Calculate fast TWAP inline
        uint256 timeElapsed = block.timestamp - oracle.lastOracleUpdate;
        uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);
        uint256 timeDelta = block.timestamp - oracle.fastSnapshotTime;
        uint64 fastTWAP = timeDelta == 0 ? oracle.currentPrice : uint64((currentAccum - oracle.fastAccumSnapshot) / timeDelta);

        if (fastTWAP == 0) return 0;

        uint256 price1e8 = M.b64ToPrice(fastTWAP);
        value = FixedPointMathLib.fullMulDiv(uint256(asset.reserves), price1e8, M.PRICE_PRECISION);
    }

    /// @notice Update cached total value with reserve delta (O(1))
    /// @dev Called on swap/deposit/withdraw to maintain cache without O(n) loop
    /// @dev Uses fullMulDiv for precision and returns 0 instead of sentinel
    /// @param cachedTotal Current cached total value
    /// @param asset The asset that changed
    /// @param oracle The oracle entry for this asset
    /// @param reservesDelta Change in reserves (can be negative)
    /// @return newTotal Updated total value (can be 0)
    function updateTotalValueDelta(
        uint256 cachedTotal,
        IBAMM.Asset storage asset,
        LibStorage.OracleEntry storage oracle,
        int256 reservesDelta
    ) internal view returns (uint256 newTotal) {
        if (reservesDelta == 0) return cachedTotal;

        // Calculate fast TWAP inline
        uint256 timeElapsed = block.timestamp - oracle.lastOracleUpdate;
        uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);
        uint256 timeDelta = block.timestamp - oracle.fastSnapshotTime;
        uint64 fastTWAP = timeDelta == 0 ? oracle.currentPrice : uint64((currentAccum - oracle.fastAccumSnapshot) / timeDelta);

        if (fastTWAP == 0) return cachedTotal;

        uint256 price1e8 = M.b64ToPrice(fastTWAP);

        if (reservesDelta > 0) {
            // Positive delta: add value with fullMulDiv
            uint256 valueDelta = FixedPointMathLib.fullMulDiv(uint256(reservesDelta), price1e8, M.PRICE_PRECISION);
            newTotal = cachedTotal + valueDelta;
        } else {
            // Negative delta: subtract value with fullMulDiv
            uint256 valueDelta = FixedPointMathLib.fullMulDiv(uint256(-reservesDelta), price1e8, M.PRICE_PRECISION);
            newTotal = cachedTotal > valueDelta ? cachedTotal - valueDelta : 0;
        }

        // Return 0 explicitly instead of sentinel - caller should handle
        return newTotal;
    }

    /// @notice Update cached total liabilities with liability delta (O(1))
    /// @dev Called on deposit/withdraw to maintain cache without O(n) loop
    /// @dev Uses fullMulDiv for precision and returns 0 instead of sentinel
    /// @param cachedTotal Current cached total liabilities
    /// @param asset The asset that changed
    /// @param oracle The oracle entry for this asset
    /// @param liabilitiesDelta Change in liabilities (can be negative)
    /// @return newTotal Updated total liabilities (can be 0)
    function updateTotalLiabilitiesDelta(
        uint256 cachedTotal,
        IBAMM.Asset storage asset,
        LibStorage.OracleEntry storage oracle,
        int256 liabilitiesDelta
    ) internal view returns (uint256 newTotal) {
        if (liabilitiesDelta == 0) return cachedTotal;

        // Calculate fast TWAP inline
        uint256 timeElapsed = block.timestamp - oracle.lastOracleUpdate;
        uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);
        uint256 timeDelta = block.timestamp - oracle.fastSnapshotTime;
        uint64 fastTWAP = timeDelta == 0 ? oracle.currentPrice : uint64((currentAccum - oracle.fastAccumSnapshot) / timeDelta);

        if (fastTWAP == 0) return cachedTotal;

        uint256 price1e8 = M.b64ToPrice(fastTWAP);

        if (liabilitiesDelta > 0) {
            // Positive delta: add value with fullMulDiv
            uint256 valueDelta = FixedPointMathLib.fullMulDiv(uint256(liabilitiesDelta), price1e8, M.PRICE_PRECISION);
            newTotal = cachedTotal + valueDelta;
        } else {
            // Negative delta: subtract value with fullMulDiv
            uint256 valueDelta = FixedPointMathLib.fullMulDiv(uint256(-liabilitiesDelta), price1e8, M.PRICE_PRECISION);
            newTotal = cachedTotal > valueDelta ? cachedTotal - valueDelta : 0;
        }

        // Return 0 explicitly instead of sentinel - caller should handle
        return newTotal;
    }

    // ========== LP FEE ACCRUAL ==========

    /// @notice Accrue fees to LP token holders via liquidity index
    /// @dev Increases reserves and adjusts liquidityIndex proportionally with fullMulDiv
    /// @param asset Asset storage reference
    /// @param lpState LP state storage reference
    /// @param feeAmount Fee amount to accrue
    function accrueFeesToLPs(
        IBAMM.Asset storage asset,
        IBAMM.LPState storage lpState,
        uint256 feeAmount
    ) internal {
        if (lpState.totalScaledSupply == 0) return;
        if (feeAmount == 0) return;

        // Add fee to reserves
        uint256 oldReserves = asset.reserves;
        asset.reserves = (oldReserves + feeAmount).toUint128();

        // Update liquidity index with fullMulDiv for precision
        // newIndex = oldIndex * newReserves / oldReserves
        if (oldReserves > 0) {
            uint256 newIndex = FixedPointMathLib.fullMulDiv(
                uint256(lpState.liquidityIndex),
                uint256(asset.reserves),
                oldReserves
            );
            lpState.liquidityIndex = newIndex.toUint128();
        }
    }
}
