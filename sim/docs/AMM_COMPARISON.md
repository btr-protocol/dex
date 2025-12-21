# AMM Comparison: Mathematical Framework and Implementation Guide

This document provides a comprehensive comparison of major AMM protocols, serving as the mathematical foundation for our Zig simulation implementations.

## Table of Contents

1. [Overview](#overview)
2. [Invariant Functions](#invariant-functions)
3. [Pricing and Slippage](#pricing-and-slippage)
4. [Fee Mechanics](#fee-mechanics)
5. [Dynamic Fee Mechanisms](#dynamic-fee-mechanisms)
6. [Price Setting](#price-setting)
7. [N-Asset Support](#n-asset-support)
8. [Liquidity Split Framework](#liquidity-split-framework)
9. [Implementation Summary](#implementation-summary)

---

## Overview

All AMMs can be classified as **Constant Function Market Makers (CFMMs)** where some invariant function `f(x, y, ...) = k` is maintained. The key differentiators are:

| Protocol | Type | Core Innovation |
|----------|------|-----------------|
| Uniswap V2 | CPMM | Simple constant product |
| Uniswap V3 | CLMM | Concentrated liquidity in tick ranges |
| Uniswap V4 | CLMM + Hooks | Customizable via hook contracts |
| Curve V1/V2 | StableSwap | Low slippage for correlated assets |
| Balancer V2/V3 | Weighted | Arbitrary token weights |
| Gyroscope E-CLP | Elliptic | Concentrated liquidity on ellipse |
| Trader Joe V2 | DLMM | Discrete bins with constant sum |
| Wombat | ALM | Coverage ratio-based pricing |
| AIMM | Adaptive | Spline-based with inventory skew |

---

## Invariant Functions

### Uniswap V2 (Constant Product)

```
x · y = k
```

Where:
- `x`, `y` = token reserves
- `k` = invariant constant

**Swap output:**
```
Δy = y · Δx / (x + Δx)
```

**Spot price:**
```
P = y / x
```

### Uniswap V3 (Concentrated Liquidity)

Virtual reserves within tick range `[p_a, p_b]`:

```
(x + L/√p_b)(y + L·√p_a) = L²
```

Where:
- `L` = liquidity
- `p` = current price
- Tick spacing: `P = 1.0001^tick`

**Real reserves:**
```
x_real = L · (1/√p - 1/√p_b)
y_real = L · (√p - √p_a)
```

**Swap within tick:**
```
Δ√p = Δy / L  (exact input of y)
Δ√p = Δx · √p² / L  (exact input of x)
```

### Uniswap V4

Same as V3 with programmable hooks:
- `beforeSwap` / `afterSwap`
- `beforeAddLiquidity` / `afterAddLiquidity`
- Dynamic fee adjustment via hooks

### Curve StableSwap

Hybrid invariant combining constant sum and constant product:

```
A·n^n·∑x_i + D = A·D·n^n + D^(n+1) / (n^n·∏x_i)
```

Where:
- `A` = amplification coefficient (higher = flatter curve near balance)
- `n` = number of tokens
- `D` = invariant (total value at balance)
- `x_i` = reserve of token i

**Newton's method for D:**
```
D_{n+1} = (A·n^n·S + D_p·n) · D / ((A·n^n - 1)·D + (n+1)·D_p)

where:
  S = ∑x_i
  D_p = D^(n+1) / (n^n · ∏x_i)
```

**Newton's method for y (swap output):**
```
y_{n+1} = (y² + c) / (2y + b - D)

where:
  c = D^(n+1) / (n^n · A · ∏x_j)  [j ≠ i]
  b = S' + D/(A·n^n)
  S' = ∑x_j  [j ≠ i]
```

### Curve V2 (CryptoSwap)

Adds internal oracle and dynamic A:

```
K·D^(n-1)·∑x_i + ∏x_i = K·D^n + (D/n)^n

where K = A·∏(p_i)·γ² / (γ + 1 - K_0)^2
```

- Uses EMA price oracle for rebalancing
- `gamma` controls curvature transition
- Repegs around oracle price

### Balancer Weighted Pool

Constant mean (weighted geometric mean):

```
∏(B_i^{w_i}) = k

where ∑w_i = 1
```

**Spot price:**
```
P_{i→j} = (B_i / w_i) / (B_j / w_j) = (B_i · w_j) / (B_j · w_i)
```

**Swap output:**
```
Δy = B_out · (1 - (B_in / (B_in + Δx))^{w_in/w_out})
```

### Gyroscope E-CLP (Elliptic Concentrated Liquidity Pool)

Concentrated liquidity on an ellipse:

```
(x/α + y/β)² + (x·sin(θ) + y·cos(θ))²/λ² = r²
```

Where:
- `α`, `β` = semi-axes
- `θ` = rotation angle
- `λ` = concentration parameter
- `r` = radius (liquidity)

**Derived invariant:**
```
(√α·x + √β·y)² / L² = 1 - (x - x_c)²/a² - (y - y_c)²/b²
```

Price bounds: `[p_low, p_high]` define the ellipse shape.

### Trader Joe V2 / Meteora DLMM

Discrete bins with constant sum per bin:

```
x_i + y_i = L_i  (within bin i)
```

**Bin price:**
```
P_i = (1 + binStep/10000)^{(i - 2^{23})}
```

Where:
- `binStep` = basis points (e.g., 25 = 0.25%)
- Bin ID offset = 8,388,608 (2²³)

**Swap mechanics:**
- Constant sum within each bin (zero slippage)
- Slippage only when crossing bins
- Composition fee on bin crossings

### Wombat ALM

Asset-Liability Model with coverage ratios:

```
Coverage: c_i = r_i / l_i
```

Where:
- `r_i` = reserves of token i
- `l_i` = liabilities (LP deposits) of token i

**Haircut on withdrawal:**
```
h = (1 - c)²  when c < 1
h = 0         when c ≥ 1
```

**Slippage based on coverage change:**
```
slippage = A · |c_after - c_before| · (1 + |1 - c_avg|)
```

### AIMM (Adaptive Inventory Market Maker)

Spline-based pricing with inventory skew:

```
Price = P_oracle · (1 + spread/2 · direction + inventory_skew)
```

**Inventory skew (linear):**
```
skew = γ · 100 · (progress - 0.5)

where progress = ∫dx along spline / total_arc_length
```

**Spread model:**
```
spread = base_spread · (1 + λ·dispersion) · (1 + ν·volatility)
```

**Coverage integration:**
```
coverage_factor = min(c_in, c_out) / max(c_in, c_out)
```

---

## Pricing and Slippage

| Protocol | Spot Price | Slippage Source |
|----------|-----------|-----------------|
| Uniswap V2 | `y/x` | Constant product curve |
| Uniswap V3 | `1.0001^tick` | Virtual reserves in range |
| Curve | Complex (Newton) | Flat near balance, steep at edges |
| Balancer | `(B_i·w_j)/(B_j·w_i)` | Weighted power function |
| Gyroscope | Ellipse tangent | Elliptic curve geometry |
| DLMM | `(1+s)^{id-offset}` | Bin crossings only |
| Wombat | `c_out/c_in` | Coverage ratio changes |
| AIMM | Oracle + skew | Spline position + inventory |

### Price Impact Formulas

**Uniswap V2:**
```
impact = Δx / (x + Δx)
```

**Uniswap V3:**
```
impact = (P_after - P_before) / P_before
       = (1.0001^{tick_after} - 1.0001^{tick_before}) / 1.0001^{tick_before}
```

**Curve:**
```
impact ≈ Δx / (A · D)  [near balance]
```

**Balancer:**
```
impact = 1 - (B_in / (B_in + Δx))^{w_in/w_out}
```

---

## Fee Mechanics

| Protocol | Base Fee | Fee Application | LP Share |
|----------|----------|-----------------|----------|
| Uniswap V2 | 30 bps | Input token | 100% to LP |
| Uniswap V3 | 5/30/100 bps | Input token | 100% to LP |
| Uniswap V4 | Configurable | Hook-defined | Hook-defined |
| Curve V1 | 4 bps | Output token | 50% admin |
| Curve V2 | 4-400 bps | Dynamic | 50% admin |
| Balancer V2 | Pool-defined | Input token | Protocol % |
| Balancer V3 | Pool-defined | Dynamic hooks | Configurable |
| Gyroscope | 10-100 bps | Input token | Protocol % |
| DLMM | Bin-specific | Per bin cross | LP in bin |
| Wombat | 1-10 bps | Input token | Protocol % |
| AIMM | Spread-based | Bid/ask spread | Coverage-based |

### Fee Calculation

**Standard (Uniswap V2 style):**
```
fee = amount_in · fee_bps / 10000
amount_in_after_fee = amount_in - fee
```

**Split fee:**
```
lp_fee = fee · (1 - protocol_share)
protocol_fee = fee · protocol_share
```

---

## Dynamic Fee Mechanisms

### Uniswap V4 Hooks

```solidity
function beforeSwap(PoolKey key, SwapParams params)
    returns (bytes4, BeforeSwapDelta, uint24 lpFeeOverride)
```

Fee can be adjusted per-swap based on:
- Volatility
- Time of day
- Order size
- MEV protection

### Curve V2 Dynamic Fees

```
fee = fee_mid · f + fee_out · (1 - f)

where f = reduction_coefficient / (reduction_coefficient + (∏x_i/D^n - 1)²)
```

Fees increase as pool becomes imbalanced.

### Balancer V3 Rate Providers

- External oracles for yield-bearing tokens
- Fee adjustment based on rate changes
- Composable with hooks

### DLMM Variable Fees

```
total_fee = base_fee + variable_fee

variable_fee = bin_step · volatility_accumulator
```

Where volatility accumulator increases with:
- Bin crossing frequency
- Trade size relative to bin liquidity

### AIMM Adaptive Spread

```
spread = σ_base · (1 + λ·D) · (1 + ν·V)

where:
  D = dispersion = sum of absolute spline coefficient changes
  V = volatility = EMA of |price_change| / TWAP
```

---

## Price Setting

| Protocol | Price Source | Update Mechanism |
|----------|-------------|------------------|
| Uniswap V2 | Endogenous | Arbitrage |
| Uniswap V3 | Endogenous | Arbitrage within tick |
| Curve V1 | Endogenous | Arbitrage |
| Curve V2 | EMA Oracle | Exponential moving average |
| Balancer | Endogenous | Arbitrage |
| Gyroscope | External Oracle | Chainlink/custom |
| DLMM | Active bin | LP positioning |
| Wombat | Coverage ratio | Deposit/withdraw flow |
| AIMM | Oracle + TWAP | External oracle with TWAP smoothing |

### Oracle Integration Patterns

**Curve V2 Internal Oracle:**
```
price_oracle = price_oracle_prev · (1 - α) + spot_price · α

where α = 1 - e^{-Δt/T}
```

**AIMM TWAP:**
```
twap_accumulator += price · Δt
twap = (accumulator_now - accumulator_past) / (t_now - t_past)
```

**Gyroscope Oracle:**
```
effective_price = clamp(oracle_price, p_low, p_high)
```

---

## N-Asset Support

| Protocol | Max Assets | Symmetry | Notes |
|----------|-----------|----------|-------|
| Uniswap V2 | 2 | Symmetric | Pair-based |
| Uniswap V3 | 2 | Symmetric | Pair-based |
| Curve | 2-8 | Symmetric | Same decimals preferred |
| Balancer | 2-8 | Asymmetric | Weight-based |
| Gyroscope | 2 | Symmetric | Ellipse is 2D |
| DLMM | 2 | Symmetric | Pair-based |
| Wombat | 2+ | Symmetric | Per-asset coverage |
| AIMM | 2 | Symmetric | Spline is 2D |

### Multi-Asset Routing

For N > 2 assets, routing through intermediate pairs:

```
A → B → C

effective_rate = rate_AB · rate_BC · (1 - fee_AB) · (1 - fee_BC)
```

---

## Liquidity Split Framework

For simulation purposes, we model liquidity across protocols:

### Unified Pool Interface

```zig
pub const AmmPool = union(enum) {
    uniswap_v2: UniswapV2Pool,
    uniswap_v3: UniswapV3Pool,
    curve: CurvePool,
    balancer: BalancerPool,
    dlmm: DLMMPool,
    wombat: WombatPool,
    gyroscope: GyroscopePool,
    aimm: AIMMPool,

    pub fn getQuote(self: *const @This(), token_in: u8, token_out: u8, amount: f64) !QuoteResult;
    pub fn swap(self: *@This(), token_in: u8, token_out: u8, amount: f64, min_out: f64) !SwapResult;
    pub fn getSpotPrice(self: *const @This(), token_in: u8, token_out: u8) !f64;
    pub fn amountToMovePrice(self: *const @This(), token_in: u8, target: f64) !f64;
};
```

### Liquidity Distribution Model

```
Total liquidity L split across N protocols:

L_i = L · w_i  where ∑w_i = 1

For arbitrage simulation:
1. Find price discrepancy: ΔP = P_expensive - P_cheap
2. Calculate arbitrage amount: A = f(ΔP, L_cheap, L_expensive)
3. Execute swap: cheap.swap(A) → expensive.swap(received)
4. Update state and iterate
```

### Price Convergence

```
After arbitrage round r:
P_i^{r+1} = P_i^r + α · (P_target - P_i^r)

Convergence when: max|P_i - P_target| < ε
```

---

## Implementation Summary

### Zig Module Structure

```
sim/src/zig/src/
├── types.zig          # Shared types (QuoteResult, SwapResult, etc.)
├── uniswap_v2.zig     # Constant product
├── uniswap_v3.zig     # Concentrated liquidity
├── curve.zig          # StableSwap with Newton's method
├── balancer.zig       # Weighted pools
├── dlmm.zig           # Discrete bins (Trader Joe V2)
├── wombat.zig         # Asset-liability model
├── gyroscope.zig      # E-CLP (TODO)
├── aimm.zig           # Adaptive inventory (TODO)
├── router.zig         # Multi-pool routing (TODO)
└── config.zig         # Default configurations (TODO)
```

### Key Implementation Notes

1. **Numerical Stability**
   - Use `@log` and `@exp` for power operations where possible
   - Newton's method needs convergence checks and iteration limits
   - Handle edge cases (zero reserves, extreme prices)

2. **Fee Precision**
   - Fees in basis points (1 bps = 0.01%)
   - Split calculation: `fee · share / 10000`
   - Accumulate separately for reporting

3. **Price Impact**
   - Always calculate before and after prices
   - Report as percentage: `|P_after - P_before| / P_before`

4. **Testing**
   - Compare against on-chain results
   - Test edge cases (empty pools, max amounts)
   - Verify invariant preservation after swaps

---

## References

1. Uniswap V2 Whitepaper: https://uniswap.org/whitepaper.pdf
2. Uniswap V3 Whitepaper: https://uniswap.org/whitepaper-v3.pdf
3. Curve StableSwap: https://curve.fi/files/stableswap-paper.pdf
4. Curve V2 (CryptoSwap): https://curve.fi/files/crypto-pools-paper.pdf
5. Balancer Whitepaper: https://balancer.fi/whitepaper.pdf
6. Gyroscope E-CLP: https://docs.gyro.finance/
7. Trader Joe V2: https://docs.traderjoexyz.com/
8. Wombat Exchange: https://docs.wombat.exchange/

---

*Generated for BTR DEX Simulation Framework*
