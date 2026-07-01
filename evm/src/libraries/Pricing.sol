// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {Maths as M} from "./Maths.sol";
import {Spline} from "./Spline.sol";
import {AnchorTree} from "./AnchorTree.sol";
import {Oracle} from "./Oracle.sol";
import {TransientCache as TCache} from "./TransientCache.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title Pricing -coverage-adjusted pricing + bi-factor fee model.
/// @dev Units: see Constants. BPS=0.01%, PBPS=0.0001%, WAD=1e18.
library Pricing {
    using {M.b64To1e18} for uint64;

    /// @dev Profile weights sum (200 = 100%, 1 unit = 0.5% depth).
    uint256 private constant WEIGHT_SUM = 200;
    uint256 private constant MAX_IMPACT = 2 * SC.WAD;   // 200%
    uint256 private constant MIN_ADJ = SC.WAD / 1000;   // 0.1%

    /// @dev covFlags bit0: convex (1/c−1) coverage premium (diverges as c→0 = hard no-drain wall,
    ///      for stables) vs the linear (1−c) bounded spring (for volatiles).
    uint16 internal constant COV_CONVEX_BIT = 0x01;

    /// @notice Coverage-convergence premium (PBPS), the vol-INDEPENDENT re-peg term. Quotes an
    ///         under-covered asset (c<1) at a premium so corrective flow re-pegs it to 1; over-covered
    ///         (c>1) gets a symmetric discount. Convex form `κ·(1/c−1)` diverges as c→0 (Wombat-grade
    ///         no-drain wall, for stables); linear `κ·(1−c)` is bounded (for volatiles). Clamped to
    ///         ±premCap (PBPS). Returns a signed PBPS offset to ADD to the price multiplier.
    /// @dev Unlike the dispersion-scaled skew (∝σ, ~0 for stables), this is vol-independent so it
    ///      re-pegs stables strongly. Complements the skew (does not replace it). κ=0 ⇒ 0 (disabled).
    function covPremiumBps(
        uint256 coverage, // WAD (1e18 = 100%)
        uint16 kappaCovBps,
        uint16 premCapBps,
        bool convex
    ) internal pure returns (int256 offBps) {
        if (kappaCovBps == 0 || coverage == SC.WAD) return 0;
        bool under = coverage < SC.WAD;
        // deficit magnitude in WAD: convex 1/c−1 (unbounded as c→0) or linear |1−c|.
        uint256 defWad;
        if (convex) {
            // |1/c − 1| = |WAD − c| / c  (in WAD)
            uint256 diff = under ? SC.WAD - coverage : coverage - SC.WAD;
            defWad = (diff * SC.WAD) / coverage;
        } else {
            defWad = under ? SC.WAD - coverage : coverage - SC.WAD;
        }
        // premium (PBPS) = κ · deficit; κ in BPS. defWad(WAD)·κ(BPS)/BPS → WAD; ·PBPS/WAD → PBPS.
        uint256 prem = (defWad * uint256(kappaCovBps)) / SC.BPS; // WAD-scaled
        prem = (prem * SC.PBPS) / SC.WAD; // → PBPS
        uint256 cap = uint256(premCapBps);
        if (prem > cap) prem = cap;
        return under ? int256(prem) : -int256(prem);
    }

    /// @notice Avellaneda-Stoikov inventory skew. Linear: skew = sign*γ*100*progress, clamp [-100,+100].
    ///         At critMin: +γ*100 (premium); target=WAD: 0; critMax: -γ*100 (discount).
    ///         coverageMin/Max in 0.01% units (10000=100%). gamma in BPS (10000=1x).
    function computeInventorySkew(
        uint128 reserves,
        uint128 liabilities,
        uint16 coverageMin,
        uint16 coverageMax,
        uint16 gamma
    ) internal pure returns (int8) {
        if (liabilities == 0) return -100;
        uint256 coverage = calculateCoverage(reserves, liabilities);
        uint256 critMin = (uint256(coverageMin) * SC.WAD) / SC.BPS;
        uint256 critMax = (uint256(coverageMax) * SC.WAD) / SC.BPS;
        if (coverage <= critMin) return 100;
        if (coverage >= critMax) return -100;
        bool under = coverage < SC.WAD;
        uint256 numer = under ? SC.WAD - coverage : coverage - SC.WAD;
        uint256 denom = under ? SC.WAD - critMin : critMax - SC.WAD;
        uint256 progress = (numer * SC.WAD) / denom;
        uint256 skew = (uint256(gamma) * 100 * progress) / (SC.BPS * SC.WAD);
        if (skew > 100) skew = 100;
        return under ? int8(int256(skew)) : int8(-int256(skew));
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

        // executionPrice is in base per token units (1e18), so baseOut = amountIn * executionPrice / SC.WAD
        amountOut = (amountIn * executionPrice) / SC.WAD;
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
        uint256 scaledVol = (uint256(volatility) * uint256(vega)) / (1000 * SC.BPS);
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
        Spline.Point[] memory points = _buildSplinePoints(profile, dispersion);

        // X-axis: cumulative depth percentage (0 to 10000 = 0% to 100%)
        // Y-axis: price offset from TWAP (in SC.PBPS units)
        // inventorySkew maps to a position on this curve

        // Map inventorySkew (-100 to +100) to cumulative depth position
        // Skew 0 = center of profile (50% cumulative depth)
        // Negative skew = traverse left (lower depth)
        // Positive skew = traverse right (higher depth)
        uint256 targetDepth = _skewToDepth(inventorySkew);

        // Interpolate price offset at target depth using monotone cubic spline
        int256 priceOffsetBps = Spline.eval(targetDepth, points);

        // Convert offset to absolute price
        int256 multiplier = int256(SC.PBPS) + priceOffsetBps;
        if (multiplier < 0) multiplier = 0;

        midPrice = (twap * uint256(multiplier)) / SC.PBPS;
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
            uint256 impact = (amountIn * SC.WAD) / depth;
            if (impact > MAX_IMPACT) impact = MAX_IMPACT;
            uint256 midPrice = _skewToPrice(twap, inventorySkew, dispersion);
            uint256 k = impact / 2;
            if (selling) {
                uint256 adj = k < SC.WAD ? SC.WAD - k : MIN_ADJ;
                return (midPrice * adj) / SC.WAD;
            }
            return (midPrice * (SC.WAD + k)) / SC.WAD;
        }
        // Phase 42H.D · G5.b -`points` built once, reused for both `Spline.eval`
        // (zero-width path, line 176) AND `Spline.area` (line 181). Avoids double
        // O(N) array rebuild on the swap hot path (~5–8k gas saved per swap).
        Spline.Point[] memory points = _buildSplinePoints(profile, dispersion);
        uint256 startDepth = _skewToDepth(inventorySkew);
        uint256 volumeFraction = (amountIn * SC.BPS) / depth;
        if (volumeFraction > SC.BPS) volumeFraction = SC.BPS;
        uint256 endDepth;
        if (selling) {
            endDepth = volumeFraction >= startDepth ? 0 : startDepth - volumeFraction;
        } else {
            endDepth = startDepth + volumeFraction;
            if (endDepth > SC.BPS) endDepth = SC.BPS;
        }
        // Integrate over the ORDERED depth band [lo, hi]. BUG-2 fix: previously this called
        // `Spline.area(startDepth, endDepth)` which, on a descending sell (startDepth > endDepth),
        // sign-flips the integral (Spline.sol inv branch) and was then divided by an UNSIGNED width
        // → avgOffset = −(true mean) → sells were quoted a PREMIUM above TWAP. Ordering the bounds
        // makes `area` monotone-direction (no negation): avgOffset is the TRUE mean offset —
        // negative (discount) for a sell band below center, positive (premium) for a buy band above.
        uint256 lo = selling ? endDepth : startDepth;
        uint256 hi = selling ? startDepth : endDepth;
        uint256 width = hi - lo;
        if (width == 0) {
            int256 off = Spline.eval(startDepth, points);
            int256 mult = int256(SC.PBPS) + off;
            if (mult < 0) mult = 0;
            return (twap * uint256(mult)) / SC.PBPS;
        }
        int256 avgOffsetBps = Spline.area(points, lo, hi) / int256(width);
        int256 MAX_NEG = -int256(SC.PBPS) * 90 / 100; // floor: -90% (≥ 10% of TWAP)
        if (avgOffsetBps < MAX_NEG) avgOffsetBps = MAX_NEG;
        int256 multiplier = int256(SC.PBPS) + avgOffsetBps;
        avgPrice = (twap * uint256(multiplier)) / SC.PBPS;

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
    ) internal view returns (Spline.Point[] memory points) {
        uint256 count = 0;
        for (uint256 i = 0; i < 16; i++) {
            if (profile.weights[i] == 0) break;
            count++;
        }
        points = new Spline.Point[](count + 1);
        points[0] = Spline.Point({
            x: 0,
            y: (int256(int16(profile.knots[0])) * int256(uint256(dispersion))) / 100
        });
        uint256 cumW = 0;
        for (uint256 i = 0; i < count; i++) {
            cumW += uint256(profile.weights[i]);
            points[i + 1] = Spline.Point({
                x: (cumW * SC.BPS) / WEIGHT_SUM,
                y: (int256(int16(profile.knots[i + 1])) * int256(uint256(dispersion))) / 100
            });
        }
    }

    /// @dev skew∈[-100,+100] → depth∈[0,10000]. -100→0, 0→5000, +100→10000.
    /// @dev Phase 42D A4-4 DISCARD: unchecked add is sound -precondition `skew ∈ [-100,+100]`
    ///      is enforced by `computeInventorySkew` clamps; range `[5000 - 5000, 5000 + 5000] = [0, 10000]`
    ///      always non-negative. Caller MUST pass a clamped skew (int8 alone is insufficient).
    function _skewToDepth(int8 inventorySkew) internal pure returns (uint256) {
        unchecked { return uint256(5000 + int256(inventorySkew) * 50); }
    }

    /// @dev skew → absolute price (no-profile fallback). offsetBps = skew*disp/100.
    function _skewToPrice(uint256 twap, int8 skew, uint32 dispersion) internal pure returns (uint256) {
        int256 offsetBps = (int256(int16(skew)) * int256(uint256(dispersion))) / 100;
        int256 multiplier = int256(SC.PBPS) + offsetBps;
        if (multiplier < 0) multiplier = 0;
        return (twap * uint256(multiplier)) / SC.PBPS;
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
        IPool.RoutePath memory path = AnchorTree.findRoutingPath($, tokenIn, tokenOut);

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
                _executeLeg($, path.hops[i], path.hops[i + 1], acc.currentAmount, isEdge);

            acc.currentAmount = amountOut;
            quote.hopAmounts[i + 1] = amountOut;
            quote.hopPrices[i] = execPriceB64;

            if (sigma > acc.sigmaPair) acc.sigmaPair = sigma;
            if (delta > acc.deltaPair) acc.deltaPair = delta;
            if (minF > acc.minFeePath) acc.minFeePath = minF;
            if (maxF > acc.maxFeePath) acc.maxFeePath = maxF;
        }

        quote.amountIn = amountIn;
        {
            // Path spread: S_vol = 100 + σ·vega/100; U = Δ·λ/100; clamp [minFee,maxFee].
            uint16 vegaSpread = cacheIn.vega > cacheOut.vega ? cacheIn.vega : cacheOut.vega;
            uint16 lambdaSpread = cacheIn.lambda > cacheOut.lambda ? cacheIn.lambda : cacheOut.lambda;
            int256 impact = netCoverageImpact(
                cacheIn.reserves, cacheIn.liabilities, cacheOut.reserves, cacheOut.liabilities,
                amountIn, acc.currentAmount, cacheIn.price, cacheOut.price, acc.maxFeePath
            );
            uint256 sVol = 100 + (uint256(acc.sigmaPair) * uint256(vegaSpread)) / (100 * SC.BPS);
            uint256 u = (uint256(acc.deltaPair) * uint256(lambdaSpread)) / SC.BPS;
            uint256 rawSpread = impact < 0 ? sVol : sVol + u;
            quote.spreadBps = rawSpread < uint256(acc.minFeePath)
                ? acc.minFeePath
                : (rawSpread > uint256(acc.maxFeePath) ? acc.maxFeePath : uint16(rawSpread));
        }

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
            // R44-2 (T3-HIGH2): if a base-token oracle is pinned, read real base price + halt
            //   swaps on depeg. Otherwise fallback to 1e18 (legacy stable-base behavior).
            cache.price = _readBasePriceOrHalt($);
        } else {
            (cache.price,) = Oracle.decodeB64s(_readOracle($, token));
        }
    }

    /// @notice R44-2 (T3-HIGH2): read base-token oracle price and revert on depeg.
    /// @dev If `$.baseTokenOracle == address(0)` returns 1e18 unchanged (backwards-compat for
    ///      stable-base deployments). Otherwise reads the configured feed via `IOracle.getFeed`
    ///      and compares to 1e18 unit-of-account parity. Reverts `Err.BaseDepegged` when
    ///      |basePrice - 1e18| * BPS / 1e18 > `Constants.BASE_DEPEG_HALT_BPS`.
    function _readBasePriceOrHalt(IPool.PoolStorage storage $) internal view returns (uint256 basePrice) {
        address oracle = $.baseTokenOracle;
        if (oracle == address(0)) return 1e18;
        IOracle.FeedData memory feed = IOracle(oracle).getFeed($.baseTokenFeedId);
        (basePrice,) = Oracle.decodeB64s(feed);
        if (basePrice == 0) revert Err.BaseDepegged(0, type(uint256).max);
        uint256 deviation = basePrice > 1e18 ? basePrice - 1e18 : 1e18 - basePrice;
        uint256 devBps = (deviation * SC.BPS) / 1e18;
        if (devBps > uint256(C.BASE_DEPEG_HALT_BPS)) revert Err.BaseDepegged(basePrice, devBps);
    }

    /// @dev Execute one path leg → (out, σ, Δ, minFee, maxFee, execPriceB64).
    function _executeLeg(
        IPool.PoolStorage storage $,
        address from,
        address to,
        uint256 amountIn,
        bool isEdge
    ) private returns (uint256 amountOut, uint32 sigma, uint32 delta, uint16 minFee, uint16 maxFee, uint64 execPriceB64) {
        // F-A4-3 (LOW): guard against zero amountIn -mirrors HIGH-style explicit zero checks.
        // Prior code did execPriceB64 derivation by `amountOut * 1e18 ... / amountIn`, which divides
        // by zero on amountIn==0; revert here gives a clean error vs panic.
        if (amountIn == 0) revert Err.ZeroValue();
        // profileAsset = child in parent↔child edge.
        bool isUpward = $.assets[from].anchor == to;
        address profileAsset = isUpward ? from : to;
        uint8 decimalsFrom = $.assets[from].decimals;
        uint8 decimalsTo = $.assets[to].decimals;

        IOracle.FeedData memory feed;
        uint256 twap;
        if (profileAsset == $.baseToken) {
            feed = Oracle.getBaseFeed();
            // R44-2b: base-token edge-hop must honor depeg halt; cannot hardcode 1e18 when
            //   a base oracle is pinned. Falls back to 1e18 when oracle unset (legacy stable-base).
            twap = _readBasePriceOrHalt($);
        } else {
            feed = _readOracle($, profileAsset);
            (twap,) = Oracle.decodeB64s(feed);
        }
        sigma = Oracle.getSigma(feed);
        int32 fastSpread = feed.fastOffset - feed.slowOffset;
        delta = fastSpread < 0 ? uint32(-fastSpread) : uint32(fastSpread);

        IPool.Asset storage asset = $.assets[profileAsset];
        IPool.RiskConfig memory rc = $.riskConfigs[profileAsset];
        minFee = asset.minFeeBps;
        maxFee = asset.maxFeeBps;

        if (isEdge) {
            // BUG-3 fix: an edge hop is a SELL of the profile asset iff child→parent (isUpward);
            // base→child is a BUY. Price in canonical anchor-per-child space. The prior code passed
            // a hardcoded `isSelling=true` for every leg, so buys were priced through the sell
            // branch (dead buy path + decimal-mismatched volumeFraction) → underpriced buys.
            amountOut = _priceEdgeHop($, asset, rc, amountIn, twap, sigma, isUpward, profileAsset);
        } else {
            // Interior hop: mid-price multiply model needs the directional rate
            // (child-per-parent on a downward leg).
            uint256 dirTwap = isUpward ? twap : (1e18 * 1e18) / twap;
            uint256 midPrice = _getMidPriceForLeg($, asset, rc, dirTwap, sigma, profileAsset);
            amountOut = (amountIn * midPrice) / 1e18;
        }

        // Decimal scaling.
        if (decimalsFrom > decimalsTo) amountOut /= 10 ** uint256(decimalsFrom - decimalsTo);
        else if (decimalsTo > decimalsFrom) amountOut *= 10 ** uint256(decimalsTo - decimalsFrom);

        // Cap by reserves (minLiquidity enforced @ Exchange).
        uint128 toRes = $.assets[to].reserves;
        bool clamped = amountOut > toRes;
        if (clamped) amountOut = toRes;

        // Exec price (`to` per `from`) in 1e18.
        uint256 price18 = (amountOut * 1e18 * (10 ** uint256(18 - decimalsTo))) /
            (amountIn * (10 ** uint256(18 - decimalsFrom)));
        uint256 priceOut = price18 / (10 ** uint256(18 - decimalsTo));
        // Phase 42D A4-2: revert on degenerate zero (was: silent clamp to 1, which poisoned oracle).
        if (priceOut == 0) revert Err.ZeroValue();
        // R44-9 (Pass-44B): sentinel = 0 → skip oracle push for this hop.
        // Reserve-clamped exec price reflects pool emptiness, not market — polluting TWAP via
        // accumulator push enables an attacker to drain reserves and inject manipulated prices.
        // `pushOracle` consumer treats 0 as "do not push".
        // The accumulator's canonical convention is anchor-per-profileAsset (readers decode then
        // invert on downward legs, see `_readOracle` callsite above). `price18` is `to`-per-`from`:
        //   upward (child→anchor): to=anchor ⇒ price18 already anchor-per-child (canonical).
        //   downward (anchor→child): to=child ⇒ price18 is child-per-anchor ⇒ must invert,
        //     else the pushed mark is the reciprocal (~1/P) and poisons every reader.
        if (clamped) {
            execPriceB64 = uint64(0);
        } else if (isUpward) {
            execPriceB64 = M.encodeB64(priceOut, decimalsTo);
        } else {
            execPriceB64 = M.encodeB64((uint256(1e18) * 1e18) / price18, 18);
        }
    }

    /// @dev Coverage-adjusted mark: `twap·(1 + covPremium)`. The vol-independent re-peg term that
    ///      moves an under-covered asset's quote to attract corrective flow (c→1). No-op when
    ///      kappaCovBps=0 (default) — so volatile legs (kappaCov≈0) are unchanged.
    function _covAdjTwap(uint256 twap, uint128 reserves, uint128 liabilities, IPool.RiskConfig memory rc)
        private pure returns (uint256)
    {
        if (rc.kappaCovBps == 0) return twap;
        int256 off = covPremiumBps(
            calculateCoverage(reserves, liabilities), rc.kappaCovBps, rc.premCapBps, (rc.covFlags & COV_CONVEX_BIT) != 0
        );
        if (off == 0) return twap;
        int256 mult = int256(SC.PBPS) + off;
        if (mult < 1) mult = 1;
        return (twap * uint256(mult)) / SC.PBPS;
    }

    /// @dev Effective depth amplifier: forced to 0 when the re-peg term is active, because the c<1
    ///      virtual-depth branch LOWERS slippage on the scarce asset (subsidizes drainage) and would
    ///      fight the coverage wall. Neutralizing it lets slippage stiffen normally as reserves fall.
    function _effAmp(IPool.RiskConfig memory rc) private pure returns (uint16) {
        return rc.kappaCovBps > 0 ? 0 : rc.depthAmplifier;
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
        // Coverage-convergence: shift the mark for an under-covered asset (re-peg), and neutralize
        // the depth-amp drainage subsidy while doing so. No-op for volatile legs (kappaCovBps=0).
        twap = _covAdjTwap(twap, asset.reserves, asset.liabilities, rc);
        uint16 effAmp = _effAmp(rc);

        if (selling) {
            // child→base: amountIn is already in profile-asset (child) decimals, matching `depth`.
            (amountOut,) = quoteSwap(
                amountIn, asset.reserves, asset.liabilities, twap, sigma,
                $.profiles[profileAsset], skew, true, effAmp,
                asset.vega, asset.minDispersion, asset.maxDispersion
            );
        } else {
            // Buy quote w/ cost: estimate child-out via mid, traverse spline, refine.
            uint256 depth = calculateDepth(asset.reserves, asset.liabilities, effAmp);
            uint32 dispersion = _calculateDispersion(sigma, asset.vega, asset.minDispersion, asset.maxDispersion);
            IPool.LiquidityProfile storage profile = $.profiles[profileAsset];
            uint256 midPrice = _getMidPriceFromProfile(twap, skew, dispersion, profile);
            // Estimate in `from` decimals; returned amountOut keeps this basis (`_executeLeg`
            // rescales from→to downstream).
            uint256 estOut = (amountIn * SC.WAD) / midPrice;
            // BUG-3 fix: `_traverseSplineByVolume` divides the trade size by `depth` (in profile-asset
            // = `to` decimals), so the size must share those decimals. `estOut` is in `from` decimals;
            // on a downward buy `from` is the profile asset's anchor. Scale from→to before traversal,
            // else a 6dec→18dec buy underflows volumeFraction to 0 → flat, size-independent slippage.
            int256 decShift = int256(uint256(asset.decimals)) - int256(uint256($.assets[asset.anchor].decimals));
            uint256 estChild = decShift >= 0
                ? estOut * (10 ** uint256(decShift))
                : estOut / (10 ** uint256(-decShift));
            uint256 execPrice = _traverseSplineByVolume(twap, dispersion, profile, skew, estChild, depth, false);
            amountOut = (amountIn * SC.WAD) / execPrice;
        }
    }

    /// @dev Mid-price for intermediate hop (interior leg of multi-hop path).
    ///      R44-8 (Pass-44B) ACKNOWLEDGED TRADE-OFF: interior hops use mid-price w/ skew but
    ///      without spline volume-traversal impact. For paths of length ≤ 3 (single intermediate)
    ///      the under-charge is bounded by (max-skew · max-dispersion) ≈ 1% in production configs.
    ///      For longer paths the cumulative deviation grows. Mitigation in this pass: rely on
    ///      AnchorTree MAX_DEPTH=4 (max path length 6 hops, max interior = 4); future hardening
    ///      should add reduced-impact spline traversal (scale factor ~30% PBPS) or tighten
    ///      MAX_DEPTH to 3. Edge hops (first/last) ALWAYS apply full spline impact via
    ///      `_priceEdgeHop`, so under-charge is purely an interior-leg phenomenon.
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
        twap = _covAdjTwap(twap, asset.reserves, asset.liabilities, rc); // coverage-convergence re-peg

        return _getMidPriceFromProfile(twap, skew, dispersion, $.profiles[profileAsset]);
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
            ? _readInternalOracle($, token)
            : IOracle(cfg.primary).getFeed(cfg.feedId);
        // External-oracle safety: the swap hot-path previously consumed the feed with NO freshness
        // gate — a dead/censored keeper (external) or an un-poked accumulator (internal) froze the
        // mark, re-creating the unbounded pick-off external feeds exist to kill. Fail-closed: revert
        // on a feed older than its per-feed `ttl` (short for followed flagships, long for price-leader
        // internal feeds). Matches PoolOracle.readOracle + _readBasePriceOrHalt; halting > bleeding.
        uint256 age = block.timestamp >= data.updatedAt ? block.timestamp - data.updatedAt : type(uint32).max;
        if (age > data.ttl) {
            revert Err.StaleData(age > type(uint32).max ? type(uint32).max : uint32(age), data.ttl);
        }
        TCache.cacheOracleFeed(token, data);
    }

    /// @dev Read from internal oracle storage (when cfg.primary == address(this)).
    function _readInternalOracle(IPool.PoolStorage storage $, address token) private view returns (IOracle.FeedData memory data) {
        IPool.FeedAccumulator storage acc = $.accumulators[token];
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
        return (uint256(reserves) * SC.WAD) / uint256(liabilities);
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
        uint256 priceOut,
        uint16 feeBps
    ) internal pure returns (int256) {
        // A3-2 fix: config-sourced fee replaces hard-coded 0.1% heuristic.
        // feeBps in PBPS (1e6 = 100%). Conservative upper-bound from path acc.maxFeePath.
        uint256 totalOut = amountOut + (amountOut * uint256(feeBps)) / 1_000_000;
        if (totalOut > reservesOut) return int256(SC.WAD);
        if (amountIn > type(uint128).max || totalOut > type(uint128).max) return int256(SC.WAD);
        uint128 newResIn = reservesIn + uint128(amountIn);
        uint128 newResOut = reservesOut - uint128(totalOut);
        // |R-L| ≡ |C-1|·L; portfolio imbalance = Σ(price·|gap|).
        uint256 gapIn0 = reservesIn > liabilitiesIn ? reservesIn - liabilitiesIn : liabilitiesIn - reservesIn;
        uint256 gapOut0 = reservesOut > liabilitiesOut ? reservesOut - liabilitiesOut : liabilitiesOut - reservesOut;
        uint256 gapIn1 = newResIn > liabilitiesIn ? newResIn - liabilitiesIn : liabilitiesIn - newResIn;
        uint256 gapOut1 = newResOut > liabilitiesOut ? newResOut - liabilitiesOut : liabilitiesOut - newResOut;
        uint256 imb0 = (priceIn * gapIn0 + priceOut * gapOut0) / SC.WAD;
        uint256 imb1 = (priceIn * gapIn1 + priceOut * gapOut1) / SC.WAD;
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
        uint256 coverage = (uint256(reserves) * SC.WAD) / uint256(liabilities);
        if (coverage >= SC.WAD) return uint256(reserves);
        uint256 criticalFloor = SC.WAD / 2;
        if (coverage <= criticalFloor || depthAmplifier == 0) return uint256(reserves);

        // progress = (c - 0.5) / 0.5; exponent = PBPS / (PBPS + 2k); virtualDepth = k·deficit·progress^exp.
        uint256 progress = ((coverage - criticalFloor) * SC.WAD) / (SC.WAD - criticalFloor);
        uint256 k = uint256(depthAmplifier);
        uint256 deficit = uint256(liabilities) - uint256(reserves);
        uint256 exponentWad = (SC.WAD * SC.PBPS) / (SC.PBPS + 2 * k);
        uint256 concaveProgress = _powWad(progress, exponentWad);
        depth = uint256(reserves) + (k * deficit * concaveProgress) / (SC.PBPS * SC.WAD);
        if (depth > uint256(liabilities)) depth = uint256(liabilities);
        if (depth == 0) depth = 1;
    }

    /// @dev x^y in WAD via Solady FixedPointMathLib.powWad. A4-1 fix: replaces hand-rolled approx.
    ///      Targets x ∈ (0, WAD], y ≥ 0. Guards x=0 (returns 0) + x=WAD (returns WAD) to skip
    ///      Solady's ln-based path on degenerate inputs.
    function _powWad(uint256 x, uint256 y) private pure returns (uint256 result) {
        if (x == 0) return 0;
        if (x == SC.WAD) return SC.WAD;
        if (y == 0) return SC.WAD;
        if (y == SC.WAD) return x;
        // x ≤ WAD ≪ 2^255, y ≪ 2^255 in our domain → safe int256 cast.
        int256 r = FixedPointMathLib.powWad(int256(x), int256(y));
        return r < 0 ? 0 : uint256(r);
    }
}
