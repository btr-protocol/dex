# Keeper + pool launch params (testnet)

## Decision

Keep **hard NXR re-anchor**. Reject trade-offset / mark-smoothing / adaptive θ for launch.

Economic gate: one-sided swap cost ≥ θ (i.e. full `minFee ≥ 2·θ` at σ≈0). Matches `Pricing.sol` (`minFee ≈ 2·θ`).

## Keeper (`oracle.chapel.toml`)

| Class | θ | heartbeat | TTL |
|-------|---|-----------|-----|
| Stable | **0.3 bp** | **1800 s** | 7200 s |
| Volatile | **10 bp** | **300 s** | 600 s |

Do **not** use stable θ=0.1 bp: +29% batched txs on 7d NXR replay.

## Pool floors (`testnet-asset-params.json`)

| Pool | minFee | Why |
|------|--------|-----|
| Stable | **1 bp** (100 PBPS) | Covers 2·θ=0.6 bp with margin; LP/trader equilibrium from stable-core sim |
| Volatile | **20 bp** (2000 PBPS) | Covers 2·θ=20 bp; fee 0.01 bp fails arb gate (LVR APR ~22%) |

## Cadence (order of magnitude)

- Stable θ=0.3 (partial NXR 7d, 3 feeds): ~825 batches/day (vs ~1380 at θ=0.1)
- Volatile θ=10 / hb300 (local 21d×30s, 5 feeds): ~360–430 updates/feed/day, ~1770 batched/day across vol feeds
- Volatile θ=5: ~600–750/feed/day — more gas, only modest LVR help once fee covers θ

## Run keeper

```bash
cd ~/Work/btr/keepers
cargo run -- oracle-daemon --config oracle.chapel.toml --once
KEEPER_EXECUTE=1 cargo run -- oracle-daemon --config oracle.chapel.toml --execute
```
