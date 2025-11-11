# Piecewise Bonding Curve Specification

## Overview

BAMM uses a **piecewise linear bonding curve** instead of traditional invariant functions (like Uniswap's `x*y=k` or Curve's complex invariant). This design is inspired by concentrated liquidity (Uniswap V3) but optimized for gas efficiency with configurable segments rather than tick-based liquidity.

## Why Piecewise Over Invariant?

### Computational Efficiency
- **No invariant solving**: Traditional AMMs require solving complex equations (Newton's method for Curve)
- **Direct calculation**: Simply walk through segments, summing liquidity
- **Predictable gas**: Linear complexity O(n) where n = number of segments (typically 2-16)
- **Cheaper than**: Curve Cryptoswap, Gyroscope ECLP, and even Uniswap V3's tick iterations

### Flexibility
- **Custom liquidity shapes**: Configure any distribution (concentrated, uniform, inverted, skewed...)
- **Dynamic adaptation**: Breadth scales with volatility automatically
- **Per-asset profiles**: Each asset can have unique liquidity distribution

## Core Concepts

### 1. Segments as Price Ranges

Each segment is a **vector** (price range) defined by two consecutive `twapOffsets`:

```
Segment[i] = price range from offset[i] to offset[i+1]
```

**Example with 3 segments:**
```
twapOffsets: [-50, 0, 50, 100]

Segment 0: -50% to 0%   (below TWAP)
Segment 1: 0% to +50%   (around TWAP)
Segment 2: +50% to +100% (above TWAP)
```

### 2. Offsets as Percentages of Breadth

Offsets range from **-100 to +100**, representing percentage of the total breadth range:

- **-100**: Far below TWAP (lower bound of breadth)
- **0**: At TWAP (reference price)
- **+100**: Far above TWAP (upper bound of breadth)

The breadth defines the total price range width and scales with volatility.

### 3. Breadth Scaling with Volatility

```
breadth = minBreadth + (maxBreadth - minBreadth) × (volatility / 100%)
```

**Example:**
```
minBreadth = 500 (0.5% range at low vol)
maxBreadth = 5000 (5% range at high vol)
volatility = 10% (10_000_000 in 1e6 base)

breadth = 500 + (5000 - 500) × 0.10 = 950 bps
```

As volatility increases, the breadth widens, spreading liquidity over a wider price range.

### 4. Segment Weights (Liquidity Distribution)

Each segment has a **weight** (0-255) that determines what fraction of total liquidity sits in that range:

```
segment_liquidity[i] = total_reserves × (weight[i] / WEIGHT_SUM)

where WEIGHT_SUM = 255
```

**Weights must sum to 255** (normalized during `_setLiquidityProfile`).

### 5. Converting Offsets to Prices

```solidity
price[i] = slowTWAP × (1 + offset[i] × breadth / 10000)
```

**Example:**
```
slowTWAP = 100_000_000_000_000_000 (1e18 format)
breadth = 1000 bps (10%)
offset = -50 (50% below TWAP)

priceChange = -50 × 1000 / 100 = -500 bps
price = 100_000_000 × (10000 - 500) / 10000 = 95_000_000
```

The segment spans from price[i] to price[i+1].

## Pricing Algorithm

### Execution Price Calculation

When a user trades `amount`, we "walk" through segments, consuming liquidity:

```
1. Calculate breadth based on current volatility
2. Convert all offsets to actual prices
3. Start at lowest price (for buy) or highest (for sell)
4. For each segment:
   a. Calculate available liquidity: reserves × weight / 255
   b. Determine fill amount: min(remaining_amount, segment_liquidity)
   c. Calculate cost: fill_amount × avg_price_in_segment
   d. Accumulate total cost
5. Return weighted average: total_cost / total_amount
```

### Example Trade Walkthrough

**Setup:**
```
Reserves: 1000 tokens
Segments: 3 segments with offsets [-50, 0, 50, 100]
Weights: [100, 100, 55] (normalized to 255)
TWAP: 100000000000000000000 (in 1e18 = 100.0)
Breadth: 1000 bps (10%)
```

**Step 1: Calculate Prices**
```
offset[-50] → price = 100 × (10000 - 500) / 10000 = 95
offset[0]   → price = 100 × (10000 + 0) / 10000 = 100
offset[50]  → price = 100 × (10000 + 500) / 10000 = 105
offset[100] → price = 100 × (10000 + 1000) / 10000 = 110
```

**Step 2: Calculate Segment Liquidity**
```
Segment 0 [95-100]:  liquidity = 1000 × 100 / 255 = 392 tokens
Segment 1 [100-105]: liquidity = 1000 × 100 / 255 = 392 tokens
Segment 2 [105-110]: liquidity = 1000 × 55 / 255 = 216 tokens
```

**Step 3: Trade 500 tokens (Buy)**

Walk through segments:
```
Segment 0: Fill 392 tokens at avg price (95+100)/2 = 97.5
  Cost: 392 × 97.5 = 38,220
  Remaining: 500 - 392 = 108 tokens

Segment 1: Fill 108 tokens at avg price (100+105)/2 = 102.5
  Cost: 108 × 102.5 = 11,070
  Remaining: 0 tokens

Total Cost: 38,220 + 11,070 = 49,290
Execution Price: 49,290 / 500 = 98.58
```

The trader pays an average of 98.58 per token, experiencing price impact as they consume liquidity across segments.

## Configuration Examples

### Concentrated Liquidity (Around TWAP)
```solidity
segments: 3
twapOffsets: [-20, 0, 20, 50]
weights: [50, 150, 55]  // Heavy weight around TWAP
minBreadth: 200  // 0.2%
maxBreadth: 2000 // 2%
```
Most liquidity sits in the -20% to +20% range around TWAP.

### Uniform Distribution
```solidity
segments: 4
twapOffsets: [-100, -50, 0, 50, 100]
weights: [64, 64, 64, 63]  // Equal distribution
minBreadth: 1000  // 1%
maxBreadth: 10000 // 10%
```
Liquidity spread evenly across the full range.

### Skewed Ask-Side (For Lending Pools)
```solidity
segments: 3
twapOffsets: [-30, 0, 40, 100]
weights: [85, 85, 85]  // Concentrated but skewed right
minBreadth: 500
maxBreadth: 5000
```
More liquidity on the ask side (above TWAP) to facilitate borrowing.

### Asymmetric (Safety Buffer Below)
```solidity
segments: 4
twapOffsets: [-100, -50, 0, 30, 50]
weights: [120, 60, 50, 25]  // Heavy weight below TWAP
minBreadth: 1000
maxBreadth: 8000
```
Protection against downside price movement with deep liquidity below TWAP.

## Gas Efficiency Analysis

### Computational Complexity

| Operation | Complexity | Gas Estimate |
|-----------|------------|--------------|
| Calculate breadth | O(1) | ~100 gas |
| Convert offsets to prices | O(n) | ~50n gas |
| Walk segments | O(n) | ~200n gas |
| **Total** | **O(n)** | **~350n gas** |

Where `n` = number of segments (typically 2-16).

### Comparison with Other AMMs

| AMM Type | Complexity | Typical Gas |
|----------|------------|-------------|
| **BAMM Piecewise** | **O(n), n≤16** | **~3,000-6,000** |
| Uniswap V2 | O(1) | ~2,000 |
| Curve StableSwap | O(k) iterations | ~5,000-10,000 |
| Curve Cryptoswap | O(k) iterations | ~15,000-30,000 |
| Gyroscope ECLP | O(k) iterations | ~10,000-20,000 |
| Uniswap V3 | O(m) ticks | ~5,000-50,000+ |

**Key Advantage**: Unlike Curve/Gyroscope which use Newton's method (variable iterations), BAMM has **predictable, bounded gas cost**.

### Why It's Faster

1. **No invariant solving**: Direct calculation, no iterative root-finding
2. **Bounded loops**: Maximum 16 segments, all in memory
3. **Simple arithmetic**: Addition, multiplication, division only
4. **No logarithms**: Unlike Curve Cryptoswap's log calculations
5. **No square roots**: Unlike Gyroscope's ellipse calculations

## Integration with Oracle System

### Dynamic Adaptation

The piecewise curve adapts to market conditions:

1. **Volatility increases** → Breadth widens → Liquidity spreads out
2. **Volatility decreases** → Breadth narrows → Liquidity concentrates
3. **Price changes** → TWAP updates → Segments shift with market

### Oracle Modes and Pricing

| Oracle Mode | TWAP Source | Breadth Calculation | Update Frequency |
|-------------|-------------|---------------------|------------------|
| Internal-only | Computed on swap | From internal vol | Every swap |
| External-only | Read from oracle | From external vol | Oracle updates |
| Hybrid | External (main) | From oracle vol | Oracle updates |

All modes use the same piecewise calculation, just with different TWAP/volatility inputs.

## Example: 2-Asset Pool Swap

### Setup
```
Pool: USDC ↔ WETH
USDC reserves: 1,000,000 USDC
WETH reserves: 500 WETH
WETH TWAP: $2000
```

### WETH Liquidity Profile
```
segments: 3
twapOffsets: [-50, 0, 50, 100]
weights: [80, 100, 75]
volatility: 20% → breadth: 3000 bps (30%)
```

### User Buys 10 WETH

**Step 1: Calculate WETH prices**
```
offset -50 → $2000 × (1 - 0.50 × 0.30) = $1700
offset 0   → $2000 × (1 + 0.00 × 0.30) = $2000
offset 50  → $2000 × (1 + 0.50 × 0.30) = $2300
offset 100 → $2000 × (1 + 1.00 × 0.30) = $2600
```

**Step 2: Segment liquidity**
```
Segment 0 [$1700-$2000]: 500 × 80/255 = 157 WETH
Segment 1 [$2000-$2300]: 500 × 100/255 = 196 WETH
Segment 2 [$2300-$2600]: 500 × 75/255 = 147 WETH
```

**Step 3: Execute (buy 10 WETH)**
```
Fill from Segment 1: 10 WETH at avg ($2000+$2300)/2 = $2150/WETH
Total cost: 10 × $2150 = $21,500 USDC
```

User pays $21,500 USDC for 10 WETH, experiencing ~7.5% price impact due to concentrated liquidity.

## Security Considerations

### Bounds Checking
- Offsets validated: -100 ≤ offset ≤ 100
- Weights validated: sum = WEIGHT_SUM (255)
- Segment count: MIN_SEGMENTS (2) ≤ n ≤ MAX_SEGMENTS (16)
- Breadth validated: minBreadth < maxBreadth

### Price Manipulation Protection
- Uses slowTWAP (longer window) as reference price
- Breadth limits extreme price ranges
- Circuit breakers for excessive deviation
- Segment boundaries prevent infinite price impact

### Rounding and Precision
- All calculations use integer arithmetic
- Price precision: 1e18 (18 decimals for extreme price ratios)
- Weight precision: sum exactly 255
- Breadth precision: 1e8 format (percentage values, not prices)

### Edge Cases
1. **No liquidity in range**: Uses highest/lowest segment price
2. **Single segment**: Falls back to simple TWAP pricing
3. **Zero amount**: Returns spot price (slowTWAP)
4. **Inverted segments**: Skipped (rightPrice ≤ leftPrice)

## Future Optimizations

### Possible Improvements
1. **Logarithmic pricing within segments**: Replace linear avg with `sqrt(p0 * p1)` for constant product
2. **Binary search for segment**: O(log n) segment finding instead of linear walk
3. **Segment caching**: Cache frequently accessed segment boundaries
4. **Packed storage**: Store multiple weights in single uint256

### Trade-offs
- More complex math = higher gas cost
- Current linear approach is "good enough" for typical trades
- Optimization priority: correctness > gas > precision

## References

- [Uniswap V3 Whitepaper](https://uniswap.org/whitepaper-v3.pdf) - Concentrated liquidity inspiration
- [Curve Whitepaper](https://curve.fi/whitepaper) - StableSwap invariant
- [Curve Cryptoswap](https://curve.fi/files/crypto-pools-paper.pdf) - Dynamic AMM
- [Gyroscope ECLP](https://docs.gyro.finance/gyroscope-protocol/concentrated-liquidity-pools/e-clps) - Ellipse pools

## Version History

- **v1.0.0** (2025-11-10): Initial piecewise bonding curve implementation
  - Segment-based liquidity distribution
  - Dynamic breadth scaling
  - O(n) execution price calculation
