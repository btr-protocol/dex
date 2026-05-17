# AMM Simulator

High-performance AMM comparison framework (Zig) for capital efficiency and toxic flow analysis.

This README consolidates 5 prior design docs (Phase 42Z housekeeping): overview/usage, architecture, implementation guide, AIMM formula spec, AIMM implementation verification, AIMM parameter design.

---

## Table of Contents

1. [Overview & Quick Start](#1-overview--quick-start)
2. [Architecture](#2-architecture)
3. [Implementation Guide (per-AMM)](#3-implementation-guide-per-amm)
4. [AIMM Formula Specification](#4-aimm-formula-specification)
5. [AIMM Implementation Verification](#5-aimm-implementation-verification)
6. [AIMM Parameters & Hypothesis Testing](#6-aimm-parameters--hypothesis-testing)

---

# 1. Overview & Quick Start


High-performance AMM comparison framework for capital efficiency and toxic flow analysis.

## Overview

Compare 13 different AMM designs under identical capital allocation (L₀) to measure:
- **Capital Efficiency**: Slippage and price impact per $ of liquidity
- **Fee Revenue**: LP earnings from organic trades
- **LVR (Loss vs Rebalancing)**: LP losses from toxic flow / arbitrage
- **Net APR**: Fee revenue - LVR

## AMMs Included

### 2-Asset (Hub-Spoke Topology)
- **Uniswap V2**: Constant product (xy=k)
- **Uniswap V3**: Concentrated liquidity (CLMM)
- **Uniswap V4**: CLMM + hooks
- **Joe V2**: Discrete liquidity bins (DLMM)
- **Gyroscope 2-CLP**: Elliptic concentrated liquidity

### N-Asset (Single Pool)
- **Balancer Stable**: StableSwap with amplification
- **Balancer Weighted**: Constant mean (∏xᵢʷⁱ=k)
- **Balancer reCLAMM**: Auto-rebalanced CLMM
- **Curve StableSwap NG**: Hybrid constant sum/product
- **Curve CryptoSwap**: EMA-recentered crypto pools
- **Curve FxSwap**: FX-optimized CryptoSwap
- **Wombat**: Coverage ratio-based ALM
- **Gyroscope 3-CLP**: 3-asset elliptic CLP
- **BTR AIMM**: Adaptive inventory with spline pricing

## Quick Start

### 1. Build

```bash
~/.local/zig/zig build
```

Outputs:
- `zig-out/lib/liAIMM_sim.a` - Static library

### 2. Run Simulation

```bash
# Create config (see config.example.yaml)
cp config.example.yaml my_config.yaml

# Edit config with your parameters
vim my_config.yaml

# Run simulation (TODO: CLI implementation)
./zig-out/bin/amm-sim run --config my_config.yaml --output ./results
```

### 3. View Results

```bash
# Open HTML report
open ./results/index.html
```

## Configuration

See `config.example.yaml` for full spec. Key sections:

### Simulation Parameters

```yaml
simulation:
  series_factory:
    start: 2024-01-01T00:00:00Z
    end: 2024-02-01T00:00:00Z
    timeframe: s10  # 10-second candles
    source: binance
    quote: USDT
```

### Liquidity Setup

```yaml
liquidity:
  reserves_usd:
    USDC: 1000000  # $1M per token
    USDT: 1000000
    WBTC: 1000000
    WETH: 1000000
  daily_utilization: 2  # 200% daily turnover
```

**Allocation Logic**:
- **2-asset AMMs**: N-1 pools vs hub, each gets L₀/(N-1)
  - Example: 4 tokens → 3 pools × $1M = $3M total
- **N-asset AMMs**: 1 pool gets L₀ total
  - Example: 4 tokens → 1 pool × $3M

### AMM Configuration

```yaml
amms:
  - name: Uniswap V2 (Multi-CPMM)
    type: uniswap_v2
    pools:
      - tokens: [USDC, WBTC]
        params:
          fee: 0.003  # 0.3%

  - name: BTR V1 (Single-AIMM)
    type: aimm
    pools:
      - tokens: [USDC, USDT, WBTC, WETH]
        params:
          base_token: USDC
          assets:
            USDC:
              min_fee: 0.000005
              max_fee: 0.02
            WBTC:
              min_fee: 0.0002
              max_fee: 0.03
              min_dispersion: 0.0001
              max_dispersion: 0.3
              gamma: 2
              vega: 0.5
              lambda: 0.1
```

### Trader Behavior

```yaml
traders:
  daily_volume: auto  # Calculated from liquidity.daily_utilization
  toxicity:
    base: 0.25  # 25% of volume is toxic flow (arb)
    factor: power_law  # Toxic flow scales with volume²
  weights:  # Trade routing probability
    USDC: 0.5
    WBTC: 0.25
    WETH: 0.5
```

## Architecture

```
┌──────────────────────────────────────────┐
│         Simulation Engine                │
│  • Price feeds (series_factory)          │
│  • Organic trades (random pairs/sizes)   │
│  • Toxic flow (arbitrage)                │
│  • Metrics (fees, LVR, slippage)         │
└──────────────────────────────────────────┘
                   │
                   ▼
┌──────────────────────────────────────────┐
│          AMM Interface                   │
│  • getQuote(token_in, token_out, amt)    │
│  • swap(...)                             │
│  • getSpotPrice(...)                     │
│  • getArbSize(..., external_price)       │
│  • getTvl(...)                           │
└──────────────────────────────────────────┘
         │                        │
    ┌────┴────┐             ┌────┴────┐
    ▼         ▼             ▼         ▼
┌─────────┐ ┌─────────┐ ┌─────────┐ ┌─────────┐
│ Uni V2  │ │ Uni V3  │ │Balancer │ │ AIMM    │
│ (2-pool)│ │ (2-pool)│ │(N-pool) │ │(N-pool) │
└─────────┘ └─────────┘ └─────────┘ └─────────┘
```

## Key Metrics

### Volume & Fees
- **Organic Volume**: User-driven trades following weight distribution
- **Toxic Volume**: Arbitrage to align pool price with external markets
- **Total Fees**: `volume × fee_rate`
- **LP Fees**: `total_fees × (1 - protocol_share)`

### LVR (Loss vs Rebalancing)
- **Definition**: Profit arbitrageurs extract by trading against stale pool prices
- **Calculation**: `Σ(amount_out × external_price - amount_in)` for all arb trades
- **Impact**: Higher volatility → more LVR → lower LP returns

### Capital Efficiency
- **Slippage**: Average price impact per $1000 trade
- **Depth**: Liquidity available within 1% of mid price
- **Utilization**: `volume / TVL` ratio

### LP Returns
- **Gross APR**: `(total_fees / TVL) × 365 / days`
- **Net APR**: `gross_APR - LVR_APR`
- **Comparison**: Which AMM design yields highest net APR?

## Output

### HTML Report (`results/index.html`)

Interactive dashboard with:
- TVL timeline per AMM
- Cumulative fees chart
- LVR comparison
- Net APR ranking
- Volume breakdown (organic vs toxic)
- Slippage distribution

Built with TradingView Lightweight Charts + custom CSS.

### CSV Exports

- `results/tvl.csv`: Timestep, AMM, TVL
- `results/fees.csv`: Timestep, AMM, Fees, Volume
- `results/lvr.csv`: Timestep, AMM, LVR, ArbCount
- `results/trades.csv`: Full trade log with slippage

## Development

### Project Structure

```
sim/
├── src/
│   ├── types.zig           # Common types (SwapResult, etc.)
│   ├── uniswap_v2.zig      # Uniswap V2 implementation
│   ├── uniswap_v3.zig      # Uniswap V3 implementation
│   ├── balancer_stable.zig # Balancer Stable pools
│   ├── curve_cryptoswap.zig# Curve V2 CryptoSwap
│   ├── wombat.zig          # Wombat coverage pools
│   ├── aimm.zig            # BTR AIMM
│   ├── simulator.zig       # Simulation engine
│   └── root.zig            # Public API
├── build.zig               # Build configuration
├── config.example.yaml     # Example config
├── ARCHITECTURE.md         # Design overview
├── IMPLEMENTATION.md       # AMM implementation details
├── CONFIG_SPEC.md          # Configuration format
└── README.md               # This file
```

### Adding a New AMM

1. Create `src/my_amm.zig`:
```zig
const types = @import("types.zig");

pub const MyAmm = struct {
    pub fn getQuote(...) types.QuoteResult { ... }
    pub fn swap(...) types.SwapResult { ... }
    pub fn getSpotPrice(...) f64 { ... }
    pub fn getArbSize(...) f64 { ... }
    pub fn getTvl(...) f64 { ... }
};
```

2. Add to `src/root.zig`:
```zig
pub const MyAmm = @import("my_amm.zig").MyAmm;
```

3. Add tests in `src/my_amm.zig`:
```zig
test "my_amm_basic_swap" {
    var amm = MyAmm.init(...);
    const result = try amm.swap(...);
    try testing.expect(result.amount_out > 0);
}
```

4. Update `IMPLEMENTATION.md` with invariant details

## References

See inline citations in `ARCHITECTURE.md` for:
- Protocol whitepapers
- Invariant derivations
- Fee mechanics
- Oracle designs

## Status

**Current**: Uniswap V2 implemented, 12 AMMs remaining

**Next**:
1. Complete all 13 AMM implementations
2. Build simulation engine
3. Integrate series_factory
4. Generate HTML reports

See `IMPLEMENTATION.md` for detailed checklist.

## Related

- **Contracts**: `~/Work/btr/dex/evm` - BTR AIMM Solidity implementation
- **Frontend**: `~/Work/btr/dex/front` - Web interface
- **Research**: `~/Work/btr/research` - Series factory data pipeline
- **SDK**: `~/Work/btr/dex/sdk` - TypeScript SDK

## License

Private - BTR internal use only.

---

# 2. Architecture


High-performance AMM comparison framework written in Zig for capital efficiency and toxic flow analysis.

> **Status:** This document describes the *target* architecture. Currently implemented in `sim/src/`: `types.zig` (core interfaces) + `uniswap_v2.zig`. All other AMMs (Uniswap V3/V4, Joe V2, Gyro, Balancer, Curve, Wombat, BTR AIMM) are **roadmap** — design pinned here but not yet coded. See the "Implementation Status" section below for the live checklist.

## Design Goals

1. **Fair Comparison**: All AMMs start with identical capital (L₀) and comparable marginal depth
2. **Capital Efficiency**: Measure slippage, price impact, and LVR across different invariant designs
3. **Toxic Flow Analysis**: Simulate arbitrage extraction and measure LP profitability
4. **Multi-Token Support**: Both 2-asset (hub-spoke) and N-asset (single pool) topologies

## Core Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Simulation Engine                         │
│  - Price feed from series_factory                            │
│  - Trader simulation (organic + toxic)                       │
│  - Arbitrage detection and execution                         │
│  - Metrics collection (fees, LVR, slippage)                  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      AMM Interface                           │
│  - getQuote(token_in, token_out, amount_in)                  │
│  - swap(token_in, token_out, amount_in, min_out)             │
│  - getSpotPrice(token_in, token_out)                         │
│  - getArbSize(token_in, token_out, external_price)           │
│  - getTvl(token_prices)                                      │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┴─────────────────────┐
        │                                           │
        ▼                                           ▼
┌──────────────────┐                     ┌──────────────────┐
│  2-Asset AMMs    │                     │  N-Asset AMMs    │
│  (Hub-Spoke)     │                     │  (Single Pool)   │
├──────────────────┤                     ├──────────────────┤
│ • Uniswap V2     │                     │ • Balancer       │
│ • Uniswap V3     │                     │   - Stable       │
│ • Uniswap V4     │                     │   - Weighted     │
│ • Joe V2 (DLMM)  │                     │   - reCLAMM      │
│ • Gyro 2-CLP     │                     │ • Curve V2       │
│                  │                     │   - StableSwap   │
│ Hub-spoke with   │                     │   - CryptoSwap   │
│ N-1 pools vs     │                     │   - FxSwap       │
│ common hub       │                     │ • Wombat         │
│ (e.g., USDC)     │                     │ • Gyro 3-CLP     │
│                  │                     │ • BTR AIMM       │
│ Each pool gets   │                     │                  │
│ L₀/(N-1) value   │                     │ Single pool gets │
│                  │                     │ L₀ total value   │
└──────────────────┘                     └──────────────────┘
```

## Liquidity Allocation Framework

To ensure fair comparison, all AMMs start with identical total capital L₀ but different topologies:

### 2-Asset AMMs (Hub-Spoke Topology)

**Protocol**: Uniswap V2, V3, V4, Joe V2, Gyro 2-CLP

**Setup**:
- Choose hub token H (typically USDC)
- For N tokens total, create N-1 pools: (A₁/H), (A₂/H), ..., (Aₙ₋₁/H)
- Each pool receives: **L₀/(N-1) of total value**
- Within each pool: **50/50 value split** at initial price P₀

**Example** (4 tokens: USDC, USDT, WBTC, WETH with L₀ = $3M):
```
Pool USDT/USDC: $1M = $500k USDT + $500k USDC
Pool WBTC/USDC: $1M = $500k WBTC + $500k USDC
Pool WETH/USDC: $1M = $500k WETH + $500k USDC
```

**Routing**:
- Direct pairs (X/USDC): Single hop
- Cross pairs (WBTC/WETH): Two hops via hub (WBTC→USDC→WETH)
- Fee paid twice on 2-hop routes

### N-Asset AMMs (Single Pool)

**Protocol**: Balancer (Stable/Weighted/reCLAMM), Curve (StableSwap/CryptoSwap/FxSwap), Wombat, Gyro 3-CLP, BTR AIMM

**Setup**:
- Single pool with all N tokens
- Total capital: **L₀**
- Per-token allocation:
  - **Equal weights**: L₀/N per token
  - **Custom weights**: L₀ · wᵢ per token i
- Tune amplification/range parameters to match hub-spoke marginal depth at P₀

**Example** (4 tokens with L₀ = $3M, equal weights):
```
Single Pool {USDC, USDT, WBTC, WETH}:
  USDC: $750k
  USDT: $750k
  WBTC: $750k
  WETH: $750k
```

**Routing**:
- All pairs: Direct swap (single hop)
- Fee paid once
- Better capital efficiency for multi-hop trades

### Amplification Tuning

For fair comparison, N-asset pools must be tuned so that **small-trade slippage around P₀ matches the hub-spoke baseline**:

**StableSwap/Wombat**:
- Adjust amplification factor A
- Target: `slippage_stable(ΔV) ≈ slippage_cpmm_star(ΔV)` for small ΔV

**CryptoSwap**:
- Adjust A (amplification) and γ (concentration)
- Ensure liquidity concentrated near EMA price matches CPMM depth

**Balancer Weighted**:
- Weights wᵢ should match hub-edge capital ratios
- `w_USDC = (N-1)/N`, `w_other = 1/N` to replicate star topology

**BTR AIMM**:
- Set dispersion bounds to achieve similar effective range as CLMM
- Tune gamma/vega/lambda for comparable depth near anchor

## AMM Classification

### By Invariant Type

| Type | Description | Examples |
|------|-------------|----------|
| **CPMM** | Constant Product (xy = k) | Uniswap V2 |
| **CLMM** | Concentrated Liquidity (piecewise CPMM) | Uniswap V3/V4, Gyro CLP |
| **DLMM** | Discrete Liquidity (binned CPMM) | Joe V2 |
| **Hybrid CFMM** | StableSwap (A → ∞: constant sum, A → 0: CPMM) | Curve StableSwap, Balancer Stable |
| **Weighted CFMM** | Constant mean (∏xᵢʷⁱ = k) | Balancer Weighted |
| **Crypto CFMM** | Transformed hybrid with internal EMA | Curve CryptoSwap, FxSwap |
| **Coverage CFMM** | Balance-sheet based (reserves/liabilities) | Wombat |
| **Adaptive CFMM** | Spline-based with volatility adjustment | BTR AIMM |

### By Fee Dynamics

| Type | Examples |
|------|----------|
| **Static Fee** | Uniswap V2/V3/V4, Balancer Weighted, Gyro 2-CLP, Joe V2 (base) |
| **Dynamic Fee** | Curve V2 (all), Joe V2 (volatility component), Wombat (haircut), BTR AIMM |

### By Price Setting

| Type | Examples |
|------|----------|
| **Pure State** | Uniswap V2/V3/V4, Balancer, Joe V2, Gyro |
| **Internal Oracle** | Curve CryptoSwap (EMA), Balancer reCLAMM |
| **External Oracle** | Wombat (volatile pools), BTR AIMM (anchor prices) |

## Simulation Workflow

### 1. Initialization

```zig
// Load config
const config = parseConfig("config.yaml");

// Initialize AMMs with fair capital allocation
for (config.amms) |amm_config| {
    const amm = createAmm(amm_config, L0, N_tokens);
    // 2-asset: N-1 pools with L0/(N-1) each
    // N-asset: 1 pool with L0 total
}

// Load price series from series_factory
const prices = loadPriceSeries(config.series_factory);
```

### 2. Time Loop

For each timestep t:

```zig
// 1. Update external prices
for (prices[t]) |price_update| {
    external_prices.put(token, price_update.price);
}

// 2. Execute organic trades (random pairs, amounts)
const organic_volume = daily_volume * (1 - toxicity_base);
for (0..n_organic_trades) {
    const pair = randomWeightedPair(trader_weights);
    const amount = sampleTradeSize(organic_volume);
    const result = amm.swap(pair.token_in, pair.token_out, amount, 0);
    metrics.record(result);
}

// 3. Execute toxic flow (arbitrage)
for (each token pair) {
    const pool_price = amm.getSpotPrice(token_in, token_out);
    const external_price = external_prices.get(token_out) / external_prices.get(token_in);

    if (abs(pool_price - external_price) / external_price > arb_threshold) {
        const arb_size = amm.getArbSize(token_in, token_out, external_price);
        if (arb_size > 0) {
            const result = amm.swap(token_in, token_out, arb_size, 0);
            metrics.recordArb(result, external_price);
        }
    }
}

// 4. Record state
metrics.recordState(t, amm.getTvl(), amm.getAllPrices());
```

### 3. Metrics Collection

Track per-AMM:
- **Volume**: Total swap volume (organic + toxic)
- **Fees**: LP fees earned, protocol fees
- **LVR**: Loss-versus-rebalancing (toxic flow PnL)
- **Slippage**: Average price impact per trade
- **Utilization**: Volume / TVL ratio
- **APR**: Annualized LP returns (fees - LVR)

## Key Interfaces

Every AMM must implement:

```zig
pub const AmmInterface = struct {
    // Get quote without state change
    getQuoteFn: fn(token_in, token_out, amount_in) QuoteResult,

    // Execute swap (mutates state)
    swapFn: fn(token_in, token_out, amount_in, min_out) SwapResult,

    // Current spot price
    getSpotPriceFn: fn(token_in, token_out) f64,

    // Optimal arb size to match external price
    // Solves: max(amount_out * external_price - amount_in)
    getArbSizeFn: fn(token_in, token_out, external_price) f64,

    // Total value locked
    getTvlFn: fn(token_prices) f64,
};
```

## Output

### HTML Report

Generate interactive report with TradingView Lightweight Charts:

- **TVL Comparison**: Line chart of TVL over time per AMM
- **Fee Revenue**: Stacked area chart of cumulative fees
- **LVR**: Line chart of cumulative LVR per AMM
- **APR**: Bar chart of annualized returns
- **Volume**: Histogram of daily volume by AMM
- **Price Impact**: Box plot of slippage distribution

### CSV Exports

- `tvl.csv`: Timestep, AMM, TVL
- `fees.csv`: Timestep, AMM, Fees, Volume
- `lvr.csv`: Timestep, AMM, LVR, ArbCount
- `trades.csv`: Timestep, AMM, Pair, AmountIn, AmountOut, Fee, PriceImpact

## Implementation Status

- ✅ Core types and interfaces
- 🚧 AMM implementations (Uniswap V2 done, 11 remaining)
- ⏳ Simulation engine
- ⏳ Series factory integration
- ⏳ Metrics collection
- ⏳ HTML report generation

See `IMPLEMENTATION.md` for AMM-specific details.

---

# 3. Implementation Guide (per-AMM)


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

---

# 4. AIMM Formula Specification


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
- **LINEAR in progress** -smooth, predictable
- **Gamma as multiplier** -controls steepness
- **No double-penalty** -single scaling factor

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


---

# 5. AIMM Implementation Verification


## Overview
This document verifies that the AIMM simulator implementation will match the production Solidity code exactly, focusing on the critical math components: TWAP/EMA accumulators, volatility calculation, spline traversal, and asymmetric spread calculation.

**Test Case Specification:**
- Flat spline (2 points only): weights=[100, 100], endOffsets=[-50, 50]
- Neutral parameters: gamma=1.0x, vega=1.0x, lambda=1.0x
- TWAP: 2-hour fast, 12-hour slow exponential moving average
- Focus: Verify pricing math matches LibPricing.sol exactly

---

## 1. Oracle Data Structure (IOracleV1.FeedData)

**Solidity Definition** (`evm/src/interfaces/IOracle.sol`):
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


---

# 6. AIMM Parameters & Hypothesis Testing


## Overview

This document explains the AIMM (Adaptive Inventory Market Making) configuration used for the ETH/USDC comparison test, including the mathematical foundations and market rationale for each parameter choice.

## Executive Summary

**Baseline Test Results (30 days, 80% annual volatility):**
- V2 Return: -4.04% (vs -4.23% Buy & Hold)
- Price Movement: +23.8% ($1775 → $2250)
- Fee Earnings: $14 from $9,626 volume
- Realized Volatility: 78.8% annualized

**AIMM Hypothesis:** Dynamic fee structure + inventory balancing should achieve:
- **H1**: Tighter spreads (0.01%) vs V2 (0.30%) during calm periods
- **H2**: Volatility-adaptive spreads (0.1% - 5.0% range)
- **H3**: Better LP returns through improved capital allocation
- **H4**: Self-stabilizing through coverage-aware pricing

---

## Parameter Definitions & Rationale

### 1. Gamma (Inventory Sensitivity) = 1.2x

**Formula:**
```
psi = "sign" times 100 times pi^(gamma/M)

pi = |c - c_t| / |c_b - c_t|
```

```
WHERE
psi is the inventory skew
pi is the progress toward boundary
c is the coverage ratio
c_t is the target coverage (1.0)
c_b is the critical boundary (0.5 or 2.0)
gamma is the gamma sensitivity
M is the MULT_BASE (10000)
"sign" is +1 if c < c_t, else -1
```

**What It Does:**
- Controls how aggressively pricing responds to coverage imbalance
- At coverage = 75% (under-collateralized):
  - With gamma=1.0x: skew ≈ +50 bps
  - With gamma=1.2x: skew ≈ +35 bps (slightly less aggressive)
- Creates natural economic incentive to rebalance

**Why 1.2x for ETH/USDC:**
- 80% annual volatility requires responsive inventory management
- 1.2x is moderate (between default 1.0x and aggressive 1.5x)
- At 50% coverage: creates ±100 bps skew (maximum penalty/premium)
- Smooth transition - doesn't create sharp discontinuities

**Market Intuition:**
```
Coverage Ratio    Gamma Effect           Economic Signal
50% (critical)    ±100 bps (max)        "CRITICAL: Deposits only"
60%               ±81 bps               "STRESSED: Premium for sells"
75%               ±35 bps               "UNDER-COLLATERALIZED: Modest premium"
100% (target)     0 bps (equilibrium)   "BALANCED: Neutral pricing"
150%              -35 bps               "OVER-COLLATERALIZED: Modest discount"
200% (critical)   -100 bps (max)        "BLOATED: Sales only"
```

---

### 2. Vega (Volatility Sensitivity) = 1.2x

**Formula:**
```
kappa = kappa_0 + (sigma times nu) / (1000 times M)
```

```
WHERE
kappa is the dispersion (basis points)
kappa_0 is the base dispersion (1000 = 0.1%)
sigma is the volatility
nu is the vega sensitivity
M is the MULT_BASE (10000)
```

Examples at 5% daily volatility (≈80% annual):
- vega=0.5x:  dispersion = 1250 bps (12.5% range)
- vega=1.0x:  dispersion = 1500 bps (15% range)
- vega=1.2x:  dispersion = 1750 bps (17.5% range)
- vega=1.5x:  dispersion = 1875 bps (18.75% range)
```

**What It Does:**
- Expands/contracts liquidity distribution width based on volatility
- Low vega → narrow spreads even when volatile (capital efficient but risky)
- High vega → wide spreads (capital inefficient but safe)
- Inverse relationship: higher dispersion = lower density (fewer liquidity providers per price level)

**Why 1.2x for ETH/USDC:**
- Realized volatility: 78.8% annualized
- Daily swings: 2-5% are common
- 1.2x vega creates ~1750 bps dispersion (17.5% range)
- This is about 35-50x wider than V2's 0.30% fee range
- Protects capital during volatile moves while remaining capital efficient

**Comparison:**
```
Volatility Regime    Dispersion Effect
Low (<2% daily)      1000-1200 bps (dense liquidity)
Medium (3-5%)        1500-1750 bps (normal distribution)
High (>8%)           Up to maxDispersion 5000 bps (sparse)
Flash crash          maxDispersion caps at 5000 bps (emergency mode)
```

---

### 3. Lambda (Deviation Sensitivity) = 1.2x

**Formula:**
```
U = (Δ × λ) / M

S = S_v + U           (if trade worsens coverage)
S = S_v               (if trade improves coverage)
```

where:
- U = deviation surcharge
- Δ = deviation (|o_f - o_s|)
- λ = lambda sensitivity
- M = MULT_BASE (10000)
- S_v = volatility-based spread
- S = final spread

**What It Does:**
- Penalizes trades that occur during trending/uncertain markets
- Trending = fast and slow price EMAs diverge
- This protects LP capital during directional moves when volatility spikes

**Why 1.2x for ETH/USDC:**
- 80% volatility means trending markets are common
- Trending markets = "bad" fills for LPs (selling high momentum assets)
- 1.2x lambda creates noticeable surcharge when Δ > 100 bps
- Example:
  - At Δ = 100 bps: surcharge = 1.2 × 100 / 10000 = 0.012% = 1.2 bps
  - At Δ = 500 bps: surcharge = 1.2 × 500 / 10000 = 0.060% = 6 bps
- Discourages "toxic" fills without being prohibitively expensive

**Economic Intuition:**
```
Fast EMA = Slow EMA    (Δ = 0)
    ↓
Price is stable/mean-reverting
    ↓
LP wants to trade at base spread S_vol

Fast EMA >> Slow EMA   (Δ = large)
    ↓
Price is trending up (bearish for LP)
    ↓
LP adds surcharge: S_vol + surcharge
    ↓
Discourages selling at bad time
```

---

### 4. Haircut Suppressor = 1.0x (Quadratic)

**Formula:**
```
p = 1 + (η / M)

h = (1 - c)^p
```

where:
- p = haircut exponent
- η = suppression parameter (MULT_BASE = 10000)
- h = haircut ratio
- c = coverage ratio
- M = MULT_BASE (10000)

Examples at different coverage levels:
Coverage    p=1.0 (linear)    p=2.0 (quadratic)    p=4.0 (convex)
50%         50% haircut       25% haircut         6.25% haircut
75%         25% haircut       6.25% haircut       0.39% haircut
90%         10% haircut       1% haircut          0.01% haircut
```

**What It Does:**
- Penalties on withdrawals when coverage < 100%
- Protects pool from bank runs
- Lower coverage = higher penalty

**Why 1.0x (Quadratic) for ETH/USDC:**
- Standard choice balances protection with usability
- At 75% coverage: 6.25% penalty (meaningful but not crushing)
- At 50% coverage: 25% penalty (strong protection)
- Quadratic is less harsh than cubic, more harsh than linear

**Comparison:**
```
Suppressor     Curve Shape     At 50% coverage    At 75% coverage
0 (linear)     y = 1-c         50% penalty        25% penalty
10000 (quad)   y = (1-c)²      25% penalty        6.25% penalty
30000 (convex) y = (1-c)⁴      6.25% penalty      0.39% penalty
```

---

### 5. Dispersion Bounds = 0.1% - 5.0%

**Formula:**
```
κ = clamp(κ₀ + (σ × ν) / (1000 × M), κ_min, κ_max)
```

where:
- κ = dispersion (clamped)
- κ₀ = base dispersion (1000)
- σ = volatility
- ν = vega sensitivity
- M = MULT_BASE (10000)
- κ_min, κ_max = dispersion bounds

**What They Do:**
- `minDispersion`: Minimum liquidity spread when volatility is very low
- `maxDispersion`: Maximum liquidity spread (emergency cap)

**Why 0.1% - 5.0% for ETH/USDC:**

| Dispersion | Liquidity Density | Best For | Example Volatility |
|---|---|---|---|
| 0.1% (min) | Very dense | Stablecoins, low vol | < 1% daily |
| 0.5% | Dense | Blue chips, normal times | 2-3% daily |
| 2.0% | Moderate | ETH, normal vol | 4-6% daily |
| 5.0% (max) | Sparse | Crashes, flash events | > 8% daily |

**Capital Efficiency:**
```
Dispersion → Price Range → Liquidity Density

0.1% (±0.05%):     Price range = $1999 - $2001 → extremely dense
5.0% (±2.5%):      Price range = $1950 - $2050 → sparse

At $10k capital:
  - 0.1% dispersion: Can handle ~$5M volume before 50% slippage
  - 5.0% dispersion: Can handle ~$50M volume before 50% slippage
```

---

### 6. Fee Bounds = 0.01% - 1.0%

**Formula:**
```
S = clamp(S_base + S_v + U, f_min, f_max)
```

where:
- S = final spread
- S_base = base spread component
- S_v = volatility surcharge
- U = deviation surcharge
- f_min, f_max = fee bounds

**What They Do:**
- `minFeeBps`: Minimum fee even in calmest markets
- `maxFeeBps`: Maximum fee cap during most extreme volatility/uncertainty

**Why 0.01% - 1.0% for ETH/USDC:**
- V2: Fixed 0.30% fee
- AIMM: Can go as low as 0.01% (30x tighter) in calm periods
- AIMM: Can go as high as 1.0% (3.3x wider) in stressed conditions

**Comparison with V2:**
```
Market Condition           V2 Fee    AIMM Fee      AIMM Advantage
Stable markets            0.30%     0.01%         30x tighter spreads
Normal volatility         0.30%     0.10-0.20%    2-3x tighter
High volatility           0.30%     0.40-0.70%    Less exposure to crashes
Flash crash               0.30%     1.0%          Maximum protection
```

**Fee Asymmetry (Coverage-Aware):**
```
Direction of Trade    Coverage Impact     Fee Adjustment
Buy ETH (sell USDC)   Increases USDC      Arb path: -50% discount
Sell ETH (buy USDC)   Decreases USDC      Arb path: -50% discount
Deplete USDC          Worsens coverage    Toxic path: +5 bps surcharge
Flood with USDC       Improves coverage   Arb path: -50% discount
```

---

### 7. Coverage Floor = 50%

**What It Is:**
- The critical undercollateralization threshold
- At coverage = 50%, the pool is severely stressed
- Maximum inventory skew is applied (±100 bps)

**Why 50% for ETH/USDC:**
- Below 50%: Pool is insolvent (liabilities > 2× reserves)
- At 50%: Pool enters critical zone (strong discounts/premiums)
- Common standard for decentralized finance (Aave, Compound also use 50%)
- Provides operational runway while maintaining safety margin

---

### 8. Depth Amplifier = 33%

**Formula:**
```
D = R + k × (L - R) × π^e

k = a / A
```

where:
- D = effective depth
- R = reserves
- L = liabilities
- k = normalized depth amplifier
- a = depthAmplifier parameter
- A = amplitude scale (1,000,000)
- π = progress from floor to target
- e = exponent (concave curve, e ∈ (0, 1))

At 75% coverage with k=0.33:
- D = R + 0.33 × 0.25L × progress_curve ≈ R + 8% virtual liquidity

**What It Does:**
- Adds virtual liquidity when coverage is low
- Helps market-making during undercollateralization
- "Concave" curve = slower virtual depth increase as coverage improves

**Why 33% for ETH/USDC:**
- Moderate amplification (not too aggressive)
- At 75% coverage: adds ~8% virtual depth
- At 50% coverage: converges to reserves (all amplification disabled)
- Protects during stress without overcommitting capital

**Comparison:**
```
Depth Amplifier    Virtual Depth at 75% Coverage    Use Case
0%                 0% (depth = reserves)            Capital efficient
33%                ~8% virtual depth               Moderate protection
67%                ~16% virtual depth              Strong protection
100%               ~25% virtual depth              Maximum protection
```

---

### 9. Coverage-Based Risk Configuration

**Decay Configuration:**
- `decayStartRatioBps`: 98% - Start automatic deleveraging when < 98%
- `decaySlope`: 0 (disabled) - No automatic decay for now

**Risk Flags:**
- `0x07` = Swaps + Flash Loans + Liability Swaps enabled

---

### 10. Fee Split = 80% to LPs / 20% Protocol

**Why 80/20:**
- Attractive to LPs (better than typical 100% for single-asset LPs)
- Sustainable for protocol (20% covers gas, infrastructure, governance)
- Standard in modern AMMs (Uniswap V4 uses this split)

**Flash Loan Fee:** 0.09% - Attracts arbitrage capital for rebalancing

---

## Hypothesis Testing Framework

### H1: Tighter Spreads in Calm Markets
**Prediction:** AIMM achieves 0.01% fee vs V2's 0.30% during low-volatility periods
**Test:** Analyze spreads during 24-hour periods with < 1% price movement
**Success Criteria:** AIMM spreads < 0.10% (3x tighter than V2)

### H2: Volatility-Adaptive Spreads
**Prediction:** AIMM dispersion adapts from 0.1% to 5.0% based on volatility
**Test:** Correlate dispersion with realized volatility
**Success Criteria:** R² > 0.7 between volatility and dispersion

### H3: Competitive Returns with Better Risk Management
**Prediction:** AIMM returns ≥ V2 returns while maintaining lower volatility
**Test:** Compare final LP values and Sharpe ratios
**Success Criteria:** AIMM Sharpe ratio > V2 Sharpe ratio

### H4: Self-Stabilizing Inventory Balancing
**Prediction:** Coverage-aware pricing naturally attracts rebalancing trades
**Test:** Track coverage ratio stability over time
**Success Criteria:** AIMM coverage volatility < V2 coverage volatility

---

## Integration Steps

To fully implement AIMM in the simulation:

1. **Create AIMMPoolAdapter** (like V2PoolAdapter, V3PoolAdapter)
   - Implement AIMM pricing engine
   - Track coverage ratio dynamically
   - Calculate inventory skew, dispersion, fees

2. **Add Asset Configuration**
   - Store gamma, vega, lambda per asset
   - Store min/max fees and dispersion
   - Store haircut suppressor

3. **Implement Risk Configuration**
   - Coverage floor tracking
   - Depth amplifier calculation
   - Liability decay (if enabled)

4. **Add Liquidity Profile**
   - Piecewise cubic spline for liquidity distribution
   - Map cumulative depth to price offsets

5. **Integrate Fee Calculation**
   - Base spread from volatility (vega)
   - Asymmetric surcharge from deviation (lambda)
   - Coverage bonus/penalty (gamma)
   - Haircut on withdrawals

---

## Market Common Sense Validation

### Why These Parameters Make Economic Sense:

1. **Gamma = 1.2x**: Creates natural rebalancing incentive
   - Too low (0.5x): Ignores imbalances, pool drifts
   - Too high (2.0x): Creates sharp discontinuities, bad UX
   - **1.2x is "just right"** - responsive but smooth

2. **Vega = 1.2x**: Matches market volatility
   - ETH volatility (80%) is well-studied
   - 1.2x creates reasonable dispersion adaptation
   - Empirically validated in options markets

3. **Lambda = 1.2x**: Protects against adverse selection
   - Trending markets = bad fills for LPs
   - Moderate surcharge (1-6 bps) isn't prohibitive
   - Aligns with observed market microstructure costs

4. **Depth Amplifier = 33%**: Moderate virtual liquidity
   - Too aggressive: Overcommits capital during stress
   - Too conservative: Doesn't help when needed
   - 33% provides "Goldilocks" balance

5. **Haircut = Quadratic**: Protects solvency gracefully
   - Linear too harsh, convex too lenient
   - Quadratic is industry standard (Aave, Compound)
   - 25% at 50% coverage is serious but not catastrophic

---

## Next Steps

1. ✅ Create AIMM parameter definitions (DONE - this document)
2. ⏳ Implement AIMMPoolAdapter in simulation
3. ⏳ Run hypothesis tests
4. ⏳ Compare results with V2 baseline
5. ⏳ Sensitivity analysis (vary gamma, vega, lambda)
6. ⏳ Stress testing (flash crashes, sustained trends)

---

## References

- **Parametrization Docs**: `/docs/1. AIMM/1.2. Pricing/1.2.5. Parametrization.md`
- **Admin Contract**: `/evm/src/modules/Admin.sol` (lines 96-105)
- **Pricing Library**: `/evm/src/libraries/LibPricing.sol` (comprehensive implementation)
- **Test Plots**: `/contracts/test/unit/plots/` (parameter impact visualization)

---

**Last Updated:** 2025-01-11
**Status:** Baseline V2 test complete, ready for AIMM implementation
