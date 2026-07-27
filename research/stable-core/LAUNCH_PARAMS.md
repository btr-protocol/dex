# Stable-Core — Launch Parameters (empirical, 2026-07-08)

> **Live SSoT:** Sepolia deploy params live in `evm/deployments/sepolia-risk-params.json`
> and keeper config in `keepers/oracle.sepolia.toml`. Numbers below are the 2026-07-08
> BSC tape study (historical research record).

Source: 6mo BSC HyperSync tape (3.24M swaps, 6 active pools) → microstructure → push economics → capture
simulation through the REAL quote law (`front/src/lib/amm/aimm.ts`). All numbers trace to `out/*.json`.
Run locally (Mac), nothing on the cluster. Window = 182.7 days (2026-01-06 → 2026-07-08).

## THE 5 TOKENS (owner-set + tape-confirmed)
**USDC (base) · USDT · USD1 · USDe · FDUSD.** Drop USDS from the deploy config (6th, **zero** BSC stable-swap
volume in the tape). 5th slot = **FDUSD** ($31.3M 6mo vs TUSD $6.2M decaying; USDe kept as core for optionality).
- **USD1 is the star**: $579M 6mo volume — *more than USDC/USDT's $284M*. World Liberty's stable dominates BSC.
- **USDe** has ~**$0** BSC DEX stable-swap volume (it lives on Ethereum) + **de-pegged to 477bp** in-window →
  in the pool for completeness, priced conservatively (wide refBand 150bp, small cap).

## Q1 — COMPETITOR CENSUS (who to beat)
The "competition" is **one pool**: PancakeSwap v3 USDT/USDC 0.01% (`0x92b7807bF19b…`), ~$35M TVL, ~$5.1M/day,
util 0.146, **reserves 10:1 lopsided**, LP fee APR **~0.35%** (PCS skims ~32% of 1bp). PCS Classic StableSwap
(dead, 0.05%/yr APR), THENA/Wombat/Curve/DODO all near-dead. **We beat one 1bp pool.**

## Q2 — MICROSTRUCTURE (the cost to beat)
Incumbent **effective cost ~0.95–1.0bp** for the bulk (< $100k trades), rising to **1.9bp** at $100k–1M. Trade
sizes: p50 ~$35, p90 ~$311, p99 ~$2.5k (USD1/USDT). Volume concentration: $100–1k = 31%, $1k–10k = 32%,
$10k–100k = 25% of USD1/USDT flow. (`out/micro_summary.json`.)

## Q3 — PUSH ECONOMICS (your "θ=2bp too loose" concern — confirmed)
θ controls **centering precision** (a θ-stale mark = the pool mis-centered by ≤θ). θ=2bp = too loose. Tight
centering is cheap (measured gas 97,519 for a 5-feed batch, BNB $562, 0.05 gwei = $0.00274/push):

| θ (bp) | batch pushes/day | $/mo @0.05gwei | $/mo @0.1gwei | $/mo @1gwei |
|---|---|---|---|---|
| 0.1 | 933 | $77.7 | $155 | $1,555 |
| 0.2 | 864 | $72.0 | $144 | $1,440 |
| **0.3** | **806** | **$62.2** | $124 | $1,244 |
| **0.5** | **704** | **$58.7** | $117 | $1,174 |
| 1.0 | 503 | $41.9 | $84 | $838 |
| 2.0 | 73 | $6.1 | $12 | $122 |

**Premise verdict:** "rarely breach θ=1bp" = FALSE (spread noise on a ≤1bp venue). "cheap on BSC" = TRUE — even
the tightest centering (θ=0.1bp, 933 pushes/day) is **<$80/mo** at normal gas. **RECOMMEND θ = 0.3–0.5bp** (~700–
800 pushes/day, ~$60/mo) — ~10× the 2bp cadence, precise centering, negligible cost.

## Q4 + Q5 — CAPTURE SIM → OPTIMAL FEE (the money answer)
Replayed the tape through `quoteExactIn` over (minFee × TVL). The fee = `minFee floor + σ·vega` (σ-driven). Key
finding: the incumbent charges ~1bp, so the **revenue-optimum is *just under* it, NOT the 0.01bp floor** —
racing to the floor sacrifices ~3× the APR for marginal extra capture we already have.

Net LP APR (after ~0.15%/yr stable LVR), by minFee spread × pool TVL:

| minFee (spread) | ≈ all-in cost | capture% | net APR @$1M | @$2.5M | @$5M | @$10M |
|---|---|---|---|---|---|---|
| 0.1 bp | ~0.26 bp | 72–100% | 2.14% | 1.03% | 0.28% | 0.13% |
| 0.5 bp | ~0.4 bp | 61–100% | 2.77% | 1.62% | 0.72% | 0.38% |
| **1.0 bp** | **~0.6 bp** | **61–90%** | **4.65%** | **2.18%** | **1.27%** | 0.56% |
| 1.5 bp | ~0.86 bp | 29–74% | 2.93% | 2.10% | 0.94% | 0.65% |
| 1.75 bp | ~1.2 bp | ~0% | — | — | — | — |

**RECOMMEND launch minFee = 100 PBPS (1bp spread ≈ 0.6bp all-in)** — ~40% under the incumbent, captures ~90% at
$5M, best net APR. **Keep the absolute floor at 1 PBPS (0.01bp)** for a future price war (drop to it if a
competitor undercuts). vega (σ-sensitivity) stays at 1x so the fee widens protectively in vol.

## Q6 — CAPS & SCALABILITY
- **Min-viable TVL ≈ $1M** (net APR 4.7% at minFee=1bp, but capture on large trades thin).
- **Recommended launch TVL = $2.5–5M** — net APR **1.3–2.2%**, captures ~90% of BSC stable flow, beats the
  incumbent LP's 0.35% at **7–14× less TVL**. (Utilization ~1.2 vol/TVL/day vs incumbent's 0.15 — that is the edge.)
- **Max-useful TVL ≈ $10M** — beyond this APR compresses (<0.6%) without materially cutting slippage; p99 trades
  ($2.5k) see ~0 impact already at $5M. Do not seed past $10M.
- **Per-asset deposit caps** (split by observed volume share, USDe conservative):

| Asset | share | cap @ $5M launch | max cap @ $10M | note |
|---|---|---|---|---|
| USDC (base) | 35% | $1.75M | $3.5M | base numeraire |
| USDT | 26% | $1.30M | $2.6M | ref stable |
| USD1 | 27% | $1.35M | $2.7M | dominant flow |
| FDUSD | 8% | $0.40M | $0.8M | |
| USDe | 4% | $0.20M | $0.4M | **capped low — 477bp depeg risk** |

## Q7 — TOKEN 5 → **FDUSD** (tape-decided)
FDUSD $31.3M 6mo vol, σ 13bp/day, depeg 56bp — vs TUSD $6.2M (decaying) and USDS $0. Your prior confirmed.

## RECOMMENDED DEPLOY CONFIG (per asset)
```
oracleMode = EXTERNAL (all), base = USDC
θ = 0.3–0.5 bp   heartbeat = 3600s   ttl = 1200s (≈2·heartbeat cap; NOT the 7200 default — tighten for freshness)
minFeeBps = 100 PBPS (1 bp spread) launch floor   |   absolute floor 1 PBPS available
maxFeeBps = 2000   gamma = 10000 (1x)   vega = 10000 (1x)   dispersion 1000–100000   depthAmp 10000
refBandBps: USDC 50 · USDT 100 (ref USDC) · USD1 150 · FDUSD 200 · USDe 150
reservationPrice/Max: set ±band per asset (USDe tightest given depeg history)
```

## SPLINE / SUPPLY RECALIBRATION (your question) — needs NXR feeds first, AGREED
Three things move the liquidity: (1) **price push → center** (θ-triggered, ~700–800/day); (2) **σ push → width**
(batched); (3) **profile/knots → the depth SHAPE**. For v1, (1)+(2) do all the real-time work and a **static
concentrated stable spline is sufficient** — a stable's price-density near peg barely changes, so the shape needs
at most **weekly** recalibration, not real-time. **BUT** calibrating the shape optimally needs the realized
**price-action density** of each stable, which requires clean **index prices** — and NXR does **not** feed these 5
stables yet (the DEX tape is too noisy to fit knots on). **Prerequisite: add USDC/USDT/USD1/USDe/FDUSD to NXR
feeds → collect index density → then fit + schedule weekly `requestUpdateProfile`** (the on-chain path for this is
itself still to be built — flagged in the design cross-val). v1 launches without it.

## LIMITS / SENSITIVITIES (frank)
1. **6-pool coverage** — the tape covers the economically-active pools (USD1/USDT dominant); dead venues correctly
   excluded, but a resurgent venue isn't modeled.
2. **σ-horizon** — fee uses DAILY realized σ; a shorter keeper-σ horizon lowers the fee toward the floor (more
   aggressive). The 1bp-spread floor makes the recommendation robust to this.
3. **Aggregator share 70%** (sensitivity 50/90%) + **router-edge 2%** drive capture; real routing may differ.
4. **LVR proxy** 0.15%/yr flat — real intra-θ stable LVR is tiny but unmodeled per-asset; USDe tail (477bp depeg)
   is the one real risk, mitigated by the low cap + wide band + external depeg breaker.
5. **Incentivized TVL stickiness, MEV, listing/BD** not modeled — pure pricing economics.
