# Liquidity Profile and Pricing Specification

## Overview

BAMM uses a **Makima cubic spline** (modified Akima piecewise cubic Hermite interpolation) for its liquidity profile instead of traditional invariant functions (like Uniswap's `x*y=k` or Curve's complex invariant). This design provides smooth, shape-preserving price curves that can encode arbitrary empirical price densities with minimal overshoot and predictable gas costs.

**Key Components:**
1. **Liquidity Profiles**: Makima cubic spline curves (this document)
2. **Fee Multipliers**: Tri-factor dynamic fees (see [FEES.md](./FEES.md))
3. **Coverage Ratio**: ALM-based inventory balancing (see [ALM_AND_COVERAGE.md](./ALM_AND_COVERAGE.md))

## Why Makima Cubic Spline?

### Shape Preservation & Smoothness
- **C¹ continuous**: Smooth price and first derivative (marginal price) with no jumps
- **No plateau overshoot**: Eliminates key pathology of classic Akima and cubic splines
- **Preserves monotonicity**: Maintains shape in flat and monotone regions
- **Regime transitions**: Handles flat→curved transitions without artificial extrema
- **No ringing**: Minimal oscillation compared to classical cubic splines

### Computational Efficiency
- **No invariant solving**: Direct polynomial evaluation, no iterative root-finding
- **Closed-form evaluation**: O(1) per segment after O(log n) segment location
- **Predictable gas**: Bounded cost with max 32 segments
- **Cheaper than**: Curve Cryptoswap, Gyroscope ECLP
- **Pre-computed slopes**: All cubic coefficients computed off-chain

### Flexibility & Empirical Fit
- **Arbitrary density shapes**: Encode any statistical distribution (normal, skewed, bimodal, fat-tailed)
- **Bounded domain**: No wasted liquidity on unreachable price tails
- **Per-asset profiles**: Each asset can have unique empirical density
- **Dynamic adaptation**: Breadth scales with volatility automatically
- **Statistical features**: Directly encode skew, kurtosis, multimodality from historical data

## Mathematical Foundation

### What is Makima?

Makima is a **piecewise cubic Hermite interpolant** where each segment $[x_i, x_{i+1}]$ is a cubic polynomial uniquely determined by:
- **Knot values**: $y_i, y_{i+1}$ (price or cumulative liquidity at segment boundaries)
- **Knot slopes**: $d_i, d_{i+1}$ (first derivatives, pre-computed off-chain using modified Akima formula)

**The cubic polynomial on segment $i$:**

```
p(x) = a_i(x - x_i)³ + b_i(x - x_i)² + c_i(x - x_i) + d_i
```

Where coefficients are derived from knot values and slopes using standard Hermite basis.

### Modified Akima Slope Formula

Makima modifies classical Akima's slope computation by changing the weights used to blend neighboring finite differences:

**Classical Akima:**
```
w₁ = |δ_{i+1} - δᵢ|
w₂ = |δ_{i-1} - δ_{i-2}|
```

**Makima modification:**
```
w₁ = |δ_{i+1} - δᵢ| + |δ_{i+1} + δᵢ|/2
w₂ = |δ_{i-1} - δ_{i-2}| + |δ_{i-1} + δ_{i-2}|/2
```

**Key property:** This forces $d_i = 0$ when three or more consecutive samples are equal, eliminating plateau overshoot.

### Why This Matters for AMMs

1. **Flat peg zones**: When price density has flat regions (e.g., stablecoin peg bands), Makima joins them with straight segments instead of creating artificial humps
2. **Smooth regime transitions**: When flat zones transition to curved high-volatility regions, Makima biases toward the flatter side, producing intuitive monotone transitions
3. **C¹ continuity**: Continuous marginal price is far more important than continuous curvature for preventing arbitrage
4. **Low overshoot**: Sits between classical cubic spline (very smooth but oscillatory) and PCHIP (strictly monotone) in wiggle amplitude

## Storage Architecture

### Packed Segment Layout

Each segment packs **three values** into 48 bits:

```solidity
// Per-segment packed data (48 bits total):
// [0..7]   : weight    (uint8,  0-255)
// [8..15]  : endOffset (int8,   -100 to +100)
// [16..47] : slope     (int32,  fixed-point pre-computed slope)

library LiquiditySegmentsLib {
    uint256 internal constant BITS_PER_SEGMENT   = 48;
    uint256 internal constant SEGMENTS_PER_SLOT  = 5;
    uint256 internal constant SEGMENT_MASK       = (1 << 48) - 1;
    uint256 internal constant MAX_SEGMENTS       = 32;

    struct PackedSegments {
        uint256[7] data; // 7 slots × 5 segments/slot = 35 capacity, use 32
    }

    function get(PackedSegments storage self, uint256 i)
        internal view
        returns (uint8 weight, int8 endOffset, int32 slope)
    {
        unchecked {
            uint256 slotIndex = i / SEGMENTS_PER_SLOT;
            uint256 offset    = (i % SEGMENTS_PER_SLOT) * BITS_PER_SEGMENT;
            uint256 word      = self.data[slotIndex];
            uint256 chunk     = (word >> offset) & SEGMENT_MASK;

            weight    = uint8(chunk);
            endOffset = int8(uint8(chunk >> 8));
            slope     = int32(uint32(chunk >> 16));
        }
    }

    function set(PackedSegments storage self, uint256 i,
                 uint8 weight, int8 endOffset, int32 slope)
        internal
    {
        unchecked {
            uint256 slotIndex = i / SEGMENTS_PER_SLOT;
            uint256 offset    = (i % SEGMENTS_PER_SLOT) * BITS_PER_SEGMENT;

            uint256 packed =
                uint256(weight)
                | (uint256(uint8(endOffset)) << 8)
                | (uint256(uint32(slope)) << 16);

            uint256 mask = SEGMENT_MASK << offset;
            uint256 word = self.data[slotIndex];
            word = (word & ~mask) | (packed << offset);
            self.data[slotIndex] = word;
        }
    }
}
```

### Pool-Level Configuration

```solidity
struct LiquidityConfig {
    // Slot 0: Global config (17 bytes used, 15 bytes padding for future)
    uint64 minPriceStep;  // Minimum breadth (bps) at zero volatility (8 bytes)
    uint64 maxBreadth;    // Maximum breadth (bps) cap (8 bytes)
    uint8  segmentCount;  // Active segment count (2-32) (1 byte)
    // 15 bytes padding remain for future parameters

    // Slots 1-7: Packed segments (7 slots, 5 segments per slot)
    LiquiditySegmentsLib.PackedSegments segments;
}
```

**Storage efficiency:**
- **1 SLOAD** for global config (breadth bounds + segment count)
- **≤7 SLOADs** for all segments (5 segments per slot, max 32 segments)
- **Typical case**: 8 segments = 1 config slot + 2 segment slots = **3 SLOADs total**
- **Maximum case**: 32 segments = 1 config slot + 7 segment slots = **8 SLOADs total**

## Core Concepts

### 1. Segments as Cubic Spline Knots

**Important terminology:**
- **N segments** in the liquidity profile
- Each segment stores: `(weight, endOffset, slope)`
- The `endOffset[i]` defines the **right boundary** (ending knot) of segment `i` as a percentage of breadth
- **Segment 0 ALWAYS starts at -100** (meaning TWAP - 100% of breadth, i.e., TWAP - breadth)
- Segment i spans from `endOffset[i-1]` to `endOffset[i]` (with segment 0 spanning from -100 to `endOffset[0]`)

**Example:**
```
breadth = 1000 bps (10% total range)
TWAP = $1.00

Segment 0: endOffset = -50
  → Left bound:  -100 × 1000/100 = -1000 bps = -10% → $0.90
  → Right bound:  -50 × 1000/100 =  -500 bps =  -5% → $0.95
  → Spans $0.90 to $0.95

Segment 1: endOffset = 50
  → Left bound (from seg 0): -50 → $0.95
  → Right bound: 50 × 1000/100 = 500 bps = +5% → $1.05
  → Spans $0.95 to $1.05
```

**Cubic interpolation within each segment:**

```
Segment[i] spans from knot[i] to knot[i+1]
- Left knot:  price[i],   slope[i]   (from endOffset[i-1], slope[i-1])
- Right knot: price[i+1], slope[i+1] (from endOffset[i], slope[i])
```

The cubic polynomial on segment $i$ smoothly interpolates between these knots using the Makima pre-computed slopes.

**Storage layout:** For N segments, we store N `(weight, endOffset, slope)` tuples, which define N+1 knots implicitly (including the fixed -100 lower bound).

### 2. Offsets as Percentages of Breadth

`endOffset` values range from **-100 to +100**, representing percentage of the total breadth range:

- **-100**: Lower bound (far below TWAP)
- **0**: At TWAP (reference price)
- **+100**: Upper bound (far above TWAP)

The breadth defines the total price range width and scales with volatility.

### 3. Breadth Scaling with Volatility

**Breadth** defines the total price range width (in basis points) around the TWAP, scaling dynamically with volatility:

```solidity
// Formula (all values converted to uint256 for safe arithmetic):
uint256 volatility_safe = uint256(volatility);  // 1e6 precision
uint256 kappa_safe = uint256(breadthVolKappa);  // dimensionless
uint256 minStep_safe = uint256(minPriceStep);  // bps
uint256 maxBreadth_safe = uint256(maxBreadth);  // bps

// Calculate raw breadth with volatility scaling
uint256 volComponent = (volatility_safe * kappa_safe) / 1_000_000;
uint256 rawBreadth = minStep_safe + volComponent;
uint256 breadth = min(rawBreadth, maxBreadth_safe);  // Capped at max

where:
  volatility      = baseline volatility (from oracle, 1e6 precision, 100% = 100_000_000)
  breadthVolKappa = volatility sensitivity coefficient (dimensionless, typically 500-2000)
  minPriceStep    = minimum breadth at zero volatility, in bps (e.g., 200 bps = 2%)
  maxBreadth      = maximum breadth cap, in bps (e.g., 5000 bps = 50%)
```

**Example:**
```
minPriceStep = 200 bps        (2% minimum range)
maxBreadth   = 5000 bps       (50% maximum range)
kappa        = 1000           (1× volatility sensitivity)
volatility   = 10_000_000     (10% annualized vol in 1e6 precision)

volComponent = (10_000_000 × 1000) / 1_000_000 = 10_000
rawBreadth   = 200 + 10_000 = 10_200 bps (102% range - exceeds max!)
breadth      = min(10_200, 5000) = 5000 bps (50% total range)

At lower volatility (2%):
volatility   = 2_000_000
volComponent = (2_000_000 × 1000) / 1_000_000 = 2_000
rawBreadth   = 200 + 2_000 = 2_200 bps
breadth      = min(2_200, 5000) = 2_200 bps (22% total range)
```

**Key insight:** As volatility increases, breadth widens linearly (controlled by κ), stretching the cubic spline over a wider price range, until hitting the maximum cap. All intermediate calculations use uint256 to prevent overflow in arithmetic operations.

**For fee-related breadth usage, see:**
- [FEES.md](./FEES.md) - Tri-factor fee model using breadth for divergence multiplier

### 4. Segment Weights (Liquidity Distribution)

Each segment has a **weight** (0-255) determining what fraction of total liquidity sits in that range:

```
segment_liquidity[i] = total_reserves × (weight[i] / WEIGHT_SUM)

where WEIGHT_SUM = 255
```

**Weights must sum to 255** (normalized during profile configuration).

### 5. Converting Offsets to Knot Prices

Given:
- `breadth` in basis points (bps)
- `endOffset` as percentage of breadth range (-100 to +100)
- `slowTWAP` as reference price (1e18 precision)

**Formula (strictly integer arithmetic):**

```solidity
// Calculate offset as fraction of breadth (can be negative)
int256 offsetBps = int256(endOffset) * int256(breadth) / 100;

// Apply to TWAP: knotPrice = TWAP × (1 + offsetBps/10000)
uint256 knotPrice = slowTWAP * uint256(int256(10_000) + offsetBps) / 10_000;
```

**Interpretation:**
- `endOffset = -100` means **TWAP - breadth** (left edge of range)
- `endOffset = 0` means **TWAP** (center)
- `endOffset = +100` means **TWAP + breadth** (right edge of range)

**Example 1: Segment at -50% breadth**
```
slowTWAP   = 1e18 ($1.00)
breadth    = 1000 bps (10% total range from -10% to +10%)
endOffset  = -50

offsetBps = -50 × 1000 / 100 = -500 bps (-5%)
knotPrice = 1e18 × (10000 - 500) / 10000
          = 1e18 × 9500 / 10000
          = 0.95e18 ($0.95)
```

**Example 2: Full range bounds**
```
breadth = 1000 bps

endOffset = -100 (lower bound):
  offsetBps = -100 × 1000 / 100 = -1000 bps (-10%)
  knotPrice = 1e18 × 9000 / 10000 = 0.90e18 ($0.90)

endOffset = +100 (upper bound):
  offsetBps = +100 × 1000 / 100 = +1000 bps (+10%)
  knotPrice = 1e18 × 11000 / 10000 = 1.10e18 ($1.10)
```

**Bounded domain:** All liquidity is concentrated within `[TWAP - breadth, TWAP + breadth]`, no wasted capital outside this range.

### 6. Pre-computed Slopes (int32 Fixed-Point)

Slopes are computed off-chain using the Makima algorithm and stored as **int32 fixed-point** values:

```
slope[i] = d_i × SLOPE_SCALE

where SLOPE_SCALE is chosen to balance precision and range
```

**Typical scale:** `SLOPE_SCALE = 1e9` gives:
- **Range**: ±2,147,483,647 (int32 max) ≈ ±2.1 × 10⁹ after scaling
- **Precision**: 9 decimals (adequate for smooth curves)
- **Sufficient for**: Normalized local coordinates (e.g., t ∈ [0,1] within segment)

**Off-chain validation required:**
- After computing Makima slopes, verify `|d_i × SLOPE_SCALE| < 2^31` for all i
- If slope exceeds range, either:
  1. Reduce `SLOPE_SCALE` (trades precision for range)
  2. Re-normalize the curve (e.g., use cumulative liquidity instead of price)
  3. Reject configuration as invalid

## Pricing Algorithm

### Execution Price Calculation

When a user trades `amount`, we evaluate the cubic spline:

```
1. Load global config (minBreadth, maxBreadth, segmentCount)
2. Calculate current breadth based on volatility
3. Locate starting segment (linear scan, O(n) with n ≤ 32)
4. For each segment crossed by the trade:
   a. Load packed segment data (weight, endOffset, slope)
   b. Calculate knot prices from offsets and breadth
   c. Evaluate cubic polynomial for this segment
   d. Determine fill amount: min(remaining, segment_liquidity)
   e. Calculate cost by integrating cubic over fill range
   f. Accumulate total cost
5. Return weighted average: total_cost / total_amount
```

**Segment location:** Initial implementation uses **linear scan** (O(n), n ≤ 32). For small n, simple comparison loop is cheaper than binary search overhead. Binary search (O(log n)) may be introduced as a micro-optimization once monotone segment boundaries are verified.

### Cubic Hermite Evaluation

For a trade consuming liquidity in segment $i$ from $x_0$ to $x_1$:

```solidity
// Hermite basis functions
h00(t) = 2t³ - 3t² + 1
h10(t) = t³ - 2t² + t
h01(t) = -2t³ + 3t²
h11(t) = t³ - t²

where t = (x - x_i) / (x_{i+1} - x_i)  ∈ [0, 1]

// Cubic polynomial (Hermite form)
p(t) = y_i × h00(t) + slope_i × h10(t) × Δx
     + y_{i+1} × h01(t) + slope_{i+1} × h11(t) × Δx

where Δx = x_{i+1} - x_i
```

**Equivalent standard cubic form:**

From the Hermite basis, we can derive explicit coefficients:

```solidity
a = 2(y_i - y_{i+1}) + (slope_i + slope_{i+1}) × Δx
b = 3(y_{i+1} - y_i) - (2×slope_i + slope_{i+1}) × Δx
c = slope_i × Δx
d = y_i

// Then: p(t) = a×t³ + b×t² + c×t + d
```

**On-chain implementation choice:**
- **Option A (current):** Evaluate Hermite basis directly (stores only slopes, ~10 multiplies per segment)
- **Option B (future optimization):** Pre-compute and store `(a,b,c,d)` coefficients (saves arithmetic, costs more storage)

For typical segment counts (≤16), Hermite basis evaluation is adequate; coefficient storage may be considered if arithmetic dominates gas cost.

### Segment Integration (Cost Calculation)

To calculate the cost of consuming liquidity from $t_0$ to $t_1$ within a segment:

```solidity
// Integral of p(t) = a×t³ + b×t² + c×t + d from t₀ to t₁
∫[t₀,t₁] p(t) dt = (a/4)(t₁⁴ - t₀⁴) + (b/3)(t₁³ - t₀³) + (c/2)(t₁² - t₀²) + d(t₁ - t₀)
```

**Fixed-point implementation:**

```solidity
// CRITICAL: Normalize t to [0,1] range BEFORE computing powers
// If t is in 1e18 scale, t^4 ≈ 1e72, exceeding uint256 max (1e77)

// Option A: Normalize t to [0, 1e9] for safe powers
uint256 t0_norm = t0 / 1e9;  // Scale down from 1e18 to 1e9
uint256 t1_norm = t1 / 1e9;

uint256 t0_2 = t0_norm * t0_norm;
uint256 t0_3 = t0_2 * t0_norm;
uint256 t0_4 = t0_3 * t0_norm;
// Same for t1

// Integral with reduced scale (divide by appropriate power of 1e9)
integral = (a * (t1_4 - t0_4) / 4) / (1e36)  // t^4 scale: 1e9^4 = 1e36
         + (b * (t1_3 - t0_3) / 3) / (1e27)  // t^3 scale: 1e9^3 = 1e27
         + (c * (t1_2 - t0_2) / 2) / (1e18)  // t^2 scale: 1e9^2 = 1e18
         + d * (t1_norm - t0_norm) / (1e9);  // t^1 scale: 1e9

// Option B: Use Horner's method for polynomial evaluation (avoids high powers)
// p(t) = ((at + b)t + c)t + d
// More stable numerically, fewer operations
```

**Overflow protection strategy:**
1. **Normalize t to safe range** (e.g., 1e9 instead of 1e18) before computing powers
2. **Use Horner's method** for direct polynomial evaluation (avoids t^4 entirely)
3. **Verify intermediate results** don't exceed uint256 bounds in tests
4. **Consider breaking large segments** into smaller sub-segments if t range is large

**Note:** Actual implementation should profile both approaches and choose based on gas vs. precision trade-offs.

## Comparison with Other AMM Invariants

| AMM Type | Form | C^n Class | Overshoot | Empirical Fit | Gas Cost | Iteration Required |
|----------|------|-----------|-----------|---------------|----------|-------------------|
| **Makima (BAMM)** | Piecewise cubic Hermite | C¹ | None on plateaus | Excellent | ~3-8k | No |
| Uniswap V2 | x·y = k | C∞ | N/A (global) | Poor | ~2k | No |
| Curve StableSwap | Amplified sum+product | C∞ | N/A | Medium | ~5-10k | Yes (D solve) |
| Curve Cryptoswap | Dynamic A + log terms | C∞ | N/A | Medium | ~15-30k | Yes (multi-step) |
| Gyroscope ECLP | Elliptical quadratic | C∞ | N/A | Good | ~10-20k | Yes (quadratic) |
| Uniswap V3 | Piecewise x·y = k | C⁰ | Jumps at ticks | Good (LP chosen) | ~5-50k+ | No |
| Classical cubic spline | Global C² spline | C² | Heavy | Poor (Runge) | ~3-8k | No |
| Akima spline | Local cubic | C¹ | Moderate | Good | ~3-8k | No |
| PCHIP | Monotone cubic | C¹ | None (monotone) | Very good | ~3-8k | No |

**Key advantage of Makima:** Combines smoothness (C¹), shape preservation (no overshoot), empirical fit, and closed-form evaluation.

## Modeling Liquidity Shapes from Price Action

### Workflow: Empirical Density → Makima Spline

1. **Estimate price density and regime structure**
   - Compute smoothed histogram or kernel density of log-price from historical data
   - Identify regimes: peg bands, volatility clusters, momentum bursts, tails
   - Detect support/resistance levels, bimodal structures

2. **Define target liquidity density**
   - Map price density into liquidity density $q(p)$
   - Overweight regions where tighter spreads are desired (e.g., around peg or VWAP)
   - Normalize over bounded domain $[p_{\min}, p_{\max}]$

3. **Choose knot locations and values**
   - Select up to 32 knot points in price space
   - Dense placement where density/volatility changes rapidly (peaks, kinks, tails)
   - Sparse placement in calm regions
   - Set knot values to match cumulative or marginal liquidity targets

4. **Fit Makima coefficients off-chain**
   - Compute slopes using Makima formula (modified Akima weights)
   - Verify C¹ continuity and plateau-preserving behavior
   - Ensure monotonicity if desired (no inverted pricing regions)
   - Quantize slopes to int32 fixed-point

5. **Deploy coefficients on-chain**
   - Pack segments into 7 storage slots
   - At runtime: locate segment, evaluate cubic in O(1)
   - Full utilization of bounded domain (no wasted capital in unreachable tails)

## Liquidity Shapes by Market Type

### Segment Budgets and Use Cases

| Shape | Features | Segments | Market Types | Notes |
|-------|----------|----------|--------------|-------|
| **Elliptical/Bell (peg)** | Single symmetric peak around 1.0, smooth shoulders | 6-8 | Stables, tight LSDs | Most knots in [0.97, 1.03] |
| **V-shaped** | Minimal center liquidity, high at edges | 3-4 | Speculative, option-like | Discourages tight trading near ref |
| **A-shape** | Steep central peak, fast falloff | 4-6 | Non-rebasing stables, RWA | Tight peg control, fragile tails |
| **M-shape (bimodal)** | Two preferred zones, central valley | 6-10 | Dual-regime governance tokens | Knots at each mode + valley |
| **Unimodal normal-like** | Approximate Gaussian, symmetric tails | 6-8 | Flagships (ETH, BTC), blue-chips | Central ±kσ region only |
| **Skewed normal** | Heavy tail one side, shifted mean | 8-12 | Altcoins with downside skew | Dense knots in heavy tail |
| **High-kurtosis (fat-tailed)** | Peaked center, heavy tails | 10-14 | Volatile alts, meme tokens | Sharp central peak + tail knots |
| **Inverse normal (U-shaped)** | Low near ref, high near bounds | 6-8 | Corridor options, exotic | Ideal for bounded domain |
| **Bimodal/Double normal** | Two separate modes, low between | 12-16 | Regime-switching alts | 4-6 segments per mode |
| **Trimodal** | Three+ distinct modes | 16-24 | Long-lived multi-regime tokens | Uses most of 32 segment cap |
| **Upward-skewed LSD** | Support above spot, thin downside | 8-12 | wstETH-like yield-bearing | Dense knots above spot |
| **LBP / Launch curve** | Temporal decay or reverse | 6-10 | Token launches, LBPs | Designer-chosen, not empirical |

**Typical usage:** Most real markets need **6-16 segments** on bounded domain. Remaining headroom (up to 32) for exotic multi-modal shapes.

## Configuration Examples

### Concentrated Liquidity (Stable Peg)
```solidity
segmentCount: 8
// 8 segments = 9 knot boundaries (endOffset for each segment end)
endOffsets: [-30, -15, -5, 0, 5, 15, 30, 50]  // 8 values for 8 segments
weights:    [ 18,  25, 40, 70, 50, 30, 15,  7] // 8 weights, sum = 255
slopes:     [s0, s1, s2, s3, s4, s5, s6, s7]   // 8 precomputed int32 slopes (1e9 scale)
minPriceStep: 200    // 2% minimum breadth
maxBreadth:   2000   // 20% maximum breadth
```
Heavy concentration around TWAP (segments 2-4 around offset 0), smooth shoulders.

**Note:** Each segment `i` spans from implicit knot at previous segment's end to `endOffset[i]`. First segment starts at lower bound (offset -100, meaning TWAP - breadth).

### Skewed Normal (Downside Risk)
```solidity
segmentCount: 12
endOffsets: [-100, -70, -50, -30, -15, -5, 0, 10, 20, 30, 50, 70] // 12 values
weights:    [  30,  28,  26,  28,  35, 40, 32, 20, 10,  3,  2,  1] // 12 weights, sum = 255
slopes:     [s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11]     // 12 precomputed slopes (1e9 scale)
minPriceStep: 1000   // 10% minimum breadth
maxBreadth:   8000   // 80% maximum breadth
```
More weight in downside tail (segments 0-5 cover -100 to 0), reflects asymmetric crash risk.

### Bimodal (Dual Regimes)
```solidity
segmentCount: 14
endOffsets: [-100, -80, -60, -40, -20, 0, 20, 40, 60, 80, 90, 95, 98, 100] // 14 values
weights:    [  15,  30,  35,  25,  10, 5,  8, 15, 28, 35, 25, 12,  8,   4] // 14 weights, sum = 255
slopes:     [s0, s1, s2, s3, s4, s5, s6, s7, s8, s9, s10, s11, s12, s13]   // 14 precomputed slopes (1e9 scale)
minPriceStep: 2000    // 20% minimum breadth
maxBreadth:   10000   // 100% maximum breadth
```
Two peaks: one around offset -60 (segments 1-2), one around +80 (segments 8-9), with valley in middle (segments 4-6).

## Gas Efficiency Analysis

### Computational Complexity

| Operation | Complexity | Cold Gas | Warm Gas | Notes |
|-----------|------------|----------|----------|-------|
| Load global config | O(1) | ~2,100 | ~100 | First SLOAD vs subsequent |
| Calculate breadth | O(1) | ~50 | ~50 | Arithmetic only |
| Locate segment (linear) | O(n) | - | ~50n | Simple comparison loop |
| Load packed segment | O(1) | ~2,100 | ~100 | Per slot (5 segments/slot) |
| Evaluate cubic (Hermite) | O(1) | - | ~300 | 10-12 muls, few adds |
| Integrate segment | O(1) | - | ~500 | Power computation + integral |
| **Per segment (amortized)** | **O(1)** | **~500** | **~200** | Assuming warm after first |
| **Typical (8 segments, 2 slots)** | **O(n)** | **~6,000** | **~2,500** | First swap vs. subsequent |
| **Worst case (32 segments, 7 slots)** | **O(n)** | **~18,000** | **~8,000** | All cold SLOADs |

**Key insights:**
- **SLOAD dominates** cost (2,100 cold vs. 100 warm)
- **5 segments per slot** amortizes SLOAD cost
- **Typical 8-segment pool**: 1 config slot + 2 segment slots = **3 cold SLOADs** on first swap, ~300 gas total on warm swaps
- **Arithmetic is cheap**: Cubic evaluation + integration ~800 gas total per segment

### Comparison with Other AMMs

| AMM Type | Complexity | Typical Gas | Notes |
|----------|------------|-------------|-------|
| **BAMM Makima** | **O(n), n≤32** | **~3,000-8,000** | Bounded, predictable |
| Uniswap V2 | O(1) | ~2,000 | Simple but inflexible |
| Curve StableSwap | O(k) iterations | ~5,000-10,000 | Newton's method for D |
| Curve Cryptoswap | O(k) iterations | ~15,000-30,000 | Complex multi-step solve |
| Gyroscope ECLP | O(k) iterations | ~10,000-20,000 | Quadratic/biquadratic solve |
| Uniswap V3 | O(m) ticks | ~5,000-50,000+ | Highly variable |
| Classical/Akima spline | O(n), n≤32 | ~3,000-8,000 | Similar to Makima |

**Key advantage:** No iterative solving, bounded loop count, predictable cost.

### Why It's Efficient

1. **No invariant solving**: Direct polynomial evaluation, no Newton iterations
2. **Bounded segments**: Maximum 32 segments, typically ≤16 active
3. **Simple arithmetic**: No logarithms, square roots, or transcendental functions
4. **Packed storage**: 5 segments per SLOAD (amortized cost)
5. **Pre-computed slopes**: Heavy lifting done off-chain

## Integration with Oracle System

### Dynamic Adaptation

The Makima spline adapts to market conditions:

1. **Volatility increases** → Breadth widens → Spline stretches over wider price range
2. **Volatility decreases** → Breadth narrows → Spline concentrates liquidity
3. **Price changes** → TWAP updates → Knots shift with market reference price

### Oracle Modes

| Oracle Mode | TWAP Source | Breadth Calculation | Update Frequency |
|-------------|-------------|---------------------|------------------|
| Internal-only | Computed on swap | From internal vol | Every swap |
| External-only | Read from oracle | From external vol | Oracle updates |
| Hybrid | External (main) | From oracle vol | Oracle updates |

All modes evaluate the same Makima cubic, just with different TWAP/volatility inputs.

## Security Considerations

### Configuration Validation

All liquidity profiles must pass the following validation before deployment:

**1. Bounds checking:**
- **Offsets validated**: -100 ≤ endOffset[i] ≤ 100 for all i
- **Offsets ordered**: endOffset[i-1] < endOffset[i] (strictly increasing)
- **Weights validated**: sum(weights) = WEIGHT_SUM (255)
- **Segment count**: 2 ≤ segmentCount ≤ MAX_SEGMENTS (32)
- **Breadth validated**: 0 < minBreadth < maxBreadth

**2. Slope range validation:**

Given `SLOPE_SCALE` (e.g., 1e9), enforce:

```solidity
// int32 range: -2^31 ≤ slope_i ≤ 2^31 - 1
|slope_i| ≤ 2_147_483_647

// Implies maximum unscaled slope:
|d_i| ≤ 2_147_483_647 / SLOPE_SCALE

// For SLOPE_SCALE = 1e9:
|d_i| ≤ 2.147
```

**Off-chain validation:**
- After computing Makima slopes, verify all `|d_i × SLOPE_SCALE|` fit in int32
- Reject configurations where slopes exceed range
- Alternative: reduce `SLOPE_SCALE` (trades precision for range)

**3. Monotonicity enforcement:**

**Important:** Makima preserves monotonicity for monotone input data but does not enforce it. If the spline represents a quantity that **must** be monotone (e.g., cumulative liquidity, price vs. reserves), validate at configuration time:

```solidity
// For each segment i, check knot prices are strictly increasing:
for (uint i = 1; i < segmentCount; i++) {
    require(knotPrice[i-1] < knotPrice[i], "Non-monotone knots");
}

// Or for cumulative liquidity:
require(cumulativeLiquidity[i-1] < cumulativeLiquidity[i], "Decreasing liquidity");
```

**Why this matters:** Makima is **shape-preserving** (no new extrema on monotone intervals) but **not monotone-enforcing**. If knots themselves are non-monotone, the spline will faithfully reproduce that non-monotonicity, which may create price inversions or arbitrage opportunities.

**Validation responsibility:** Off-chain configuration tool must ensure monotonicity before deploying profile on-chain.

### Price Manipulation Protection

**Oracle and circuit breaker integration:**

The Makima spline uses `slowTWAP` as the reference price for positioning knots, with automatic protection against price manipulation and catastrophic events:

**Circuit breakers** (automatic on-chain protection):
1. **Reserve price floor**: Halts swaps if oracle or spot price drops below configured minimum (e.g., stablecoin depeg to $0.92)
2. **Deviation freeze**: Compares fast/slow TWAP momentum ratios; freezes asset if divergence exceeds threshold (e.g., LST depeg, oracle manipulation)

**Key parameters:**
- **slowTWAP window**: Typically 30-60 minutes (configurable per asset)
- **Deviation thresholds**: 1% for stablecoin pairs, 5% for LST pairs
- **Staleness protection**: Skip checks if reference oracle >24h old (fail-open to preserve liquidity)

**For complete circuit breaker specifications, see:**
- [CIRCUIT_BREAKERS.md](./CIRCUIT_BREAKERS.md) - Full circuit breaker design, scenarios, and configuration
- [ORACLE.md](./ORACLE.md) - Oracle system architecture, TWAP windows, staleness handling
- [ORACLE_ARCHITECTURE.md](./ORACLE_ARCHITECTURE.md) - Multi-mode oracle design (internal/external/hybrid)

**Bounded domain advantage:**
- All liquidity concentrated within `[TWAP - breadth, TWAP + breadth]`
- No infinite slippage (unlike unbounded x·y=k curves)
- Circuit breakers protect against drain via toxic asset arbitrage
- C¹ smoothness eliminates MEV opportunities at knot boundaries

### Rounding and Precision

- **Knot prices**: 1e18 precision (18 decimals)
- **Slopes**: int32 fixed-point with configurable scale
- **Weights**: uint8, sum exactly 255
- **Breadth**: basis points (1e4 denominator)
- **Integer arithmetic**: All calculations avoid floating-point

### Edge Cases

1. **No liquidity in range**: Reject trade or use boundary price
2. **Single segment**: Still a full cubic Hermite (unless slopes are zero, which degenerates to linear interpolation between endpoints)
3. **Zero amount**: Return spot price (slowTWAP)
4. **Slope overflow**: Validated during configuration (see Configuration Validation above)
5. **Inverted segments**: Skip segments where right_price ≤ left_price (should never occur with proper monotonicity validation)

## Testing Requirements

### Unit Tests

- Knot price calculation from offsets and breadth
- Cubic Hermite evaluation correctness
- Packed segment get/set round-trip
- Weight normalization (sum = 255)
- Breadth scaling with volatility

### Integration Tests

- Multi-segment trade walkthrough
- Segment boundary crossings
- Price impact vs. trade size
- Comparison with off-chain Makima reference implementation

### Fuzz Tests

- Random segment configurations (weights, offsets, slopes)
- Random trade sizes across full liquidity range
- Monotonicity verification (no price inversions)
- Gas cost stability (bounded variance)

### Property Tests

- **C¹ continuity**: No jumps in price or marginal price at knots
- **Plateau preservation**: Flat regions remain flat
- **Monotonicity**: If configured monotone, verify no local maxima/minima
- **Bounded cost**: Gas cost ≤ MAX_GAS for any valid trade

## Future Optimizations

### Possible Improvements

1. **Binary search for segment location**
   - Replace O(n) linear scan with O(log n) bisection
   - Requires monotone segment boundaries (already enforced by validation)
   - Benefit marginal for n ≤ 16, more significant for n > 20
   - Simple comparison loop is cheaper than binary overhead for small n

2. **Segment caching**
   - Cache last-used segment index for sequential trades
   - Exploits locality: consecutive swaps often hit same segment
   - Requires careful invalidation on oracle updates

3. **Coefficient pre-computation**
   - Store full cubic coefficients `(a,b,c,d)` instead of just slopes
   - **Saves:** ~6-8 multiplies per segment (Hermite→standard form conversion)
   - **Costs:** 3× storage per segment (4 coefficients vs. 1 slope)
   - **Current 48-bit packing would need redesign** (4 coefficients require ~128+ bits)
   - Consider if arithmetic dominates gas profile over SLOAD

4. **SIMD-style evaluation**
   - Batch multiple segment evaluations if supported by future EVM opcodes
   - Speculative: not currently viable on EVM

### Trade-offs

- **Binary search:** Minimal code complexity, small gas win for large n
- **Coefficient storage:** Significant storage cost increase, modest gas savings
- **Current approach:** Hermite basis + linear scan balances simplicity, storage, and gas
- **Optimization priority:** correctness > gas > precision

### When to Optimize

Monitor gas profiling in production:
- If **SLOAD dominates** → coefficient storage may help (but breaks 48-bit packing)
- If **arithmetic dominates** → binary search or coefficient storage
- If **n typically ≤ 8** → current approach is already near-optimal

## Appendix: Makima vs. Other Splines

### Why Not Classical Cubic Spline?

- **Overshoot**: Classical C² spline oscillates heavily around non-smooth data
- **Global coupling**: Changing one knot affects entire curve (tridiagonal solve)
- **Runge phenomenon**: High-degree polynomials at uniform knots create wild oscillations

### Why Not PCHIP?

- **Strict monotonicity**: PCHIP enforces monotonicity, which is too restrictive for multi-modal densities
- **Less smooth transitions**: Can produce flatter regions than desired

### Why Not Raw Akima?

- **Plateau overshoot**: Classical Akima can overshoot when ≥3 consecutive equal points
- **Makima fixes this**: Modified weights eliminate overshoot while preserving Akima's locality

### Why Makima is Optimal for AMMs

- **Local definition**: Each knot's slope depends only on nearby knots (no global solve)
- **Shape-preserving**: Flat regions stay flat, monotone regions stay monotone
- **C¹ smooth**: No arbitrage opportunities from price/marginal price jumps
- **Bounded domain friendly**: Utilizes all segments within $[p_{\min}, p_{\max}]$
- **Empirical fit**: Directly encodes statistical features from price history
- **Gas efficient**: Closed-form evaluation, no iteration

## References

### Academic Papers
- [Makima interpolation (MathWorks)](https://blogs.mathworks.com/cleve/2019/04/29/makima-piecewise-cubic-interpolation/)
- [Modified Akima weights analysis](https://tins.ro/publications/repository/Dan_et_al_AQTR_2020.pdf)
- [Akima spline comparison](http://hosting.pilsfree.net/tonny/zcu/FAV/KIV/KIV.PPR/Apendix%20B%20-%20Comparison%20of%20linear,%20cubic%20spline%20and%20akima%20interpolation%20methods.pdf)

### AMM Protocols
- [Uniswap V3 Whitepaper](https://uniswap.org/whitepaper-v3.pdf) - Concentrated liquidity
- [Curve Whitepaper](https://curve.fi/whitepaper) - StableSwap invariant
- [Curve Cryptoswap](https://curve.fi/files/crypto-pools-paper.pdf) - Dynamic AMM
- [Gyroscope ECLP](https://docs.gyro.finance/gyroscope-protocol/concentrated-liquidity-pools/e-clps) - Ellipse pools
- [Balancer LBP](https://docs.balancer.fi/concepts/explore-available-balancer-pools/liquidity-bootstrapping-pool.html) - Launch curves

### Implementation Guides
- [MATLAB makima documentation](https://www.mathworks.com/help/matlab/ref/makima.html)
- [SciPy Akima1DInterpolator](https://docs.scipy.org/doc/scipy/reference/generated/scipy.interpolate.Akima1DInterpolator.html)
- [Solidity gas optimization patterns](https://rareskills.io/post/gas-optimization)
- [Storage packing techniques](https://dittoeth.com/blog/packing)

---

**Related Specifications:**
- [FEES.md](./FEES.md) - Tri-factor fee model
- [ALM_AND_COVERAGE.md](./ALM_AND_COVERAGE.md) - Coverage ratio dynamics
- [ORACLE.md](./ORACLE.md) - Oracle architecture
