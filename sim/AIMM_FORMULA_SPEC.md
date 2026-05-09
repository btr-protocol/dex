# AIMM Formula Specification

**Status:** CANONICAL REFERENCE
**Date:** 2025-01-11

This document defines the canonical formulas for AIMM. All implementations (Solidity, Python simulator, documentation) MUST align with these specifications.

---

## 1. Oracle: TWAP with Accumulators

### Purpose
Provide manipulation-resistant reference prices for pricing calculations.

### Formula
```
a(t) = a(t-1) + p(t) times Delta t

o = (a_("now") - a_("past")) / tau
```

```
WHERE
a(t) = text(price accumulator at time t)
p(t) = text(price at time t)
Delta t = text(time step)
o = text(TWAP output (oracle price))
tau = text(total time elapsed in window)
```

### Parameters
| Parameter | Value | Description |
|-----------|-------|-------------|
| Fast window | 2 hours | Short-term price trend |
| Slow window | 12 hours | Long-term price baseline |

### Properties
- **Time-bound**: Averages over fixed time windows
- **Continuous**: Conceptually updates with time (implementation may batch)
- **Manipulation-resistant**: Requires sustained price manipulation

### Storage
```solidity
struct PriceAccumulator {
    uint256 cumulative;    // Cumulative price × time
    uint256 lastPrice;     // Last recorded price
    uint32 lastTimestamp;  // When last updated
}
```

### TWAP Calculation
```
Delta a = a_("now") - a(("now") - w)

o = (Delta a) / tau
```

```
WHERE
Delta a = text(change in accumulator over window)
w = text(window duration)
tau = text(time elapsed in same units as) Delta t
```

---

## 2. Volatility: Activity-Based EMA

### Purpose
Track realized volatility for spread calculation, updating only on swap activity.

### Formula
```
r = |ln(p_("now") / p_("prev"))|

v' = alpha times r + (1 - alpha) times v
```

```
WHERE
r = text(absolute log return)
p_("now"), p_("prev") = text(current and previous prices)
v = text(EMA volatility)
v' = text(updated EMA volatility)
alpha = text(smoothing factor)
```

### Parameters
| Parameter | Value | Description |
|-----------|-------|-------------|
| α (fast) | 0.125 | ~8-swap half-life |
| α (slow) | 0.025 | ~40-swap half-life |

### Properties
- **Activity-bound**: Only updates when swaps occur
- **Decay via α**: Controls responsiveness vs smoothness
- **Range**: 0 to ∞ (typically 0.001 to 0.10 for 0.1% to 10% per-swap vol)

### Effective Volatility
```
sigma = (v_f + v_s) / 2
```

```
WHERE
v_f = text(fast EMA volatility)
v_s = text(slow EMA volatility)
sigma = text(effective volatility, average for balanced responsiveness)
```

### Units
- VOL_BASE = 1,000,000 (1% = 1,000,000)
- Stored as uint32

---

## 3. Deviation: EMA Divergence

### Purpose
Measure directional uncertainty from TWAP divergence.

### Formula
```
Delta = max(|o_f - o_s|, |o_f - s|) / s times P
```

```
WHERE
o_f = text(fast TWAP oracle)
o_s = text(slow TWAP oracle)
s = text(spot price)
P = text(OFFSET_PRECISION) = 10,000,000
```

### Properties
- Captures trending markets (fast ≠ slow)
- Captures spot divergence (fast ≠ current)
- High Δ = directionally uncertain = higher toxic flow penalty

### Units
- OFFSET_PRECISION = 10,000,000 (0.0001% units)
- Stored as uint32

---

## 4. Coverage Ratio

### Purpose
Measure asset health (reserves vs liabilities).

### Formula
```
c = R / L
```

```
WHERE
c is the coverage ratio
R is the reserves
L is the liabilities
```

### Critical Levels
| Level | Coverage | State |
|-------|----------|-------|
| Critical floor | 50% | Maximum stress, max skew |
| Target | 100% | Equilibrium, zero skew |
| Critical ceiling | 200% | Over-collateralized, max discount |

### Units
- WAD = 1e18 (100% = 1e18)

---

## 5. Inventory Skew (Linear)

### Purpose
Create price incentive for coverage rebalancing.

### Formula
```
pi = |c - c_t| / |c_b - c_t|

psi = "sign"(c_t - c) times gamma times 100 times pi
```

```
WHERE
pi is the progress toward boundary (in [0, 1])
c is the current coverage ratio
c_t is the target coverage (1.0)
c_b is the critical boundary (0.5 or 2.0)
gamma is the gamma sensitivity (MULT_BASE = 10000)
psi is the inventory skew (in [-100, +100])
"sign"(...) is +1 if (c < c_t), else -1
```

### Properties
- **LINEAR in progress** — smooth, predictable
- **Gamma as multiplier** — controls steepness
- **No double-penalty** — single scaling factor

### Example (γ = 1.0x)
| Coverage | Progress | Skew |
|----------|----------|------|
| 50% | 1.0 | +100 (max premium) |
| 75% | 0.5 | +50 |
| 100% | 0.0 | 0 (equilibrium) |
| 125% | 0.25 | -25 |
| 150% | 0.5 | -50 |
| 200% | 1.0 | -100 (max discount) |

### Rationale
Matches Avellaneda-Stoikov inventory adjustment:
```
δ = γ × q × σ²
```
Linear in inventory position (q), scaled by risk aversion (γ).

---

## 6. Dispersion (Liquidity Spread Width)

### Purpose
Control how liquidity spreads across price range based on volatility.

### Formula
```
kappa = "clamp"(kappa_0 + (sigma times nu) / (1000 times M), kappa_("min"), kappa_("max"))
```

```
WHERE
kappa is the dispersion (liquidity spread width in basis points)
kappa_0 is the base dispersion (1000 = 0.1%)
sigma is the effective volatility (VOL_BASE units, 1% = 1,000,000)
nu is the vega sensitivity (M = 10000)
M is the MULT_BASE (10000)
kappa_("min"), kappa_("max") are the dispersion bounds
```

### Example (vega = 1.0x)
| Volatility (σ) | Dispersion |
|----------------|------------|
| 0.5% (500,000) | 0.15% (1500 bps) |
| 1.0% (1,000,000) | 0.20% (2000 bps) |
| 2.0% (2,000,000) | 0.30% (3000 bps) |
| 5.0% (5,000,000) | 0.60% (6000 bps) |

### Units
- BPS_PRECISION = 1,000,000 (0.0001% = 1 unit)

---

## 7. Spread (Fee) Model

### Purpose
Charge fees that reward beneficial trades and penalize toxic trades.

### Coverage Impact
```
improves_coverage = (post_coverage closer to target) than (pre_coverage)
```

Specifically, a trade improves coverage if it moves the combined coverage deviation toward zero.

### Spread Formulas

**Arb Flow (improves coverage):**
```
S_a = max(f_("min"), (sigma times nu) / (100 times M))
```

```
WHERE
S_a is the arb spread (basis points)
f_("min") is the minimum fee
sigma is the effective volatility
nu is the vega sensitivity
M is the MULT_BASE (10000)
```

**Toxic Flow (worsens coverage):**
```
S_t = max(f_("min"), (sigma times nu) / (100 times M) + (Delta times lambda) / M)
```

```
WHERE
S_t is the toxic spread (basis points)
Delta is the deviation
lambda is the lambda sensitivity
(Other terms same as arb flow)
```

### Parameter Meanings
| Parameter | Purpose | Default |
|-----------|---------|---------|
| min_fee | Floor to prevent zero fees | 100 (0.01%) |
| max_fee | Ceiling to cap fees | 10000 (1.0%) |
| vega | Volatility sensitivity | 10000 (1.0x) |
| lambda | Deviation sensitivity | 10000 (1.0x) |

### Example Calculations

**Calm market, arb flow:**
- σ = 500,000 (0.5%), Δ = 0, vega = 10000, lambda = 10000
- spread = max(100, (500000 × 10000) / (100 × 10000))
- spread = max(100, 500) = **500 bps = 0.05%**

**Volatile market, arb flow:**
- σ = 2,000,000 (2%), Δ = 0, vega = 10000, lambda = 10000
- spread = max(100, (2000000 × 10000) / (100 × 10000))
- spread = max(100, 2000) = **2000 bps = 0.20%**

**Volatile market, toxic flow:**
- σ = 2,000,000 (2%), Δ = 500,000 (5%), vega = 10000, lambda = 10000
- vol_component = 2000
- deviation_surcharge = (500000 × 10000) / 10000 = 500000
- spread = max(100, 2000 + 500000) = **502000 bps** (capped to max_fee)
- After cap: **10000 bps = 1.0%**

---

## 8. Depth Calculation

### Purpose
Provide virtual liquidity when under-collateralized.

### Formula
```
if c >= 1:
    D = R
else:
    pi = (c - c_f) / (1 - c_f)
    e = 1 / (1 + 2k)
    D = R + k times (L - R) times pi^e
```

```
WHERE
D is the effective depth
c is the coverage ratio
R is the reserves
L is the liabilities
c_f is the critical floor (e.g., 0.5)
k is the depth amplifier (normalized, e.g., 0.33)
pi is the progress from floor to target
e is the exponent (concave curve)
```

### Properties
- At 100% coverage: depth = reserves (no amplification)
- At critical floor: depth = reserves (no virtual depth)
- Between: concave interpolation adding virtual depth

---

## 9. Spline Traversal (Pricing)

### Purpose
Calculate execution price by traversing liquidity profile.

### Starting Position
```
d_("start") = 5000 + psi times 50
```

```
WHERE
d_("start") is the depth position (in [0, 10000])
psi is the inventory skew (in [-100, +100])
```

### Volume Fraction
```
f = min(x_("in") / D, 1) times 10000
```

```
WHERE
f is the volume fraction
x_("in") is the input amount
D is the effective depth
```

### Ending Position
```
if selling:
    d_end = max(0, d_start - f)
else:
    d_end = min(10000, d_start + f)
```

### Price Calculation
```
p = o times (1 + bar a / B)
```

```
WHERE
p is the execution price
o is the oracle price (TWAP)
bar a is the average offset over depth range
B is the BPS_PRECISION (1,000,000)
```

### Flat Spline (Linear)
For 2-point profile with linear interpolation:
```
offset = interpolate(start_depth, end_depth)
```

---

## 10. Summary Table

| Component | Formula | Units |
|-----------|---------|-------|
| TWAP | Δaccumulator / Δtime | WAD (1e18) |
| Volatility | α × \|return\| + (1-α) × prev | VOL_BASE (1e6) |
| Deviation | max(\|fast-slow\|, \|fast-spot\|) | OFFSET_PRECISION (1e7) |
| Coverage | reserves / liabilities | WAD (1e18) |
| Skew | γ × 100 × progress (LINEAR) | int8 (-100 to +100) |
| Dispersion | 1000 + σ×vega/(1000×10000) | BPS_PRECISION (1e6) |
| Spread (arb) | max(min, σ×vega/(100×10000)) | BPS_PRECISION (1e6) |
| Spread (toxic) | spread_arb + Δ×λ/10000 | BPS_PRECISION (1e6) |

---

## 11. Implementation Checklist

### Solidity (evm/src/libraries/)
- [ ] LibOracle.sol: Update to accumulator-based TWAP
- [ ] LibOracle.sol: Keep activity-based EMA for volatility
- [ ] LibPricing.sol: Fix skew to LINEAR (γ × 100 × progress)
- [ ] LibPricing.sol: Fix spread_arb formula (no +100 base)
- [ ] LibPricing.sol: Ensure deviation surcharge ONLY on toxic flow

### Python Simulator (sim/src/sim/amms/)
- [ ] aimm_verified.py: Implement accumulator-based TWAP
- [ ] aimm_verified.py: Fix skew to linear formula
- [ ] aimm_verified.py: Fix spread formulas

### Documentation (docs/, specs/)
- [ ] Update all references to use canonical formulas
- [ ] Remove references to exponential skew
- [ ] Clarify arb vs toxic spread distinction

---

## 12. Design Rationale

### Why Linear Skew?
1. **Matches A-S theory**: Avellaneda-Stoikov uses linear inventory term
2. **Predictable**: LPs can estimate their expected return
3. **No double-penalty**: Gamma as multiplier, not exponent
4. **Tunable**: Gamma can increase steepness if needed (1.5x, 2.0x)

### Why Accumulator TWAP?
1. **Manipulation-resistant**: Requires sustained price control
2. **Time-weighted**: Natural average over window
3. **Industry standard**: Uniswap v2/v3 uses this approach
4. **Continuous**: Not dependent on trading activity

### Why Activity-Based Volatility EMA?
1. **Captures realized vol**: Only updates on actual trades
2. **Responsive**: Adapts quickly to regime changes
3. **Efficient**: No continuous state updates needed
4. **Per-swap**: Natural boundary for calculation

### Why Asymmetric Spread?
1. **Incentivizes rebalancing**: Arb gets lower fees
2. **Punishes toxic flow**: Directional trades pay more
3. **Self-stabilizing**: Coverage naturally trends to target
4. **Capital efficient**: Attracts beneficial liquidity

