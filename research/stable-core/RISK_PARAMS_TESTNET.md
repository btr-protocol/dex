# BSC Stable-Core — Testnet Launch Risk Parameters (sim-derived, 2026-07-08)

**Source:** faithful 3-month state-machine simulation (`faithful_sim.ts`) — 11.5M real BSC swaps replayed through
a live model of our own pool: real quote law, live marks tracked from the tape, coverage evolving per swap,
rebalancing charged at market cost. Full analysis: `stable_report.html`. TVL range: **$50K → $1M** (testnet).

## The decision: minFee = 1bp is the LP↔trader equilibrium

minFee sweep @ $250K (the knob that trades trader-share against LP yield):

| minFee | win·trades | win·vol | LP net APR | read |
|--:|--:|--:|--:|---|
| 0.3bp | 35% | 19% | 4.9% | traders win, **LPs starved** |
| 0.5bp | 30% | 16% | 7.9% | |
| **1.0bp** | **23%** | **12%** | **15.2%** | **← launch here** |
| 1.5bp | 18% | 8% | 22.5% | LP-rich, share fading |
| 2.0bp | 10% | 5% | 24.4% | share collapses |

**1bp (100 PBPS)** wins ~23% of the *sane, non-toxic* flow while paying LPs a healthy ~15% APR. On stables σ is
too small to lift a fee off a floor, so the earlier "minFee=1 PBPS, let σ do the work" plan starved LPs — the
floor must be the *real* fee. **1 PBPS (0.01bp) is retained only as a price-war lever** (drop via `setAssetParams`).

## Behaviour across the testnet TVL range (minFee=1bp)

| TVL | win·trades | win·vol | LP net APR | fees/yr | note |
|--:|--:|--:|--:|--:|---|
| $50K | 21.4% | 6.7% | 13.8% | $8k | fragile — occasional full-leg drain (self-heals) |
| $100K | 22.6% | 8.8% | 14.7% | $16k | |
| $250K | 22.9% | 11.6% | 15.2% | $39k | |
| $500K | 23.1% | 13.8% | 15.5% | $79k | |
| $1M | 22.9% | 15.6% | 11.0% | $111k | |

Win-share **by trade count is ~flat (~23%) across the whole range** — we take the same slice of small, sane
flow regardless of size. Volume-share and absolute fees scale with TVL; APR is highest where the fixed fee base
concentrates. Rebalancing stays **~2–4% of won volume** — because a correctly-marked pool takes balanced
two-sided flow and barely skews.

## The LP-protection insight: freshness, not the coverage band

Tightening `coverageMin` 0.5→0.8 changed win-share / APR / drain **negligibly** — the skew toll discourages but
can't hard-block a rare large trade on a tiny pool, and it self-heals via rebalance. **What actually protects LPs
is the fresh mark** (tight θ): it keeps the pool quoting at true peg, so it intermediates balanced flow and bleeds
~0 LVR. Hence **θ is the load-bearing LP parameter — keep it tight.**

## Launch parameters (in `dex/evm/deploy/testnet-asset-params.json`)

**Class defaults (TVL-invariant):** minFee **100 PBPS (1bp)** · maxFee 2000 · vega 10000 (1×) · gamma 10000 (1×) ·
dispersion 1000..100000 (concentrated) · **θ 0.3bp** (fresh-mark LP shield, ~800 pushes/day ≈ $60/mo) ·
heartbeat 3600s · ttl 7200s · oracleMode EXTERNAL. Shared: coverageMin 5000 / coverageMax 20000 (not load-bearing),
depthAmplifier 10000. Profile: knots ±[50,25,0,25,50], weights [50,50,50,50].

**Per-asset refBand (depeg clamp, bps):** USDC 50 · USDT 100 (peg-ref USDC) · USD1 150 · USDe 200 · FDUSD 200.

**Deposit-cap schedule** (per-asset = volume weights base 35% / USDT 26% / USD1 27% / FDUSD 8.5% / USDe 3.5%):

| total TVL | USDC | USDT | USD1 | FDUSD | USDe |
|--:|--:|--:|--:|--:|--:|
| $50K | $17.5K | $13K | $13.5K | $4.3K | $1.75K |
| $250K | $87.5K | $65K | $67.5K | $21K | $8.75K |
| $1M | $350K | $260K | $270K | $85K | $35K |

Raise the active tier via `setAssetParams` as TVL fills. USDe stays tiny (near-0 BSC flow + depeg risk).

## What to watch on testnet
- **Coverage excursions per leg** — if a leg pins at the floor under sustained one-way flow, the keeper rebalance
  cadence (not the coverage band) is the fix; confirm rebalancing stays low (~2–4%).
- **θ freshness** — if realized LVR rises, tighten θ before touching fees.
- **USD1 feed** — youngest token; Pyth conf/heartbeat monitored, NX-Rates fallback ready.
- Post-testnet: our structural edge (fresh-mark LVR recapture) pays far more in **volatile pairs** — the stable-core
  is the positioning beachhead, the volatile-core is the revenue thesis.
