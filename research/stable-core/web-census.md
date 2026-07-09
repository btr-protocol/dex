# Web census — BSC stable-stable venues (verified 2026-07-07, deep-research wf_b5ee9e63-4c7)

All claims survived 3-0 adversarial verification; on-chain cross-checked via BSC RPC + GeckoTerminal/DefiLlama.

## Venue ranking (the competition is ONE pool)
| Venue | TVL | Vol/day | Util | LP fee APR | Verdict |
|---|---|---|---|---|---|
| **PCS v3 USDT/USDC 0.01%** `0x92b7807bf19b7dddf89b706143896d05228f3121` | ~$35.0M | ~$5.1M (9.4k tx) | 0.146 | ~0.53% gross / ~0.35% LP (PCS skims ~32%) | **the incumbent** |
| PCS Classic StableSwap | $16.3M | $0.2–0.9M | ~0.02 | **0.05%/yr** (1.4bps realized blended) | economically dead |
| THENA | $2.9M (−73% over window) | small | — | — | moribund |
| Wombat | $1.2M BSC (−75%; stables $70–85k) | ~$6.4k | — | — | dismiss |
| Curve BSC | $0.85M | ~$3.5k | — | — | dismiss |

Notable: the incumbent pool's reserves are LOPSIDED (~31.9M USDT vs ~3.1M USDC ≈ 10:1) — v3 passive range pinned; one-sided pricing degradation. An oracle-centered two-sided book with inventory skew quotes better on the thin side. That's our attack surface.

## BSC supply stack (asset selection)
USDT **$9.17B** ≫ USD1 **$1.71B** (#2 — overtook USDC) > USDC **$1.58B** > USDe **$242M** ≫ FDUSD **$55.5M** ≫ TUSD ~$11M.
→ Core USDT/USD1/USDC/USDe validated (owner's USD1 instinct confirmed — #2 float on BSC). 5th slot: FDUSD only marginally better than TUSD; **"none" is defensible**; final call from the tape (Micro phase).

## Parametrization benchmark (freshest competitor design)
PCS Infinity StableSwap presets: **A=1000** fiat-redeemable stables (off-peg fee multiplier 10, MA 600s), A=100 crypto-collateralized (mult 12.5), A=500 LRTs; default fee **0.01%** tight pairs, paid to LPs; Curve-NG-style ASYMMETRIC fee (rebalancing flow pays less, imbalance-worsening more — philosophically the same as our coverage skew/toll; we do it continuously via the spline+skew instead of a multiplier).

## Open (web produced no surviving claims — empirical pipeline must answer)
- Aggregator routing share/edge on BSC (capture sim keeps 70%±20% aggregator-share sensitivity).
- Oracle push gas benchmarks (PushSim measures our own batchPush + live gas).
- 12-month depeg history per asset (USD1 tight-peg claim REFUTED 0-3 — do not assume USD1 pegs tightly; measure from tape).

## First-order market math (to be confirmed by capture sim)
Total addressable BSC stable-stable flow ≈ $5–7M/day, essentially all in the incumbent pool at 1bp.
If we capture ~50% at ~1bp effective → ~$250–350/day fees → on $2.5M TVL ≈ **3.7–5.1% gross APR** vs incumbent LP's 0.35% — the edge comes from running ~10× less TVL for comparable execution (oracle-centered ⇒ no $35M passive float needed). Empirical grid to confirm + bound (min viable / max useful TVL).
