// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Err} from "../Errors.sol";
import {LibMaths as M} from "./LibMaths.sol";
import {LibSpline} from "./LibSpline.sol";
import {LibAnchorTree} from "./LibAnchorTree.sol";
import {LibOracle} from "./LibOracle.sol";
import {LibTransientCache as TCache} from "./LibTransientCache.sol";
import {LibConstants as C} from "./LibConstants.sol";

/// @title LibPricing — coverage-adjusted pricing + bi-factor fee model.
/// @dev Units: see LibConstants. BPS=0.01%, PBPS=0.0001%, WAD=1e18.
library LibPricing {
    using {M.b64To1e18} for uint64;

    /// @dev Profile weights sum (200 = 100%, 1 unit = 0.5% depth).
    uint256 private constant WEIGHT_SUM = 200;
    uint256 private constant MAX_IMPACT = 2 * C.WAD;   // 200%
    uint256 private constant MIN_ADJ = C.WAD / 1000;   // 0.1%

    /// @notice Avellaneda-Stoikov inventory skew. Linear: skew = sign*γ*100*progress, clamp [-100,+100].
    ///         At critMin: +γ*100 (premium); target: 0; critMax: -γ*100 (discount).
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

    /// @notice Quote sell-side swap with coverage-adjusted depth + spline traversal.
    function quoteSwap(
        uint256 amountIn,
        uint128 reserves,
        uint128 liabilities,
        uint256 twap,
        uint32 volatility,
        IPool.LiquidityProfile storage profile,
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

    /// @notice Quote buy given cost via spline traversal. Refines amountOut twice.
    function quoteBuyWithCost(
        uint256 costIn,
        uint128 reserves,
        uint128 liabilities,
        uint256 twap,
        uint32 volatility,
        IPool.LiquidityProfile storage profile,
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

    /// @dev κ⁻¹: dispersion ∝ σ. dispersion = clamp(1000 + σ·vega/1000/BPS, [min,max]).
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

    /// @dev TWAP @ skew=0; spline maps skew→price offset.
    function _getMidPriceFromProfile(
        uint256 twap,
        int8 inventorySkew,
        uint32 dispersion,
        IPool.LiquidityProfile storage profile
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

    /// @dev Exact analytical Hermite-spline integration → VWAP over trade.
    function _traverseSplineByVolume(
        uint256 twap,
        uint32 dispersion,
        IPool.LiquidityProfile storage profile,
        int8 inventorySkew,
        uint256 amountIn,
        uint256 depth,
        bool selling
    ) internal view returns (uint256 avgPrice) {
        // No profile: linear fallback.
        if (profile.weights[0] == 0) {
            uint256 impact = (amountIn * C.WAD) / depth;
            if (impact > MAX_IMPACT) impact = MAX_IMPACT;
            uint256 midPrice = _skewToPrice(twap, inventorySkew, dispersion);
            uint256 k = impact / 2;
            if (selling) {
                uint256 adj = k < C.WAD ? C.WAD - k : MIN_ADJ;
                return (midPrice * adj) / C.WAD;
            }
            return (midPrice * (C.WAD + k)) / C.WAD;
        }
        LibSpline.Point[] memory points = _buildSplinePoints(profile, dispersion);
        uint256 startDepth = _skewToDepth(inventorySkew);
        uint256 volumeFraction = (amountIn * 10000) / depth;
        if (volumeFraction > 10000) volumeFraction = 10000;
        uint256 endDepth;
        if (selling) {
            endDepth = volumeFraction >= startDepth ? 0 : startDepth - volumeFraction;
        } else {
            endDepth = startDepth + volumeFraction;
            if (endDepth > 10000) endDepth = 10000;
        }
        uint256 width = selling ? (startDepth - endDepth) : (endDepth - startDepth);
        if (width == 0) {
            int256 off = LibSpline.eval(startDepth, points);
            int256 mult = int256(C.PBPS) + off;
            if (mult < 0) mult = 0;
            return (twap * uint256(mult)) / C.PBPS;
        }
        int256 avgOffsetBps = LibSpline.area(points, startDepth, endDepth) / int256(width);
        int256 MAX_NEG = -int256(C.PBPS) * 90 / 100; // floor: -90% (≥ 10% of TWAP)
        if (avgOffsetBps < MAX_NEG) avgOffsetBps = MAX_NEG;
        int256 multiplier = int256(C.PBPS) + avgOffsetBps;
        avgPrice = (twap * uint256(multiplier)) / C.PBPS;

        // Add absolute minimum price floor (5% of TWAP)
        uint256 minPrice = (twap * 5) / 100;
        if (avgPrice < minPrice) avgPrice = minPrice;
    }

    /// @dev Profile (weights[], knots[]) → spline (x=cumDepth[0,10000], y=offsetBps).
    ///      knots[i] in [-100,+100] = % of dispersion range. price = TWAP*(1+disp*knot/100/PBPS).
    ///      ∀ N segments: N+1 knots; max(knot)-min(knot) = 100. Up to 16 segs.
    function _buildSplinePoints(
        IPool.LiquidityProfile storage profile,
        uint32 dispersion
    ) internal view returns (LibSpline.Point[] memory points) {
        uint256 count = 0;
        for (uint256 i = 0; i < 16; i++) {
            if (profile.weights[i] == 0) break;
            count++;
        }
        points = new LibSpline.Point[](count + 1);
        points[0] = LibSpline.Point({
            x: 0,
            y: (int256(int16(profile.knots[0])) * int256(uint256(dispersion))) / 100
        });
        uint256 cumW = 0;
        for (uint256 i = 0; i < count; i++) {
            cumW += uint256(profile.weights[i]);
            points[i + 1] = LibSpline.Point({
                x: (cumW * 10000) / WEIGHT_SUM,
                y: (int256(int16(profile.knots[i + 1])) * int256(uint256(dispersion))) / 100
            });
        }
    }

    /// @dev skew∈[-100,+100] → depth∈[0,10000]. -100→0, 0→5000, +100→10000.
    function _skewToDepth(int8 inventorySkew) internal pure returns (uint256) {
        unchecked { return uint256(5000 + int256(inventorySkew) * 50); }
    }

    /// @dev skew → absolute price (no-profile fallback). offsetBps = skew*disp/100.
    function _skewToPrice(uint256 twap, int8 skew, uint32 dispersion) internal pure returns (uint256) {
        int256 offsetBps = (int256(int16(skew)) * int256(uint256(dispersion))) / 100;
        int256 multiplier = int256(C.PBPS) + offsetBps;
        if (multiplier < 0) multiplier = 0;
        return (twap * uint256(multiplier)) / C.PBPS;
    }

    // --- Anchor-path routing & spread ---

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

    /// @dev Path metrics accumulator (reduce stack depth).
    struct PathAccumulator {
        uint256 currentAmount;
        uint32 sigmaPair;
        uint32 deltaPair;
        uint16 minFeePath;
        uint16 maxFeePath;
    }

    /// @notice Get anchor path swap quote through graph routing
    function getAnchorPathQuote(
        IPool.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (IPool.SwapQuote memory quote) {
        IPool.RoutePath memory path = LibAnchorTree.findRoutingPath($, tokenIn, tokenOut);

        quote.routeHops = path.hops;
        quote.hopAmounts = new uint256[](path.hops.length);
        quote.hopAmounts[0] = amountIn;
        quote.hopPrices = new uint64[](path.hops.length - 1);

        EndpointCache memory cacheIn = _cacheEndpoint($, tokenIn);
        EndpointCache memory cacheOut = _cacheEndpoint($, tokenOut);

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

    /// @dev Single SLOAD/oracle read per endpoint.
    function _cacheEndpoint(IPool.PoolStorage storage $, address token)
        private returns (EndpointCache memory cache)
    {
        IPool.Asset storage asset = $.assets[token];
        IPool.RiskConfig storage rc = $.riskConfigs[token];
        cache.reserves = asset.reserves;
        cache.liabilities = asset.liabilities;
        cache.vega = asset.vega;
        cache.lambda = asset.lambda;
        cache.gamma = asset.gamma;
        cache.coverageMin = rc.coverageMin;
        cache.coverageMax = rc.coverageMax;
        if (token == $.baseToken) {
            cache.price = 1e18;
        } else {
            (cache.price,) = LibOracle.decodeB64s(_readOracle($, token));
        }
    }

    /// @dev Execute one path leg → (out, σ, Δ, minFee, maxFee, execPriceB64).
    function _executeLeg(
        IPool.PoolStorage storage $,
        address from,
        address to,
        uint256 amountIn,
        bool isEdge,
        bool isSelling
    ) private returns (uint256 amountOut, uint32 sigma, uint32 delta, uint16 minFee, uint16 maxFee, uint64 execPriceB64) {
        // profileAsset = child in parent↔child edge.
        bool isUpward = $.assets[from].anchor == to;
        address profileAsset = isUpward ? from : to;
        uint8 decimalsFrom = $.assets[from].decimals;
        uint8 decimalsTo = $.assets[to].decimals;

        IOracle.FeedData memory feed;
        uint256 twap;
        if (profileAsset == $.baseToken) {
            feed = LibOracle.getBaseFeed();
            twap = 1e18;
        } else {
            feed = _readOracle($, profileAsset);
            (twap,) = LibOracle.decodeB64s(feed);
        }
        if (!isUpward) twap = (1e18 * 1e18) / twap; // child→parent

        sigma = LibOracle.getSigma(feed);
        int32 fastSpread = feed.fastOffset - feed.slowOffset;
        delta = fastSpread < 0 ? uint32(-fastSpread) : uint32(fastSpread);

        IPool.Asset storage asset = $.assets[profileAsset];
        IPool.RiskConfig memory rc = $.riskConfigs[profileAsset];
        minFee = asset.minFeeBps;
        maxFee = asset.maxFeeBps;

        if (isEdge) {
            amountOut = _priceEdgeHop($, asset, rc, amountIn, twap, sigma, isSelling, profileAsset);
        } else {
            uint256 midPrice = _getMidPriceForLeg($, asset, rc, twap, sigma, profileAsset);
            amountOut = (amountIn * midPrice) / 1e18;
        }

        // Decimal scaling.
        if (decimalsFrom > decimalsTo) amountOut /= 10 ** uint256(decimalsFrom - decimalsTo);
        else if (decimalsTo > decimalsFrom) amountOut *= 10 ** uint256(decimalsTo - decimalsFrom);

        // Cap by reserves (minLiquidity enforced @ Exchange).
        uint128 toRes = $.assets[to].reserves;
        if (amountOut > toRes) amountOut = toRes;

        // Exec price in `to` decimals.
        uint256 price18 = (amountOut * 1e18 * (10 ** uint256(18 - decimalsTo))) /
            (amountIn * (10 ** uint256(18 - decimalsFrom)));
        uint256 priceOut = price18 / (10 ** uint256(18 - decimalsTo));
        if (priceOut == 0) priceOut = 1;
        execPriceB64 = M.encodeB64(priceOut, decimalsTo);
    }

    /// @dev Edge hop w/ full price impact.
    function _priceEdgeHop(
        IPool.PoolStorage storage $,
        IPool.Asset storage asset,
        IPool.RiskConfig memory rc,
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

    /// @dev Mid-price for intermediate hop.
    function _getMidPriceForLeg(
        IPool.PoolStorage storage $,
        IPool.Asset storage asset,
        IPool.RiskConfig memory rc,
        uint256 twap,
        uint32 sigma,
        address profileAsset
    ) private view returns (uint256 midPrice) {
        int8 skew = computeInventorySkew(asset.reserves, asset.liabilities, rc.coverageMin, rc.coverageMax, asset.gamma);
        uint32 dispersion = _calculateDispersion(sigma, asset.vega, asset.minDispersion, asset.maxDispersion);

        return _getMidPriceFromProfile(twap, skew, dispersion, $.profiles[profileAsset]);
    }

    /// @dev Path spread w/ cached endpoints. S_vol = 100 + σ·vega/100; U = Δ·λ/100; clamp [minFee,maxFee].
    function _calculatePathSpreadCached(
        EndpointCache memory cacheIn,
        EndpointCache memory cacheOut,
        uint256 amountIn,
        uint256 amountOut,
        uint32 sigmaPair,
        uint32 deltaPair,
        uint16 minFeePath,
        uint16 maxFeePath
    ) private pure returns (uint16) {
        uint16 vegaSpread = cacheIn.vega > cacheOut.vega ? cacheIn.vega : cacheOut.vega;
        uint16 lambdaSpread = cacheIn.lambda > cacheOut.lambda ? cacheIn.lambda : cacheOut.lambda;
        int256 impact = netCoverageImpact(
            cacheIn.reserves, cacheIn.liabilities, cacheOut.reserves, cacheOut.liabilities,
            amountIn, amountOut, cacheIn.price, cacheOut.price
        );
        uint256 sVol = 100 + (uint256(sigmaPair) * uint256(vegaSpread)) / (100 * C.BPS);
        uint256 u = (uint256(deltaPair) * uint256(lambdaSpread)) / C.BPS;
        uint256 rawSpread = impact < 0 ? sVol : sVol + u;
        if (rawSpread < uint256(minFeePath)) return minFeePath;
        if (rawSpread > uint256(maxFeePath)) return maxFeePath;
        return uint16(rawSpread);
    }

    /// @dev Read oracle w/ transient cache. Supports internal (storage) + external (IOracle).
    function _readOracle(IPool.PoolStorage storage $, address token)
        private returns (IOracle.FeedData memory data)
    {
        bool found;
        (found, data) = TCache.tryLoadOracleFeed(token);
        if (found) return data;
        IPool.OracleConfig memory cfg = $.oracleConfigs[token];
        if (cfg.primary == address(0)) revert Err.NotConfigured(Err.Resource.ORACLE, token);
        // primary == address(this) → internal storage; else external IOracle.
        data = cfg.primary == address(this)
            ? _readInternalOracle(token)
            : IOracle(cfg.primary).getFeed(cfg.feedId);
        TCache.cacheOracleFeed(token, data);
    }

    /// @dev ERC-7201 oracle storage.
    function _os() private pure returns (IPool.OracleStorage storage os) {
        bytes32 slot = C.ORACLE_STORAGE_LOC;
        assembly { os.slot := slot }
    }

    /// @dev Read from internal oracle storage (when cfg.primary == address(this)).
    function _readInternalOracle(address token) private view returns (IOracle.FeedData memory data) {
        IPool.FeedAccumulator storage acc = _os().accumulators[token];
        if (acc.lastUpdate == 0) revert Err.NotConfigured(Err.Resource.ORACLE, token);
        data = IOracle.FeedData({
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

    /// @notice Split totalFee → (proto, lp). protoShare ∈ [0,100].
    function splitFee(uint256 totalFee, uint8 protoShare)
        internal pure returns (uint256 protoFee, uint256 lpFee)
    {
        protoFee = (totalFee * uint256(protoShare)) / 100;
        lpFee = totalFee - protoFee;
    }

    // --- Coverage ---

    /// @notice Coverage ratio R/L. uint256.max if L == 0.
    function calculateCoverage(uint128 reserves, uint128 liabilities) internal pure returns (uint256) {
        if (liabilities == 0) return type(uint256).max;
        return (uint256(reserves) * C.WAD) / uint256(liabilities);
    }

    /// @notice Net coverage impact (value-weighted, base). neg=improves, pos=worsens.
    /// @dev Imbalance_j = price_j * |R_j - L_j|. impact = imbalance1 - imbalance0.
    function netCoverageImpact(
        uint128 reservesIn,
        uint128 liabilitiesIn,
        uint128 reservesOut,
        uint128 liabilitiesOut,
        uint256 amountIn,
        uint256 amountOut,
        uint256 priceIn,
        uint256 priceOut
    ) internal pure returns (int256) {
        uint256 totalOut = amountOut + (amountOut * 100) / 100000; // 0.1% heuristic fee
        if (totalOut > reservesOut) return int256(C.WAD);
        if (amountIn > type(uint128).max || totalOut > type(uint128).max) return int256(C.WAD);
        uint128 newResIn = reservesIn + uint128(amountIn);
        uint128 newResOut = reservesOut - uint128(totalOut);
        // |R-L| ≡ |C-1|·L; portfolio imbalance = Σ(price·|gap|).
        uint256 gapIn0 = reservesIn > liabilitiesIn ? reservesIn - liabilitiesIn : liabilitiesIn - reservesIn;
        uint256 gapOut0 = reservesOut > liabilitiesOut ? reservesOut - liabilitiesOut : liabilitiesOut - reservesOut;
        uint256 gapIn1 = newResIn > liabilitiesIn ? newResIn - liabilitiesIn : liabilitiesIn - newResIn;
        uint256 gapOut1 = newResOut > liabilitiesOut ? newResOut - liabilitiesOut : liabilitiesOut - newResOut;
        uint256 imb0 = (priceIn * gapIn0 + priceOut * gapOut0) / C.WAD;
        uint256 imb1 = (priceIn * gapIn1 + priceOut * gapOut1) / C.WAD;
        return int256(imb1) - int256(imb0);
    }

    /// @notice Effective pricing depth. D = R + k·(L-R)·progress^(1/(1+2k)) on (50%, 100%).
    ///         k = depthAmplifier / PBPS. Concave monotonic.
    function calculateDepth(
        uint128 reserves,
        uint128 liabilities,
        uint16 depthAmplifier
    ) internal pure returns (uint256 depth) {
        if (reserves == 0) return liabilities == 0 ? 1 : 1; // both zero or undercollateralized
        if (liabilities == 0) return uint256(reserves);
        uint256 coverage = (uint256(reserves) * C.WAD) / uint256(liabilities);
        if (coverage >= C.WAD) return uint256(reserves);
        uint256 criticalFloor = C.WAD / 2;
        if (coverage <= criticalFloor || depthAmplifier == 0) return uint256(reserves);

        // progress = (c - 0.5) / 0.5; exponent = PBPS / (PBPS + 2k); virtualDepth = k·deficit·progress^exp.
        uint256 progress = ((coverage - criticalFloor) * C.WAD) / (C.WAD - criticalFloor);
        uint256 k = uint256(depthAmplifier);
        uint256 deficit = uint256(liabilities) - uint256(reserves);
        uint256 exponentWad = (C.WAD * C.PBPS) / (C.PBPS + 2 * k);
        uint256 concaveProgress = _powWad(progress, exponentWad);
        depth = uint256(reserves) + (k * deficit * concaveProgress) / (C.PBPS * C.WAD);
        if (depth > uint256(liabilities)) depth = uint256(liabilities);
        if (depth == 0) depth = 1;
    }

    /// @notice Linear liability decay when coverage < threshold. Caps @ (L - R).
    ///         decayAmount = L · decaySlope · dt / WAD.
    function calculateDecay(
        uint128 liabilities,
        uint128 reserves,
        uint16 decayStartRatioBps,
        uint32 decaySlope,
        uint32 dt
    ) internal pure returns (uint128) {
        if (dt == 0 || decaySlope == 0 || liabilities == 0) return 0;
        uint256 coverage = calculateCoverage(reserves, liabilities);
        uint256 threshold = (uint256(decayStartRatioBps) * C.WAD) / C.PBPS;
        if (coverage >= threshold) return 0;
        uint256 rawDecay = (uint256(liabilities) * uint256(decaySlope) * uint256(dt)) / C.WAD;
        uint256 maxDecay = liabilities > reserves ? liabilities - reserves : 0; // cap @ 100% coverage
        return rawDecay > maxDecay ? uint128(maxDecay) : uint128(rawDecay);
    }

    /// @notice Power-law withdrawal haircut: h(c) = (1-c)^p, p = 1 + suppression/PBPS.
    ///         h(0) = 1 (block); h(1) = 0 (no penalty).
    function applyWithdrawalHaircut(
        uint256 amount,
        uint128 reserves,
        uint128 liabilities,
        uint16 suppression
    ) internal pure returns (uint256 actualAmount, uint256 haircutAmount) {
        if (liabilities == 0 || reserves >= liabilities) return (amount, 0);
        uint256 coverage = calculateCoverage(reserves, liabilities);
        if (coverage > C.WAD) coverage = C.WAD;
        uint256 deficit = C.WAD - coverage;
        uint256 pWad = C.WAD + (uint256(suppression) * C.WAD) / C.PBPS;
        uint256 haircutRatio = deficit == 0 ? 0 : (deficit == C.WAD ? C.WAD : _powWad(deficit, pWad));
        if (haircutRatio > C.WAD) haircutRatio = C.WAD;
        haircutAmount = (amount * haircutRatio) / C.WAD;
        actualAmount = amount - haircutAmount;
    }

    /// @dev x^y in WAD via binary exp on integer part + linear approx on fractional remainder.
    ///      Targets x ∈ (0, WAD], y ≥ WAD. SECURITY: hand-rolled, defer Solady swap to audit.
    function _powWad(uint256 x, uint256 y) private pure returns (uint256 result) {
        if (x == 0) return 0;
        if (x == C.WAD) return C.WAD;
        if (y == C.WAD) return x;
        uint256 expInt = y / C.WAD;
        uint256 rem = y % C.WAD;
        uint256 acc = C.WAD;
        uint256 base = x;
        for (uint256 i = 0; i < 256 && expInt > 0; i++) {
            if ((expInt & 1) == 1) acc = (acc * base) / C.WAD;
            base = (base * base) / C.WAD;
            expInt >>= 1;
        }
        result = acc;
        if (rem > 0 && x < C.WAD) {
            uint256 adj = (rem * (C.WAD - x)) / C.WAD;
            if (result > adj) result -= (result * adj) / (C.WAD * 10);
        }
    }
}
