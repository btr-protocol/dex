// SPDX-License-Identifier: MIT
pragma solidity =0.8.35;

import {IOracle} from "../interfaces/IOracle.sol";
import {IPool} from "../interfaces/IPool.sol";
import {Err} from "@btr-shared/Errors.sol";
import {B64 as M} from "@btr-shared/libs/B64.sol";
import {NUQuartic as NUQ} from "./NUQuartic.sol";
import {AnchorTree} from "./AnchorTree.sol";
import {Oracle} from "./Oracle.sol";
import {TransientCache as TCache} from "./TransientCache.sol";
import {Constants as C} from "./Constants.sol";
import {Constants as SC} from "@btr-shared/Constants.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @title Pricing -coverage-adjusted pricing + bi-factor fee model.
/// @dev Units: see Constants. BPS=0.01%, PBPS=0.0001%, WAD=1e18.
library Pricing {
  // Staleness-premium coefficient for the A-S σ√age keeper-lag defense in `_pathSpread` (the term is
  // STALE_Z·σ·√excess/BPS). Global (not per-asset) to avoid a RiskConfig storage change; the
  // deviation-push policy (minFee ≈ 2·θ) is the primary defense, so this only bites past the keeper
  // grace (age > ttl/2) — a missed push. 100 gives ~10bps at 1% vol / 100s stale (see _staleTerm).
  uint256 private constant STALE_Z = 100;

  uint256 private constant MAX_IMPACT = 2 * SC.WAD; // 200%
  uint256 private constant MIN_ADJ = SC.WAD / 1000; // 0.1%
  /// @dev Spline segment offset floor: an averaged offset never discounts below −90% of PBPS (price ≥
  ///      10% of mark) even for a pathological knot×dispersion — a hard backstop under the spline curve.
  int256 private constant SPLINE_MIN_OFFSET_PBPS = -int256(SC.PBPS) * 90 / 100;
  /// @dev Absolute execution-price floor = 5% of mark (500 bps); final guard below the spline floor.
  uint256 private constant MIN_EXEC_PRICE_BPS = 500;

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

  /// @notice Quote sell-side swap with coverage-adjusted depth + curve traversal.
  function quoteSwap(
    uint256 amountIn,
    uint128 reserves,
    uint128 liabilities,
    uint256 mark,
    uint32 sigma,
    NUQ.Curve storage curve,
    int8 inventorySkew,
    bool selling,
    uint16 depthAmplifier,
    uint16 vega,
    uint32 minDispersion,
    uint32 maxDispersion
  ) internal view returns (uint256 amountOut) {
    // Calculate effective depth and dispersion
    uint256 depth = calculateDepth(reserves, liabilities, depthAmplifier);
    uint32 dispersion = _calculateDispersion(sigma, vega, minDispersion, maxDispersion);

    // Execution price (base per token, 1e18) from the volume traverse; out = in·px/WAD.
    uint256 executionPrice =
      _traverseCurveByVolume(mark, dispersion, curve, inventorySkew, amountIn, depth, selling);
    amountOut = (amountIn * executionPrice) / SC.WAD;
  }

  /// @dev κ⁻¹: dispersion ∝ σ. dispersion = clamp(minDispersion + σ·vega/1000/BPS, [min,max]).
  ///      `minDispersion` is the quiet-tape floor (owner-set per asset); do NOT hardcode a 1000 PBPS
  ///      base or tight stable bands (1–6 bp) are unreachable when σ≈0.
  function _calculateDispersion(
    uint32 sigma,
    uint16 vega,
    uint32 minDispersion,
    uint32 maxDispersion
  ) internal pure returns (uint32 dispersion) {
    // Linear mapping: dispersion increases with σ above the per-asset floor.
    // Vega controls sensitivity: 10000 (100%=1x) means σ/1000, 5000 (50%=0.5x) means σ/2000
    uint256 scaledSigma = (uint256(sigma) * uint256(vega)) / (1000 * SC.BPS);
    uint256 raw = uint256(minDispersion) + scaledSigma;

    if (raw > uint256(maxDispersion)) return maxDispersion;
    return uint32(raw);
  }

  /// @dev Clamp + scale a PBPS price offset onto the mark: price = mark·max(0, 1 + offset/PBPS).
  function _offsetToPrice(uint256 mark, int256 offsetPbps) private pure returns (uint256) {
    int256 m = int256(SC.PBPS) + offsetPbps;
    if (m < 0) m = 0;
    return (mark * uint256(m)) / SC.PBPS;
  }

  /// @dev Offset → price with the SAME two economic backstops the area path applies: the
  ///      SPLINE_MIN_OFFSET_PBPS floor (offset never below −90% PBPS) and the MIN_EXEC_PRICE_BPS
  ///      floor (price never below 5% of mark). Shared by the area, dust (width==0) and buy-mid
  ///      paths so a mutated/degenerate curve can never quote below the floors on ANY path.
  function _flooredOffsetPrice(uint256 mark, int256 offsetPbps) private pure returns (uint256 px) {
    if (offsetPbps < SPLINE_MIN_OFFSET_PBPS) offsetPbps = SPLINE_MIN_OFFSET_PBPS;
    px = _offsetToPrice(mark, offsetPbps);
    uint256 minPrice = (mark * MIN_EXEC_PRICE_BPS) / SC.BPS;
    if (px < minPrice) px = minPrice;
  }

  /// @dev Dispersion contract: the curve is fitted at its reference dispersion (header dispRef,
  ///      pbps); live quotes y-scale it by dispersion/dispRef, then drop the Q fixed point. A linear
  ///      y-scale preserves monotonicity and C2 exactly — the W-tier is the coarse regime anchor,
  ///      dispersion the fine σ-adaptive scale.
  function _scaleY(int256 yQ, uint256 header, uint32 dispersion) private pure returns (int256) {
    return (yQ * int256(uint256(dispersion))) / (int256((header >> 232) & 0xffff) * NUQ.Q);
  }

  /// @dev Exact analytical quartic I-spline integration → VWAP over trade. Empty curve (header 0 —
  ///      unset preset or presetId 0) falls back to the skew-anchored linear-impact quote: swaps
  ///      stay live between listing and the first profile assignment.
  function _traverseCurveByVolume(
    uint256 mark,
    uint32 dispersion,
    NUQ.Curve storage curve,
    int8 inventorySkew,
    uint256 amountIn,
    uint256 depth,
    bool selling
  ) internal view returns (uint256 avgPrice) {
    uint256 header = curve.header;
    if (header == 0) {
      uint256 impact = (amountIn * SC.WAD) / depth;
      if (impact > MAX_IMPACT) impact = MAX_IMPACT;
      // _skewToPrice floors the mid on the SAME −90% offset / 5%-of-mark backstops the spline path uses,
      // so a degenerate mark (or a pathological dispersion×skew) can never zero the empty-curve BUY quote
      // (SC.WAD+k ≥ WAD ⇒ buy ≥ mid ≥ 5% mark). The SELL branch keeps its own floor: impact adj can still
      // push its output below the floored mid.
      uint256 midPrice = _skewToPrice(mark, inventorySkew, dispersion);
      uint256 k = impact / 2;
      if (selling) {
        uint256 adj = k < SC.WAD ? SC.WAD - k : MIN_ADJ;
        uint256 sellPx = (midPrice * adj) / SC.WAD;
        uint256 minPrice = (mark * MIN_EXEC_PRICE_BPS) / SC.BPS; // 5%-of-mark backstop, as on the curve path
        return sellPx < minPrice ? minPrice : sellPx;
      }
      return (midPrice * (SC.WAD + k)) / SC.WAD;
    }
    return _traverseCurve(mark, dispersion, curve, header, inventorySkew, amountIn, depth, selling);
  }

  function _traverseCurve(
    uint256 mark,
    uint32 dispersion,
    NUQ.Curve storage curve,
    uint256 header,
    int8 inventorySkew,
    uint256 amountIn,
    uint256 depth,
    bool selling
  ) private view returns (uint256 avgPrice) {
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
    uint256 lo = selling ? endDepth : startDepth;
    uint256 hi = selling ? startDepth : endDepth;
    uint256 width = hi - lo;
    if (width == 0) {
      return _flooredOffsetPrice(mark, _scaleY(NUQ.evalQ(curve, header, startDepth), header, dispersion));
    }
    int256 avgOffsetPbps =
      _scaleY(NUQ.areaQ(curve, header, lo, hi) / int256(width), header, dispersion);
    avgPrice = _flooredOffsetPrice(mark, avgOffsetPbps);
  }

  /// @dev skew∈[-100,+100] maps linearly onto the spline x-domain [0, SC.BPS]; midpoint SC.BPS/2 at
  ///      skew 0, slope SC.BPS/200 per skew unit (±100 → 0 / SC.BPS).
  /// @dev Phase 42D A4-4 DISCARD: unchecked add is sound -precondition `skew ∈ [-100,+100]`
  ///      is enforced by `computeInventorySkew` clamps; range `[mid - mid, mid + mid] = [0, SC.BPS]`
  ///      always non-negative. Caller MUST pass a clamped skew (int8 alone is insufficient).
  function _skewToDepth(int8 inventorySkew) internal pure returns (uint256) {
    unchecked {
      return uint256(int256(SC.BPS) / 2 + int256(inventorySkew) * (int256(SC.BPS) / 200));
    }
  }

  /// @dev skew → absolute price (no-profile fallback). offsetPbps = skew*disp/100. Routes through the
  ///      SAME backstops as the curve path (`_flooredOffsetPrice`): a fresh listing (skew ≡ −100, empty
  ///      preset) under an extreme admin maxDispersion (≥ PBPS) would otherwise clamp offset ≤ −PBPS →
  ///      midPrice 0 → zero/bricked buy quote (buy-sizing div-by-0 at `_priceEdgeHop`). Floor covers both
  ///      empty-curve buy call sites (fallback + sizing) and the sell fallback consistently.
  function _skewToPrice(uint256 mark, int8 skew, uint32 dispersion)
    internal
    pure
    returns (uint256)
  {
    return _flooredOffsetPrice(mark, (int256(int16(skew)) * int256(uint256(dispersion))) / 100);
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
    uint16 confidence; // feed 1σ CI (bps); widens the spread (see _pathSpread confidence surcharge)
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

  /// @notice Swap-exec entry: pre-warm oracle cache, quote without UI analytics fields.
  function getAnchorPathQuote(
    IPool.PoolStorage storage $,
    address tokenIn,
    address tokenOut,
    uint256 amountIn
  ) internal returns (IPool.SwapQuote memory quote) {
    _primeOracleCache($, tokenIn, tokenOut);
    return _quotePath($, tokenIn, tokenOut, amountIn, false);
  }

  /// @notice View quote (no cache writes) — includes hopPrices + endpoint skews for UI.
  function getAnchorPathQuoteView(
    IPool.PoolStorage storage $,
    address tokenIn,
    address tokenOut,
    uint256 amountIn
  ) internal view returns (IPool.SwapQuote memory quote) {
    return _quotePath($, tokenIn, tokenOut, amountIn, true);
  }

  function _quotePath(
    IPool.PoolStorage storage $,
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    bool analytics
  ) private view returns (IPool.SwapQuote memory quote) {
    IPool.RoutePath memory path = AnchorTree.findRoutingPath($, tokenIn, tokenOut);

    // Exec path skips route/hop analytics arrays (G-2); view path keeps them for UI.
    if (analytics) {
      quote.routeHops = path.hops;
      quote.hopAmounts = new uint256[](path.hops.length);
      quote.hopAmounts[0] = amountIn;
      quote.hopPrices = new uint64[](path.hops.length - 1);
    }

    EndpointCache memory cIn = _cacheEndpoint($, tokenIn);
    EndpointCache memory cOut = _cacheEndpoint($, tokenOut);

    for (uint256 i = 1; i + 1 < path.hops.length; i++) {
      address hop = path.hops[i];
      if (($.riskConfigs[hop].flags & C.HALT_MASK) != 0) {
        revert Err.FeatureDisabled(Err.Resource.ASSET);
      }
      if (hop == $.baseToken) _readBasePriceOrHalt($);
    }

    PathAccumulator memory acc;
    acc.currentAmount = amountIn;

    _walkLegs($, path, acc, quote, analytics);
    if (analytics) quote.amountIn = amountIn; // echo of caller's own arg — view/UI only
    _settleQuote($, quote, acc, cIn, cOut, analytics);
  }

  /// @dev Path tail: spread, coverage toll, fee split; skews only when `analytics`.
  function _settleQuote(
    IPool.PoolStorage storage $,
    IPool.SwapQuote memory quote,
    PathAccumulator memory acc,
    EndpointCache memory cIn,
    EndpointCache memory cOut,
    bool analytics
  ) private view {
    quote.spreadPbps = _pathSpread(acc, cIn, cOut);
    acc.currentAmount -= _covToll(cOut, acc.currentAmount);
    uint256 feeOut = (acc.currentAmount * uint256(quote.spreadPbps)) / (2 * SC.PBPS);
    (quote.protoFee, quote.lpFee) = splitFee(feeOut, $.feeParams.protoShare);
    quote.amountOut = acc.currentAmount - feeOut;
    if (analytics) {
      quote.skewIn = computeInventorySkew(
        cIn.reserves,
        cIn.liabilities,
        cIn.coverageMin,
        cIn.coverageMax,
        cIn.gamma
      );
      quote.skewOut = computeInventorySkew(
        cOut.reserves,
        cOut.liabilities,
        cOut.coverageMin,
        cOut.coverageMax,
        cOut.gamma
      );
    }
  }

  /// @dev Full path spread (PBPS, clamped): S_vol + U_stale + U_conf, then clamp to the path fee
  ///      bounds. Pulled out of `getAnchorPathQuote` to keep that function off the stack-too-deep edge
  ///      (sVol/rawSpread live here, not in the hot frame).
  ///      - S_vol = minFeePath + σ·vega/(100·BPS) — per-asset floor at σ=0 (MIN_FEE_PBPS = 1 PBPS = 0.01 bp).
  ///      - U_stale = STALE_Z·σ·√(age)/BPS keyed on the stalest endpoint: defense-in-depth for keeper
  ///        LAG so a late/censored keeper degrades gracefully (wider quote) rather than being picked
  ///        off up to the hard TTL revert. ≈0 when fresh (age→0). With the deviation-triggered push
  ///        policy (minFee ≈ 2·θ) this rarely engages — it only bites when the keeper misses its push.
  ///      - U_conf = confidence·(PBPS/BPS): the feed's 1σ CI (bps) widens the quote so uncertain marks
  ///        are priced defensively. A CI past MAX_CONFIDENCE_HALT_BPS already halted in `_readOracle`.
  function _pathSpread(
    PathAccumulator memory acc,
    EndpointCache memory cIn,
    EndpointCache memory cOut
  ) private pure returns (uint16) {
    uint256 sVol = uint256(acc.minFeePath)
      + (uint256(acc.sigmaPair) * uint256(cIn.vega > cOut.vega ? cIn.vega : cOut.vega))
      / (100 * SC.BPS);
    uint256 conf = uint256(cIn.confidence > cOut.confidence ? cIn.confidence : cOut.confidence);
    uint256 rawSpread = sVol
      + _staleTerm(
        cIn.staleExcess > cOut.staleExcess ? cIn.staleExcess : cOut.staleExcess, acc.sigmaPair
      ) + conf * (SC.PBPS / SC.BPS); // bps → PBPS
    return rawSpread > uint256(acc.maxFeePath) ? acc.maxFeePath : uint16(rawSpread);
  }

  /// @dev Staleness term (PBPS) = STALE_Z·σ·√(staleExcess)/BPS, where staleExcess = age beyond the
  ///      keeper grace (ttl/2). σ is PBPS-scaled (1e4 = 1%), so it MUST be normalized by
  ///      BPS here exactly as `sVol` normalizes σ·vega by 100·BPS — otherwise the raw σ·√excess term
  ///      is ~1e4× too large and saturates the spread to maxFee the instant age crosses ttl/2 (a step,
  ///      not the intended gentle ramp). Now: σ=1% (1e4), excess=100s → ~10bps; excess=1800s → ~42bps
  ///      (non-saturating, clamped by maxFeePath only in extremes). sqrt(0)=0 ⇒ 0 within the keeper
  ///      grace (flat market stays tight). Own frame keeps `_pathSpread` off the stack-too-deep edge.
  function _staleTerm(uint32 staleExcess, uint32 sigma) private pure returns (uint256) {
    if (staleExcess == 0 || sigma == 0) return 0; // typical case: inside keeper grace — skip the sqrt
    return (STALE_Z * uint256(sigma) * FixedPointMathLib.sqrt(staleExcess)) / SC.BPS;
  }

  /// @dev Staleness excess + confidence for spread surcharge. Price is read separately on the leg path.
  function _readOracleStale(IPool.PoolStorage storage $, address token)
    private
    view
    returns (uint32 staleExcess, uint16 confidence)
  {
    IOracle.FeedData memory feed = _readOracle($, token);
    confidence = feed.confidence;
    // Authenticated source age when present (same clock as Oracle.gate / observedAt).
    uint32 obs = Oracle.observedAt(feed);
    uint256 age = block.timestamp >= obs ? block.timestamp - obs : 0;
    uint256 grace = uint256(feed.ttl) / 2;
    staleExcess = age > grace ? uint32(age - grace) : 0;
  }

  /// @dev Single SLOAD/oracle read per endpoint.
  function _cacheEndpoint(IPool.PoolStorage storage $, address token)
    private
    view
    returns (EndpointCache memory cache)
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
      // The base asset's canonical OracleConfig is also its depeg breaker. Replacements use the
      // same timelocked oracle-update path as every spoke; no duplicate fast authority exists.
      _readBasePriceOrHalt($);
      // base leg is the numeraire (price≡1 / its own depeg breaker) — no keeper-staleness pick-off.
    } else {
      (cache.staleExcess, cache.confidence) = _readOracleStale($, token);
    }
  }

  /// @notice Read the base asset's canonical oracle and revert on depeg.
  /// @dev Compares the external mark to 1e18 unit-of-account parity. Reverts `Err.BaseDepegged` when
  ///      |basePrice - 1e18| * BPS / 1e18 > `Constants.BASE_DEPEG_HALT_BPS`.
  function _readBasePriceOrHalt(IPool.PoolStorage storage $)
    internal
    view
    returns (uint256 basePrice)
  {
    address base = $.baseToken;
    // Tx-cache hit first (primed by the swap-exec path): saves a full external getFeed per hop —
    // spoke→spoke reads the base mark on BOTH legs. View path unchanged (tload is view-safe).
    // A cache hit was already gated at prime time (same tx, same timestamp ⇒ identical verdict) —
    // decode the mark and skip straight to the depeg band, matching _readOracle's cached-feed model.
    (bool found, IOracle.FeedData memory feed) = TCache.tryLoadOracleFeed(base);
    if (found) {
      basePrice = Oracle.mark(feed);
    } else {
      IPool.OracleConfig storage cfg = $.oracleConfigs[base];
      if (cfg.primary == address(0)) revert Err.NotConfigured(Err.Resource.ORACLE, base);
      feed = IOracle(cfg.primary).getFeed(cfg.feedId);
      // ORC-10: the base leg is exempt from the staleness PREMIUM (price is pinned to the unit of
      // account, not keeper-pushed), so it must still clear the same fail-closed safety triad every
      // other priced/gating feed does — STALE (a FROZEN base feed inside the depeg band), DEAD
      // (mark 0) and UNCERTAIN (confidence > halt). `Oracle.gate` centralizes all three.
      basePrice = Oracle.gate(feed);
    }
    uint256 deviation = basePrice > SC.WAD ? basePrice - SC.WAD : SC.WAD - basePrice;
    uint256 devBps = (deviation * SC.BPS) / SC.WAD;
    if (devBps > uint256(C.BASE_DEPEG_HALT_BPS)) revert Err.BaseDepegged(basePrice, devBps);
  }

  function _walkLegs(
    IPool.PoolStorage storage $,
    IPool.RoutePath memory path,
    PathAccumulator memory acc,
    IPool.SwapQuote memory quote,
    bool analytics
  ) private view {
    for (uint256 i = 0; i < path.hops.length - 1; i++) {
      LegResult memory r =
        _executeLeg($, path.hops[i], path.hops[i + 1], acc.currentAmount, analytics);
      acc.currentAmount = r.amountOut;
      if (analytics) {
        quote.hopAmounts[i + 1] = r.amountOut;
        quote.hopPrices[i] = r.execPriceB64;
      }
      if (r.sigma > acc.sigmaPair) acc.sigmaPair = r.sigma;
      if (r.minFee > acc.minFeePath) acc.minFeePath = r.minFee;
      if (r.maxFee > acc.maxFeePath) acc.maxFeePath = r.maxFee;
    }
  }

  function _executeLeg(
    IPool.PoolStorage storage $,
    address from,
    address to,
    uint256 amountIn,
    bool analytics
  ) private view returns (LegResult memory r) {
    if (amountIn == 0) revert Err.ZeroValue();
    bool isUpward = $.assets[from].anchor == to;
    address profileAsset = isUpward ? from : to;

    (uint256 mark, uint32 sigma, uint16 minFee, uint16 maxFee) = _legMarkAndFees($, profileAsset);
    r.sigma = sigma;
    r.minFee = minFee;
    r.maxFee = maxFee;

    IPool.Asset storage asset = $.assets[profileAsset];
    IPool.RiskConfig storage rc = $.riskConfigs[profileAsset];
    r.amountOut = _priceEdgeHop($, asset, rc, amountIn, mark, sigma, isUpward, profileAsset);
    bool clamped;
    (r.amountOut, clamped) = _legScaleOut($, from, to, r.amountOut);
    if (analytics && !clamped) {
      r.execPriceB64 = _legExecPriceB64($, from, to, amountIn, r.amountOut, isUpward);
    }
  }

  /// @dev Decimal rescale + reserve cap on leg output (minLiquidity enforced @ Exchange).
  function _legScaleOut(IPool.PoolStorage storage $, address from, address to, uint256 amountOut)
    private
    view
    returns (uint256 out, bool clamped)
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
    private
    view
    returns (uint256 mark, uint32 sigma, uint16 minFee, uint16 maxFee)
  {
    // Depth-1 star: profileAsset is always the spoke (edge), never base (L2-1).
    IOracle.FeedData memory feed = _readOracle($, profileAsset);
    mark = Oracle.mark(feed);
    sigma = feed.sigma;
    IPool.Asset storage asset = $.assets[profileAsset];
    minFee = asset.minFeePbps;
    maxFee = asset.maxFeePbps;
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
    uint256 price1e18 = (amountOut * 1e18 * (10 ** uint256(18 - decimalsTo)))
      / (amountIn * (10 ** uint256(18 - decimalsFrom)));
    if (price1e18 == 0) revert Err.ZeroValue();
    if (isUpward) {
      execPriceB64 = M.encodeB64(price1e18 / (10 ** uint256(18 - decimalsTo)), decimalsTo);
    } else {
      execPriceB64 = M.encodeB64((SC.WAD * SC.WAD) / price1e18, 18);
    }
  }

  /// @dev Edge hop w/ full price impact.
  function _priceEdgeHop(
    IPool.PoolStorage storage $,
    IPool.Asset storage asset,
    IPool.RiskConfig storage rc,
    uint256 amountIn,
    uint256 mark,
    uint32 sigma,
    bool selling,
    address profileAsset
  ) private view returns (uint256 amountOut) {
    int8 skew = computeInventorySkew(
      asset.reserves, asset.liabilities, rc.coverageMin, rc.coverageMax, asset.gamma
    );

    NUQ.Curve storage curve = $.curves[$.assets[profileAsset].presetId];
    if (selling) {
      // child→base: amountIn is already in profile-asset (child) decimals, matching `depth`.
      amountOut = quoteSwap(
        amountIn,
        asset.reserves,
        asset.liabilities,
        mark,
        sigma,
        curve,
        skew,
        true,
        rc.depthAmplifier,
        asset.vega,
        asset.minDispersion,
        asset.maxDispersion
      );
    } else {
      // Buy: mid estimate at the skew anchor sizes the child-unit volume for the real traverse.
      uint256 depth = calculateDepth(asset.reserves, asset.liabilities, rc.depthAmplifier);
      uint32 dispersion =
        _calculateDispersion(sigma, asset.vega, asset.minDispersion, asset.maxDispersion);
      uint256 header = curve.header;
      uint256 midPrice = header == 0
        ? _skewToPrice(mark, skew, dispersion)
        : _flooredOffsetPrice(
          mark, _scaleY(NUQ.evalQ(curve, header, _skewToDepth(skew)), header, dispersion)
        );
      uint256 estOut = (amountIn * SC.WAD) / midPrice;
      int256 decShift =
        int256(uint256(asset.decimals)) - int256(uint256($.assets[asset.anchor].decimals));
      uint256 estChild =
        decShift >= 0 ? estOut * (10 ** uint256(decShift)) : estOut / (10 ** uint256(-decShift));
      uint256 execPrice =
        _traverseCurveByVolume(mark, dispersion, curve, skew, estChild, depth, false);
      amountOut = (amountIn * SC.WAD) / execPrice;
    }
  }

  /// @dev Read the token's external feed, tx-cache hit first. VIEW: never writes the transient cache
  ///      — the swap-exec path pre-warms it via `_primeOracleCache`, so a quote-only call
  ///      (Pool.getSwapQuote via off-chain route-discovery STATICCALL) stays a pure `view`.
  function _readOracle(IPool.PoolStorage storage $, address token)
    private
    view
    returns (IOracle.FeedData memory data)
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
    private
    view
    returns (IOracle.FeedData memory data)
  {
    IPool.OracleConfig storage cfg = $.oracleConfigs[token];
    if (cfg.primary == address(0)) revert Err.NotConfigured(Err.Resource.ORACLE, token);
    // INTERNAL mode: quote off a synthetic never-stale peg feed (mark = pegB64, σ = STABLE_SIGMA_PBPS,
    // confidence 0). External feed still GATES via priceBandGuard (depeg breaker).
    if (cfg.mode == C.ORACLE_MODE_INTERNAL) {
      return Oracle.getPegFeed($.assets[token].pegB64, C.STABLE_SIGMA_PBPS);
    }
    data = IOracle(cfg.primary).getFeed(cfg.feedId);
    // ORC-10: STALE + UNCERTAIN + DEAD — centralized in Oracle.gate.
    Oracle.gate(data);
  }

  /// @dev Swap-exec pre-warm: cache both endpoints' feeds once so the leg walk + priceBandGuard
  ///      dedupe to tload hits (the multi-leg gas optimization, unchanged from pre-split behavior).
  ///      Base token is priced via `_readBasePriceOrHalt`, never `_readOracle` ⇒ nothing to cache.
  ///      Uses the identical fetch+gate as a cache-miss read, so cached == fresh (no behavior change).
  function _primeOracleCache(IPool.PoolStorage storage $, address tokenIn, address tokenOut)
    private
  {
    _cacheFeed($, tokenIn);
    _cacheFeed($, tokenOut);
    // Base is read by _readBasePriceOrHalt on every hop of every leg — prime it too so multi-leg
    // paths (and the depeg re-check per leg) hit tload instead of an external getFeed each time.
    _cacheFeed($, $.baseToken);
  }

  function _cacheFeed(IPool.PoolStorage storage $, address token) private {
    (bool found,) = TCache.tryLoadOracleFeed(token);
    if (found) return;
    TCache.cacheOracleFeed(token, _fetchFeed($, token));
  }

  /// @dev Convex coverage toll — port of `dex/sim/src/amm/aimm.rs` `cov_q` (sim-validated, commit 2d21a29). Charges
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
    if (cWad == SC.WAD) return 0; // Q(1)=0 analytic max; skip lnWad on clamped at/above-peg legs
    return FixedPointMathLib.lnWad(int256(cWad)) - int256(cWad) + int256(SC.WAD);
  }

  /// @notice Split totalFee → (proto, lp). protoShare ∈ [0,100].
  function splitFee(uint256 totalFee, uint8 protoShare)
    internal
    pure
    returns (uint256 protoFee, uint256 lpFee)
  {
    protoFee = (totalFee * uint256(protoShare)) / 100;
    lpFee = totalFee - protoFee;
  }

  // --- Coverage ---

  /// @notice Coverage ratio R/L. uint256.max if L == 0.
  function calculateCoverage(uint128 reserves, uint128 liabilities)
    internal
    pure
    returns (uint256)
  {
    if (liabilities == 0) return type(uint256).max;
    return (uint256(reserves) * SC.WAD) / uint256(liabilities);
  }

  /// @notice Effective pricing depth. D = R + k·(L-R)·progress^(1/(1+2k)) on (50%, 100%).
  ///         k = depthAmplifier / PBPS. Concave monotonic.
  function calculateDepth(uint128 reserves, uint128 liabilities, uint16 depthAmplifier)
    internal
    pure
    returns (uint256 depth)
  {
    if (reserves == 0) return 1; // both zero or undercollateralized
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
