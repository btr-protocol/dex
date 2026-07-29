# BSC Stable-Core — TVL Sizing to Own the Small-Trade Segment (empirical, 2026-07-08)

**Question:** how much TVL, per asset, to absorb *most* small stablecoin trades on BSC — the ≤$2k segment
(and, for headroom, ≤$10k) — so aggregators route them to us?

**Method (all local, nothing on the cluster):** 6-month tape of the real competing pools (Uniswap v3 + PancakeSwap
v3, `data/*.parquet`) → daily/size distribution (`daily_dist.py` → `out/daily_dist.json`) + per-asset TVL sweep
through the **real quote law** (`sdk/src/amm/aimm.ts`) at launch minFee = 1bp (`tvl_threshold.ts` →
`out/tvl_threshold.json`). Window 183 days (2026-01 → 2026-07). Stables priced $1.

---

## 1. What the daily activity actually looks like

| Pool (venue) | 6mo vol | trades | vol/day | trades/day | p50 | p90 | p99 | **≤$2k: trades / vol** | **≤$10k: trades / vol** |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| **PCSv3 USD1/USDT** | **$579M** | **2.70M** | **$3.17M** | **14,774** | $35 | $311 | $2,516 | **98.5% / 51%** | 99.8% / 74% |
| **UNIv3 USDT/USDC** | $284M | 432k | $1.55M | 2,367 | $12 | $695 | $9,000 | 96.7% / 21% | 99.1% / 37% |
| PCSv3 FDUSD/USDT | $31.5M | 83k | $0.17M | 456 | $6 | $410 | $8,074 | 96.0% / 22% | 99.3% / 61% |
| PCSv3 TUSD/USDT | $6.2M | 20k | $0.03M | 111 | $15 | $255 | $9,600 | 96.9% / 24% | 99.3% / 66% |
| PCSv3 USDe/USDT | $0.1M | 3.3k | $629 | 18 | $3 | $100 | $454 | ~100% | ~100% |

**Combined competing stable flow ≈ $4.9M/day, ≈17,600 trades/day.** The market is two pools:
**USD1/USDT (PCS) is the prize** ($3.17M/day, ~14.8k trades/day) and **USDT/USDC (Uni)** is the runner-up. FDUSD/TUSD
are marginal; USDe stable-swap is dead on BSC (lives on Ethereum).

**The segment is real:** **96–98.5% of all trades are ≤$2k**, and on the USD1/USDT pool those small trades carry
**51% of the volume**. Own ≤$2k and you own ~97% of *trades* (the routing-reputation prize) and ~half the *volume*.

Incumbent effective cost (fee+slippage) on the two big pools: **~0.94bp** (USD1/USDT), **~0.79–0.85bp** (USDT/USDC),
roughly flat under $100k. That's what we beat.

---

## 2. Minimum TVL to win the small-trade segment

Our all-in cost at minFee = 1bp (≈0.6bp base + σ term + slippage) vs the incumbent, swept over TVL. Win = our cost
≤ venue × 0.98. **Volume-weighted capture across all launch pairs:**

| Total TVL | ≤$2k: vol% / trades% won | ≤$10k: vol% / trades% won |
|---:|---:|---:|
| **$0.25M** | **98.7% / 99.6%** | 62.8% / 97.1% |
| **$0.50M** | 98.7% / 99.6% | **99.4% / 99.7%** |
| $1.0M | 98.7% / 99.6% | 99.4% / 99.7% |
| $1.5M | 98.7% / 99.6% | 99.4% / 99.7% |

**Small trades need almost no depth** — a $2k swap on a concentrated stable pool moves price <1bp even at $250k TVL.
The binding constraint is only the *large* tail ($10k+), which needs more.

### Min TVL on the core pairs (USD1/USDT + USDT/USDC = ~95% of flow), and the per-asset reserve split

| Goal | Min total TVL | USDC (base) | USDT | USD1 | FDUSD | USDe | captures |
|---|---:|---:|---:|---:|---:|---:|---|
| **Win ≤$2k** (97% of trades) | **$0.25M** | $87k | $65k | $68k | $21k | $8k | 98.7% of ≤$2k vol |
| **Win ≤$10k** (99% of trades, 74% of USD1/USDT vol) | **$1.5M** | $525k | $390k | $409k | $127k | $49k | 99.4% of ≤$10k vol |

(Per-asset split = base 35% + spokes 65%×volume-share. "Win ≤$10k" here means beating the incumbent on *every* trade
right up to a full $10k; winning 99% of the ≤$10k *volume* — which is dominated by $1–3k trades — happens at $0.5M.)

---

## 3. Recommendation

- **The old $5M figure was for max APR / winning up to $50k+ trades — overkill for your stated goal.** To *absorb most
  traffic under $2k* you need **~$0.25M mathematically; launch at $0.5M–$1M for margin** (inventory skew, depeg
  robustness, and not sitting on the razor's edge vs the incumbent). That already wins ~99% of trades and ~99% of the
  ≤$10k volume.
- **To comfortably own up to the full $10k trade** (headroom, larger-trader reputation): **$1.5M–$2M**.
- **It scales linearly** — climb the trade-size ladder by adding TVL later; you don't need it at launch.
- **Concentrate it where the flow is:** USD1 and USDT legs carry it (USD1/USDT is 64% of all flow). USDe gets a token
  reserve + wide band (dead flow, optionality only); FDUSD a small leg.
- **Net LP APR stays attractive at these sizes** — at $1M/1bp the capture grid shows ~4.65% net (fee revenue is high
  relative to the small TVL); deposit caps keep it from diluting.

**Risk params (unchanged from LAUNCH_PARAMS.md, confirmed by this sizing):** minFee **100 PBPS (1bp)** launch spread,
absolute floor 1 PBPS for a price war; θ **0.3–0.5bp** push cadence (~700–800/day, ~$60/mo); vega 1×; per-asset
refBands USDC 50 / USDT 100 / USD1 150 / USDe 150 / FDUSD 200 bp; USDe small cap + conservative pricing.

**Bottom line: a $0.5M–$1M launch pool owns ~97% of BSC stablecoin trades. $1.5–2M owns the ≤$10k tail too. Both are
a fraction of what we assumed — the small-trade dominance is cheap.**
