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
    // Staleness-premium coefficient for the A-S σ√age keeper-lag defense in `_pathSpread` (the term is
    // STALE_Z·σ·√excess/BPS). Global (not per-asset) to avoid a RiskConfig storage change; the
    // deviation-push policy (minFee ≈ 2·θ) is the primary defense, so this only bites past the keeper
    // grace (age > ttl/2) — a missed push. 100 gives ~10bps at 1% vol / 100s stale (see _staleTerm).
    uint256 private constant STALE_Z = 100;

    uint256 private constant MAX_IMPACT = 2 * SC.WAD;   // 200%
    uint256 private constant MIN_ADJ = SC.WAD / 1000;   // 0.1%

    /// @notice Coverage-driven inventory skew = a reservation-price mid-shift (shift fair value against
    ///         inventory: Avellaneda-Stoikov theory, first instantiated on-chain by DODO PMM's oracle-
    ///         anchored `i`/`k` proactive maker) driven by the coverage-ratio imbalance metric R/L
    ///         (Platypus/Wombat). Two distinct roles — the A-S/DODO *response*, the Wombat *metric* it
    ///         consumes; AIMM feeds the coverage metric a mid-shift rather than Wombat's slippage-on-invariant.
    ///         Linear: skew = sign*γ*100*progress, clamp [-100,+100].
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
        uint16 gamma;
        uint16 coverageMin;
        uint16 coverageMax;
        uint32 staleExcess; // seconds the mark is stale BEYOND the keeper grace (age − ttl/2, else 0)
        uint16 confidence;  // feed 1σ CI (bps); widens the spread (see _pathSpread confidence surcharge)
        uint16 kappaCovBps; // convex coverage-wall strength (0 = off); tolls the drained OUTPUT side
    }

    /// @dev Per-leg result — struct return keeps `_walkLegs` off the via_ir stack-too-deep edge.
    struct LegResult {
        uint256 amountOut;
        uint32 sigma;
        uint16 minFee;
        uint16 maxFee;
        uint64 execPriceB64;
    }

    /// @dev Path metrics accumulator (reduce stack depth).
    struct PathAccumulator {
        uint256 currentAmount;
        uint32 sigmaPair;
        uint16 minFeePath;
        uint16 maxFeePath;
    }

    /// @notice Swap-exec entry: pre-warm the tx oracle cache, then quote. Non-view — the cache write
    ///         is a hot-path dedup (leg walk + priceBandGuard tload instead of a second getFeed).
    /// @dev Quote-ONLY callers (Pool.getSwapQuote → Router route-discovery STATICCALL) MUST use the
    ///      `view` variant below, which never writes the transient cache, so the STATICCALL succeeds.
    function getAnchorPathQuote(
        IPool.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal returns (IPool.SwapQuote memory quote) {
        _primeOracleCache($, tokenIn, tokenOut);
        return getAnchorPathQuoteView($, tokenIn, tokenOut, amountIn);
    }

    /// @notice Get anchor path swap quote through graph routing (pure `view` — no cache writes).
    function getAnchorPathQuoteView(
        IPool.PoolStorage storage $,
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (IPool.SwapQuote memory quote) {
        IPool.RoutePath memory path = AnchorTree.findRoutingPath($, tokenIn, tokenOut);

        quote.routeHops = path.hops;
        quote.hopAmounts = new uint256[](path.hops.length);
        quote.hopAmounts[0] = amountIn;
        quote.hopPrices = new uint64[](path.hops.length - 1);

        EndpointCache memory cacheIn = _cacheEndpoint($, tokenIn);
        EndpointCache memory cacheOut = _cacheEndpoint($, tokenOut);

        // Every INTERIOR node the flow transits must be halted-checked, not just the swap endpoints
        // (PoolSwap checks those). In a depth-1 star the sole interior node is the base hub on a
        // spoke→base→spoke route, so this also enforces the base-depeg halt on cross-spoke swaps — a
        // depegged base is priced only via _readBasePriceOrHalt, which the spoke-profiled legs never
        // call. Freeze/pause (HALT_MASK) + base depeg both stop transit through a compromised hub.
        for (uint256 i = 1; i + 1 < path.hops.length; i++) {
            address hop = path.hops[i];
            if (($.riskConfigs[hop].flags & C.HALT_MASK) != 0) revert Err.FeatureDisabled(Err.Resource.ASSET);
            if (hop == $.baseToken) _readBasePriceOrHalt($); // interior base hub → enforce depeg halt
        }

        PathAccumulator memory acc;
        acc.currentAmount = amountIn;

        _walkLegs($, path, acc, quote); // per-leg pricing + path accumulation (own frame, stack-safe)

        quote.amountIn = amountIn;
        _settleQuote($, quote, acc, cacheIn, cacheOut); // spread + coverage toll + fee split + skews (own frame)
    }

    /// @dev Path tail: spread, convex coverage toll, fee split, endpoint skews. Its own frame keeps
    ///      `getAnchorPathQuote` off the via_ir stack-too-deep edge (the toll's lnWad math + fee locals
    ///      live here, not in the hot routing frame). Mutates `quote` (memory, by ref).
    function _settleQuote(
        IPool.PoolStorage storage $,
        IPool.SwapQuote memory quote,
        PathAccumulator memory acc,
        EndpointCache memory cacheIn,
        EndpointCache memory cacheOut
    ) private view {
        quote.spreadBps = _pathSpread(acc, cacheIn, cacheOut);

        // Convex coverage wall (cov_q port): toll the drained OUTPUT side BEFORE fees, in place on
        // acc.currentAmount. The toll is simply NOT credited to the trader ⇒ it stays in the output
        // reserve = graceful skim to LP surplus. κ=0 ⇒ 0. This single choke tolls swap, cross-withdraw
        // AND swapLiability (all route through getAnchorPathQuote) — no toll-exempt lever.
        acc.currentAmount -= _covToll(cacheOut, acc.currentAmount);

        // The gross output (acc.currentAmount) is priced off the FULL amountIn (the spline applies
        // price-impact only, no fee), so the pool nets exactly feeOut of value on the swap. That is the
        // whole fee pot — split once between protocol and LP. (A separate input-side half-spread would
        // be phantom revenue: the trader was already credited full amountIn in the gross output, so
        // skimming the input side just drains LP reserves into the treasury.)
        // Multiply before halving — (spread/2) as uint16 truncates 1 PBPS to 0 and zeroes fees at the floor.
        uint256 feeOut = (acc.currentAmount * uint256(quote.spreadBps)) / (2 * 1_000_000);
        (quote.protoFee, quote.lpFee) = splitFee(feeOut, $.feeParams.protoShare);
        quote.amountOut = acc.currentAmount - feeOut;

        quote.skewIn = computeInventorySkew(cacheIn.reserves, cacheIn.liabilities, cacheIn.coverageMin, cacheIn.coverageMax, cacheIn.gamma);
        quote.skewOut = computeInventorySkew(cacheOut.reserves, cacheOut.liabilities, cacheOut.coverageMin, cacheOut.coverageMax, cacheOut.gamma);
    }

    /// @dev Full path spread (PBPS, clamped): S_vol + U_stale + U_conf, then clamp to the path fee
    ///      bounds. Pulled out of `getAnchorPathQuote` to keep that function off the stack-too-deep edge
    ///      (sVol/rawSpread live here, not in the hot frame).
    ///      - S_vol = minFeePath + σ·vega/(100·BPS) — per-asset floor at σ=0 (MIN_FEE_PBPS = 1 PBPS = 0.01 bp).
    ///      - U_stale = STALE_Z·σ·√(age)/100 keyed on the stalest endpoint: defense-in-depth for keeper
    ///        LAG so a late/censored keeper degrades gracefully (wider quote) rather than being picked
    ///        off up to the hard TTL revert. ≈0 when fresh (age→0). With the deviation-triggered push
    ///        policy (minFee ≈ 2·θ) this rarely engages — it only bites when the keeper misses its push.
    ///      - U_conf = confidence·(PBPS/BPS): the feed's 1σ CI (bps) widens the quote so uncertain marks
    ///        are priced defensively. A CI past MAX_CONFIDENCE_HALT_BPS already halted in `_readOracle`.
    function _pathSpread(PathAccumulator memory acc, EndpointCache memory cIn, EndpointCache memory cOut)
        private pure returns (uint16)
    {
        uint256 sVol = uint256(acc.minFeePath)
            + (uint256(acc.sigmaPair) * uint256(cIn.vega > cOut.vega ? cIn.vega : cOut.vega)) / (100 * SC.BPS);
        uint256 conf = uint256(cIn.confidence > cOut.confidence ? cIn.confidence : cOut.confidence);
        uint256 rawSpread = sVol
            + _staleTerm(cIn.staleExcess > cOut.staleExcess ? cIn.staleExcess : cOut.staleExcess, acc.sigmaPair)
            + conf * (SC.PBPS / SC.BPS); // bps → PBPS
        return rawSpread > uint256(acc.maxFeePath) ? acc.maxFeePath : uint16(rawSpread);
    }

    /// @dev Staleness term (PBPS) = STALE_Z·σ·√(staleExcess)/BPS, where staleExcess = age beyond the
    ///      keeper grace (ttl/2). σ (getSigma) is PBPS-scaled (1e4 = 1%), so it MUST be normalized by
    ///      BPS here exactly as `sVol` normalizes σ·vega by 100·BPS — otherwise the raw σ·√excess term
    ///      is ~1e4× too large and saturates the spread to maxFee the instant age crosses ttl/2 (a step,
    ///      not the intended gentle ramp). Now: σ=1% (1e4), excess=100s → ~10bps; excess=1800s → ~42bps
    ///      (non-saturating, clamped by maxFeePath only in extremes). sqrt(0)=0 ⇒ 0 within the keeper
    ///      grace (flat market stays tight). Own frame keeps `_pathSpread` off the stack-too-deep edge.
    function _staleTerm(uint32 staleExcess, uint32 sigma) private pure returns (uint256) {
        return (STALE_Z * uint256(sigma) * FixedPointMathLib.sqrt(staleExcess)) / SC.BPS;
    }

    /// @dev Staleness excess + confidence for spread surcharge. Price is read separately on the leg path.
    function _readOracleStale(IPool.PoolStorage storage $, address token)
        private view returns (uint32 staleExcess, uint16 confidence)
    {
        IOracle.FeedData memory feed = _readOracle($, token);
        confidence = feed.confidence;
        uint256 age = block.timestamp >= feed.updatedAt ? block.timestamp - feed.updatedAt : 0;
        uint256 grace = uint256(feed.ttl) / 2;
        staleExcess = age > grace ? uint32(age - grace) : 0;
    }

    /// @dev Single SLOAD/oracle read per endpoint.
    function _cacheEndpoint(IPool.PoolStorage storage $, address token)
        private view returns (EndpointCache memory cache)
    {
        IPool.Asset storage asset = $.assets[token];
        IPool.RiskConfig storage rc = $.riskConfigs[token];
        cache.reserves = asset.reserves;
        cache.liabilities = asset.liabilities;
        cache.vega = asset.vega;
        cache.gamma = asset.gamma;
        cache.coverageMin = rc.coverageMin;
        cache.coverageMax = rc.coverageMax;
        cache.kappaCovBps = rc.kappaCovBps; // base stays 0 (numeraire — never walled)
        if (token == $.baseToken) {
            // R44-2 (T3-HIGH2): if a base-token oracle is pinned, read real base price + halt
            //   swaps on depeg. Otherwise fallback to 1e18 (legacy stable-base behavior).
            _readBasePriceOrHalt($);
            // base leg is the numeraire (price≡1 / its own depeg breaker) — no keeper-staleness pick-off.
        } else {
            (cache.staleExcess, cache.confidence) = _readOracleStale($, token);
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
        // Freshness gate: the base leg is exempt from the staleness premium (its price is pinned to the
        // unit of account, not keeper-pushed), so a FROZEN base feed sitting inside the depeg band would
        // otherwise pass unchecked. Fail-closed on a stale feed, mirroring _readOracle's per-feed TTL.
        uint256 baseAge = block.timestamp >= feed.updatedAt ? block.timestamp - feed.updatedAt : type(uint32).max;
        if (baseAge > feed.ttl) revert Err.StaleData(baseAge > type(uint32).max ? type(uint32).max : uint32(baseAge), feed.ttl);
        basePrice = Oracle.mark(feed);
        if (basePrice == 0) revert Err.BaseDepegged(0, type(uint256).max);
        uint256 deviation = basePrice > 1e18 ? basePrice - 1e18 : 1e18 - basePrice;
        uint256 devBps = (deviation * SC.BPS) / 1e18;
        if (devBps > uint256(C.BASE_DEPEG_HALT_BPS)) revert Err.BaseDepegged(basePrice, devBps);
    }

    /// @dev Walk every path leg (all EDGES under the depth-1 star), accumulating amounts, hop prices,
    ///      and the path σ/Δ/fee bounds into `acc`/`quote` (memory, by ref). Own frame keeps
    ///      `getAnchorPathQuote` off the stack-too-deep edge (the 6-tuple leg result lives here).
    function _walkLegs(
        IPool.PoolStorage storage $,
        IPool.RoutePath memory path,
        PathAccumulator memory acc,
        IPool.SwapQuote memory quote
    ) private view {
        for (uint256 i = 0; i < path.hops.length - 1; i++) {
            LegResult memory r = _executeLeg($, path.hops[i], path.hops[i + 1], acc.currentAmount);
            acc.currentAmount = r.amountOut;
            quote.hopAmounts[i + 1] = r.amountOut;
            quote.hopPrices[i] = r.execPriceB64;
            if (r.sigma > acc.sigmaPair) acc.sigmaPair = r.sigma;
            if (r.minFee > acc.minFeePath) acc.minFeePath = r.minFee;
            if (r.maxFee > acc.maxFeePath) acc.maxFeePath = r.maxFee;
        }
    }

    /// @dev Execute one path leg → LegResult (out, σ, minFee, maxFee, execPriceB64).
    function _executeLeg(
        IPool.PoolStorage storage $,
        address from,
        address to,
        uint256 amountIn
    ) private view returns (LegResult memory r) {
        if (amountIn == 0) revert Err.ZeroValue();
        bool isUpward = $.assets[from].anchor == to;
        address profileAsset = isUpward ? from : to;

        (uint256 twap, uint32 sigma, uint16 minFee, uint16 maxFee) = _legMarkAndFees($, profileAsset);
        r.sigma = sigma;
        r.minFee = minFee;
        r.maxFee = maxFee;

        IPool.Asset storage asset = $.assets[profileAsset];
        IPool.RiskConfig memory rc = $.riskConfigs[profileAsset];
        r.amountOut = _priceEdgeHop($, asset, rc, amountIn, twap, sigma, isUpward, profileAsset);
        bool clamped;
        (r.amountOut, clamped) = _legScaleOut($, from, to, r.amountOut);
        r.execPriceB64 = clamped ? 0 : _legExecPriceB64($, from, to, amountIn, r.amountOut, isUpward);
    }

    /// @dev Decimal rescale + reserve cap on leg output (minLiquidity enforced @ Exchange).
    function _legScaleOut(IPool.PoolStorage storage $, address from, address to, uint256 amountOut)
        private view returns (uint256 out, bool clamped)
    {
        uint8 decimalsFrom = $.assets[from].decimals;
        uint8 decimalsTo = $.assets[to].decimals;
        if (decimalsFrom > decimalsTo) amountOut /= 10 ** uint256(decimalsFrom - decimalsTo);
        else if (decimalsTo > decimalsFrom) amountOut *= 10 ** uint256(decimalsTo - decimalsFrom);
        uint128 toRes = $.assets[to].reserves;
        clamped = amountOut > toRes;
        out = clamped ? toRes : amountOut;
    }

    /// @dev Leg oracle read + fee bounds. Own frame keeps `_executeLeg` stack-safe under via_ir.
    function _legMarkAndFees(IPool.PoolStorage storage $, address profileAsset)
        private view returns (uint256 twap, uint32 sigma, uint16 minFee, uint16 maxFee)
    {
        if (profileAsset == $.baseToken) {
            twap = _readBasePriceOrHalt($);
            sigma = Oracle.getSigma(Oracle.getBaseFeed());
        } else {
            IOracle.FeedData memory feed = _readOracle($, profileAsset);
            twap = Oracle.mark(feed);
            sigma = Oracle.getSigma(feed);
        }
        IPool.Asset storage asset = $.assets[profileAsset];
        minFee = asset.minFeeBps;
        maxFee = asset.maxFeeBps;
    }

    /// @dev Informational per-hop execution price for SwapQuote.hopPrices (UI/analytics only).
    function _legExecPriceB64(
        IPool.PoolStorage storage $,
        address from,
        address to,
        uint256 amountIn,
        uint256 amountOut,
        bool isUpward
    ) private view returns (uint64 execPriceB64) {
        uint8 decimalsFrom = $.assets[from].decimals;
        uint8 decimalsTo = $.assets[to].decimals;
        uint256 price18 = (amountOut * 1e18 * (10 ** uint256(18 - decimalsTo))) /
            (amountIn * (10 ** uint256(18 - decimalsFrom)));
        if (price18 == 0) revert Err.ZeroValue();
        if (isUpward) {
            execPriceB64 = M.encodeB64(price18 / (10 ** uint256(18 - decimalsTo)), decimalsTo);
        } else {
            execPriceB64 = M.encodeB64((uint256(1e18) * 1e18) / price18, 18);
        }
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
            // child→base: amountIn is already in profile-asset (child) decimals, matching `depth`.
            (amountOut,) = quoteSwap(
                amountIn, asset.reserves, asset.liabilities, twap, sigma,
                $.profiles[profileAsset], skew, true, rc.depthAmplifier,
                asset.vega, asset.minDispersion, asset.maxDispersion
            );
        } else {
            // Buy quote w/ cost: estimate child-out via mid, traverse spline, refine.
            uint256 depth = calculateDepth(asset.reserves, asset.liabilities, rc.depthAmplifier);
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

    /// @dev Read the token's external feed, tx-cache hit first. VIEW: never writes the transient cache
    ///      — the swap-exec path pre-warms it via `_primeOracleCache`, so a quote-only call
    ///      (Pool.getSwapQuote → Router route-discovery STATICCALL) stays a pure `view`.
    function _readOracle(IPool.PoolStorage storage $, address token)
        private view returns (IOracle.FeedData memory data)
    {
        bool found;
        (found, data) = TCache.tryLoadOracleFeed(token);
        if (found) return data;
        return _fetchFeed($, token);
    }

    /// @dev Fetch + fail-closed gate a feed, NO cache write. Primary is ALWAYS an external IOracle
    ///      (internal-TWAP discovery removed). Two axes: (1) STALE — revert if the mark is older than
    ///      its per-feed `ttl` (a dead/censored keeper must halt, not be picked off); (2) UNCERTAIN —
    ///      revert if the feed's 1σ CI exceeds MAX_CONFIDENCE_HALT_BPS. Halting > bleeding.
    function _fetchFeed(IPool.PoolStorage storage $, address token)
        private view returns (IOracle.FeedData memory data)
    {
        IPool.OracleConfig memory cfg = $.oracleConfigs[token];
        if (cfg.primary == address(0)) revert Err.NotConfigured(Err.Resource.ORACLE, token);
        // INTERNAL mode: quote off a synthetic never-stale peg feed (mark = ema = pegB64, σ = STABLE_SIGMA,
        // confidence 0). A CONSTANT mark ⇒ no per-swap write ⇒ the monopoly-sequencer LVR leak is void.
        // This also makes _readOracleAge yield staleExcess=confidence=0 (fresh, certain) automatically.
        // The external feed still GATES via _priceBandGuard (depeg breaker) — it is not the price source.
        if (cfg.mode == C.ORACLE_MODE_INTERNAL) {
            return Oracle.getPegFeed($.assets[token].pegB64, C.STABLE_SIGMA);
        }
        data = IOracle(cfg.primary).getFeed(cfg.feedId);
        uint256 age = block.timestamp >= data.updatedAt ? block.timestamp - data.updatedAt : type(uint32).max;
        if (age > data.ttl) {
            revert Err.StaleData(age > type(uint32).max ? type(uint32).max : uint32(age), data.ttl);
        }
        if (data.confidence > C.MAX_CONFIDENCE_HALT_BPS) {
            revert Err.ThresholdViolation(data.confidence, C.MAX_CONFIDENCE_HALT_BPS);
        }
    }

    /// @dev Swap-exec pre-warm: cache both endpoints' feeds once so the leg walk + priceBandGuard
    ///      dedupe to tload hits (the multi-leg gas optimization, unchanged from pre-split behavior).
    ///      Base token is priced via `_readBasePriceOrHalt`, never `_readOracle` ⇒ nothing to cache.
    ///      Uses the identical fetch+gate as a cache-miss read, so cached == fresh (no behavior change).
    function _primeOracleCache(IPool.PoolStorage storage $, address tokenIn, address tokenOut) private {
        _cacheFeed($, tokenIn);
        _cacheFeed($, tokenOut);
    }

    function _cacheFeed(IPool.PoolStorage storage $, address token) private {
        if (token == $.baseToken) return;
        (bool found,) = TCache.tryLoadOracleFeed(token);
        if (found) return;
        TCache.cacheOracleFeed(token, _fetchFeed($, token));
    }

    /// @dev Convex coverage toll — port of prime aimm.rs `cov_q` (sim-validated, commit 2d21a29). Charges
    ///      κ·L·(Q(c₀)−Q(c₁)) in OUTPUT units on the drained side, Q(c)=ln c−c+1 (the convex no-drain wall
    ///      that diverges as c→0). The toll is retained in the output reserve (skim to LP surplus), never a
    ///      mark shift ⇒ NOT round-trip-extractable (unlike the deleted covPremiumBps). Uncapped wall: as
    ///      c₁→0 the toll saturates to grossOut ⇒ amountOut→0, halting the drain gracefully.
    ///      Charge-only (dQ clamped ≥0): a coverage-RESTORING trade drains the healthy leg (c≈1, Q≈0 ⇒
    ///      ~0 toll), so no rebate ledger is needed and a round trip strictly loses (LP-safe). κ=0 ⇒ 0 gas.
    ///      Own frame keeps `getAnchorPathQuote` off the via_ir stack-too-deep edge.
    ///      Internal (not private) so the CoverageProofs fuzz suite can exercise the pure math directly.
    function _covToll(EndpointCache memory cOut, uint256 grossOut) internal pure returns (uint256) {
        if (cOut.kappaCovBps == 0 || cOut.liabilities == 0 || grossOut == 0) return 0;
        uint256 r0 = uint256(cOut.reserves);
        uint256 l = uint256(cOut.liabilities);
        if (grossOut >= r0) return grossOut; // fully drains the leg → wall blocks the whole fill
        // Clamp both coverages to the peg before differencing: Q(c)=ln c−c+1 is non-monotonic (max at
        // c=1, decreasing on BOTH sides), so a raw endpoint diff lets a drain that STARTS over-covered
        // (c₀>1) cross the peg to below the floor with dQ≤0 ⇒ zero toll — the wall would be bypassable
        // from an over-covered start. min(c,1) restricts Q to its increasing branch so the toll prices
        // exactly the below-peg deficit; the over-peg portion stays free (charge-only) and a
        // drain-toward-peg from above still gives dQ=0.
        uint256 c0 = (r0 * SC.WAD) / l;
        uint256 c1 = ((r0 - grossOut) * SC.WAD) / l;
        if (c0 > SC.WAD) c0 = SC.WAD;
        if (c1 > SC.WAD) c1 = SC.WAD;
        int256 dQ = _covQ(c0) - _covQ(c1);
        if (dQ <= 0) return 0; // draining toward/at peg: no charge (charge-only)
        uint256 toll = (uint256(dQ) * uint256(cOut.kappaCovBps) * l) / (SC.BPS * SC.WAD);
        return toll > grossOut ? grossOut : toll;
    }

    /// @dev Coverage potential Q(c) = ln c − c + 1 (WAD): ≤0, max 0 at c=1, convex wall diverging as c→0.
    ///      Finite differences of Q telescope to 0 over any closed reserve loop ⇒ round-trip-neutral.
    function _covQ(uint256 cWad) internal pure returns (int256) {
        return FixedPointMathLib.lnWad(int256(cWad)) - int256(cWad) + int256(SC.WAD);
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
