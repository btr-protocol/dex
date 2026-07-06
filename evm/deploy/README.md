# Deploy & asset params

**Single source of truth:** [`evm/deploy/testnet-asset-params.json`](../evm/deploy/testnet-asset-params.json)

JSON holds per-asset fees, oracle θ/heartbeat/ttl, Hermite spline knots/weights, risk config, and depeg bands for BNB Smart Chain testnet (chainId **97**, alias **chapel**).

## Why JSON only (not YAML + JSON)

| Format | Role |
|--------|------|
| **JSON** (`testnet-asset-params.json`) | Deploy scripts, SDK, front, keeper config generation — machine-readable, no ambiguity |
| **YAML** (`sim/config.example.yaml`) | Simulation harness only (time series, liquidity, trader toxicity) — human-edited scenario files |

Sim YAML references JSON for fee floors; it does not duplicate the full asset table.

## Units

- On-chain `Asset.minFeeBps` = **PBPS** (parts per million of 100%)
- **100 PBPS = 1 bp = 0.01%**
- **1 PBPS = 0.0001% = 0.01 bp** — protocol floor (`Constants.MIN_FEE_PBPS`)

Spread at σ=0 equals `minFeePath` (max of leg minFee values). σ, confidence, and staleness widen above this floor.

## Oracle trust (v2)

- Keeper pushes: mark + Parkinson σ **sample** + mark **confidence** (decoupled from σ).
- Chain: price EMA + **σ-EMA** (asymmetric bands + mark-move evidence floor).
- Pricing reads: `lastPriceB64` (quote), `sigmaEma` (spread/dispersion/staleness).
- **Pusher:** testnet = single EOA via `grantOracle`; mainnet = Gnosis Safe 2-of-3 as oracle address (no contract fork).

See `docs/dex/1. AIMM/1.2. Modules/1.2.2. Internal Oracle.md`.

## batchPush gas scaling (steady-state)

Benchmarks: `evm/test/unit/ExternalOracleGas.t.sol` — warm slots, non-zero→non-zero SSTORE, `dt > tau`.

| Feeds (N) | Total gas | Marginal ~gas/feed |
|-----------|-----------|-------------------|
| 1 | ~18k | ~18k (fixed overhead) |
| 6 | ~59k | ~10k |
| 8 | ~75k | ~9k |
| 10 | ~91k | ~9k |
| 12 | ~107k | ~9k |
| 20 | ~171k | ~9k |
| 30 | ~252k | ~8k |

**Scaling:** O(N) linear. Fixed cost ~18k (auth + loop + slim `BatchPushed(count,pusher)` event). Marginal ~8–10k/feed. At 30 feeds ≈252k gas — comfortable headroom on BSC.

**On-chain optimizations (commit `4a2b223`):** raw `calldataload` loop, manual one-slot `FeedData` codec, slim `BatchPushed` event (~16% marginal savings vs prior). Prior: dedup B64 decode, α=0 fast path, single SSTORE.

**Keeper-side:** skip unchanged feeds per tick — no on-chain benefit pushing identical mark/σ/conf.
