# AMM Simulator Architecture

High-performance AMM comparison framework written in Zig for capital efficiency and toxic flow analysis.

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
