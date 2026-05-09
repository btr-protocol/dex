# AMM Simulator

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
