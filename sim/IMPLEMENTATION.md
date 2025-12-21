# AMM Implementation Guide

Detailed implementation specifications for all 13 AMMs in the simulator.

## Implementation Checklist

| AMM | Type | Status | File |
|-----|------|--------|------|
| Uniswap V2 | 2-asset CPMM | ✅ Done | `uniswap_v2.zig` |
| Uniswap V3 | 2-asset CLMM | ⏳ TODO | `uniswap_v3.zig` |
| Uniswap V4 | 2-asset CLMM + hooks | ⏳ TODO | `uniswap_v4.zig` |
| Balancer Stable | N-asset StableSwap | ⏳ TODO | `balancer_stable.zig` |
| Balancer Weighted | N-asset Weighted | ⏳ TODO | `balancer_weighted.zig` |
| Balancer reCLAMM | 2-asset CLMM | ⏳ TODO | `balancer_reclamm.zig` |
| Curve StableSwap NG | N-asset StableSwap | ⏳ TODO | `curve_stableswap.zig` |
| Curve CryptoSwap | N-asset Crypto | ⏳ TODO | `curve_cryptoswap.zig` |
| Curve FxSwap | N-asset FX | ⏳ TODO | `curve_fxswap.zig` |
| Gyroscope 2-CLP/3-CLP | 2/3-asset CLP | ⏳ TODO | `gyroscope.zig` |
| Joe V2 (DLMM) | 2-asset DLMM | ⏳ TODO | `joe_v2.zig` |
| Wombat | N-asset Coverage | ⏳ TODO | `wombat.zig` |
| BTR AIMM | N-asset Adaptive | ⏳ TODO | `aimm.zig` |

---

## 1. Uniswap V2 - CPMM

**Invariant**: `x * y = k`

**Formula**:
```
Δy = y * Δx' / (x + Δx')
where Δx' = Δx * (1 - fee)
```

**Implementation**:
- 2-asset only, hub-spoke topology
- Fixed fee (default 0.3%)
- Pure state-based pricing (no oracle)
- Spot price: `p = y / x`

**Arb sizing**:
```
Optimal Δx where marginal price = external_price:
Δx = (√(x*y*p_ext*(1-f)) - x*p_ext) / (p_ext*(1-f))
```

**Files**: `src/uniswap_v2.zig` ✅

---

## 2. Uniswap V3 - CLMM

**Invariant**: `(x + L/√p_b) * (y + L*√p_a) = L²` (within active range)

**Formula**:
```
Within tick range [p_a, p_b]:
  L = liquidity (constant in range)
  √P = sqrt price

Swap moves √P:
  Δy = L * (√P_new - √P_old)  (when price increases)
  Δx = L * (1/√P_new - 1/√P_old)  (when price decreases)
```

**Implementation**:
- 2-asset, hub-spoke topology
- Static fee tiers (0.01%, 0.05%, 0.3%, 1%)
- Tick-based liquidity distribution
- Concentrated around current price

**Tick math**:
```
price(i) = 1.0001^i
√price(i) = 1.0001^(i/2)
```

**Active range setup**:
- For simulation: concentrate liquidity in ±X% band (e.g., ±10%)
- Calculate tick bounds from price range
- All liquidity in single position for simplicity

**Arb sizing**:
```
Within range: Similar to V2 but with L instead of x*y
```

**Files**: `src/uniswap_v3.zig` ⏳

---

## 3. Uniswap V4 - CLMM + Hooks

**Invariant**: Same as V3

**Implementation**:
- Same as V3 for core math
- Hooks allow dynamic fee adjustment
- For baseline comparison: use V3 with static fee
- For experiments: implement dynamic fee hook

**Hook interface**:
```zig
beforeSwap(params) -> fee_override
afterSwap(result) -> void
```

**Files**: `src/uniswap_v4.zig` ⏳

---

## 4. Balancer Stable - StableSwap

**Invariant**: `A*D^(n-1)*Σ(x_i) + Π(x_i) = A*D^n + (D/n)^n`

where:
- `A` is the amplification coefficient
- `D` is the total deposit value
- `n` is the number of tokens
- `x_i` is the effective balance of token i

**Pricing**:
```
Spot price of i vs j:
p_ij = (∂F/∂x_j) / (∂F/∂x_i)

For 2 assets:
p = (A*D + x_i) / (A*D + x_j) approximately
```

**Implementation**:
- N-asset single pool
- Static fee (configurable, e.g., 0.04%)
- Amplification A tunes flat curve (high A = very flat near peg)
- Iterative solver for D and new balances

**Solving for output**:
```
Given Δx_i, solve for Δx_j:
1. Calculate D from current balances
2. Update x_i' = x_i + Δx_i
3. Solve for x_j' such that F(x_1, ..., x_i', ..., x_j', ...) = D
4. Δx_j = x_j - x_j'
```

**Files**: `src/balancer_stable.zig` ⏳

---

## 5. Balancer Weighted - Constant Mean

**Invariant**: `∏(x_i^w_i) = k`

where:
- `w_i` is the weight of token i (Σ`w_i` = 1)
- `x_i` is the balance of token i

**Pricing**:
```
Spot price of i vs j:
p_ij = (x_j / x_i) * (w_i / w_j)

Swap i→j:
Δx_j = x_j * (1 - (x_i / (x_i + Δx_i))^(w_i/w_j))
```

**Implementation**:
- N-asset single pool
- Static fee
- Weights configurable (e.g., 50/50, 80/20, etc.)
- For equal comparison: equal weights w_i = 1/N

**Files**: `src/balancer_weighted.zig` ⏳

---

## 6. Balancer reCLAMM

**Invariant**: Underlying pool uses weighted/stable math, but with auto-rebalanced virtual reserves

**Implementation**:
- 2-asset concentrated liquidity
- Controller adjusts virtual reserves to keep price in target range
- For simulation: treat as V3-like CLMM with slower rebalancing
- Fee: static

**Files**: `src/balancer_reclamm.zig` ⏳

---

## 7. Curve StableSwap NG

**Invariant**: Similar to Balancer Stable but different formulation

```
A*n^n*Σx_i + D = A*n^n*D + (D^(n+1))/(n^n*Πx_i)
```

**Dynamic Fee**:
```
fee = base_fee * f_multiplier(imbalance)
where imbalance = max_i(x_i) / min_i(x_i)
```

**Implementation**:
- N-asset single pool
- Dynamic fee based on balance ratios
- Iterative solver for D

**Files**: `src/curve_stableswap.zig` ⏳

---

## 8. Curve CryptoSwap

**Invariant**: Transformed coordinates with internal EMA

```
K = Πx_i + K_offset(γ, A, D)

where coordinates are scaled by internal price oracle (EMA)
```

**Dynamic Fee**:
```
fee = fee_mid when near EMA price
fee → fee_out when far from EMA
```

**Implementation**:
- N-asset single pool
- Internal EMA oracle for each pair
- Amplification A and concentration γ
- Dynamic fee based on distance from EMA

**EMA update**:
```
p_ema_new = p_ema_old * (1 - α) + p_spot * α
where α = time-weighted decay
```

**Files**: `src/curve_cryptoswap.zig` ⏳

---

## 9. Curve FxSwap

**Invariant**: Same as CryptoSwap but with FX-specific scaling

**Implementation**:
- Treat as CryptoSwap with different oracle/scale parameters
- For simulation: reuse CryptoSwap code with FX price feeds

**Files**: `src/curve_fxswap.zig` ⏳

---

## 10. Gyroscope CLP

**2-CLP Invariant** (quadratic):
```
(x/α)² + (y/β)² ≤ 1
Truncated to price band [p_low, p_high]
```

**3-CLP Invariant** (cubic):
```
Extension to 3 assets with cubic surface
```

**E-CLP Invariant** (elliptic):
```
Parameters: (α, β, c, s, λ)
Ellipse in transformed space
```

**Implementation**:
- 2-CLP: 2-asset, hub-spoke
- 3-CLP: 3-asset single pool
- Static fee
- Concentrated liquidity within ellipse bounds

**Pricing**:
```
Price = gradient of invariant at current point
Truncated at bounds
```

**Files**: `src/gyroscope.zig` ⏳

---

## 11. Joe V2 - DLMM (Liquidity Book)

**Invariant**: Discrete bins with local CPMM

**Bin structure**:
```
Each bin k has:
  - Constant price P_k = P_0 * (1 + binStep)^k
  - Reserves (x_k, y_k) with local x_k * y_k = L_k
  - Within bin: constant sum approximation
```

**Swap logic**:
```
1. Start at active bin
2. Consume liquidity in bin at price P_k
3. If bin exhausted, move to next bin
4. Continue until amount_in consumed
```

**Dynamic Fee**:
```
fee = base_fee + volatility_fee
volatility_fee = f(bins_crossed, volatility_accumulator)
```

**Implementation**:
- 2-asset, hub-spoke
- Bins stored in HashMap<i32, Bin>
- Active bin tracks current price
- Fee increases with volatility

**Files**: `src/joe_v2.zig` ⏳

---

## 12. Wombat - Coverage Ratio

**Invariant**: Coverage-based pricing

```
`c_i` = `L_i` / `D_i`  (coverage ratio for asset i)

where:
  `L_i` is reserves (liability coverage)
  `D_i` is liabilities (deposits)
```

**Pricing**:
```
For stable pools:
Δx_j = f(c_i, c_j, Δx_i, A)

Slippage increases when c deviates from 1:
- c < 1: under-collateralized, high haircut
- c > 1: over-collateralized, normal fee
```

**Dynamic Fee/Haircut**:
```
fee = base_fee + haircut(c_i, c_j)
haircut = f(min(c_i, c_j))  (higher when under-covered)
```

**Implementation**:
- N-asset single pool
- Oracle-based for volatile pools (external prices)
- Coverage ratio tracking per asset
- Dynamic haircut

**Files**: `src/wombat.zig` ⏳

---

## 13. BTR AIMM - Adaptive Inventory

**Invariant**: Spline-based liquidity distribution

**Per-asset state**:
```
For each asset i:
  - Anchor price p_i (vs base token)
  - Dispersion σ_i (liquidity spread width)
  - Fee bounds [f_min, f_max]
  - Volatility estimate v_i
```

**Pricing**:
```
Price follows spline curve:
p(inventory) = spline(inventory_ratio, anchor, σ, γ, vega, lambda)

Fee adapts to volatility:
f = f_min + (f_max - f_min) * f_multiplier(v, inventory)
```

**Liquidity shaping**:
```
Gamma (γ): Curvature of distribution
Vega: Volatility sensitivity
Lambda: Time decay responsiveness
```

**Implementation**:
- N-asset single pool
- External oracle for anchor prices
- Spline-based pricing
- Volatility-adaptive fees

**Files**: `src/aimm.zig` ⏳

---

## Common Patterns

### Arb Sizing

All AMMs implement:
```zig
pub fn getArbSize(
    token_in: []const u8,
    token_out: []const u8,
    external_price: f64
) AmmError!f64
```

**Approach**:
1. Get current pool price
2. If pool price ≈ external price, return 0
3. Otherwise, binary search or analytical solution for amount_in where:
   - `marginal_price_after_swap = external_price`
   - Equivalently: maximize `amount_out * external_price - amount_in`

**For CPMM** (analytical):
```zig
Δx = (√(x*y*p*(1-f)) - x*p) / (p*(1-f))
```

**For complex invariants** (numerical):
```zig
Binary search Δx in [0, x*0.5]:
  quote = getQuote(Δx)
  marginal_price = Δx / quote.amount_out
  if marginal_price ≈ external_price: return Δx
```

### Multi-Token Routing

**2-asset AMMs** (hub-spoke):
```zig
if (token_in == hub) {
    // Direct: hub → spoke
    return pool[token_out].swap(amount_in, false);
}
if (token_out == hub) {
    // Direct: spoke → hub
    return pool[token_in].swap(amount_in, true);
}
// 2-hop: spoke → hub → spoke
result1 = pool[token_in].swap(amount_in, true);
result2 = pool[token_out].swap(result1.amount_out, false);
return combine(result1, result2);
```

**N-asset AMMs** (single pool):
```zig
// Always direct swap
return pool.swap(token_in, token_out, amount_in);
```

### Testing

Each AMM should have tests for:
1. **Basic swap**: Verify amount_out matches expected from invariant
2. **Price impact**: Larger trades have higher impact
3. **Round trip**: Swap A→B→A returns less than original (fees)
4. **Arb sizing**: getArbSize brings price to external_price
5. **TVL**: Sum of reserves matches expected value

Example:
```zig
test "uniswap_v2_basic_swap" {
    var amm = UniswapV2.init(allocator, "USDC");
    try amm.addPool("WETH", 1000, 2_000_000, 30); // 1000 WETH, 2M USDC, 0.3% fee

    const result = try amm.swap("USDC", "WETH", 10000, 0);
    try testing.expect(result.amount_out > 0);
    try testing.expect(result.amount_out < 10000 / 2000); // Due to slippage + fee
}
```

---

## Build System

Update `build.zig` to compile all AMMs into a library:

```zig
const amm_sources = [_][]const u8{
    "src/types.zig",
    "src/uniswap_v2.zig",
    "src/uniswap_v3.zig",
    // ... all AMMs
};

const lib = b.addStaticLibrary("amm_sim", "src/root.zig");
for (amm_sources) |src| {
    lib.addCSourceFile(src, &[_][]const u8{});
}
```

**Entry point** (`src/root.zig`):
```zig
pub const types = @import("types.zig");
pub const UniswapV2 = @import("uniswap_v2.zig").UniswapV2;
pub const UniswapV3 = @import("uniswap_v3.zig").UniswapV3;
// ... all AMMs
```

---

## Next Steps

1. ✅ Implement Uniswap V2
2. ⏳ Implement remaining 12 AMMs
3. ⏳ Create simulation engine
4. ⏳ Integrate series_factory price feeds
5. ⏳ Build metrics collection
6. ⏳ Generate HTML reports

See `ARCHITECTURE.md` for simulation framework details.
