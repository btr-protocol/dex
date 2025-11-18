# Orbital/Orbswap vs BAMM: Technical Architecture Comparison

**Version:** 1.1
**Date:** 2025-01-17
**Status:** Research & Analysis
**Revision Notes:** v1.1 incorporates expert feedback on mathematical rigor, notation clarity, and claim precision

---

## Executive Summary

Both Orbital/Orbswap and BAMM architectures aim to maximize capital efficiency in multi-asset pools, but they employ fundamentally different mathematical frameworks:

- **Orbital/Orbswap:** Single high-dimensional invariant surface (sphere/superellipse) with tick-based concentrated liquidity in polar coordinates
- **BAMM:** Per-asset Makima-shaped curves with Wombat-style asset-liability model, coverage-driven fees, hub-and-spoke pricing via numéraire, and virtual depth routing

Recent BAMM architectural refinements—virtual numéraire depth, no base state changes on triangulated swaps, geometric-mean path fees with 50/50 split, and coverage-only inventory factors—eliminate the traditional hub-and-spoke downsides and make BAMM highly competitive, especially for heterogeneous asset pools with explicit ALM requirements.

This document provides a rigorous, section-by-section technical comparison based on published research and implementation analysis.

---

## 1. Architectural Core: Global Invariant vs Per-Asset Curves

### 1.1 Orbital Architecture (Paradigm 2025)

**Invariant Foundation:**

Orbital defines a **single N-dimensional pricing surface** for all pool assets using a spherical constraint. For a reserve vector `x ∈ ℝⁿ`, center `c`, and radius `R`, the invariant is:

```
‖x - c‖² = R²
```

This constrains all valid reserve states to lie on an n-dimensional sphere's surface.[^1]

**Pricing Mechanism:**

Token exchange rates are derived from the no-arbitrage condition under the spherical constraint. Pricing is proportional to the gradient of the invariant: reserves with fewer tokens command higher prices because the marginal rate is determined by the local geometry of the sphere.[^1]

**Equal Price Point and Polar Decomposition:**

Orbital introduces a symmetry axis defined by the equal-price direction vector `v⃗ = (1/√n)(1, 1, ..., 1)`. Any reserve state can be decomposed as:

```
x⃗ = αv⃗ + w⃗
```

where `α` measures the projection along the symmetry axis and `w⃗` is orthogonal to `v⃗` (i.e., `⟨v⃗, w⃗⟩ = 0`). After suitable choice of coordinates, the sphere constraint becomes:

```
α² + ‖w⃗‖² = R²
```

This polar decomposition separates the "equally balanced" direction from deviations.[^1]

**Tick Architecture:**

Ticks function as nested **spherical caps** created by intersecting the sphere with hyperplanes orthogonal to the equal-price direction `v⃗`. A tick boundary is defined by a plane constant, and assets trading within a tick remain in the spherical cap region. Each tick can be characterized by its distance from the equal-price point, with inner ticks behaving like interior points and outer ticks behaving like boundary points.[^1]

**Global Trade Invariant:**

By aggregating all interior ticks into one sphere and all boundary ticks into a lower-dimensional sphere, Orbital derives a **toroidal surface** that combines interior and boundary tick liquidity into a single computable formula. Critically, this global invariant can be evaluated using **only sums of reserves and sums of squared reserves**, enabling O(1) evaluation complexity regardless of the number of assets N.[^1]

Trade computation involves solving for the trade size that maintains the invariant, which reduces to a **quartic equation** in the general case.

### 1.2 Orbswap Architecture (arXiv 2510.05428)

**Circular/Superelliptic Variant:**

Orbswap builds on Orbital's spherical geometry but introduces modifications optimized for stablecoin behavior. The base circular invariant for the simplified case is centered around a focal distance `l`:

```
Σᵢ (xᵢ - l)² = l²
```

From this, Orbswap constructs **superelliptic variants** using a center curve function `C(x)` with parameter `β`:

```
C(x) = 1 / (1 - (1 - ((x-1)/x)^β)^(1/β))
```

This formulation "flattens" the pricing surface around equal prices (1:1 ratios), concentrating liquidity density where stablecoins typically trade, while steepening outside that region for better depeg price discovery.[^2][^4]

**Polar Coordinate Parameterization:**

Swaps are parameterized in **polar coordinates from a focal point**, allowing rotation-based execution rather than Cartesian translation. Unlike traditional AMM swap functions that move along a curve in the Cartesian plane, the circular/superelliptic invariants enable rotation using polar coordinates with distance `l` from a focal point.[^2][^3]

**Implementation in Rust:**

Orbswap is **designed to leverage Arbitrum Stylus** to execute "intense trigonometric calculations" in Rust, accessing advanced math libraries unsuitable for Solidity. The implementation uses `sin`, `cos`, `sqrt`, and related functions for polar coordinate transforms. The design includes the ability to **skew concentrated liquidity** asymmetrically using the `β` parameter and tick boundaries.[^2][^4]

While a pure-EVM implementation is theoretically possible using approximation libraries, it would be **gas-prohibitive** for practical use.[^3]

**Key Differences from Orbital:**

- **Orbital:** Perfect spheres with tick-based concentrated liquidity, allowing customizable LP exposure across price ranges
- **Orbswap:** Superelliptic invariant with center curve `C(x)` optimizes high-dimensional pool geometry specifically for stablecoin 1:1 behavior; v0 uses uniform approach (sacrificing individual LP customization), but v1 aims to restore asymmetric tick support[^3]

### 1.3 BAMM Makima + ALM Architecture

**Per-Asset Bonding Curves:**

Each asset `i` has its own **one-dimensional bonding curve** vs the numéraire (hub), defined piecewise using segment weights and **Makima-style piecewise cubic Hermite interpolation** around oracle TWAPs.[^5][^6]

Makima produces a C¹ interpolant with controlled slopes and reduced overshoot, well-suited for shaping liquidity around observed price densities.

**Wombat-Style Asset-Liability Model:**

Pool solvency and pricing discipline come from explicit per-asset accounting:

```
Cᵢ = Rᵢ / Lᵢ
```

where:
- `Rᵢ` = reserves for asset i
- `Lᵢ` = liabilities for asset i
- `Cᵢ` = coverage ratio

The AMM's invariant logic is built around **per-asset coverage and liability decay**, not a single global geometric constraint.[^7][^8]

**Hub-and-Spoke Pricing with Virtual Numéraire:**

Pricing between A and B is implemented as a **two-leg route A→numéraire→B**, with critical refinements:

- Base (numéraire) is treated as **purely virtual for routing**—no state changes, no fees on triangulated swaps
- Virtual depth for the base leg is chosen to match A and B's effective depths
- Final price is fully determined by A's and B's curves vs the common numéraire
- Eliminates traditional hub-and-spoke path dependence issues[^9]

### 1.4 Implications

**Orbital/Orbswap:**

- Enforces a **single global no-arbitrage relation** between all assets
- Any trade moves a common point on a high-dimensional surface
- Pricing is globally consistent under that invariant
- Strong symmetry assumptions baked into the geometry

**BAMM:**

- Enforces **per-asset solvency and curve behavior**
- Cross-asset prices composed via numéraire
- Consistency mediated by oracles and ALM constraints, not by a single explicit N-dimensional surface
- Flexibility to handle asymmetric asset characteristics

---

## 2. Pricing Surfaces and Mathematical Complexity

### 2.1 Orbital Pricing Complexity

**Quartic Trade Equations:**

On Orbital, trades must satisfy `F(r + Δr) = 0` for the spherical constraint `F(r) = Σ rᵢ² - R² = 0`, leading to a **quartic equation in trade size** that must be solved (typically via Newton's method).[^1]

**Tick Crossing Segmentation:**

When trades cross tick boundaries (interior ↔ boundary), execution must be segmented:

1. Solve the quartic until the first tick boundary
2. Flip that tick's classification
3. Update the invariant parameters
4. Solve again for the remaining amount

This increases implementation complexity and introduces path segmentation logic.[^1]

**Computational Cost:**

- Quartic root-finding via iterative methods
- Boundary detection and state transitions
- Error bounds and edge-case handling in fixed-point arithmetic
- High precision requirements to avoid rounding errors in multi-step trades

### 2.2 Orbswap Pricing Complexity

**Trigonometric Transformations:**

For a trade Δx of asset x to asset y, Orbswap:

1. Converts to polar coordinates around the focal point at distance `l`
2. Applies the superelliptic invariant with center curve `C(x)`
3. Uses functions like `sin`, `cos`, `sqrt`, and related operations to compute Δy via polar rotation[^2][^3][^4]

**EVM Challenges:**

Transcendental functions (`sin`, `cos`, `sqrt`) are **gas-intensive** on standard EVM and require approximation libraries or precompiles. The Rust implementation demonstrates explicit use of these operations throughout the swap path.[^2][^4]

**Arbitrum Stylus Strategy:**

Orbswap is **designed to leverage Arbitrum Stylus** to execute "intense trigonometry calculations" in Rust, accessing advanced math libraries unsuitable for Solidity. This significantly reduces gas costs compared to pure-EVM approximations. A standard EVM implementation is possible but would likely be **prohibitively expensive** for production use, effectively making Stylus a practical requirement rather than just an optimization.[^3]

### 2.3 BAMM Pricing Complexity

**Piecewise Cubic Primitives:**

For each asset vs numéraire, BAMM defines a **piecewise price function** `Pᵢ(q)` over reserves `q`, obtained from Makima interpolation through anchor points:

- Within each segment `k` over interval `[qₖ, qₖ₊₁]`, `Pᵢ(q)` is a cubic polynomial with continuous first derivative
- Marginal price within a segment: `Pᵢ(q)`
- Total value: `∫ Pᵢ(q) dq` (closed-form cubic primitives)

**Segment Walking:**

In practice, BAMM uses **discrete segment liquidity** and treats marginal price as constant within a small band, walking segments linearly. A direct A↔B swap is implemented as **two virtual legs** but executed as a single path quote:

- Traverse A's and B's curves using the same piecewise machinery
- Real numéraire kept out of state updates and fee logic in triangulated design
- Computational core: repeated 1D segment traversal and simple arithmetic

**Complexity Analysis:**

- Pricing reduces to **walking a small, bounded number of segments per leg** (e.g., up to 16)
- Only multiplications, additions, and divisions—**no transcendental functions**
- **No polynomial root finding**
- Complexity per trade: **O(n_segments)**, where n_segments is typically ≤ 16

### 2.4 Complexity Comparison Summary

| Aspect | Orbital | Orbswap | BAMM |
|--------|---------|---------|------|
| **Core Math** | Quartic solves, tick boundary detection | Trigonometric transforms, superelliptic center curve | Piecewise cubic segments |
| **Functions Required** | Polynomial roots (Newton) | sin, cos, sqrt, polar transforms | +, ×, ÷ only |
| **Per-Trade Complexity** | Quartic solve + possible segmentation | Polar conversion + transcendental ops | O(n_segments) linear walk |
| **EVM Suitability** | Medium (fixed-point quartic) | Low (Stylus practically required) | High (elementary ops only) |
| **Auditability** | Medium (geometric elegance, numerical edge cases) | Low-Medium (complex trigonometry) | High (simple arithmetic) |
| **Gas Cost** | High | Very High on EVM, Medium-High on Stylus | Low-Medium |

**Result:** Orbital/Orbswap achieve a truly global invariant but at the cost of significantly higher mathematical and implementation complexity; BAMM uses simpler 1D primitives per asset with Makima interpolation, which is much easier to implement, reason about, and optimize for gas.

---

## 3. Liquidity Concentration: Polar Ticks vs Makima Shaping

### 3.1 Orbital Ticks and Capital Efficiency

**Tick Definition:**

Liquidity is concentrated via **ticks defined as spherical caps**. A tick with plane constant `κ` allows reserves where the projection onto the equal-price vector satisfies:

```
⟨r, e⟩ ≥ κ
```

corresponding to a maximum tolerated depeg of one asset while still remaining interior.[^1]

**Virtual Reserves:**

The minimum reserve per asset in a tick is:

```
xₘᵢₙ = (k√n - √(k²n - n((n-1)r - k√n)²)) / n
```

Liquidity providers effectively deposit only `xₘᵢₙ` per asset, with efficiency gains calculated as:

```
xₑ𝒻 = xₐₛᵣₐ / (xₐₛᵣₐ - xₘᵢₙ)
```

**Quantified Capital Efficiency:**

Paradigm's analysis shows:[^1]

- **5-asset pool, 90¢ depeg floor (`pₘᵢₙ = 0.90`):** ~**15× capital efficiency**
- **5-asset pool, 99¢ depeg floor (`pₘᵢₙ = 0.99`):** ~**150× capital efficiency**

These gains come from not needing to hold full reserves for worst-case single-asset depegs—interior ticks maintain fair pricing across stable assets even if one goes to zero.

**Symmetric Concentration:**

Orbital's tick system is **symmetric** and analytically neat, but each LP chooses tick radii/plane constants in a **common geometric framework**. Asymmetry (e.g., one asset being qualitatively riskier) is not a first-class parameter and requires distortions of the geometry.[^1]

### 3.2 Orbswap Superellipse Concentration

**Curve Flattening Near Peg:**

The superellipse invariant concentrates liquidity around the equal-price region by:

- Flattening the curve near `pᵢ = 1` (almost constant-sum behavior)
- Steepening it outside that region (constant-product or worse)
- Skewing the exponent and coefficients to match observed stablecoin trading patterns[^2][^3]

**Polar Bands:**

Ticks or polar bands can further sharpen or modulate this concentration, similar to Orbital's spherical caps but adapted to the superellipse geometry.[^3]

**Trade-off:**

Orbswap v0 uses a **uniform approach** that simplifies implementation but sacrifices individual LP customization; v1 aims to restore asymmetric tick support.[^3]

### 3.3 BAMM Makima Liquidity Shaping

**Non-Parametric Flexibility:**

BAMM uses **Makima-interpolated segment prices** (modified Akima piecewise cubic Hermite interpolation with continuous first derivative and reduced overshoot for flat regions[^12]) around each asset's numéraire TWAP, with anchor points chosen based on recent price action and realized price density (e.g., more anchors around frequently visited prices).[^5][^6]

**Per-Asset Tuning:**

For stablecoins:
- Anchor points and segment weights chosen so curve is almost flat in a tight band around `p = 1` (constant-sum-like)
- Rapidly steepens outside (constant-product-like or worse)
- Mimics "high concentration near peg" behavior Orbital gets from inner ticks, but tuned **per asset**

For volatile assets:
- Makima allows constructing **asymmetric profiles** reflecting skew and momentum
- Example: more depth below current price (to absorb dips) and less depth above, or vice versa, based on recent price paths vs numéraire
- Much harder to encode in a symmetric spherical/superelliptic invariant[^5][^6]

**Heterogeneous Pools:**

BAMM's Makima curves are **fully per-asset**:

- Narrow, almost flat bands for USDC
- Moderate ones for ETH
- Very wide, lumpy ones for a governance token
- **All in the same pool**, by simply modifying each asset's anchor points and weights

**Empirical Capital Efficiency:**

Capital efficiency is determined by chosen anchors and their mapping to price. While **local slippage formulas can be derived** from segment definitions (cubic polynomial integration), overall capital efficiency is more **empirical and configuration-dependent** than Orbital's closed-form geometric ratios. This data-driven approach is also **more flexible** and allows per-asset tuning.[^5][^6]

### 3.4 Technical Pros/Cons Summary

| Feature | Orbital Ticks | Orbswap Superellipse | BAMM Makima |
|---------|---------------|----------------------|-------------|
| **Concentration Mechanism** | Spherical caps (tick boundaries) | Superellipse flattening + polar bands | Piecewise cubic anchors |
| **Capital Efficiency** | Analytically derived (15×–150×) | Similar to Orbital, empirical tuning | Empirical, per-asset configurable |
| **Symmetry** | Symmetric by design | Symmetric (v0), asymmetric planned (v1) | Fully asymmetric per asset |
| **Heterogeneous Assets** | Requires geometric distortions | Limited (stablecoin-focused) | Native support |
| **Configurability** | Common framework, tick radii | Uniform (v0) | Per-asset anchor points |
| **Explainability** | Closed-form expressions | Superellipse parameters | Data-driven, visual |

---

## 4. ALM Model: None vs Coverage-Based Asset-Liability

### 4.1 Orbital/Orbswap ALM

**Reserve-Based Only:**

Orbital's paper focuses on **reserve-based invariants** and does not define per-asset liabilities, coverage ratios, or explicit ALM rules. LPs deposit and withdraw reserves, and their risk is determined purely by the invariant geometry and fee schedule.[^1]

Orbswap also focuses on high-dimensional stablecoin pricing surfaces; ALM is implicitly handled by fees and the invariant, not by a Wombat-style separation of assets and liabilities per token.[^2][^3][^4]

**No Explicit Bad-Debt Resolution:**

There is no notion of liabilities, coverage ratios, or decay. Solvency and LP risk management must be bolted on externally or left to the invariant's behavior under stress.

### 4.2 BAMM Wombat-Style ALM

**Coverage Ratio:**

BAMM explicitly adopts a **coverage-ratio ALM** per asset:

```
Cᵢ = Rᵢ / Lᵢ
```

where:
- `Rᵢ` = reserves in token units
- `Lᵢ` = liabilities in token units
- `Cᵢ` = coverage (core solvency metric, as in Wombat)[^7][^8]

**Time-Based Liability Decay:**

When coverage `Cᵢ < 1` persists, a **time-based liability decay** schedule gradually reduces `Lᵢ`, writing down claims and smoothing permanent losses:

- Decay function is monotone, bounded below, and parameterizable per token (floor, half-life, exponent)
- Provides explicit bad-debt resolution mechanism
- Prevents indefinite under-collateralization[^7][^8]

**Inventory Component of Swap Fees:**

The **inventory component** is a function of coverage `Cᵢ` only, with linear ramps:

- **Rebates** for trades that increase `Cᵢ` (under-collateralized assets)
- **Penalties** for trades that decrease `Cᵢ` (over-collateralized assets)
- Does **not** use value-weighted portfolio shares (avoiding hub-and-spoke bias)[^9]

**Tri-Factor Fee Model:**

On top of the coverage-driven inventory term, BAMM adds:

1. **Volatility shock factor** `m_vol`: derived from ratio of fast/slow vol EMAs
2. **Price-divergence factor** `m_pd`: derived from spot vs fast and fast vs slow TWAP deviations

These multiply to give a per-asset risk multiplier `mᵢ`, and for an A↔B path:

```
m_path = √(m_A × m_B)
```

determines the path fee, which is then **split 50/50 across LPs of A and B** (in value terms).[^9]

### 4.3 Fees as ALM Feedback

**Circuit Breakers:**

BAMM includes oracle-based circuit breakers:

- Max TWAP change per block
- Max fast/slow TWAP divergence
- Can **freeze swaps** for a toxic asset when prices diverge too far
- Isolates impact while other assets keep trading[^9]

**Granular Risk Control:**

Each asset has independent:
- Coverage monitoring
- Decay parameters
- Circuit breaker thresholds
- Fee multipliers

This enables fine-grained per-asset solvency control absent from Orbital/Orbswap.

### 4.4 ALM Comparison Summary

| Aspect | Orbital/Orbswap | BAMM |
|--------|-----------------|------|
| **Liability Tracking** | None (reserve-only) | Explicit per-asset Lᵢ |
| **Coverage Ratios** | Not defined | Core solvency metric Cᵢ = Rᵢ/Lᵢ |
| **Bad-Debt Resolution** | External/implicit | Time-based decay, parameterizable |
| **Circuit Breakers** | Not native | Oracle-based, per-asset |
| **Fee Feedback** | Implicit via geometry | Explicit tri-factor (coverage, vol, divergence) |
| **Heterogeneous Asset Support** | Limited | Native (stables + majors + alts) |

**Conclusion:** For a heterogeneous pool (stables + majors + alts), BAMM's asset-liability plus coverage-driven fees is a **major advantage**; Orbital is mostly tailored to homogeneous stables with no explicit liability concept.

---

## 5. Path Dependence and Fees

### 5.1 Orbital/Orbswap: Single-Step Trades

In Orbital, a trade from A to B is always a **single movement on the N-dimensional surface**, so there is no explicit triangulation or double fee; path dependence only appears in the sense of which ticks become interior/boundary during the trade.[^1]

Orbswap similarly executes a single step on the superellipse invariant for a given asset pair, with one fee computation.[^2][^3][^4]

**No Routing Complexity:**

All assets are directly priced against each other via the global invariant—no routing decisions needed.

### 5.2 BAMM: Virtual Numéraire and Geometric-Mean Fees

**Original Hub-and-Spoke Weakness:**

Traditional hub-and-spoke designs suffer from:
- Double fee accumulation (A→hub fee + hub→B fee)
- Worst-depth path dependence (limited by hub's depth)

**BAMM Fixes (Current Architecture):**

After recent adjustments:[^9]

1. **Virtual numéraire depth:** In A→base→B, base is treated as **infinite-depth for slippage** by using virtual depth equal to effective depth of the active asset per leg
2. **No state change to base:** **No state change is applied to base reserves or liabilities** for triangulated swaps
3. **Path-independent depth:** Effective depth of A↔B determined by A and B's Makima curves and reserves, not by base's raw reserves; mathematically approximates a direct A/B surface defined by their two 1D curves
4. **Single path fee:** Fee multipliers from coverage, volatility, and price divergence computed for A and B, combined via geometric mean `m_path = √(m_A × m_B)`, applied to baseline vol-derived fee to yield one `f_path`
5. **50/50 split:** Fee value split evenly between A and B in value terms, preventing under-collateralized side from being starved of fees

**Per-Path Economic Behavior:**

From the **trader's perspective**, A↔B via base behaves like a single-hop trade with:
- **One fee** (not double fees)
- **Depth determined by A and B's curves** (not bottlenecked by base)
- **Pricing derived from A and B's Makima curves** composed via the numéraire

The main hub-and-spoke downsides (double fees, base depth bottleneck) are removed.[^9]

However, **global price relationships** across three or more assets (e.g., triangle A–B–C) are still mediated by oracles and composition via the hub, not by a single N-dimensional invariant as in Orbital. Under the assumption that oracles are correct and `effectiveDepth()` is well-tuned, per-path behavior aligns closely with direct pool behavior.

### 5.3 Path Comparison Summary

| Aspect | Orbital/Orbswap | BAMM (with fixes) |
|--------|-----------------|-------------------|
| **Trade Execution** | Single-step on N-D surface | Two-leg via virtual numéraire |
| **Routing** | None needed (global invariant) | Virtual routing (no state changes) |
| **Fee Count** | One | One (geometric mean of legs) |
| **Fee Distribution** | Implicit in geometry | 50/50 split across legs |
| **Depth Dependency** | Global invariant determines | Per-asset curves determine |
| **Path Independence** | Native | Achieved via virtual depth |

**Result:** For any given A↔B path, both architectures deliver **single-hop economic behavior** (one fee, depth not bottlenecked by intermediary). BAMM's two-leg implementation via virtual numéraire is a technical detail that doesn't introduce the traditional hub-and-spoke downsides, though global multi-asset price consistency is ensured differently (oracle-mediated composition vs. geometric invariant).

---

## 6. Depeg Behavior, Asset Mixing, and Contagion

### 6.1 Orbital Depegs

**Single-Asset Depeg Resilience:**

Orbital derives explicit formulas for minimum reserves of any one coin in a tick given its plane constant. Under a **single-asset depeg** where one coin goes to price `pₘᵢₙ`, traders can drain that coin but **cannot force the reserves of the others below a tick-specific floor**, giving LPs "virtual reserves" of the remaining stables.[^1]

**Multi-Asset Depeg Fragility:**

The design assumes that **only one asset depegs at a time**. Multi-asset depegs or correlated failures can still cause problematic state changes, and the **entire pool shares risk** because the invariant couples all reserves.[^1]

**Orbswap Warning:**

Orbswap explicitly warns that large high-dimensional stablecoin pools are fragile: **correlated depegs and fat-tailed stablecoins** can cause extreme moves and require hedging or additional payoff structures (e.g., binary options) to control risk.[^2][^4]

### 6.2 BAMM Depegs and Asset Mixing

**Per-Asset Coverage Response:**

In BAMM, each asset has its own coverage ratio and liability decay. A depegged asset:

1. Sees its `Cᵢ` drop below 1
2. Fees adjust via `m_inv(Cᵢ)` (inventory component)
3. Decay gradually reduces `Lᵢ` if the situation persists
4. Limits long-term bad debt[^7][^8]

**Circuit Breaker Isolation:**

Circuit breakers (e.g., max TWAP change per block, max fast/slow TWAP divergence) can **freeze swaps** for a toxic asset when oracle or internal prices diverge too far, **isolating its impact while other assets keep trading**.[^9]

**Limited Contagion:**

Because ALM is per-asset and cross-asset prices are mediated by the numéraire rather than a global invariant, **contagion is limited**:

- Catastrophic failure in one asset reduces its coverage and LP payouts
- Does **not** directly force reserve flows in unrelated assets except via explicit governance or rebalancing
- Unaffected assets continue trading normally[^7][^8]

**Asymmetric Risk Profiles:**

Makima liquidity shaping can be made **asymmetric for risky tokens**:

- Much shallower depth around current price
- Tighter circuit breakers
- Makes it cheap to support **long-tail tokens** in the same pool without giving them undue slippage privileges[^5][^6]

### 6.3 Depeg Comparison Summary

| Aspect | Orbital | Orbswap | BAMM |
|--------|---------|---------|------|
| **Single-Asset Depeg** | Excellent (virtual reserves) | Similar to Orbital | Good (coverage + decay) |
| **Multi-Asset Depeg** | Fragile (coupled invariant) | Fragile (fat-tail warning) | Resilient (per-asset ALM) |
| **Contagion Control** | None (global surface) | None | Circuit breakers, per-asset isolation |
| **Heterogeneous Assets** | Limited (symmetric geometry) | Limited (stablecoin focus) | Native (asymmetric profiles) |
| **Bad-Debt Handling** | External | External | Built-in (decay) |

**Conclusion:** Orbital is excellent at handling **single-asset stablecoin depegs** with explicit virtual-reserve boundaries but has no integrated ALM; BAMM is designed to handle **arbitrary asset classes** with explicit per-asset solvency, decay, and circuit breakers, making it more robust for a mixed-asset mega-pool.

---

## 7. Gas, Scalability, and Implementation Risk

### 7.1 Orbital/Orbswap Implementation

**Computational Requirements:**

- Quartic solves
- Tick boundary detection
- High-dimensional geometry handling
- Approximate numerics with careful error bounds
- Edge-case handling

**EVM Challenges:**

Implementation must rely on approximate numerics, which is both **gas-intensive and security-sensitive**.[^1]

Orbswap's polar coordinate implementation and superellipse evaluation add:
- Trigonometric operations (`sin`, `cos`)
- Square roots (`sqrt`)
- Logarithmic functions

All of which are **heavy on-chain**; Rust examples illustrate computational complexity beyond typical AMM arithmetic.[^2][^4]

**Scalability in N:**

Good **per evaluation** (because invariants use aggregate sums), but tick configuration space grows dramatically if you want rich per-asset heterogeneity, which the basic symmetric designs do not target.[^1][^3]

**Mitigation (Orbswap):**

Plans to leverage **Arbitrum Stylus** to execute calculations in Rust, accessing advanced math libraries unsuitable for Solidity. This may reduce costs but adds deployment complexity and limits to Stylus-compatible chains.[^3]

### 7.2 BAMM Implementation

**Computational Requirements:**

- Fixed-length piecewise segments
- Makima interpolation (cubic polynomials)
- Elementary arithmetic only (+, ×, ÷)
- Bounded segment traversal (≤ 16 segments typically)

**Gas Characteristics:**

- Swaps traverse at most a bounded number of segments with elementary arithmetic
- Gas cost is **predictable and easy to optimize** (e.g., via `uint256` arithmetic and caching)
- Unified volatility system decodes oracle bundle **once per asset** and reuses derived values for both breadth and fees, saving several hundred gas per asset per swap
- Tri-factor fees add only **~1–2k gas per leg**[^9]

**Scalability in N:**

Adding assets is **linear in N**:

- Each new asset adds one Makima curve and its ALM state
- Routing and pricing remain **O(segments)** per leg
- **No explosion in geometric complexity** with dimension[^9]

**Auditability:**

BAMM's math (Makima curves, coverage, linear fee ramps) is **far easier** to reason about and verify than high-dimensional toroidal invariants or polar mappings, which **reduces bug risk** and speeds up iteration.[^5][^6]

### 7.3 Implementation Comparison Summary

| Aspect | Orbital | Orbswap | BAMM |
|--------|---------|---------|------|
| **Math Complexity** | Quartic solves, tick boundaries | Trigonometric + superelliptic center curve | Piecewise cubics (Makima) |
| **Gas Cost** | High | Very High on EVM, Medium-High on Stylus | Low-Medium |
| **Precision Requirements** | High (multi-step error propagation) | High (transcendental approximations) | Medium (segment arithmetic) |
| **Audit Complexity** | Medium-High (geometric edge cases) | Medium-High (trigonometry + polar transforms) | Low-Medium (simple arithmetic) |
| **Scalability** | O(1) per eval, config space grows | O(1) per eval, config space grows | O(n_segments) per leg, linear in N |
| **Chain Compatibility** | EVM (with approximations) | Stylus practically required | Standard EVM |

---

## 8. Summary of Factual Pros/Cons

### 8.1 Orbital/Orbswap

**Pros:**

✅ Single, elegant N-dimensional invariant gives strong global price consistency and full capital sharing across all pairs
✅ Explicit geometric derivations of capital efficiency under tick choices and depeg bounds (15×–150×), especially in homogeneous stablecoin baskets
✅ One-hop trades A↔B with no explicit routing or double fee logic
✅ Analytically beautiful mathematical framework

**Cons:**

❌ High mathematical and implementation complexity (quartic solves, tick segmentation, trigonometric transforms, high-dimensional geometry)
❌ No native ALM: no per-asset liabilities, coverage ratios, or built-in decay/circuit breaker mechanisms
❌ Fragility if many assets depeg or are highly fat-tailed; risk of correlated shocks in a tightly coupled global invariant
❌ Less suited to heterogeneous assets (stables + majors + alts) where you want strongly different liquidity and risk profiles per token
❌ Gas-intensive (especially Orbswap's trigonometric operations)
❌ Higher audit and security risk due to complexity

### 8.2 BAMM Makima + ALM (with Latest Fixes)

**Pros:**

✅ Per-asset Makima curves enable highly flexible, asymmetric liquidity shaping tailored to each token's realized volatility and price density vs the numéraire
✅ Wombat-style coverage-ratio ALM with per-asset liabilities, coverage, decay, and circuit breakers gives explicit, explainable solvency and bad-debt management across all asset types
✅ Tri-factor fees with coverage-only inventory, volatility shock, and price divergence provide a clean risk-based fee model, now aggregated via geometric mean and split 50/50 across legs to avoid negative bias
✅ Virtual numéraire depth and no base state changes in triangulated swaps eliminate path dependence and double fees while preserving simple two-leg implementation, making A↔B effectively single-hop economically
✅ Architecture is compatible with mixing stables, majors, and volatile alts in a single pool without isolation, while still containing risk via per-asset ALM and circuit breakers
✅ Math and code are comparatively simple (piecewise polynomials, linear ramps), making the system more auditable, gas-efficient, and explainable
✅ Linear scalability in N (adding assets doesn't increase geometric complexity)
✅ Standard EVM compatibility (no Stylus required)

**Cons / Trade-offs:**

⚠️ No single closed-form N-dimensional invariant; cross-asset price relationships are mediated by oracles and composition via the numéraire, so global geometric optimality is not guaranteed—consistency depends on oracle accuracy
⚠️ Capital sharing is approximated via virtual depth rather than enforced by an invariant; in edge cases effectiveness depends on the `effectiveDepth()` heuristic and segment configurations, not on a provably optimal global surface
⚠️ Capital-efficiency analysis is more empirical and configuration-dependent (based on Makima anchor choices and segment tuning) rather than derived from closed-form geometric ratios like Orbital's tick-based 15×–150× calculations; local slippage formulas can be derived from segment definitions, but overall efficiency requires empirical validation
⚠️ Less mathematically "elegant" than a single global invariant (though this also makes it more practical and flexible)

---

## 9. Conclusion

After the path-dependence and fee fixes, **BAMM's Makima+ALM hub-and-spoke design is not just viable but highly competitive** with Orbital/Orbswap:

### When Orbital/Orbswap Excels:

- **Homogeneous stablecoin pools** where all assets have similar risk profiles
- Use cases requiring **provable geometric capital efficiency** bounds
- Scenarios where **single-asset depeg protection** is paramount
- Protocols willing to invest in **complex mathematical implementation** and potentially require Stylus for gas optimization

### When BAMM Excels:

- **Heterogeneous pools** mixing stables, majors, and volatile alts
- Protocols requiring **explicit ALM** with coverage ratios, liability decay, and bad-debt resolution
- Use cases needing **per-asset risk management** (circuit breakers, asymmetric liquidity profiles)
- Development teams prioritizing **auditability, gas efficiency, and implementation simplicity**
- Scenarios where **oracle-mediated pricing** and **flexible fee models** are preferred over geometric constraints
- Chains where **standard EVM** is required (no Stylus)

### Overall Assessment:

BAMM trades some **global geometric elegance** for:

- **Per-asset configurability**
- **Explicit ALM**
- **Much more practical, explainable, and extensible architecture**

This trade-off is especially favorable in the **"single mega-pool with all asset classes"** regime that Orbital and Orbswap only partially address.

Both architectures represent significant advances in AMM design, but they target fundamentally different use cases and make different engineering trade-offs. The choice between them depends on pool composition, risk management requirements, implementation constraints, and architectural philosophy.

---

## References

[^1]: Paradigm (2025). "Orbital." https://www.paradigm.xyz/2025/06/orbital

[^2]: Tolstikov, V., Wentz, M., Schiarizzi, J., & Ding, D. (2025). "Concentrated N-dimensional AMM with Polar Coordinates in Rust." arXiv:2510.05428. https://arxiv.org/abs/2510.05428

[^3]: Orbswap (2025). "Orbital AMM Lite-paper." https://orbswap.org/lite-paper

[^4]: Tolstikov et al. (2025). arXiv:2510.05428, PDF version. https://arxiv.org/pdf/2510.05428

[^5]: BAMM Internal Documentation. "Makima Liquidity Shaping." (Project specs)

[^6]: BAMM Internal Documentation. "LibMakimaPricing Implementation." (Project source)

[^7]: Wombat Exchange (2023). "Coverage Ratio Concepts." https://docs.wombat.exchange/concepts/coverage-ratio

[^8]: Wombat Exchange (2023). "Volatile Pool AMM Whitepaper." https://www.wombat.exchange/Wombat_Whitepaper_VolatilePoolAMM.pdf

[^9]: BAMM Internal Documentation. "Tri-Factor Fee Model and Virtual Numéraire Architecture." (Project specs)

---

**Document Metadata:**

- **Author:** Technical Analysis / AI-Assisted Research
- **Review Status:** Draft for internal review
- **Next Steps:** Validate mathematical claims, run comparative simulations, gather community feedback
- **Related Specs:** `ARCHITECTURE.md`, `FEES.md`, `ALM_AND_COVERAGE.md`, `ORACLE.md`
