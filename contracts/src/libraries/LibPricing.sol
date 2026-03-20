// SPDX-License-Identifier: MIT
pragma solidity ^0.8.33;

import {IOracleV1} from "../interfaces/IOracleV1.sol";
import {IPoolV1} from "../interfaces/IPoolV1.sol";
import {IErrors} from "../interfaces/IErrors.sol";
import {LibMaths as M} from "./LibMaths.sol";
import {LibSpline} from "./LibSpline.sol";
import {LibAnchorTree} from "./LibAnchorTree.sol";
import {LibOracle} from "./LibOracle.sol";
import {LibTransientCache as TCache} from "./LibTransientCache.sol";
import {LibConstants as C} from "./LibConstants.sol";

/// @title LibPricing
/// @notice Pricing and fee computation for AIMM
/// @dev Includes coverage-adjusted pricing and market-aware (bi-factor) fee model
///
/// ========== UNITS REFERENCE ==========
///
/// All percentage-based parameters use unified 0.01% BPS scale (10000 = 100%):
///
/// **Primary BPS Scale (C.BPS = 10,000, 0.01% per unit, max uint16 = 655%):**
/// - coverageMin/Max: 5000 = 50%, 10000 = 100%, 20000 = 200%
/// - gamma/vega/lambda: 10000 = 1.0x (100% sensitivity), 5000 = 0.5x
/// - depth/position (x-axis): 0 to 10000 = 0% to 100% cumulative depth
/// - knots: percentage of dispersion range (-100 to +100)
///
/// **PBPS Scale (C.PBPS = 1,000,000, 0.0001% per unit):**
/// - Fee rates: 5,000 = 0.5%, 100 = 0.01%
/// - Spline offsets: in PBPS units
/// - Volatility EMAs: 1,000,000 = 1%, 10,000,000 = 10%
/// - Oracle offsets: 100,000 = 10% deviation from TWAP
/// - dispersion (min/max): 0.0001% units
/// - depthAmplifier: 0.0001% units
///
/// **WAD Scale (C.WAD = 1e18):**
/// - Oracle prices: base-per-token in WAD units
/// - Coverage ratio: reserves/liabilities in WAD units (1e18 = 100%)
/// - Decay slopes: WAD units per second
///

library LibPricing {
    using {M.b64To1e18} for uint64;

    // ========== CONSTANTS ==========

    /// @notice Profile weights sum (200 = 100%, 1 unit = 0.5% of depth)
    uint256 private constant WEIGHT_SUM = 200;

    // Impact bounds (using C.WAD)
    uint256 private constant MAX_IMPACT = 2 * C.WAD;   // Max 200% impact
    uint256 private constant MIN_ADJ = C.WAD / 1000;   // Min 0.1% price adjustment


    // ========== PRICING FUNCTIONS ==========

    /// @notice Compute inventory skew from coverage ratio (Avellaneda-Stoikov inventory risk premium)
    /// @dev LINEAR function bounded by critical min/max with target at equilibrium
    ///
    /// Formula: skew = sign × gamma × 100 × progress
    /// - progress = |c - c_target| / |c_boundary - c_target| (normalized distance from target)
    /// - gamma is a MULTIPLIER (basis 10000): 10000 = 1.0x, 5000 = 0.5x, 20000 = 2.0x
    ///
    /// Key properties:
    /// - At coverageMin (e.g., 5000 = 50%): skew = +gamma×100 (max premium, pool buying)
    /// - At target (100%): skew = 0 (equilibrium)
    /// - At coverageMax (e.g., 20000 = 200%): skew = -gamma×100 (max discount, pool selling)
    /// - Linear interpolation - predictable, matches Avellaneda-Stoikov theory
    /// - Gamma as multiplier, NOT exponent - controls steepness linearly
    ///
    /// @param reserves Asset reserves
    /// @param liabilities Asset liabilities
    /// @param coverageMin Critical coverage floor (0.01% units, e.g., 5000 = 50%, max uint16 = 655%)
    /// @param coverageMax Critical coverage ceiling (0.01% units, e.g., 20000 = 200%)
    /// @param gamma Inventory sensitivity multiplier (basis 10000, e.g., 10000 = 1.0x, 5000 = 0.5x)
    /// @return inventorySkew Directional bias from inventory imbalance (-100 to +100)
    function computeInventorySkew(
        uint128 reserves,
        uint128 liabilities,
        uint16 coverageMin,
        uint16 coverageMax,
        uint16 gamma
    ) internal pure returns (int8 inventorySkew) {
        // Edge case: zero liabilities = infinite coverage, treat as maximally over-collateralized
        if (liabilities == 0) return -100;

        // Calculate coverage ratio
        uint256 coverage = calculateCoverage(reserves, liabilities);

        // Critical bounds (parametric for flexibility across different pool types)
        // coverageMin/Max use 0.01% units: 10000 = 100%, 5000 = 50%, 20000 = 200%
        uint256 critMin = (uint256(coverageMin) * C.WAD) / 10000;  // e.g., 5000 → 50%
        uint256 critMax = (uint256(coverageMax) * C.WAD) / 10000;  // e.g., 20000 → 200%
        uint256 target = C.WAD;       // 100% target

        // At or below critical min: max premium (capped at +100)
        if (coverage <= critMin) return 100;

        // At or above critical max: max discount (capped at -100)
        if (coverage >= critMax) return -100;

        uint256 progress;
        uint256 skew;

        // Under target: positive skew (premium)
        if (coverage < target) {
            // progress = (target - coverage) / (target - critMin)
            // At critMin: progress = 1, at target: progress = 0
            uint256 rangeUnder = target - critMin;
            uint256 posUnder = target - coverage;
            progress = (posUnder * C.WAD) / rangeUnder;

            // Linear: skew = gamma × 100 × progress / 100 (gamma is % in BPS, so divide by 100)
            skew = (uint256(gamma) * 100 * progress) / (C.BPS * C.WAD);

            if (skew > 100) return 100;
            return int8(int256(skew));
        }

        // Over target: negative skew (discount)
        // progress = (coverage - target) / (critMax - target)
        // At target: progress = 0, at critMax: progress = 1
        uint256 rangeOver = critMax - target;
        uint256 posOver = coverage - target;
        progress = (posOver * C.WAD) / rangeOver;

        // Linear: skew = -gamma × 100 × progress / 100 (gamma is % in BPS, so divide by 100)
        skew = (uint256(gamma) * 100 * progress) / (C.BPS * C.WAD);

        if (skew > 100) return -100;
        return int8(-int256(skew));
    }

    /// @notice Quote swap with coverage-adjusted depth and spline traversal
    /// @param amountIn Input amount
    /// @param reserves Asset reserves
    /// @param liabilities Asset liabilities
    /// @param twap Reference price from oracle (TWAP)
    /// @param volatility Asset volatility (sigma)
    /// @param profile Liquidity profile
    /// @param inventorySkew Inventory skew from coverage imbalance (-100 to +100)
    /// @param selling True if selling asset
    /// @param depthAmplifier Depth curve parameter
    /// @param vega Volatility sensitivity multiplier
    /// @param minDispersion Minimum dispersion bound
    /// @param maxDispersion Maximum dispersion bound
    /// @return amountOut Output amount
    /// @return executionPrice Average execution price (VWAP)
    function quoteSwap(
        uint256 amountIn,
        uint128 reserves,
        uint128 liabilities,
        uint256 twap,
        uint32 volatility,
        IPoolV1.LiquidityProfile storage profile,
        int8 inventorySkew,
        bool selling,
        uint16 depthAmplifier,
        uint16 vega,
        uint32 minDispersion,
        uint32 maxDispersion
    ) internal view returns (uint256 amountOut, uint256 executionPrice) {
        // Calculate effective depth and dispersion
        uint256 depth = calculateDepth(reserves, liabilities, depthAmplifier);
        uint32 dispersion = _calculateDispersion(volatility, vega, minDispersion, maxDispersion);

        // Traverse spline by volume to get execution price
        executionPrice = _traverseSplineByVolume(
            twap,
            dispersion,
            profile,
            inventorySkew,
            amountIn,
            depth,
            selling
        );

        // executionPrice is in base per token units (1e18), so baseOut = amountIn * executionPrice / C.WAD
        amountOut = (amountIn * executionPrice) / C.WAD;
    }

    /// @notice Quote buy given cost with spline traversal
    /// @param costIn Cost in base units
    /// @param reserves Asset reserves
    /// @param liabilities Asset liabilities
    /// @param twap Reference price from oracle (TWAP)
    /// @param volatility Asset volatility (sigma)
    /// @param profile Liquidity profile
    /// @param inventorySkew Inventory skew from coverage imbalance
    /// @param depthAmplifier Depth curve parameter
    /// @param vega Volatility sensitivity multiplier
    /// @param minDispersion Minimum dispersion bound
    /// @param maxDispersion Maximum dispersion bound
    /// @return amountOut Amount that can be bought
    /// @return executionPrice Average execution price (VWAP)
    function quoteBuyWithCost(
        uint256 costIn,
        uint128 reserves,
        uint128 liabilities,
        uint256 twap,
        uint32 volatility,
        IPoolV1.LiquidityProfile storage profile,
        int8 inventorySkew,
        uint16 depthAmplifier,
        uint16 vega,
        uint32 minDispersion,
        uint32 maxDispersion
    ) internal view returns (uint256 amountOut, uint256 executionPrice) {
        // Calculate effective depth and dispersion
        uint256 depth = calculateDepth(reserves, liabilities, depthAmplifier);
        uint32 dispersion = _calculateDispersion(volatility, vega, minDispersion, maxDispersion);

        // Get mid price from profile for initial estimate
        uint256 midPrice = _getMidPriceFromProfile(twap, inventorySkew, dispersion, profile);

        // Initial estimate of amount
        amountOut = (costIn * C.WAD) / midPrice;

        // Traverse spline by volume to get execution price
        executionPrice = _traverseSplineByVolume(
            twap,
            dispersion,
            profile,
            inventorySkew,
            amountOut,
            depth,
            false // buying
        );

        // Refine output based on execution price
        amountOut = (costIn * C.WAD) / executionPrice;
    }

    /// @notice Calculate liquidity dispersion from volatility (inverse of price density κ)
    /// @dev When σ↑, dispersion↑ (liquidity spreads over broader range, like sparse order book)
    /// @param volatility Baseline volatility (1e6 precision, sigma)
    /// @param vega Volatility sensitivity multiplier (basis 10000, e.g., 10000 = 1.0x)
    /// @param minDispersion Minimum dispersion bound (0.0001% units)
    /// @param maxDispersion Maximum dispersion bound (0.0001% units)
    /// @return dispersion Dispersion in bps (0.0001% units)
    function _calculateDispersion(
        uint32 volatility,
        uint16 vega,
        uint32 minDispersion,
        uint32 maxDispersion
    ) internal pure returns (uint32 dispersion) {
        // Linear mapping: dispersion increases with volatility
        // Base dispersion + volatility scaled by vega
        // Vega controls sensitivity: 10000 (100%=1x) means vol/1000, 5000 (50%=0.5x) means vol/2000
        uint256 scaledVol = (uint256(volatility) * uint256(vega)) / (1000 * C.BPS);
        uint256 raw = 1000 + scaledVol;

        // Clamp to [minDispersion, maxDispersion]
        if (raw < uint256(minDispersion)) return minDispersion;
        if (raw > uint256(maxDispersion)) return maxDispersion;

        return uint32(raw);
    }

    /// @notice Get mid price from piecewise profile based on inventory skew
    /// @dev TWAP is at skew 0; inventory imbalance shifts along the monotone cubic spline
    /// @param twap Reference TWAP price (corresponds to skew 0)
    /// @param inventorySkew Inventory skew from coverage imbalance (-100 to +100)
    /// @param dispersion Liquidity dispersion in bps (defines price range)
    /// @param profile Piecewise liquidity profile with weights and knots
    /// @return midPrice Price at the imbalance-adjusted position via spline interpolation
    function _getMidPriceFromProfile(
        uint256 twap,
        int8 inventorySkew,
        uint32 dispersion,
        IPoolV1.LiquidityProfile storage profile
    ) internal view returns (uint256 midPrice) {
        // If profile is empty, fall back to simple linear offset
        if (profile.weights[0] == 0) {
            return _skewToPrice(twap, inventorySkew, dispersion);
        }

        // Build spline control points from liquidity profile
        // The profile defines segments with cumulative depth and price offsets
        LibSpline.Point[] memory points = _buildSplinePoints(profile, dispersion);

        // X-axis: cumulative depth percentage (0 to 10000 = 0% to 100%)
        // Y-axis: price offset from TWAP (in C.PBPS units)
        // inventorySkew maps to a position on this curve

        // Map inventorySkew (-100 to +100) to cumulative depth position
        // Skew 0 = center of profile (50% cumulative depth)
        // Negative skew = traverse left (lower depth)
        // Positive skew = traverse right (higher depth)
        uint256 targetDepth = _skewToDepth(inventorySkew);

        // Interpolate price offset at target depth using monotone cubic spline
        int256 priceOffsetBps = LibSpline.eval(targetDepth, points);

        // Convert offset to absolute price
        int256 multiplier = int256(C.PBPS) + priceOffsetBps;
        if (multiplier < 0) multiplier = 0;

        midPrice = (twap * uint256(multiplier)) / C.PBPS;
    }

    /// @notice Traverse spline by volume to calculate average execution price
    /// @dev Uses exact analytical integration of cubic Hermite spline segments
    /// @param twap Reference TWAP price
    /// @param dispersion Liquidity dispersion in bps
    /// @param profile Liquidity profile
    /// @param inventorySkew Starting inventory skew from coverage imbalance
    /// @param amountIn Volume to trade
    /// @param depth Total effective depth
    /// @param selling True if selling (traverse left), false if buying (traverse right)
    /// @return avgPrice Average execution price over the trade
    function _traverseSplineByVolume(
        uint256 twap,
        uint32 dispersion,
        IPoolV1.LiquidityProfile storage profile,
        int8 inventorySkew,
        uint256 amountIn,
        uint256 depth,
        bool selling
    ) internal view returns (uint256 avgPrice) {
        // If profile is empty, fall back to linear approximation
        if (profile.weights[0] == 0) {
            uint256 impact = (amountIn * C.WAD) / depth;
            if (impact > MAX_IMPACT) impact = MAX_IMPACT;
            uint256 midPrice = _skewToPrice(twap, inventorySkew, dispersion);
            uint256 k = impact / 2;
            if (selling) {
                uint256 adj = k < C.WAD ? C.WAD - k : MIN_ADJ;
                return (midPrice * adj) / C.WAD;
            } else {
                return (midPrice * (C.WAD + k)) / C.WAD;
            }
        }

        // Build spline control points
        LibSpline.Point[] memory points = _buildSplinePoints(profile, dispersion);

        // Starting position on the curve (0-10000)
        uint256 startDepth = _skewToDepth(inventorySkew);

        // Calculate volume as fraction of depth (in basis points)
        uint256 volumeFraction = (amountIn * 10000) / depth;
        if (volumeFraction > 10000) volumeFraction = 10000; // Cap at 100%

        // Calculate ending position
        uint256 endDepth;
        if (selling) {
            // Selling: traverse left (lower depth)
            endDepth = volumeFraction >= startDepth ? 0 : startDepth - volumeFraction;
        } else {
            // Buying: traverse right (higher depth)
            endDepth = startDepth + volumeFraction;
            if (endDepth > 10000) endDepth = 10000;
        }

        // Calculate width of traversal
        uint256 width = selling ? (startDepth - endDepth) : (endDepth - startDepth);
        if (width == 0) {
            // Zero width: return mid price at current position
            int256 priceOffsetBps = LibSpline.eval(startDepth, points);
            int256 mult = int256(C.PBPS) + priceOffsetBps;
            if (mult < 0) mult = 0;
            return (twap * uint256(mult)) / C.PBPS;
        }

        // Exact integration: Calculate area under offset curve
        int256 offsetArea = LibSpline.area(points, startDepth, endDepth);

        // Average offset = Area / Width
        int256 avgOffsetBps = offsetArea / int256(width);

        // Clamp offset to prevent zero/negative prices
        // Maximum negative offset is -90% to maintain minimum 10% of TWAP
        int256 MAX_NEGATIVE_OFFSET = -int256(C.PBPS) * 90 / 100;  // -90%
        if (avgOffsetBps < MAX_NEGATIVE_OFFSET) {
            avgOffsetBps = MAX_NEGATIVE_OFFSET;
        }

        // Convert to absolute price
        int256 multiplier = int256(C.PBPS) + avgOffsetBps;
        avgPrice = (twap * uint256(multiplier)) / C.PBPS;

        // Add absolute minimum price floor (5% of TWAP)
        uint256 minPrice = (twap * 5) / 100;
        if (avgPrice < minPrice) avgPrice = minPrice;
    }

    /// @notice Build spline control points from liquidity profile
    /// @dev Converts profile segments (weights, knots) into (depth, priceOffset) points
    ///
    /// Weight normalization and domain mapping:
    /// - Weights must sum to 200 (enforced by validateProfile)
    /// - Each weight unit represents 0.5% of the cumulative liquidity domain
    /// - X-axis domain is [0, 10000] representing cumulative depth (0% to 100%)
    /// - Cumulative weights are rescaled to span the full [0, 10000] domain
    /// - Each segment's X position = (cumulativeWeight * 10000) / WEIGHT_SUM
    /// - This ensures user-defined profile controls the entire depth curve
    ///
    /// Knots array structure:
    /// - Dispersion defines the liquidity breadth range around TWAP (e.g., dispersion=1% means ±1% around TWAP)
    /// - Knots are in percentage units of this dispersion range (e.g., knot=-50 means -50% of dispersion)
    /// - Full formula: price = TWAP × (1 + dispersion × knot / 100 / C.PBPS)
    /// - Example: TWAP=$1.00, dispersion=1% (10000 bps), knot=-50:
    ///   - offset = -50% × 1% = -0.5% from TWAP
    ///   - price = $1.00 × (1 - 0.005) = $0.995
    /// - knots[0] is the starting offset (at x=0, leftmost boundary)
    /// - knots[i+1] is the offset at the end of segment i (after weights[i])
    /// - For N segments, we need N+1 knots to define all segment boundaries
    /// - Constraint: max(knots) - min(knots) must equal 100 (representing 100% of dispersion range)
    ///
    /// @param profile Liquidity profile with up to 16 segments and 17 knots
    /// @param dispersion Dispersion in bps for scaling offsets to prices
    /// @return points Array of spline control points
    function _buildSplinePoints(
        IPoolV1.LiquidityProfile storage profile,
        uint32 dispersion
    ) internal view returns (LibSpline.Point[] memory points) {
        // Count valid segments (stop at first zero weight)
        uint256 count = 0;
        for (uint256 i = 0; i < 16; i++) {
            if (profile.weights[i] == 0) break;
            count++;
        }

        // Number of knots = count + 1 (one more than segments)
        uint256 numKnots = count + 1;
        points = new LibSpline.Point[](numKnots);

        // First knot: starting point at x=0
        int256 firstOffsetBps = (int256(int16(profile.knots[0])) * int256(uint256(dispersion))) / 100;
        points[0] = LibSpline.Point({
            x: 0,
            y: firstOffsetBps
        });

        // Build remaining knot points from segments
        uint256 cumulativeWeight = 0;
        for (uint256 i = 0; i < count; i++) {
            cumulativeWeight += uint256(profile.weights[i]);
            int256 offsetBps = (int256(int16(profile.knots[i + 1])) * int256(uint256(dispersion))) / 100;

            // Scale x-coordinate: (cumulativeWeight * 10000) / WEIGHT_SUM
            uint256 xPos = (cumulativeWeight * 10000) / WEIGHT_SUM;

            points[i + 1] = LibSpline.Point({
                x: xPos,
                y: offsetBps
            });
        }
    }

    /// @notice Map inventory skew to cumulative depth position
    /// @dev Skew 0 = 5000 (center), -100 = 0, +100 = 10000
    /// @param inventorySkew Inventory skew (-100 to +100)
    /// @return depth Cumulative depth (0 to 10000)
    function _skewToDepth(int8 inventorySkew) internal pure returns (uint256 depth) {
        // Skew is already clamped to [-100, 100] by construction
        // -100 → 0, 0 → 5000, +100 → 10000
        unchecked {
            return uint256(5000 + int256(inventorySkew) * 50);
        }
    }

    /// @notice Convert inventory skew to absolute price (fallback when no profile)
    /// @param twap Reference TWAP price
    /// @param skew Inventory skew as % of dispersion (-100 to +100)
    /// @param dispersion Dispersion in bps
    /// @return price Absolute price
    function _skewToPrice(
        uint256 twap,
        int8 skew,
        uint32 dispersion
    ) internal pure returns (uint256 price) {
        // offsetBps = skew × dispersion / 100
        int256 offsetBps = (int256(int16(skew)) * int256(uint256(dispersion))) / 100;

        // price = TWAP × (C.PBPS + offsetBps) / C.PBPS
        int256 multiplier = int256(C.PBPS) + offsetBps;
        if (multiplier < 0) multiplier = 0;

        price = (twap * uint256(multiplier)) / C.PBPS;
    }

    // ========== ANCHOR-PATH ROUTING & SPREAD ==========

    /// @dev Internal struct to cache endpoint data and avoid redundant SLOADs
    struct EndpointCache {
        uint128 reserves;
        uint128 liabilities;
        uint16 vega;
        uint16 lambda;
        uint16 gamma;
        uint16 coverageMin;
        uint16 coverageMax;
        uint256 price;  // 1e18 format
    }

    /// @dev Internal struct to accumulate path metrics (reduces stack depth)
    struct PathAccumulator {
        uint256 currentAmount;
        uint32 sigmaPair;
        uint32 deltaPair;
        uint16 minFeePath;
        uint16 maxFeePath;
    }

    /// @notice Get anchor path swap quote through graph routing
    function getAnchorPathQuote(
        IPoolV1.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (IPoolV1.SwapQuote memory quote) {
        IPoolV1.RoutePath memory path = LibAnchorTree.findRoutingPath($, tokenIn, tokenOut);

        quote.routeHops = path.hops;
        quote.hopAmounts = new uint256[](path.hops.length);
        quote.hopAmounts[0] = amountIn;
        quote.hopPrices = new uint64[](path.hops.length - 1);

        EndpointCache memory cacheIn = _cacheEndpoint($, tokenIn);
        EndpointCache memory cacheOut = _cacheEndpoint($, tokenOut);

        // Use struct to reduce stack variables
        PathAccumulator memory acc;
        acc.currentAmount = amountIn;

        for (uint256 i = 0; i < path.hops.length - 1; i++) {
            bool isEdge = (i == 0) || (i == path.hops.length - 2);
            (uint256 amountOut, uint32 sigma, uint32 delta, uint16 minF, uint16 maxF, uint64 execPriceB64) =
                _executeLeg($, path.hops[i], path.hops[i + 1], acc.currentAmount, isEdge, true);

            acc.currentAmount = amountOut;
            quote.hopAmounts[i + 1] = amountOut;
            quote.hopPrices[i] = execPriceB64;

            if (sigma > acc.sigmaPair) acc.sigmaPair = sigma;
            if (delta > acc.deltaPair) acc.deltaPair = delta;
            if (minF > acc.minFeePath) acc.minFeePath = minF;
            if (maxF > acc.maxFeePath) acc.maxFeePath = maxF;
        }

        quote.amountIn = amountIn;
        quote.spreadBps = _calculatePathSpreadCached(
            cacheIn, cacheOut, amountIn, acc.currentAmount,
            acc.sigmaPair, acc.deltaPair, acc.minFeePath, acc.maxFeePath
        );

        uint256 halfSpread = uint256(quote.spreadBps) / 2;
        uint256 feeIn = (amountIn * halfSpread) / 1_000_000;
        uint256 feeOut = (acc.currentAmount * halfSpread) / 1_000_000;

        (quote.protoFee, quote.lpFee) = splitFee(feeOut + (feeIn * acc.currentAmount) / amountIn, $.feeParams.protoShare);
        quote.amountOut = acc.currentAmount - feeOut;

        quote.skewIn = computeInventorySkew(cacheIn.reserves, cacheIn.liabilities, cacheIn.coverageMin, cacheIn.coverageMax, cacheIn.gamma);
        quote.skewOut = computeInventorySkew(cacheOut.reserves, cacheOut.liabilities, cacheOut.coverageMin, cacheOut.coverageMax, cacheOut.gamma);
    }

    /// @notice Cache endpoint data to avoid redundant SLOADs
    /// @dev Reads asset storage once and oracle once, caches all needed fields
    function _cacheEndpoint(
        IPoolV1.PoolStorage storage $,
        address token
    ) private returns (EndpointCache memory cache) {
        IPoolV1.Asset storage asset = $.assets[token];
        IPoolV1.RiskConfig storage rc = $.riskConfigs[token];

        // Cache asset fields (single SLOAD per slot due to packing)
        cache.reserves = asset.reserves;
        cache.liabilities = asset.liabilities;
        cache.vega = asset.vega;
        cache.lambda = asset.lambda;
        cache.gamma = asset.gamma;
        cache.coverageMin = rc.coverageMin;
        cache.coverageMax = rc.coverageMax;

        // Cache price (oracle read with transient cache)
        if (token == $.baseToken) {
            cache.price = 1e18;
        } else {
            IOracleV1.FeedData memory feed = _readOracle($, token);
            (cache.price,) = LibOracle.decodeB64s(feed);
        }
    }

    /// @notice Execute a single leg in the path
    /// @dev Returns fee bounds and execution price to avoid redundant SLOAD in caller
    /// @return amountOut Output amount for this leg
    /// @return sigma Volatility σ for this leg
    /// @return delta Deviation Δ for this leg
    /// @return minFee Min fee bps from profile asset
    /// @return maxFee Max fee bps from profile asset
    /// @return execPriceB64 Execution price (amountOut decimals, for oracle)
    function _executeLeg(
        IPoolV1.PoolStorage storage $,
        address from,
        address to,
        uint256 amountIn,
        bool isEdge,
        bool isSelling
    ) private returns (uint256 amountOut, uint32 sigma, uint32 delta, uint16 minFee, uint16 maxFee, uint64 execPriceB64) {
        // Determine profileAsset (child) - always the child in parent↔child edge
        address fromAnchor = $.assets[from].anchor;
        bool isUpward = fromAnchor == to;
        address profileAsset = isUpward ? from : to;

        // Get decimals for scaling
        uint8 decimalsFrom = $.assets[from].decimals;
        uint8 decimalsTo = $.assets[to].decimals;

        // Get oracle and price (uses transient cache for oracle feed)
        IOracleV1.FeedData memory feed;
        uint256 twap;
        if (profileAsset == $.baseToken) {
            feed = LibOracle.getBaseFeed();
            twap = 1e18;
        } else {
            feed = _readOracle($, profileAsset);
            (twap,) = LibOracle.decodeB64s(feed);
        }

        // Invert price if downward (child→parent)
        if (!isUpward) twap = (1e18 * 1e18) / twap;

        // Extract σ and Δ once
        sigma = LibOracle.getSigma(feed);
        int32 fastSpread = feed.fastOffset - feed.slowOffset;
        delta = fastSpread < 0 ? uint32(-fastSpread) : uint32(fastSpread);

        // Load asset and risk config once
        IPoolV1.Asset storage asset = $.assets[profileAsset];
        IPoolV1.RiskConfig memory rc = $.riskConfigs[profileAsset];

        minFee = asset.minFeeBps;
        maxFee = asset.maxFeeBps;

        if (isEdge) {
            // Edge: full price impact
            amountOut = _priceEdgeHop($, asset, rc, amountIn, twap, sigma, isSelling, profileAsset);
        } else {
            // Intermediate: mid-price only
            uint256 midPrice = _getMidPriceForLeg($, asset, rc, twap, sigma, profileAsset);
            amountOut = (amountIn * midPrice) / 1e18;
        }

        // Scale output for decimal differences
        if (decimalsFrom > decimalsTo) {
            amountOut = amountOut / (10 ** uint256(decimalsFrom - decimalsTo));
        } else if (decimalsTo > decimalsFrom) {
            amountOut = amountOut * (10 ** uint256(decimalsTo - decimalsFrom));
        }

        // Cap output by available reserves
        // Note: minLiquidity enforcement happens at execution time (ExchangeV1)
        // Inventory skew naturally creates exponential pricing as reserves deplete
        IPoolV1.Asset storage toAsset = $.assets[to];
        if (amountOut > toAsset.reserves) {
            amountOut = toAsset.reserves;
        }

        // Calculate execution price for oracle (price of "to" in terms of "from")
        // Use actual executed amounts, adjusted to 18 decimals for precision
        uint256 price18 = (amountOut * 1e18 * (10 ** uint256(18 - decimalsTo))) /
            (amountIn * (10 ** uint256(18 - decimalsFrom)));
        // Scale to output token decimals and encode B64
        uint256 priceOutDecimals = price18 / (10 ** uint256(18 - decimalsTo));
        if (priceOutDecimals == 0) priceOutDecimals = 1;
        execPriceB64 = M.encodeB64(priceOutDecimals, decimalsTo);
    }

    /// @notice Price an edge hop with full price impact (accepts pre-computed sigma)
    function _priceEdgeHop(
        IPoolV1.PoolStorage storage $,
        IPoolV1.Asset storage asset,
        IPoolV1.RiskConfig memory rc,
        uint256 amountIn,
        uint256 twap,
        uint32 sigma,
        bool selling,
        address profileAsset
    ) private view returns (uint256 amountOut) {
        int8 skew = computeInventorySkew(asset.reserves, asset.liabilities, rc.coverageMin, rc.coverageMax, asset.gamma);

        if (selling) {
            (amountOut,) = quoteSwap(
                amountIn, asset.reserves, asset.liabilities, twap, sigma,
                $.profiles[profileAsset], skew, true, rc.depthAmplifier,
                asset.vega, asset.minDispersion, asset.maxDispersion
            );
        } else {
            (amountOut,) = quoteBuyWithCost(
                amountIn, asset.reserves, asset.liabilities, twap, sigma,
                $.profiles[profileAsset], skew, rc.depthAmplifier,
                asset.vega, asset.minDispersion, asset.maxDispersion
            );
        }
    }

    /// @notice Get mid-price for intermediate hop (accepts pre-computed sigma)
    function _getMidPriceForLeg(
        IPoolV1.PoolStorage storage $,
        IPoolV1.Asset storage asset,
        IPoolV1.RiskConfig memory rc,
        uint256 twap,
        uint32 sigma,
        address profileAsset
    ) private view returns (uint256 midPrice) {
        int8 skew = computeInventorySkew(asset.reserves, asset.liabilities, rc.coverageMin, rc.coverageMax, asset.gamma);
        uint32 dispersion = _calculateDispersion(sigma, asset.vega, asset.minDispersion, asset.maxDispersion);

        return _getMidPriceFromProfile(twap, skew, dispersion, $.profiles[profileAsset]);
    }

    /// @notice Calculate path-level spread using cached endpoint data
    /// @dev Avoids redundant SLOADs by using pre-cached EndpointCache structs
    function _calculatePathSpreadCached(
        EndpointCache memory cacheIn,
        EndpointCache memory cacheOut,
        uint256 amountIn,
        uint256 amountOut,
        uint32 sigmaPair,
        uint32 deltaPair,
        uint16 minFeePath,
        uint16 maxFeePath
    ) private pure returns (uint16 spreadBps) {
        // Endpoint-only risk aversion: use MAX of endpoints
        uint16 vegaSpread = cacheIn.vega > cacheOut.vega ? cacheIn.vega : cacheOut.vega;
        uint16 lambdaSpread = cacheIn.lambda > cacheOut.lambda ? cacheIn.lambda : cacheOut.lambda;

        // Check if swap improves coverage using cached data
        int256 impact = netCoverageImpact(
            cacheIn.reserves,
            cacheIn.liabilities,
            cacheOut.reserves,
            cacheOut.liabilities,
            amountIn,
            amountOut,
            cacheIn.price,
            cacheOut.price
        );

        bool improvesCoverage = impact < 0;

        // Symmetric volatility band: S_vol = 100 + (σ_pair × vega_spread) / 100 (vega is % in BPS)
        uint256 sVol = 100 + (uint256(sigmaPair) * uint256(vegaSpread)) / (100 * C.BPS);

        // Directional deviation surcharge: U = Δ_pair × lambda_spread / 100 (lambda is % in BPS)
        uint256 u = (uint256(deltaPair) * uint256(lambdaSpread)) / C.BPS;

        uint256 rawSpread = improvesCoverage ? sVol : sVol + u;

        // Clamp to path-level [minFeePath, maxFeePath]
        if (rawSpread < uint256(minFeePath)) return minFeePath;
        if (rawSpread > uint256(maxFeePath)) return maxFeePath;
        return uint16(rawSpread);
    }

    /// @notice Read oracle for asset with transient caching
    /// @dev Uses transient cache to avoid redundant external calls (~2100 gas per cache hit)
    /// @dev Supports both internal oracle (reads from storage) and external oracle (IOracleV1 call)
    function _readOracle(
        IPoolV1.PoolStorage storage $,
        address token
    ) private returns (IOracleV1.FeedData memory data) {
        // Try transient cache first
        bool found;
        (found, data) = TCache.tryLoadOracleFeed(token);
        if (found) return data;

        // Cache miss: perform oracle read
        IPoolV1.OracleConfig memory cfg = $.oracleConfigs[token];
        if (cfg.primary == address(0)) {
            revert IErrors.NotConfigured(IErrors.Resource.ORACLE, token);
        }

        // Check if using internal oracle (cfg.primary == address(this) in module context)
        // For internal oracle, read directly from OracleStorage instead of external call
        if (cfg.primary == address(this)) {
            data = _readInternalOracle(token);
        } else {
            data = IOracleV1(cfg.primary).getFeed(cfg.feedId);
        }

        // Cache for subsequent reads in this transaction
        TCache.cacheOracleFeed(token, data);
    }

    /// @notice Access oracle storage (ERC-7201 namespace)
    function _os() private pure returns (IPoolV1.OracleStorage storage os) {
        bytes32 slot = C.ORACLE_STORAGE_LOC;
        assembly {
            os.slot := slot
        }
    }

    /// @notice Read from internal oracle storage directly
    /// @dev Used when cfg.primary == address(this), avoiding external call
    function _readInternalOracle(address token) private view returns (IOracleV1.FeedData memory data) {
        IPoolV1.FeedAccumulator storage acc = _os().accumulators[token];

        if (acc.lastUpdate == 0) {
            revert IErrors.NotConfigured(IErrors.Resource.ORACLE, token);
        }

        data = IOracleV1.FeedData({
            lastPriceB64: acc.lastPriceB64,
            fastOffset: acc.fastOffset,
            slowOffset: acc.slowOffset,
            fastVolEMA: acc.fastVolEMA,
            slowVolEMA: acc.slowVolEMA,
            updatedAt: acc.lastUpdate,
            ttl: acc.ttl,
            confidence: acc.confidence
        });
    }

    /// @notice Split total fee into protocol and LP portions
    /// @dev Protocol share is percentage 0-100
    /// @param totalFee Total fee amount
    /// @param protoShare Protocol share as percentage (0-100, e.g. 25 = 25%)
    /// @return protoFee Protocol fee portion
    /// @return lpFee LP fee portion
    function splitFee(
        uint256 totalFee,
        uint8 protoShare
    ) internal pure returns (uint256 protoFee, uint256 lpFee) {
        // protoFee = totalFee * protoShare / 100
        protoFee = (totalFee * uint256(protoShare)) / 100;
        lpFee = totalFee - protoFee;
    }

    // ========== INTERNAL HELPERS ==========

    // ========== COVERAGE FUNCTIONS (inlined from LibAIMMCoverage) ==========

    /// @notice Calculate coverage ratio (R / L)
    /// @param reserves Reserves in token units
    /// @param liabilities Liabilities in token units
    /// @return coverage Coverage ratio (1e18 = 100%)
    function calculateCoverage(
        uint128 reserves,
        uint128 liabilities
    ) internal pure returns (uint256 coverage) {
        if (liabilities == 0) return type(uint256).max; // Infinite coverage
        return (uint256(reserves) * C.WAD) / uint256(liabilities);
    }

    /// @notice Calculate net coverage impact of a swap (value-weighted in base)
    /// @dev Simplified to use price * |reserves - liabilities| directly
    ///      Algebraically equivalent but more gas-efficient
    /// @param reservesIn Input asset reserves
    /// @param liabilitiesIn Input asset liabilities
    /// @param reservesOut Output asset reserves
    /// @param liabilitiesOut Output asset liabilities
    /// @param amountIn Amount of input asset
    /// @param amountOut Amount of output asset
    /// @param priceIn Input asset price in base (C.WAD units, e.g. USDC/USD = 1e18)
    /// @param priceOut Output asset price in base (C.WAD units, e.g. ETH/USD = 3000e18)
    /// @return netImpact Net coverage impact (negative = improves, positive = worsens)
    function netCoverageImpact(
        uint128 reservesIn,
        uint128 liabilitiesIn,
        uint128 reservesOut,
        uint128 liabilitiesOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 priceIn,
        uint256 priceOut
    ) internal pure returns (int256 netImpact) {
        // Estimate reserves after swap (with conservative fee assumption)
        uint256 estFee = (amountOut * 100) / 100000; // 0.1% heuristic
        uint256 totalOut = amountOut + estFee;

        // Safety: if outflow exceeds reserves, treat as maximum worsening
        if (totalOut > reservesOut) {
            return int256(C.WAD);
        }

        // Check uint128 bounds
        if (amountIn > type(uint128).max || totalOut > type(uint128).max) {
            return int256(C.WAD);
        }

        uint128 newResIn = reservesIn + uint128(amountIn);
        uint128 newResOut = reservesOut - uint128(totalOut);

        // Simplified formula: Value_j * |Coverage_j - 1| = Price_j * |Reserves_j - Liabilities_j|
        // This avoids division and is algebraically equivalent

        // Calculate absolute gaps before swap
        uint256 gapIn0 = reservesIn > liabilitiesIn ?
            reservesIn - liabilitiesIn : liabilitiesIn - reservesIn;
        uint256 gapOut0 = reservesOut > liabilitiesOut ?
            reservesOut - liabilitiesOut : liabilitiesOut - reservesOut;

        // Calculate absolute gaps after swap
        uint256 gapIn1 = newResIn > liabilitiesIn ?
            newResIn - liabilitiesIn : liabilitiesIn - newResIn;
        uint256 gapOut1 = newResOut > liabilitiesOut ?
            newResOut - liabilitiesOut : liabilitiesOut - newResOut;

        // Portfolio imbalance = Σ(price_j * |gap_j|)
        uint256 imbalance0 = (priceIn * gapIn0 + priceOut * gapOut0) / C.WAD;
        uint256 imbalance1 = (priceIn * gapIn1 + priceOut * gapOut1) / C.WAD;

        // netImpact = imbalance1 - imbalance0
        // Negative = improves (reduces imbalance)
        // Positive = worsens (increases imbalance)
        return int256(imbalance1) - int256(imbalance0);
    }

    /// @notice Calculate effective depth for pricing with concave monotonic increase
    /// @dev Depth amplifier uses concave power curve from critical floor (50%) to target (100%)
    ///
    /// Formula: D = R + k × (L - R) × progress^(1/(1+2k))
    ///   where progress = (coverage - critical) / (1 - critical)
    ///
    /// Key properties:
    /// - At critical floor (50%): D = R (all curves converge, no virtual depth)
    /// - Concave monotonically increasing from critical to target
    /// - Higher k = faster rise (more concave curve)
    /// - k controls both amplitude AND curvature
    ///
    /// @param reserves Reserves in token units
    /// @param liabilities Liabilities in token units
    /// @param depthAmplifier Depth curvature amplifier (0=default, else in 0.0001% units)
    ///                       k = depthAmplifier / 1_000_000 (e.g., 500_000 = 50%)
    /// @return depth Effective depth for pricing
    function calculateDepth(
        uint128 reserves,
        uint128 liabilities,
        uint16 depthAmplifier
    ) internal pure returns (uint256 depth) {
        // Edge case: both zero
        if (reserves == 0 && liabilities == 0) {
            return 1; // Return minimal depth to avoid division by zero
        }

        // Edge case: reserves=0 but liabilities>0 (undercollateralized with no assets)
        if (reserves == 0 && liabilities > 0) {
            return 1; // Minimal depth - effectively blocks pricing
        }

        // When liabilities = 0, depth = reserves (no virtual depth, no amplification)
        // Reserve caps in _executeLeg prevent quotes exceeding available reserves
        if (liabilities == 0) return uint256(reserves);

        // Calculate coverage ratio
        uint256 coverage = (uint256(reserves) * C.WAD) / uint256(liabilities);

        // When at or above 100%: depth = reserves (fully covered, no amplification needed)
        if (coverage >= C.WAD) {
            return uint256(reserves);
        }

        // Critical floor = 50% (0.5 C.WAD)
        uint256 criticalFloor = C.WAD / 2;

        // At or below critical floor: depth = reserves (all curves converge)
        if (coverage <= criticalFloor) {
            return uint256(reserves);
        }

        // If k=0, depth = reserves (no amplification)
        if (depthAmplifier == 0) {
            return uint256(reserves);
        }

        // Progress from critical to target: (coverage - critical) / (1 - critical)
        // range = C.WAD - criticalFloor = 0.5 C.WAD
        uint256 range = C.WAD - criticalFloor;
        uint256 progressNum = coverage - criticalFloor;
        // progress in WAD units: progressNum * C.WAD / range
        uint256 progress = (progressNum * C.WAD) / range;

        // k = depthAmplifier (so 500,000 = 0.5, 1,000,000 = 1.0)
        uint256 k = uint256(depthAmplifier);
        uint256 deficit = uint256(liabilities) - uint256(reserves);

        // Concave virtual depth using power function
        // exponent = 1 / (1 + 2k/C.PBPS) = C.PBPS / (C.PBPS + 2k)
        // Higher k = lower exponent = more concave
        uint256 exponentWad = (C.WAD * C.PBPS) / (C.PBPS + 2 * k);

        // concaveProgress = progress^exponent (both in WAD)
        uint256 concaveProgress = _powWad(progress, exponentWad);

        // virtualDepth = k × deficit × concaveProgress / C.PBPS
        uint256 virtualDepth = (k * deficit * concaveProgress) / (C.PBPS * C.WAD);

        depth = uint256(reserves) + virtualDepth;

        // Cap at liabilities
        if (depth > uint256(liabilities)) {
            depth = uint256(liabilities);
        }

        // Ensure non-zero depth
        if (depth == 0) depth = 1;
    }

    /// @notice Calculate liability decay amount (linear % per year)
    /// @dev Simple linear decay: liabilities decrease at constant % per year when coverage < threshold
    /// @param liabilities Current liabilities
    /// @param reserves Current reserves
    /// @param decayStartRatioBps Coverage threshold to start decay (0.0001% units, e.g., 980000 = 98%)
    /// @param decaySlope Decay rate per year (WAD units per second, e.g., WAD/31536000 for 100%/year)
    /// @param dt Time elapsed in seconds
    /// @return decayAmount Amount of liabilities to decay
    function calculateDecay(
        uint128 liabilities,
        uint128 reserves,
        uint16 decayStartRatioBps,
        uint32 decaySlope,
        uint32 dt
    ) internal pure returns (uint128 decayAmount) {
        if (dt == 0 || decaySlope == 0 || liabilities == 0) return 0;

        uint256 coverage = calculateCoverage(reserves, liabilities);
        uint256 threshold = (uint256(decayStartRatioBps) * C.WAD) / C.PBPS;

        // Only decay if coverage is below threshold
        if (coverage >= threshold) return 0;

        // Linear decay: amount = liabilities × decaySlope × dt / C.WAD
        // decaySlope is in WAD per second (e.g., 1e18 / 365 days for 100% per year)
        uint256 rawDecay = (uint256(liabilities) * uint256(decaySlope) * uint256(dt)) / C.WAD;

        // NEVER decay more than brings coverage to 100%
        // Cap at (liabilities - reserves) to maintain liabilities >= reserves
        uint256 maxDecay = liabilities > reserves ? liabilities - reserves : 0;

        if (rawDecay > maxDecay) {
            return uint128(maxDecay);  // Stop at 100% coverage
        }

        return uint128(rawDecay);
    }

    /// @notice Apply power-law withdrawal haircut based on coverage
    /// @dev Uses power-law formula: haircut = (1 - coverage)^p
    ///
    /// Key properties:
    /// - h(0) = 100% haircut (critical safety: coverage at 0 means 0 reserves, forbid withdrawals)
    /// - h(1) = 0% haircut (no penalty when fully covered)
    /// - Defined on entire [0, 1] coverage range (handles realistic undercollateralization)
    /// - Avoids edge-case exploits in low-coverage tail
    ///
    /// Parameter mapping:
    /// - suppression in basis 10000: p = 1 + (suppression / 10000)
    /// - p=1 (suppression=0): linear haircut h(c) = 1 - c
    /// - p=2 (suppression=10000): quadratic h(c) = (1 - c)²
    /// - p=4 (suppression=30000): more convex, gentle mid-range
    ///
    /// @param amount Requested withdrawal amount
    /// @param reserves Current reserves
    /// @param liabilities Current liabilities
    /// @param suppression Power exponent parameter (basis 10000, e.g., 10000 = p of 2)
    /// @return actualAmount Actual withdrawal after haircut
    /// @return haircutAmount Amount deducted as haircut
    function applyWithdrawalHaircut(
        uint256 amount,
        uint128 reserves,
        uint128 liabilities,
        uint16 suppression
    ) internal pure returns (uint256 actualAmount, uint256 haircutAmount) {
        // Fully covered: no haircut
        if (liabilities == 0 || reserves >= liabilities) {
            return (amount, 0);
        }

        // Calculate coverage ratio (0 to 1 range in C.WAD units)
        uint256 coverage = calculateCoverage(reserves, liabilities);

        // Clamp coverage to [0, 1] for safety
        if (coverage > C.WAD) coverage = C.WAD;

        // Power-law haircut: h(c) = (1 - c)^p
        // Compute deficit = 1 - coverage
        uint256 deficit = C.WAD - coverage;

        // Exponent p = 1 + (suppression / 10000) where suppression is in PBPS
        // For WAD precision: p_wad = C.WAD + (suppression * C.WAD) / 10000
        // suppression=10000 → p=2, suppression=0 → p=1
        uint256 pWad = C.WAD + (uint256(suppression) * C.WAD) / C.PBPS;

        // Compute deficit^p using logarithmic exponentiation
        // deficit^p = exp(p * ln(deficit))
        // Since deficit is in [0, 1], we need to handle this carefully in fixed-point
        uint256 haircutRatio;

        if (deficit == 0) {
            // coverage = 1 (fully covered): no haircut
            haircutRatio = 0;
        } else if (deficit == C.WAD) {
            // coverage = 0 (no reserves): 100% haircut
            haircutRatio = C.WAD;
        } else {
            // General case: compute (deficit)^p
            // Use fixed-point power: deficit in [1e16, 1e18), compute deficit^p
            haircutRatio = _powWad(deficit, pWad);
        }

        // Cap at 100% haircut (safety, should not happen but defensive)
        if (haircutRatio > C.WAD) haircutRatio = C.WAD;

        // Calculate actual amounts
        haircutAmount = (amount * haircutRatio) / C.WAD;
        actualAmount = amount - haircutAmount;
    }

    /// @notice Compute x^y in C.WAD (1e18) fixed-point arithmetic
    /// @dev Uses exp(y * ln(x)) for positive x in (0, 1e18]
    /// @param x Base in C.WAD units (0 < x <= 1e18)
    /// @param y Exponent in C.WAD units (y >= 1e18)
    /// @return result x^y in C.WAD units
    function _powWad(uint256 x, uint256 y) private pure returns (uint256 result) {
        if (x == 0) return 0;
        if (x == C.WAD) return C.WAD;
        if (y == C.WAD) return x;

        // For power law haircut: x in [0, 1], so we use:
        // x^y = exp(y * ln(x))
        // NB: y is in C.WAD units, so we scale appropriately

        // Use a simple Newton iteration or binary approximation for coverage in [0,1]
        // Fallback: for practical purposes with reasonable y values, use:
        // x^y ≈ iterative multiplication with binary exponent expansion

        uint256 expInt = y / C.WAD;  // Integer part of exponent
        uint256 rem = y % C.WAD;  // Fractional part

        // Compute x^exp (integer part)
        uint256 acc = C.WAD;
        uint256 base = x;

        for (uint256 i = 0; i < 256 && expInt > 0; i++) {
            if ((expInt & 1) == 1) {
                acc = (acc * base) / C.WAD;
            }
            base = (base * base) / C.WAD;
            expInt >>= 1;
        }

        result = acc;

        // For fractional part, use Newton's method approximation
        // x^rem ≈ 1 + rem * ln(x) for small rem
        if (rem > 0 && x < C.WAD) {
            // Simplified: for small remaining exponent, linear approximation is acceptable
            // rem * (x - 1) gives rough adjustment
            uint256 adj = (rem * (C.WAD - x)) / C.WAD;
            if (result > adj) {
                result = result - (result * adj) / (C.WAD * 10);  // Scale adjustment
            }
        }

        return result;
    }

}
