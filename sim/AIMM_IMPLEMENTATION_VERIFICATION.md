# AIMM Implementation Verification

## Overview
This document verifies that the AIMM simulator implementation will match the production Solidity code exactly, focusing on the critical math components: TWAP/EMA accumulators, volatility calculation, spline traversal, and asymmetric spread calculation.

**Test Case Specification:**
- Flat spline (2 points only): weights=[100, 100], endOffsets=[-50, 50]
- Neutral parameters: gamma=1.0x, vega=1.0x, lambda=1.0x
- TWAP: 2-hour fast, 12-hour slow exponential moving average
- Focus: Verify pricing math matches LibPricing.sol exactly

---

## 1. Oracle Data Structure (IOracleV1.FeedData)

**Solidity Definition** (`contracts/src/interfaces/IOracleV1.sol`):
```solidity
struct FeedData {
    uint64 lastPriceB64;    // Current price in B64 format (base per token)
    int32 fastOffset;       // Fast EMA offset relative to current (0.0001% units)
    int32 slowOffset;       // Slow EMA offset relative to current (0.0001% units)
    uint32 fastVolEMA;      // Fast volatility EMA (1e6 precision, 0.0001% = 1 unit)
    uint32 slowVolEMA;      // Slow volatility EMA (1e6 precision)
    uint32 updatedAt;       // Last update timestamp
    uint16 ttl;             // Time to live for this feed
    uint8 confidence;       // Confidence level
}
```

**Key Properties:**
- `lastPriceB64`: B64-encoded price (custom floating-point format)
- `fastOffset` & `slowOffset`: Represent EMA as offset from current price (not absolute prices)
  - Formula: `offset = ((ema / current) - 1) × OFFSET_PRECISION`
  - OFFSET_PRECISION = 10,000,000 (0.0001% units)
- `fastVolEMA` & `slowVolEMA`: Volatility in VOL_BASE units (1e6 precision)

---

## 2. EMA Calculation & TWAP Accumulators

**Solidity Implementation** (LibOracle.sol, lines 43-77):
```solidity
function decodeB64s(IOracleV1.FeedData memory feed)
    internal pure returns (uint256 priceFast, uint256 priceSlow)
{
    uint256 currentPrice = M.b64To1e18(feed.lastPriceB64);  // Decode B64 → 1e18
    priceFast = _applyOffset(currentPrice, feed.fastOffset);  // current × (1 + offset/OFFSET_PRECISION)
    priceSlow = _applyOffset(currentPrice, feed.slowOffset);  // current × (1 + offset/OFFSET_PRECISION)
}

function _applyOffset(uint256 price1e18, int32 offset) private pure returns (uint256 ema1e18)
{
    // ema = current * (OFFSET_PRECISION + offset) / OFFSET_PRECISION
    int256 multiplier = int256(OFFSET_PRECISION) + int256(offset);
    if (multiplier <= 0) return 1;  // Minimum 1 wei
    return (price1e18 * uint256(multiplier)) / OFFSET_PRECISION;
}
```

**How EMAs Work:**
1. Oracle maintains cumulative accumulators for TWAP (fast: 2-hour, slow: 12-hour)
2. Current price is stored in B64 format
3. Fast and slow EMAs are NOT stored as absolute prices, but as **offsets** from the current price
4. To get the actual EMA price: `emaPrice = currentPrice × (1 + offset / OFFSET_PRECISION)`

**Simulator Implementation Requirements:**

For simplification in simulation (avoiding complex accumulator state), we can:
1. Assume the oracle feed is already updated with accurate offset values
2. Simulator receives `FeedData` with fastOffset and slowOffset pre-calculated
3. Decode using the same formula as LibOracle._applyOffset()

**Python Implementation:**
```python
OFFSET_PRECISION = 10_000_000  # 0.0001% units

def apply_offset(current_price_1e18: int, offset: int) -> int:
    """Apply offset to current price to get EMA price"""
    multiplier = OFFSET_PRECISION + offset
    if multiplier <= 0:
        return 1
    return (current_price_1e18 * multiplier) // OFFSET_PRECISION

def decode_emas(current_price_b64: int, fast_offset: int, slow_offset: int) -> tuple:
    """Decode both fast and slow EMAs from offsets"""
    current_price_1e18 = b64_to_1e18(current_price_b64)
    price_fast = apply_offset(current_price_1e18, fast_offset)
    price_slow = apply_offset(current_price_1e18, slow_offset)
    return price_fast, price_slow
```

---

## 3. Volatility & Deviation Calculation

**Solidity Implementation** (LibOracle.sol, lines 130-169):

```solidity
function getSigma(IOracleV1.FeedData memory feed)
    internal pure returns (uint32 sigma)
{
    // σ = (σ_fast + σ_slow) / 2
    return (feed.fastVolEMA + feed.slowVolEMA) / 2;
}

function getDelta(IOracleV1.FeedData memory feed)
    internal pure returns (uint32 delta)
{
    // d_fs = |fastOffset - slowOffset|
    uint256 dfs = feed.fastOffset > feed.slowOffset
        ? uint256(int256(feed.fastOffset - feed.slowOffset))
        : uint256(int256(feed.slowOffset - feed.fastOffset));

    // d_fc = |fastOffset| (fast vs current, current = 0 offset)
    uint256 dfc = feed.fastOffset >= 0
        ? uint256(int256(feed.fastOffset))
        : uint256(-int256(feed.fastOffset));

    // Δ = max(d_fs, d_fc)
    return maxDelta > type(uint32).max ? type(uint32).max : uint32(maxDelta);
}
```

**Key Properties:**
- **Sigma (σ)**: Effective volatility = average of fast and slow vol EMAs
  - Units: VOL_BASE = 1e6 (1_000_000 = 1%, 10_000 = 0.01%)
  - Used to calculate dispersion (liquidity spread width)
- **Delta (Δ)**: Effective deviation = max of:
  1. Fast vs slow EMA divergence: |fastOffset - slowOffset|
  2. Fast vs current price divergence: |fastOffset|
  - Units: Offset units (same as fastOffset/slowOffset)
  - Used to calculate deviation surcharge in fees

**Python Implementation:**
```python
def get_sigma(fast_vol_ema: int, slow_vol_ema: int) -> int:
    """Get effective volatility (average of fast and slow)"""
    return (fast_vol_ema + slow_vol_ema) // 2

def get_delta(fast_offset: int, slow_offset: int) -> int:
    """Get effective deviation (max of fast-slow spread and fast-current spread)"""
    dfs = abs(fast_offset - slow_offset)
    dfc = abs(fast_offset)
    delta = max(dfs, dfc)
    return min(delta, 2**32 - 1)  # Cap at uint32 max
```

---

## 4. Dispersion Calculation (Volatility-Based Liquidity Spread)

**Solidity Implementation** (LibPricing.sol, lines 254-271):

```solidity
function _calculateDispersion(
    uint32 volatility,      // sigma in VOL_BASE units
    uint16 vega,            // multiplier, basis 10000
    uint32 minDispersion,   // minimum in BPS_PRECISION units
    uint32 maxDispersion    // maximum in BPS_PRECISION units
) internal pure returns (uint32 dispersion) {
    // Linear mapping: dispersion increases with volatility
    // Base dispersion (1000 bps = 0.1%) + volatility scaled by vega
    uint256 scaledVol = (uint256(volatility) * uint256(vega)) / (1000 * MULT_BASE);
    uint256 raw = 1000 + scaledVol;

    if (raw < uint256(minDispersion)) return minDispersion;
    if (raw > uint256(maxDispersion)) return maxDispersion;
    return uint32(raw);
}
```

**Where:**
- MULT_BASE = 10_000 (basis for multipliers)
- Dispersion = 1000 + (sigma × vega) / (1000 × 10000)
- **Units**: BPS_PRECISION = 1_000_000 (1 unit = 0.0001%, so 10000 = 1%)

**Example Calculation:**
- Volatility (sigma) = 1_000_000 (= 1% in VOL_BASE units)
- Vega = 10_000 (1.0x neutral)
- Dispersion = 1000 + (1_000_000 × 10_000) / (1000 × 10_000) = 1000 + 1000 = 2000 bps = 0.2%

**Python Implementation:**
```python
BPS_PRECISION = 1_000_000
VOL_BASE = 1_000_000
MULT_BASE = 10_000

def calculate_dispersion(
    volatility: int,        # sigma in VOL_BASE units
    vega: int,              # multiplier, basis 10000
    min_dispersion: int,    # minimum in BPS_PRECISION units
    max_dispersion: int     # maximum in BPS_PRECISION units
) -> int:
    """Calculate liquidity dispersion from volatility"""
    scaled_vol = (volatility * vega) // (1000 * MULT_BASE)
    raw = 1000 + scaled_vol

    if raw < min_dispersion:
        return min_dispersion
    if raw > max_dispersion:
        return max_dispersion
    return raw
```

---

## 5. Inventory Skew Calculation

**Solidity Implementation** (LibPricing.sol, lines 67-145):

```solidity
function computeInventorySkew(
    uint128 reserves,
    uint128 liabilities,
    uint16 coverageMin,   // e.g., 5000 = 50% (0.01% units)
    uint16 coverageMax,   // e.g., 20000 = 200% (0.01% units)
    uint16 gamma          // multiplier in basis 10000
) internal pure returns (int8 inventorySkew) {
    // Coverage = reserves / liabilities (in WAD = 1e18)
    uint256 coverage = calculateCoverage(reserves, liabilities);

    uint256 critMin = (uint256(coverageMin) * WAD) / 10000;  // 5000 → 50%
    uint256 critMax = (uint256(coverageMax) * WAD) / 10000;  // 20000 → 200%
    uint256 target = WAD;       // 100%

    if (coverage <= critMin) return 100;   // Max premium
    if (coverage >= critMax) return -100;  // Max discount

    // Gamma as LINEAR MULTIPLIER: 10000 = 1.0x multiplier
    if (coverage < target) {
        // Under target: positive skew (premium to encourage deposits)
        uint256 rangeUnder = target - critMin;
        uint256 posUnder = target - coverage;
        uint256 progress = (posUnder * WAD) / rangeUnder;
        int256 skew = int256((uint256(gamma) * 100 * progress) / (10000 * WAD));
        return skew > 100 ? 100 : int8(skew);
    } else {
        // Over target: negative skew (discount to encourage withdrawals)
        uint256 rangeOver = critMax - target;
        uint256 posOver = coverage - target;
        uint256 progress = (posOver * WAD) / rangeOver;
        int256 skew = -int256((uint256(gamma) * 100 * progress) / (10000 * WAD));
        return skew < -100 ? -100 : int8(skew);
    }
}
```

**Key Properties:**
- Returns -100 to +100 representing price adjustment direction
- At coverage < 100%: positive skew (premium price, encourages deposits)
- At coverage > 100%: negative skew (discount price, encourages withdrawals)
- Linear formula: `skew = sign × gamma × 100 × progress / 10000` where gamma is a multiplier

**Python Implementation:**
```python
WAD = 10**18
BPS = 10_000  # 0.01% units for coverageMin/Max and multipliers

def calculate_coverage(reserves: int, liabilities: int) -> int:
    """Calculate coverage ratio: reserves / liabilities in WAD units"""
    if liabilities == 0:
        return 2 * WAD  # Infinite coverage treated as 200%
    return (reserves * WAD) // liabilities

def compute_inventory_skew(
    reserves: int,
    liabilities: int,
    coverage_min: int,    # e.g., 5000 = 50% in 0.01% BPS units
    coverage_max: int,    # e.g., 20000 = 200% in 0.01% BPS units
    gamma: int            # multiplier in basis 10000 (10000 = 1.0x)
) -> int:
    """Compute inventory skew from coverage ratio using LINEAR formula"""
    coverage = calculate_coverage(reserves, liabilities)

    crit_min = (coverage_min * WAD) // BPS  # 5000 → 50%
    crit_max = (coverage_max * WAD) // BPS  # 20000 → 200%
    target = WAD

    if coverage <= crit_min:
        return 100
    if coverage >= crit_max:
        return -100

    if coverage < target:
        # Positive skew (premium)
        range_under = target - crit_min
        pos_under = target - coverage
        progress = (pos_under * WAD) // range_under
        skew = (gamma * 100 * progress) // (BPS * WAD)
        return min(skew, 100)
    else:
        # Negative skew (discount)
        range_over = crit_max - target
        pos_over = coverage - target
        progress = (pos_over * WAD) // range_over
        skew = -(gamma * 100 * progress) // (BPS * WAD)
        return max(skew, -100)
```

---

## 6. Spline Traversal & Pricing

**Solidity Implementation** (LibPricing.sol, lines 315-399):

```solidity
function _traverseSplineByVolume(
    uint256 twap,
    uint32 dispersion,
    IPoolV1.LiquidityProfile storage profile,
    int8 inventorySkew,      // -100 to +100
    uint256 amountIn,
    uint256 depth,
    bool selling
) internal view returns (uint256 avgPrice) {
    // Build spline points from profile (weights, endOffsets)
    LibSpline.Point[] memory points = _buildSplinePoints(profile, dispersion);

    // Map inventory skew to cumulative depth (0-10000)
    uint256 startDepth = _skewToDepth(inventorySkew);  // 5000 + skew*50

    // Calculate ending position after volume is traded
    uint256 volumeFraction = (amountIn * 10000) / depth;
    if (volumeFraction > 10000) volumeFraction = 10000;

    uint256 endDepth;
    if (selling) {
        endDepth = volumeFraction >= startDepth ? 0 : startDepth - volumeFraction;
    } else {
        endDepth = startDepth + volumeFraction;
        if (endDepth > 10000) endDepth = 10000;
    }

    // Calculate area under price curve from startDepth to endDepth
    int256 offsetArea = LibSpline.area(points, startDepth, endDepth);

    // Average offset = Area / Width
    uint256 width = selling ? (startDepth - endDepth) : (endDepth - startDepth);
    int256 avgOffsetBps = offsetArea / int256(width);

    // Clamp negative offset to prevent zero/negative prices
    int256 MAX_NEGATIVE_OFFSET = -int256(BPS_PRECISION) * 90 / 100;
    if (avgOffsetBps < MAX_NEGATIVE_OFFSET) {
        avgOffsetBps = MAX_NEGATIVE_OFFSET;
    }

    // Convert offset to price
    int256 multiplier = int256(BPS_PRECISION) + avgOffsetBps;
    uint256 avgPrice = (twap * uint256(multiplier)) / BPS_PRECISION;

    // Apply minimum price floor (5% of TWAP)
    uint256 minPrice = (twap * 5) / 100;
    if (avgPrice < minPrice) avgPrice = minPrice;

    return avgPrice;
}

function _buildSplinePoints(
    IPoolV1.LiquidityProfile storage profile,
    uint32 dispersion
) internal view returns (LibSpline.Point[] memory points) {
    // Start point: skew = -100, depth = 0
    points[0] = LibSpline.Point({
        x: 0,
        y: int256(-100) * int256(uint256(dispersion)) / 100
    });

    // Build segment points from profile weights and offsets
    uint256 cumulativeWeight = 0;
    for (uint256 i = 0; i < count; i++) {
        cumulativeWeight += uint256(profile.weights[i]);
        int256 offsetBps = (int256(int16(profile.endOffsets[i])) * int256(uint256(dispersion))) / 100;
        uint256 xPos = (cumulativeWeight * 10000) / WEIGHT_SUM;  // WEIGHT_SUM = 200
        points[i + 1] = LibSpline.Point({x: xPos, y: offsetBps});
    }

    // End point: skew = +100, depth = 10000
    if (lastX < 10000) {
        points[count + 1] = LibSpline.Point({
            x: 10000,
            y: int256(100) * int256(uint256(dispersion)) / 100
        });
    }
}

function _skewToDepth(int8 inventorySkew) internal pure returns (uint256 depth) {
    // -100 → 0, 0 → 5000, +100 → 10000
    return uint256(5000 + int256(inventorySkew) * 50);
}
```

**Test Case - Flat Spline with 2 Points:**

Input:
- weights = [100, 100, 0, 0, ...]   (sum = 200 = WEIGHT_SUM)
- endOffsets = [-50, 50, 0, 0, ...]

Expected spline points:
1. (x=0, y=-50 × dispersion/100)          # skew=-100
2. (x=5000, y=-50 × dispersion/100)       # weights[0]=100 → cumulative=100 → x=(100×10000)/200=5000
3. (x=10000, y=50 × dispersion/100)       # weights[1]=100 → cumulative=200 → x=(200×10000)/200=10000

This creates a **linear** price curve that changes from -50×dispersion/100 (buying side) to +50×dispersion/100 (selling side).

**Python Implementation:**
```python
def build_spline_points(weights, end_offsets, dispersion):
    """Build spline control points from profile"""
    points = []

    # Start point: skew=-100, depth=0
    points.append({
        'x': 0,
        'y': (-100 * dispersion) // 100
    })

    # Segment points
    cumulative_weight = 0
    for i in range(len(weights)):
        if weights[i] == 0:
            break
        cumulative_weight += weights[i]
        offset_bps = (end_offsets[i] * dispersion) // 100
        x_pos = (cumulative_weight * 10000) // 200  # WEIGHT_SUM=200
        points.append({'x': x_pos, 'y': offset_bps})

    # End point if needed
    last_x = (cumulative_weight * 10000) // 200
    if last_x < 10000:
        points.append({
            'x': 10000,
            'y': (100 * dispersion) // 100
        })

    return points

def skew_to_depth(inventory_skew):
    """Map inventory skew to cumulative depth"""
    return 5000 + inventory_skew * 50

def traverse_spline_by_volume(
    twap, dispersion, points, inventory_skew, amount_in, depth, selling
):
    """Calculate average execution price by traversing spline"""
    start_depth = skew_to_depth(inventory_skew)

    # Volume as fraction of depth
    volume_fraction = (amount_in * 10000) // depth
    volume_fraction = min(volume_fraction, 10000)

    # Calculate end position
    if selling:
        end_depth = max(0, start_depth - volume_fraction)
    else:
        end_depth = min(10000, start_depth + volume_fraction)

    # Traverse spline and calculate area (detailed spline math omitted)
    # This requires interpolating the spline curve and integrating area
    width = abs(end_depth - start_depth)
    if width == 0:
        # Single point
        avg_offset_bps = evaluate_spline(points, start_depth)
    else:
        # Integrate area under curve from start to end
        offset_area = spline_area(points, start_depth, end_depth)
        avg_offset_bps = offset_area // width

    # Clamp and apply to price
    MAX_NEGATIVE_OFFSET = -(10**6 * 90) // 100
    avg_offset_bps = max(avg_offset_bps, MAX_NEGATIVE_OFFSET)

    multiplier = 10**6 + avg_offset_bps
    avg_price = (twap * multiplier) // 10**6

    # Minimum price floor
    min_price = (twap * 5) // 100
    return max(avg_price, min_price)
```

---

## 7. Asymmetric Spread & Coverage Impact

**Solidity Implementation** (LibPricing.sol, lines 728-768):

```solidity
function _calculatePathSpreadCached(
    EndpointCache memory cacheIn,
    EndpointCache memory cacheOut,
    uint256 amountIn,
    uint256 amountOut,
    uint32 sigmaPair,       // max sigma across path
    uint32 deltaPair,       // max delta across path
    uint16 minFeePath,
    uint16 maxFeePath
) private pure returns (uint16 spreadBps) {
    // Symmetric volatility band
    uint16 vegaSpread = cacheIn.vega > cacheOut.vega ? cacheIn.vega : cacheOut.vega;
    uint256 sVol = 100 + (uint256(sigmaPair) * uint256(vegaSpread)) / (100 * MULT_BASE);

    // Directional deviation surcharge
    uint16 lambdaSpread = cacheIn.lambda > cacheOut.lambda ? cacheIn.lambda : cacheOut.lambda;
    uint256 u = (uint256(deltaPair) * uint256(lambdaSpread)) / MULT_BASE;

    // Check if swap improves coverage
    int256 impact = netCoverageImpact(
        cacheIn.reserves, cacheIn.liabilities,
        cacheOut.reserves, cacheOut.liabilities,
        amountIn, amountOut,
        cacheIn.price, cacheOut.price
    );

    bool improvesCoverage = impact < 0;

    // Spread = S_vol (base) + U (surcharge) if coverage worsens
    uint256 rawSpread = improvesCoverage ? sVol : sVol + u;

    // Clamp to [minFeePath, maxFeePath]
    if (rawSpread < uint256(minFeePath)) return minFeePath;
    if (rawSpread > uint256(maxFeePath)) return maxFeePath;
    return uint16(rawSpread);
}

function netCoverageImpact(
    uint128 reservesIn,  uint128 liabilitiesIn,
    uint128 reservesOut, uint128 liabilitiesOut,
    uint256 amountIn,    uint256 amountOut,
    uint256 priceIn,     uint256 priceOut
) internal pure returns (int256 impact) {
    // Calculate coverage impact:
    // In: loses reserves (bad), gains liabilities (bad)
    // Out: gains reserves (good), loses liabilities (good)
    int256 inReserveImpact = -(int256(amountIn) * int256(priceIn)) / int256(1e18);
    int256 outReserveImpact = int256(amountOut) * int256(priceOut) / int256(1e18);
    int256 totalReserveChange = inReserveImpact + outReserveImpact;

    int256 inLiabilityImpact = int256(amountIn);
    int256 outLiabilityImpact = -(int256(amountOut));
    int256 totalLiabilityChange = inLiabilityImpact + outLiabilityImpact;

    // Calculate impact on coverage ratios
    // Negative impact = improves coverage, positive = worsens coverage
    int256 inCoverageChange = totalReserveChange - ((int256(reservesIn) * totalLiabilityChange) / int256(liabilitiesIn));
    int256 outCoverageChange = totalReserveChange - ((int256(reservesOut) * totalLiabilityChange) / int256(liabilitiesOut));

    // Net impact: sum of coverage changes at both endpoints
    impact = inCoverageChange + outCoverageChange;
    return impact;
}
```

**Fee Calculation Formula:**

```
Volatility Band:    S_vol = 100 + (σ_pair × vega_spread) / (100 × 10000)
Deviation Surcharge: U = Δ_pair × lambda_spread / 10000
Coverage Check:      improvesCoverage = netCoverageImpact(...) < 0
Spread:              rawSpread = improvesCoverage ? S_vol : S_vol + U
Final Spread:        spreadBps = clamp(rawSpread, minFeePath, maxFeePath)
```

**Python Implementation:**
```python
def calculate_path_spread(
    sigma_pair: int,
    delta_pair: int,
    vega_spread: int,
    lambda_spread: int,
    improves_coverage: bool,
    min_fee: int,
    max_fee: int
) -> int:
    """Calculate fee spread"""
    s_vol = 100 + (sigma_pair * vega_spread) // (100 * 10_000)
    u = (delta_pair * lambda_spread) // 10_000

    raw_spread = s_vol if improves_coverage else s_vol + u

    return max(min_fee, min(raw_spread, max_fee))

def net_coverage_impact(
    reserves_in: int, liabilities_in: int,
    reserves_out: int, liabilities_out: int,
    amount_in: int, amount_out: int,
    price_in: int, price_out: int
) -> int:
    """Calculate net coverage impact of swap"""
    WAD = 10**18

    # Reserve changes
    in_reserve_impact = -(amount_in * price_in) // WAD
    out_reserve_impact = (amount_out * price_out) // WAD
    total_reserve_change = in_reserve_impact + out_reserve_impact

    # Liability changes
    in_liability_impact = amount_in
    out_liability_impact = -amount_out
    total_liability_change = in_liability_impact + out_liability_impact

    # Coverage impact at each endpoint
    in_coverage_change = total_reserve_change - ((reserves_in * total_liability_change) // liabilities_in)
    out_coverage_change = total_reserve_change - ((reserves_out * total_liability_change) // liabilities_out)

    return in_coverage_change + out_coverage_change
```

---

## 8. Flat Spline Test Case

**Configuration:**
```python
# Profile
weights = [100, 100, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
end_offsets = [-50, 50, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

# Parameters (NEUTRAL)
gamma = 10_000      # 1.0x
vega = 10_000       # 1.0x
lambda_ = 10_000    # 1.0x
min_dispersion = 1_000      # 0.1%
max_dispersion = 100_000    # 10%
coverage_floor = 500_000    # 50%

# Assets
eth_reserves = 5 * 10**18      # 5 ETH
eth_liabilities = 5 * 10**18   # 5 ETH liabilities (100% coverage)

# Prices
eth_current_price = 2_000 * 10**18  # $2,000 in WAD
eth_fast_offset = 0                  # No divergence
eth_slow_offset = 0
eth_fast_vol_ema = 1_000_000        # 1% volatility
eth_slow_vol_ema = 1_000_000

# Trade
amount_in = 0.1 * 10**18  # 0.1 ETH selling
```

**Expected Results:**
1. Coverage = 1.0 (100%) → inventory_skew = 0
2. Sigma = 1_000_000 → dispersion = 1000 + (1_000_000 × 10_000) / (1000 × 10_000) = 2000 bps = 0.2%
3. Start depth = 5000 (skew 0)
4. Volume fraction = (0.1 × 10**18 × 10000) / (5 × 10**18) = 200 (0.02 = 2% of depth)
5. End depth (selling) = 5000 - 200 = 4800
6. Spline traversal: integrate from depth 4800 to 5000
7. Price offset: ~-10 bps (slight discount due to selling)
8. Execution price: $2,000 × (1 - 10/1_000_000) ≈ $1,999.98

---

## Summary: Verification Checklist

- [ ] **TWAP & EMA Accumulators**: Use offset-based encoding, `apply_offset()` to convert to absolute prices
- [ ] **Volatility (Sigma)**: Average of fast and slow vol EMAs
- [ ] **Deviation (Delta)**: Max of fast-slow and fast-current offsets
- [ ] **Dispersion**: 1000 + (sigma × vega) / (1000 × 10000), clamped to [min, max]
- [ ] **Inventory Skew**: Linear formula with gamma as multiplier, -100 to +100 range
- [ ] **Spline Traversal**: Build points, map skew to depth (5000 + skew×50), integrate area under curve
- [ ] **Asymmetric Spread**: Base = 100 + (sigma × vega) / (100 × 10000), surcharge = (delta × lambda) / 10000 if coverage worsens
- [ ] **Coverage Impact**: Compare reserves/liabilities change at both endpoints
- [ ] **Flat Spline**: 2 points with linear interpolation between

