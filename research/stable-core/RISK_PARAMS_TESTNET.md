# BTR DEX Testnet (BSC Chapel, chainId 97): Per-Asset Default Parameters

**Canonical per-asset default-parameter spec for the Hermite→quartic-I-spline redeploy.**
Every listed testnet ticker (base/quote) is mapped to a regime, a default preset curve (regime + wall tier
W + dispRef), a full risk config, a dispersion band, fees, gamma/vega, and its two relative-deviation
acceptance bands (feed-slot `maxDeviation` floor + the volatility-adaptive per-push band).

- **On-chain SSoT for deploy values:** `dex/evm/deploy/testnet-asset-params.json` (2026-07-12b) reconciled with
  the last full reseed script `dex/evm/script/ChapelEnableSwaps.s.sol`.
- **Preset catalogue SSoT:** `dex/research/stable-core/out/spline_shared_grid.json` + docs
  `1. AIMM/1.1. Pricing/1.1.2. Liquidity Shaping.md` §4 / §4.1.
- **Keeper push config:** `keepers/oracle.chapel.toml`. **On-chain oracle:** `dex/evm/src/oracles/ExternalOracle.sol`.
- Two pools, base = USDC both. Stable-core = [USDC, USDT, USD1, USDE, FDUSD]. Volatile-core = [USDC, USDT, BTCB,
  ETH, WBNB, CAKE, XAUT]. USDG is in the stable SSoT list but SKIPPED on Chapel (no mock) so 5 stables ship.

Units: `minFee`/`maxFee`/`dispersion`/`dispRef` in **PBPS** (100 PBPS = 1 bp = 0.01%). `gamma`/`vega` in BPS
basis (10000 = 1x). `coverage` in 0.01% units (10000 = 100%). `refBand`/`maxDeviation` in **bps**.

---

## 0. Methodology: derived from observed density

Every per-asset regime, wall tier, dispersion band, and fee floor in §3 and §4 is **derived from the measured
return density of the asset**, not from a class assumption or a volume ranking. Assumption-first parametrization
(the retired "USD1 is dominant flow so tighten it", "XAUT is a quiet major so meso") is not used: the parameter is
read off the shape of the observed tape.

**Data.** NX Rates `/v1/ohlc`, 14-day (2-week) window per asset, paced anon pull (dedup + sorted). Fresh 2026-07-21
pulls (`dex/research/stable-core/data/nxr_ohlc/{CAKE,FDUSD,USDE,XAUT}-USDC.json`) plus prior-window and local
cross-check tapes (`dex/research/data/ohlc/{BTC,ETH,BNB}-USDT.csv`) for the majors. Bar TF per asset noted inline
(10s..300s). Bad-print bars removed before measuring (2 for ETH; the XAUT mirror-cluster subset, see §4).

**Features measured (per asset).**
- **rvol** (realized vol, bp/day): cross-checked across close-to-close, Parkinson (high-low), and IQR-core
  estimators; reported only where the three converge (a divergence flags contamination, see XAUT).
- **kurt** (excess kurtosis of returns): tail-fatness vs a Gaussian bell (excess 0).
- **tailα** (Hill tail exponent): α > 2 = finite variance; **α < 2 = infinite-variance tail** (rare violent jumps).
- **skew** (return skew): sign and stability across TF.
- **b95 / b99** (|return| containment, bp): the 95th and 99th percentile single-bar move = the per-push band the
  wall tier and `maxDeviation` floor must sit above.
- **pegMaxDev** (bp): largest observed peg excursion (stables only), bracketed against the `maxDeviation` floor.

**Mapping rules (density feature -> param).**
1. **Regime** <- (kurt, tailα, skew): kurt near 3 + thin tail = `meso`; high kurt + heavy-but-finite tail
   (α in ~2.7-3.2) = `lepto`; tightest tail-adjusted core on a mature peg = `hyper` candidate; stable soft-peg
   with a rolloff = `plateau`; broad low-conviction alt = `platy` (defensive). Unstable-sign skew = NO `skew_*`
   preset (the pushed mark already prices skew; A-S inventory skew carries asymmetry).
2. **Wall tier W / dispRef** <- b99 containment: the tier must contain the 99th-percentile move. Widest observed
   core -> widest shape.
3. **minFee floor** <- (rvol, pegMaxDev): graded by realized and depeg vol (higher adverse-selection risk ->
   higher floor). Volatiles are floored at `2θ` by the `lepto` between-push discipline regardless.
4. **maxDeviation / refBand** <- pegMaxDev (stables) and b99 (volatiles): the acceptance floor must exceed the
   observed 99% move with margin, or a legitimate push false-halts.
5. **hyper veto** <- tailα: an asset with `tailα < 2` (infinite-variance tail) is NEVER tightened to `hyper`,
   even if its normal core is tightest; the needle is only safe on a mature peg behind the κ-wall with a
   finite-variance tail. `hyper` additionally requires `kappaCovBps > 0` (§1 wall gate).

**Coverage.** No asset is data-missing. USDC = the identity numeraire (price = 1 by construction, 0 bars, not a
DEFERRED asset). One asset carries a **finalize-blocker**: **XAUT**, whose synthetic XAUT-USDC cross is feed-QC
contaminated. Its clean-subset density is sufficient to derive a regime *recommendation* but NOT to seal; its
shipped values are held unchanged until the feed is fixed, and the exact fetch needed is stated in §4.

---

## 1. What changed: Hermite → quartic-I-spline PRESETS

The pricing engine moved from an inline per-asset Hermite profile (knots + weights baked into `addAsset`) to a
shared per-pool **preset catalogue**: 9 shape regimes over a wall ladder W in {0.5, 1, 2, 5} bp. A curve is
installed once per pool with `setCurve(pool, presetId, interior[], wQ[], dispRef, flags)` (bootstrap, pre-seal),
and each asset points at it through `Asset.presetId`. One refit updates every asset on that preset. `presetId = 0`
is the no-shape sentinel.

> **Arg-shape (do NOT carry the placeholder lengths).** The retired Chapel `_curve` placeholder shipped
> `interior[4] / wQ[9]`. That is the WRONG fitted length. `NUQuartic._validate` (`NUQuartic.sol:70`) requires
> `interior.length == wQ.length - 5` and `segs = wQ.length - 4 <= MAX_SEGS (14)`. The fitted arrays are therefore
> **W0.5 / W1 / W5 = `interior[9] / wQ[14]`** (10 segments) and **W2 = `interior[13] / wQ[18]`** (14 segments,
> the max shipped). Emit the full fitted arrays from `spline_shared_grid.json`; do not truncate to 4/9.

- **Portable whitelist** (only these ship on-chain): `hyper`/`plateau`/`lepto` @ W0.5; + `flat` @ W1; all 9 @ W2
  and W5.
- **Wall gate:** `hyper` carries `FLAG_REQUIRES_WALL`. Assigning it to an asset with `kappaCovBps = 0` reverts
  (`PoolAdmin.validatePresetAssign`). The needle concentration is only safe behind the convex coverage toll, so
  `hyper` is reserved to coverage-walled stable spokes. Base USDC (never walled, κ = 0) and all volatile legs
  (κ = 0) are barred from `hyper`.
- **`requestUpdateProfile(pool, tok, presetId, minDisp, maxDisp)`** repoints the preset + sets the dispersion band
  post-seal (timelocked twin); no per-asset knot arrays any more.
- The `sharedLiquidityProfile` `[50,100,50]` in the JSON is the OLD Hermite shape and is SUPERSEDED by the preset
  table below. The Chapel scripts still ship a **linear-ramp placeholder** `wQ[i] = (i-4)*step` (step 12.5e9 stable
  / 125e9 volatile); production weights are the fitted quartic from `spline_shared_grid.json` and MUST replace the
  placeholder at redeploy.

### 1.1. Regime defaults (docs §4.1)

| Regime | Default W | dispRef (PBPS) | Shape | Target class | Wall |
|---|---|---|---|---|---|
| `hyper` | 0.5 bp | 50 | needle at mark, 8.9x Curve peak | Tier-1 stables / pegged FX | REQUIRES_WALL |
| `flat` | 1 bp | 100 | box + hard walls | single-range / redemption band | none |
| `plateau` | 1 bp | 100 | box + soft rolloff | soft-pegs, LST accrual band | none |
| `meso` | 2 bp | 200 | Gaussian bell | FX crosses, quiet majors | none |
| `lepto` | 5 bp | 500 | fat Student-t wings | majors / crypto under stress | none; needs minFee ≥ 2θ |
| `platy` | 5 bp | 500 | broad, thin tails | wide FI / low-conviction | none |
| `skew_L`/`skew_R` | 5 bp | 500 | directional | mark carries no skew only | none |
| `pin_M` | 5 bp | 500 | M-bimodal | options gamma pin | research-only, off whitelist |

`skew_*` are redundant and arbitrable on a mark that already prices the skew: use a symmetric preset and let the
Avellaneda-Stoikov inventory skew carry all asymmetry. `pin_M` needs a frozen anchor, which contradicts keeper
re-centering. Neither ships on Chapel.

---

## 2. Global constants (all assets, both pools)

| Constant | Value | Source |
|---|---|---|
| gamma (inventory skew) | **20000** (2x) | 2026-07-12 postmortem: 1x was too soft, bots dumped BTCB |
| vega (σ sensitivity) | **10000** (1x) | fee widens protectively in vol |
| decimals | 18 | all mocks |
| `decayStartRatioBps` | 5000 | shared RiskConfig |
| `coverageMin` / `coverageMax` | 5000 / 20000 | shared; not load-bearing (see §5 note) |
| `protoShare` | 20 | FeeParams |
| `flashFeePbps` | 100 | FeeParams |
| maxFee | stable **2000** / volatile **10000** | class default |
| STABLE feed `maxDeviation` floor | **50 bps** (0.5%) | `TestnetDeploy.s.sol` |
| VOLATILE feed `maxDeviation` floor | **100 bps** (1%) | `TestnetDeploy.s.sol` |
| feed ttl | stable **7200 s** / volatile **600 s** | `addFeed` |
| SIGMA_SEED / CONF_SEED | 10000 / 25 (stables: seed lower, see §6.2 note) | `addFeed` |
| `DEV_SIGMA_Z` | 6 | per-push band multiplier |
| `SIGMA_INTERVAL_S` | 1800 | NXR 30-min Parkinson σ window |
| `MAX_DEV_THRESHOLD` | 65000 bps (650%) | per-push band cap |
| `SOURCE_TS_FUTURE_SKEW_S` | 5 s | future-skew reject |
| `maxRelayLagSecs` | 120 | absolute freshness floor |

**RiskConfig triplet** (`ChapelEnableSwaps` `_riskConfigs`):

| Template | Applies to | kappaCovBps | depthAmplifier | haircutSuppressor | decay/covMin/covMax | flags |
|---|---|---|---|---|---|---|
| base | USDC (numeraire, both pools) | 0 | 10000 | 10000 | 5000/5000/20000 | SWAP\|LIAB |
| stableSpoke | non-USDC stables | **100** (wall ON) | **0** | **0** | 5000/5000/20000 | SWAP\|LIAB |
| volatile | all volatile spokes | 0 | 10000 | 10000 | 5000/5000/20000 | SWAP\|LIAB |

Invariant: `kappaCovBps > 0` requires `depthAmplifier = 0` (the c<1 depth subsidy fights the convex wall,
enforced in `PoolAdmin`) and `haircutSuppressor = 0` (coverage-wall-bypass fix: an over-covered leg must not drain
across peg toll-free).

---

## 3. Stable-core per-asset defaults (base = USDC, κ-wall ON spokes)

| Asset | Regime | Preset (W / dispRef) | minFee | maxFee | minDisp | maxDisp | κ | depthAmp | haircut | refBand | maxDeviation |
|---|---|---|---|---|---|---|---|---|---|---|---|
| USDC (base) | `plateau` | W1 / 100 | 50 | 2000 | 200 | 2000 | 0 | 10000 | 10000 | 0 | 50 |
| USDT | **`hyper`** | W0.5 / 50 | 50 | 2000 | 600 | 6000 | 100 | 0 | 0 | 100 | 50 |
| USD1 | `plateau` | W1 / 100 | 50 | 2000 | 500 | 5000 | 100 | 0 | 0 | 100 | 50 |
| USDE | `plateau` | W2 / 200 | 75 | 2000 | 800 | 5000 | 100 | 0 | 0 | 100 | 50 |
| FDUSD | `plateau` | W1 / 100 | 100 | 2000 | 1000 | 8000 | 100 | 0 | 0 | 100 | 50 |

gamma = 20000, vega = 10000 for every stable. refFeedId for all non-USDC stables = `USDC_FEED`
(`0xdacab873…3ba17d`), refPrimary = REF_ORACLE (env). USDC self-reference is suppressed (base = numeraire).

**Observed density (14d NXR `/v1/ohlc`, per §0):**

| Asset | bars×TF | rvol (bp/d) | kurt | tailα | skew | b95 | b99 | pegMaxDev |
|---|---|--:|--:|--:|--:|--:|--:|--:|
| USDC | 0 (identity) | 0 | n/a | n/a | n/a | 0 | 0 | 0 |
| USDT | 16345×60s | 19.08 | 4.42 | 3.45 | -0.037 | 3.02 | 4.58 | 13.35 |
| USD1 | 3939×300s | 16.33 | 39.94 | **1.877** | 0.111 | 1.502 | 3.422 | 15.87 |
| USDE | 19443×60s | **49.29** | 50.29 | 3.21 | -0.027 | 1.9 | 6.65 | 25.2 |
| FDUSD | 19749×60s | 19.02 | 12.93 | 3.18 | -0.042 | 1.05 | **1.75** | **34.36** |

**Per-asset rationale (observed-density):**

- **USDC (base numeraire).** 0 bars, price = 1 by construction. κ = 0 (a base leg is never coverage-walled), so
  the wall gate bars `hyper`. `plateau` W1 is the tightest legal un-walled peg shape: box + soft rolloff, tolerates
  a small legitimate repeg without a hard cut. depthAmp = 10000 (base carries the virtual-depth subsidy). No
  refBand (self). Identity numeraire, not DEFERRED. No change.
- **USDT (`hyper`).** The one clean `hyper` candidate on measured density: kurt 4.42 (only mildly super-Gaussian),
  tailα 3.45 (finite-variance, not heavy), skew ≈ 0, and the tightest tail-adjusted core among the mature pegs.
  rvol 19.08 bp/d is the lowest of the stables. The needle-at-mark shape (8.9x Curve peak density) is safe only
  because κ = 100 walls a drain (haircutSuppressor MUST be 0). pegMaxDev 13.35 << refBand 100 and << maxDeviation
  50, so no false-halt. Only asset that clears the `hyper` bar. No change.
- **USD1.** Core is the tightest 99% of any peg (b99 3.42) which alone would argue for `hyper` W0.5, BUT
  **tailα 1.877 < 2 = an infinite-variance tail** (rare violent jumps) on the youngest peg. The tail vetoes `hyper`
  (§0 rule 5): held at `plateau` W1 / dispRef 100 whose soft rolloff absorbs the jump. rvol 16.33 is lowest ->
  minFee floor at the base 50 PBPS. κ = 100. Tighten to `hyper` W0.5 only after a clean depeg history accumulates,
  via `requestUpdateProfile`. tailα 1.877 is the load-bearing trace here. No change now.
- **USDE.** **Highest stable rvol (49.29 bp/d, 2.6x USDT)** and the **widest stable core (b99 6.65)** -> the widest
  stable shape: `plateau` **W2** / dispRef 200, widest live disp-band lower bound (800). Soft-peg accrual (kurt is
  fat but the shape is a plateau, not a needle). minFee lifted to **75 PBPS (0.75 bp)**: the realized-depeg vol
  (2.6x USDT) directly justifies a floor above USDC/USDT. Smallest deposit cap (§8). Density-vindicated. No change.
- **FDUSD.** **Tightest normal core of all assets (b99 1.75 bp)** but the **largest rare depeg tail
  (pegMaxDev 34.36 bp)**: a "tight-then-breaks" density. The tight core alone would allow W0.5; the large depeg
  tail vetoes it -> `plateau` W1 soft rolloff over a hard box. minFee **100 PBPS (1 bp)**, the highest stable floor,
  prices the break-adverse-selection of the most depeg-prone book. Widest maxDisp (8000) for the softer peg.
  pegMaxDev 34.36 < maxDeviation 50 (margin holds). No change.

---

## 4. Volatile-core per-asset defaults (base = USDC, κ = 0 all, no hyper)

| Asset | Regime | Preset (W / dispRef) | minFee | maxFee | minDisp | maxDisp | κ | depthAmp | haircut | refBand | maxDeviation |
|---|---|---|---|---|---|---|---|---|---|---|---|
| USDC (base) | `plateau` | W1 / 100 | 1000 | 10000 | 50000 | 500000 | 0 | 10000 | 10000 | 0 | **50** (shared) |
| USDT | `plateau` | W1 / 100 | 1000 | 10000 | 50000 | 500000 | 0 | 10000 | 10000 | 100 | **50** (shared) |
| BTCB | **`lepto`** | W5 / 500 | 1000 | 10000 | 50000 | 500000 | 0 | 10000 | 10000 | 0 | 100 |
| ETH | **`lepto`** | W5 / 500 | 1000 | 10000 | 50000 | 500000 | 0 | 10000 | 10000 | 0 | 100 |
| WBNB | **`lepto`** | W5 / 500 | 1000 | 10000 | 50000 | 500000 | 0 | 10000 | 10000 | 0 | 100 |
| CAKE | **`platy`** | W5 / 500 | 1000 | 10000 | 50000 | 500000 | 0 | 10000 | 10000 | 0 | 100 |
| XAUT | **`meso`** | W2 / 200 | 1000 | 10000 | 50000 | 500000 | 0 | 10000 | 10000 | 200 | 100 |

gamma = 20000, vega = 10000 for every volatile asset. minFee 1000 PBPS = 10 bp = 2θ (θ_vol = 5 bp), which
satisfies the `lepto`/`skew`/`pin` between-push discipline `minFee ≥ 2θ`. Fee charged is half the path spread.

> **maxDeviation is per-FEED, not per-pool-asset.** USDC and USDT in the volatile pool reference the SHARED stable
> feeds (`USDC_FEED` and `keccak(USDT, USDC)`), which `addFeed` already set to **50 bps** for the stable idx 0/1
> slots. There is no second volatile USDT/USDC feed, so the on-chain `maxDeviation` for those two legs is **50**
> (tighter, safe), NOT the volatile 100-bps floor. The 100-bps floor applies only to feeds unique to the volatile
> pool: BTCB / ETH / WBNB / CAKE / XAUT (idx 5-9).

> **Confirm the volatile dispRef change before sealing.** The last-live deploy kept preset 1 at **dispRef = 1000**
> (`ChapelWidenVolatileDisp`) with disp band 50k/500k. The new map installs regime-default dispRef (`plateau` 100,
> `meso` 200, `lepto`/`platy` 500) over the SAME disp band. Because quotes scale y by `disp/dispRef` (`_scaleY`), a
> lower dispRef at the same band yields a **~2x steeper curve** (e.g. `lepto` 1000 → 500). This is intended (the
> regime table is the SSoT), but VERIFY against the sim before `sealBootstrap`: post-seal, curve changes are
> timelocked-only (`requestSetCurve`, ~5m LOW).

**Observed density (14d NXR `/v1/ohlc` / local cross tapes, per §0):**

| Asset | bars×TF | rvol (bp/d) | kurt | tailα | skew | b95 | b99 | pegMaxDev |
|---|---|--:|--:|--:|--:|--:|--:|--:|
| BTCB | 120960×10s | 227.03 | **252.2** | 2.71 | 0.13 | 5.8 | 10.62 | n/a |
| ETH | 18644×1min | 237 | 43 | 2.75 | **1.43** | 12.5 | 22.1 | 0 |
| WBNB | 120960×10s | **290.1** | 17.4 | 3.1 | -0.02 | 5.6 | 9.4 | 0 |
| CAKE | 3614×300s | **514.5** | 36.2 | 2.96 | **-0.44** | 37.8 | **61.7** | n/a |
| XAUT | 15102×60s (clean subset) | 118 | 34.6 | **2.0** | 0.15 | 17.5 | **41.3** | 0 |

**Per-asset rationale (observed-density):**

- **USDC (base numeraire).** Un-walled base, `plateau` W1. Depth subsidy on (depthAmp 10000). No refBand.
- **USDT (stable leg in a volatile pool).** κ = 0 here, so `hyper` is barred: `plateau` W1, not the stable-pool
  `hyper`. refBand ±1% vs USDC (own USDT mark for quotes, USDC ref only for the depeg halt).
- **BTCB (`lepto`).** **Extreme kurt 252.2** + tailα 2.71 (heavy but finite-variance) = the fat Student-t wing
  archetype. b95 5.8 ≈ θ_vol (5 bp), so minFee 2θ = 10 bp brackets the 1-bar move; b99 10.62 << maxDeviation 100.
  `lepto` W5 / dispRef 500 places depth where informed flow lands and prices the tail honestly. No refBand. No
  change.
- **ETH (`lepto`).** kurt 43 + tailα 2.75 heavy = `lepto`. skew 1.43 is high but sign-unstable across TF -> NO
  `skew_*` (the marked price already carries it; A-S inventory skew carries the asymmetry). b95 12.5 ≈ 2.5σ,
  b99 22.1 << maxDeviation 100. minFee 2θ = 10 bp. No change.
  > **ETH density validation (2026-07-21, observed).** NXR `/v1/ohlc` ETH-USDC, 14d @ 1min (18.6k bars) + 5min
  > cross-check + local ETH-USDT 10s (120k bars, prior window). Robust (2 bad-print bars removed): realized vol
  > **~230-240 bp/day** (c2c ≈ iqr-core ≈ Parkinson all converge; ~2.3%/day, ~44%/yr); return density
  > **leptokurtic** (excess kurt 15-40 across tf, Hill tail α≈2.7 → finite variance, heavy tails) → `lepto`
  > CONFIRMED; mild +skew (0.35-1.4, sign-unstable) → no `skew_*`. Containment: 1min ±12.5bp(95%)/±22bp(99%),
  > 5min ±27/±50bp → W5 tier + maxDeviation 100 bps sits comfortably above the 99% per-push band. minFee 10 bp
  > (=2θ, θ_vol 5bp) brackets the 1min 95% move (12.5bp ≈ 2.5σ). Every shipped ETH param is density-consistent;
  > no change.
- **WBNB (`lepto`).** **Highest-vol major (rvol 290.1 bp/d)**, kurt 17.4 fat, symmetric (skew -0.02) = `lepto`.
  b99 9.4 << maxDeviation 100. minFee 2θ. No change.
- **CAKE (`platy`, kept as defensive posture).** **Highest rvol in the universe (514.5 bp/d)** and the **widest
  core (b99 61.7 bp)** put it firmly at W5 / dispRef 500. **Density-vs-regime caveat:** the measured density is
  **leptokurtic** (kurt 36.2, tailα 2.96 = heavy but finite-variance), NOT the thin tails `platy` implies. `platy`
  was chosen as a **risk posture** (illiquid alt, minimize capital-at-risk), not as a pure density fit; a pure
  density read = `lepto`. At the same W5 / dispRef 500 the two shapes are numerically identical here, and `platy`
  is the more defensive (broader, lower-amplitude), so it errs safe. skew -0.44 is notable but on 300s bars and
  still gets no `skew_*` preset (marked price carries it). b99 61.7 < maxDeviation 100, only a 1.6x margin (the
  tightest volatile headroom: watch). **Kept `platy` as documented defensive posture; the density-faithful
  alternative is `lepto` W5 (same numeric params, fatter shape). Owner call.** No value change.
- **XAUT (tokenized gold, shipped `meso` W2 HELD; finalize-blocked).** Shipped params unchanged pending a feed-QC
  fix (see blocker below). `meso` W2 (Gaussian bell) is the on-chain value; the pushed mark carries no directional
  skew so a symmetric shape plus A-S inventory skew carries any asymmetry (a `skew_*` preset would be arbitrable).
  refBand ±2% against an **independent** XAUT/USDC oracle (`XAUT_REF_ORACLE` /
  `XAUT_REF_FEED_ID = keccak(XAUT,USDC)`), NOT the unit USDC feed.
  > **Observed clean-subset density RECOMMENDS `lepto` W5, but the value is HELD (feed-QC blocker).** The clean
  > subset (kurt 34.6, tailα 2.0 borderline infinite-variance, b99 41.3 bp) is **density-inconsistent with `meso`**
  > (a Gaussian bell expects kurt ≈ 3), and b99 41.3 exceeds W2 / dispRef 200 containment (needs W5 / 500). A pure
  > density read = **`lepto` W5 / dispRef 500** (matches kurt 34.6, tailα 2.0, b99 41.3). This is a RECOMMENDATION
  > only: the shipped `meso` W2 / dispRef 200 is NOT flipped here because the tape is contaminated and the change
  > must land on clean data. minFee 10 bp (=2θ) HOLDS regardless (brackets the clean 95% move 17.5 bp + weekend
  > gold-gap adverse-selection). The independent `XAUT_REF_ORACLE` + refBand 200 + maxDeviation 100 are ESSENTIAL
  > and vindicated: they auto-reject the ~2300 mirror artifact (~44% below truth) as a depeg-halt.
  >
  > **Why the tape is contaminated (DO NOT FINALIZE).** NXR `/v1/ohlc` XAUT-USDC, 14d @ 1min (15,102 bars,
  > 07-07..07-21, paced anon pull; bulk 403-wedges, needs `NXR_API_KEY`). The XAUT-USDC synthetic cross is BROKEN:
  > bimodal price, a real gold cluster ~4100 interleaved with a spurious mirror cluster ~2300 (12% of bars <3500)
  > + 21% `tick_count==0` synthetic-fill bars, so raw density is a feed-composition artifact, NOT XAUT behavior
  > (raw daily vol 8300 bp = garbage). The clean subset (tc>0 & 3500<px<4400, 79% of bars) recovers real gold
  > micro-structure and is the row in the table above (robust ~118 bp/day, kurt 34.6, α 2.0), but mean-based
  > estimators on the full tape stay tail-inflated. Real structural feature: **weekend gold-market gaps** (feed
  > dark Fri ~24:00 → Sun; a 2268-min hole 07-10/12) = gap risk crypto legs lack.
  >
  > **BLOCKER + exact fetch needed to finalize.** Do NOT flip `meso`→`lepto` on this tape. First fix the feed:
  > export `NXR_API_KEY` (unblocks the bulk 403), then from `dex/research/stable-core/` run
  > `NXR_API_KEY=… TF=60 DAYS=14 python pull_nxr_ohlc.py` scoped to XAUT (or source XAUT/USDT direct + read the
  > cluster shards), confirm the mirror cluster and `tick_count==0` fills are gone, then re-derive
  > regime / W / dispRef on the uncontaminated tape and, if it still reads `lepto`, land the change via
  > `requestUpdateProfile`.

---

## 5. Coverage band and the LP-protection insight

`coverageMin = 5000` / `coverageMax = 20000` / `decayStartRatioBps = 5000` are shared and deliberately NOT
load-bearing. The faithful 3-month state-machine simulation (11.5M real BSC swaps replayed through our own quote
law) found that tightening `coverageMin` 0.5→0.8 changed win-share, APR, and drain **negligibly**: the skew toll
discourages but cannot hard-block a rare large trade on a tiny pool, and it self-heals via rebalance.

**What actually protects LPs is the fresh mark (tight θ).** A fresh mark keeps the pool quoting at true peg, so it
intermediates balanced two-sided flow and bleeds ~0 LVR. θ is the load-bearing LP parameter: keep it tight
(§7). Rebalancing stays ~2-4% of won volume because a correctly-marked pool takes balanced flow and barely skews.

The coverage **wall** (κ = 100 on stable spokes) is a distinct mechanism from the coverage band: it is the convex
toll that makes `hyper` needle concentration safe and blocks a toll-free cross-peg drain of an over-covered leg
(coverage-wall-bypass fix). It is ON only for walled stable spokes and MUST pair with depthAmp = 0 and
haircutSuppressor = 0.

---

## 6. Per-asset relative-deviation acceptance bands (price push)

Four distinct layers gate a signed mark. Layers 1-2 are the on-chain accept/reject band (`ExternalOracle`); layer 3
is the off-chain keeper push trigger; layer 4 is the independent cumulative depeg guard. ALL revert fail-closed:
an in-heartbeat push exceeding the band reverts and the last good mark survives.

### 6.1. Layer 1: feed-slot `maxDeviation` floor (mandatory, on-chain)

Set at `addFeed`/`updateFeed`, packed in FeedData bits [176:192], MANDATORY non-zero, ≤ 65000. This is the
microstructure/discretization floor and the per-push band on a cold start (`prevSourceTs == 0` ⇒ dtSource = 0 ⇒
band = floor exactly). Guardian may `narrowMaxDeviation` (tighten-only); owner widens via `updateFeed`.

| Asset class | `maxDeviation` floor |
|---|---|
| all 5 stables | **50 bps** (0.5%) |
| volatile-unique feeds (BTCB/ETH/WBNB/CAKE/XAUT) | **100 bps** (1%) |
| volatile USDC/USDT | **50 bps** (share the stable feeds, per §4 note) |

`maxDeviation` is a per-FEED slot. The volatile pool's USDC and USDT legs reuse the stable feeds (`USDC_FEED`,
`keccak(USDT, USDC)`) already added at 50, so only the five volatile-unique feeds carry the 100-bps floor.

### 6.2. Layer 2: volatility-adaptive per-push band (on-chain, `_checkDeviation`)

```
devBps  = |mark - prevMark| * BPS / prevMark
allowed = maxDeviation + (DEV_SIGMA_Z * prevSigmaPbps * sqrt(dtSource * 1e6 / SIGMA_INTERVAL_S)) / 1e5
allowed = min(allowed, MAX_DEV_THRESHOLD)      # 65000 bps (650%)
revert if devBps > allowed                      # CooldownActive / DeviationExceeded
```

- `DEV_SIGMA_Z = 6`, `SIGMA_INTERVAL_S = 1800` (NXR 30-min Parkinson σ window). The band widens as
  `6·σ·√(dtSource/1800)` above the floor, so a longer gap or higher stored σ admits a larger legitimate move while
  a compromised key is still bounded to `maxDeviation` on a fast push.
- σ = the **stored prior** `sigmaEma` (PBPS), never the incoming push's own σ (prevents self-widening). σ is stored
  directly (no on-chain EMA) and floored at `markMovePbps = |Δmark|/mark` to defeat a σ=0 spread-collapse self-swap.
- `dtSource = (sourceTs - prevSourceTs)/1000` s of **attested source time**, so the band is chain-agnostic
  (identical on a 400 ms and a 12 s chain). Additional per-push guards: monotonic `sourceTs` (the ms nonce,
  `< 2^48`), future-skew reject (`sourceTs ≤ (now+5s)*1000`), absolute freshness floor
  (`sourceTs ≥ (now-120s)*1000`), one-per-block cooldown.

> **Seed a smaller stable SIGMA_SEED.** The 10000 PBPS (=1%/30min) seed inflates the Layer-2 band for stables on
> the first push after a heartbeat gap: `allowed ≈ 50 + 6·σ·√(dtSource/1800)` reaches ~650 bps at a full 1800 s
> stable gap. This is NOT a hard blocker (the cold-start push is floor-tight at `dt=0`, real σ lands after push 1,
> and Layer-4 refBand 100 halts cumulative drift), but seed the stable feeds with a smaller σ (e.g. a peg-realistic
> few-bp value) at `addFeed` to tighten the first post-gap push. Volatile 10000 is fine.

### 6.3. Layer 3: keeper push trigger θ (off-chain, `oracle.chapel.toml`)

Gates WHEN the keeper broadcasts, distinct from the on-chain accept band. Push fires on cold-start OR
`|Δ|/p_last > θ` OR heartbeat elapsed OR CI-spike (confidence widens ≥ 25 bps).

| Asset class | θ | heartbeat | ttl | mark_max_age |
|---|---|---|---|---|
| stables (idx 0-4) | **0.25 bp** | 1800 s | 7200 s | 500 ms |
| volatiles (idx 5-9) | **5 bp** | 300 s | 600 s | 500 ms |

`heartbeat ≤ ttl/2` is hard-enforced at startup. θ is the load-bearing LP shield (§5): a θ-stale mark = the pool
mis-centered by ≤ θ.

### 6.4. Layer 4: cumulative depeg band (`OracleConfig.refBandBps`, independent refPrimary)

A separate, operationally-independent reference oracle. A compromised primary quorum cannot walk the mark past
`refBandBps` of the independent ref without halting swaps (`PoolIO.priceBandGuard`). This is the cumulative bound,
not a per-push cap.

| Asset | refBand | refPrimary |
|---|---|---|
| USDC (both pools) | 0 (self) | none |
| USDT (both pools) | 100 (±1%) | USDC_FEED / REF_ORACLE |
| USD1 | 100 (±1%) | USDC_FEED / REF_ORACLE |
| USDE | 100 (±1%) | USDC_FEED / REF_ORACLE |
| FDUSD | 100 (±1%) | USDC_FEED / REF_ORACLE |
| XAUT | 200 (±2%) | XAUT_REF_ORACLE (independent XAUT/USDC) |
| BTCB / ETH / WBNB / CAKE | 0 | none (no independent peg) |

> **Reconciliation note.** An earlier proposal (2026-07-08 tape study) recommended a graded stable refBand
> (USDC 50 / USDT 100 / USD1 150 / USDe 200 / FDUSD 200). The **LIVE SSoT** (`testnet-asset-params.json` +
> `ChapelEnableSwaps`) uses a **flat 100 bps** for all non-USDC stable spokes and 200 for XAUT. Carry the LIVE
> flat-100 values at redeploy; the graded schedule is retained here only as historical context.

---

## 7. Signing and push: k-of-n (2-of-3 ECDSA)

Price authority is a k-of-n set of distinct EIP-712 signers, DECOUPLED from the gas-paying relayer.

- **Scheme.** ECDSA + EIP-712, domain `"BTR ExternalOracle"` / `"1"`,
  `BATCH_TYPEHASH = keccak256("BatchQuote(bytes32 blobHash)")`. Signers = **2-of-3** (init atomically ≥ 2-of-3,
  `2 ≤ threshold ≤ count`, `MAX_SIGNERS = 6`). `bytes sig` is kept opaque/swappable (Schnorr-ready); no Schnorr
  today.
- **Signer set = NXR attesters.** Each NX-Rates replica holds its own `NXR_SIGNER_KEY`. `/v1/quote/signed`
  self-signs and fans the blob to peers via `POST /v1/quote/cosign`; a peer countersigns ONLY after re-validating
  each record against its own live view (px-tolerance bps, sourceTs skew, σ/CI understatement guards). Below quorum
  returns 503 fail-closed. Response = `{blob, sigs[], oracle, chainId, sourceTs}`.
- **On-chain verify** (`batchPushSigned`): `sigs` = k concatenated 65-byte `r||s||v` over one digest; each recovered
  address MUST be strictly greater than the previous AND present in `signers` (strictly-increasing = distinctness;
  dups/unsorted fail). All sigs verified BEFORE any state write. `k ≥ signerThreshold`.
- **Independent reference oracles.** REF_ORACLE and XAUT_REF_ORACLE each carry their own 3 signers and their own AC
  owner, all distinct from the primary set (validated at deploy). This is what makes Layer-4 refBand a real
  independent guard.
- **Deploy env NAMES (never values):** `ORACLE_SIGNER_0/1/2`, `REF_ORACLE_SIGNER_0/1/2`,
  `XAUT_REF_ORACLE_SIGNER_0/1/2`, `XAUT_REF_FEED_ID`. Ctor:
  `new ExternalOracle(ac, maxRelayLagSecs=120, initialSigners[3], threshold=2)`.
- **Key handling.** Private keys live ONLY in NXR replica env (`NXR_SIGNER_KEY`) and the keeper relay
  (`KEEPER_PRIVATE_KEY`), never printed, logged, or committed (`keepers/.env.chapel` is gitignored). The relay key
  is **gas-only**, NOT price authority, NOT deployer, NOT admin. Signer grants + threshold DECREASES are timelocked
  (15 min Chapel, 7-day grace, one pending at a time); `revokeSigner` and threshold RAISE are instant; revoking
  below threshold deliberately HALTS pushing (fail-safe).
- **Relayer (public, unpermissioned).** Dedicated Chapel gas pusher
  `0xc4B4635B76ed49A7239291F6fbB33455D059a5B9` (segregated 2026-07-11). `msg.sender` is unpermissioned; distinctness
  and quorum are enforced on the signatures, not the sender.
- **Cadence.** Keeper daemon polls `/v1/quote/signed` every `poll_interval_ms = 5`; pushes `batchPushSigned(blob,
  sigs)` when any tracked feed is due (§6.3). All-or-nothing blob (one digest, k sigs, no per-feed fallback).
  Budgets: 50 ms submission, 500 ms settlement, 600 ms loop. Multi-keeper: deterministic soft-leader
  `keeper_set[H(sourceTs) % n]` + jittered fallback kills the SPOF and the O(N) revert storm. Runtime signer
  reconcile every 2 s (chain = source of truth) enforces guardian revoke / threshold raise live.

> **Open item (blocks live):** `oracle.chapel.toml` `signers = [...]` (3 public NXR attester addresses) and
> `signer_threshold = 2` are NOT yet pinned. The keeper is fail-closed until pinned
> (`chapel_config_is_fail_closed_until_signers_are_pinned`). MUST fill the public addresses before arming.

> **Precondition (verify BEFORE broadcast, not only post-deploy):** the default redeploy KEEPS the incumbent
> oracle `0xD917…F2bF`. That path assumes the incumbent already exposes the k-of-n hardening this doc relies on.
> Cast-check before the broadcast:
> - `signerThreshold()(uint8)` == 2 and `signerCount()(uint8)` == 3 on `0xD917…F2bF`. If either **reverts** (no
>   such selector) the incumbent predates the Ostium k-of-n hardening and CANNOT accept 2-of-3 `batchPushSigned`.
>   The fresh-oracle path (deploy sequence §11, runbook §5) then becomes **MANDATORY**, not optional.
> - `getFeed(USDC_FEED)` on `REF_ORACLE` and `getFeed(keccak(XAUT,USDC))` on `XAUT_REF_ORACLE` must NOT revert.
>   `addAsset` → `PoolAdmin.validateOracleConfig` calls `getFeed(refFeedId)` on the ref oracle
>   (`PoolAdmin.sol:110`); a ref oracle with no feed reverts the FIRST refBand≠0 asset (USDT) and unwinds the
>   ENTIRE broadcast. If the ref oracles are fresh, populate their feeds first.
> - `getMark` on all 10 primary feeds returns fresh (getFeed exists AND within ttl). Any revert → stop, fix feeds
>   or take the fresh-oracle path.

---

## 8. Deposit-cap schedule (stable-core, per asset, USD)

Testnet growth schedule $50K → $1M. Per-asset split = observed 3-month stable-stable volume weights
(USDC 35% / USDT 26% / USD1 27% / FDUSD 8.5% / USDe 3.5%). Raise the active tier via `setAssetParams` as TVL fills;
win-share by trade count (~23%) is TVL-invariant, volume-share and absolute fees scale up ($8k/yr @ $50K →
$111k/yr @ $1M).

| total TVL | USDC | USDT | USD1 | FDUSD | USDe |
|--:|--:|--:|--:|--:|--:|
| $50K | $17.5K | $13K | $13.5K | $4.3K | $1.75K |
| $100K | $35K | $26K | $27K | $8.5K | $3.5K |
| $250K | $87.5K | $65K | $67.5K | $21K | $8.75K |
| $500K | $175K | $130K | $135K | $42.5K | $17.5K |
| $1M | $350K | $260K | $270K | $85K | $35K |

USDe stays tiny (near-zero BSC flow + 477 bp depeg risk).

---

## 9. Fee calibration (sim-derived, retained)

Source: faithful 3-month state-machine simulation (`faithful_sim.ts`, 11.5M real BSC swaps replayed through the
live quote law) + 6-month HyperSync tape capture-sim. The fee is `minFee floor + σ·vega` (σ-driven, half path
spread charged).

minFee sweep @ $250K (trades trader-share against LP yield):

| minFee | win·trades | win·vol | LP net APR | read |
|--:|--:|--:|--:|---|
| 0.3 bp | 35% | 19% | 4.9% | traders win, LPs starved |
| 0.5 bp | 30% | 16% | 7.9% | |
| **1.0 bp** | **23%** | **12%** | **15.2%** | LP↔trader equilibrium |
| 1.5 bp | 18% | 8% | 22.5% | LP-rich, share fading |
| 2.0 bp | 10% | 5% | 24.4% | share collapses |

The 2026-07-12 postmortem raised the **stable** floor to **50 PBPS (0.5 bp)** (USDE 75, FDUSD 100) after a
minFee-0.1bp + center-bump + κ=0 config let bots drain FDUSD→USDC and dump BTCB into the volatile pool. gamma was
raised to 2x (inventory skew was too soft) and the profile flattened. The absolute protocol floor stays 1 PBPS
(0.01 bp), retained as a price-war lever only (drop via `setAssetParams`). The **volatile** floor is 1000 PBPS
(10 bp = 2θ) so the between-push mean-arb gate `center_error_mean ≤ minFee/2` holds.

---

## 10. Risk fences (Steward-lite hard bands)

`setRiskFences` per token clamps steward parameter moves. All bands: `maxDeltaBps = 2500` (±25% risk-up clamp per
move, NOT a price band), `haircutHardMax = 10000`, gammaMin 5000 / gammaMax 40000, vegaMin 5000.

| Band | Applies to | minFeeHardMin | minFeeHardMax | maxFeeHardMax | vegaHardMax |
|---|---|---|---|---|---|
| tight | all stable + volatile USDC/USDT | 50 | 2000 | 10000 | 20000 |
| wide | volatile BTCB/ETH/WBNB/CAKE/XAUT | 100 | 20000 | 50000 | 30000 |

The reseed uses `minFeeHardMin = 50` on stables. Live-patch scripts loosen it to 25 (FDUSD 50); carry the reseed
value (50) at redeploy unless a price war requires the 1 PBPS lever.

---

## 11. Deploy sequence and open reconcile items

Canonical full reseed = `ChapelEnableSwaps.s.sol`. Bootstrap order per pool: `createPool` →
`setCurve(preset)` for each referenced preset (BEFORE the first `addAsset`, `flags = FLAG_REQUIRES_WALL` on
`hyper`) → per-token `addAsset(…, presetId, minFee, 18, minDisp, maxDisp, gamma, vega)` → `setAssetParams`
(clamp maxFee, haircut = 0 if κ-walled) → `setRiskFences` → `sealBootstrap` → seed liquidity. Post-seal changes
are timelocked twins (`requestSetCurve`/`requestUpdateProfile` LOW ~5m, `requestOracleUpdate` BASE ~15m).

**Must reconcile before deploy:**

1. **Curve weights (BLOCKER).** `ChapelEnableSwaps._curve` ships the linear-ramp placeholder `wQ[i] = (i-4)*step`,
   knots `[2000,4000,6000,8000]` hardcoded, installs ONE preset per pool (`presetId = stable?2:1`) assigned to
   EVERY asset with `flags = 0`. This deploys the WRONG pricing with no revert. Replace with the fitted quartic
   from `research/stable-core/out/spline_shared_grid.json` (map `w` PBPS → PBPS·Q with Q = 1e9, `interiorX` →
   domain [0,10000]) as a per-`presetId` lookup, install `setCurve` for each of {10,11,12} stable / {20,21,22,23}
   volatile pre-seal with `flags = 1` ONLY on `hyper` preset 11, and select the per-asset `presetId` (§3/§4) in the
   `addAsset` loop. W2 presets use 13 interior knots / 18 wQ control points (14 segments); W0.5/W1/W5 use 9 interior
   / 14 wQ (10 segments). Do NOT broadcast the §4-baseline command until this patch lands.
2. **Signer pin (BLOCKER).** `oracle.chapel.toml` `signers` + `signer_threshold` empty → keeper won't arm (§7 open
   item). Add top-level `signers = [<3 public NXR attester addrs>]` + `signer_threshold = 2`.
3. **`maxDeviation` per feed.** Absent from scripts/toml; set at `addFeed`. Deploy the class floors (stable 50,
   volatile 100). Note maxDeviation is per-FEED: volatile USDC/USDT reuse the stable feeds already at 50 (§4 note),
   so only BTCB/ETH/WBNB/CAKE/XAUT carry 100. Owner may tighten per asset toward the refBand.
4. **JSON schema.** `sharedLiquidityProfile` `[50,100,50]` is the old Hermite shape; update the JSON to the
   preset-per-asset schema in §3/§4 so front/sim/docs read the new model.
5. **MockVenus.** vUSDC/vUSDT are not registered in the real Venus Unitroller; `claimVenus` reverts until swapped
   for real Chapel markets (`ChapelWireYield`).
6. **USDG** is in the stable SSoT list but has no Chapel mock: SKIP (5 stables ship).
7. **Incumbent-oracle capability + ref-feed preconditions (BLOCKER if unmet).** The default path keeps `0xD917…`.
   Cast-verify BEFORE broadcast (§7 precondition block): `signerThreshold()==2` and `signerCount()==3` on `0xD917…`
   (revert ⇒ predates k-of-n hardening ⇒ fresh-oracle path is MANDATORY); `getFeed` non-revert on `REF_ORACLE`
   (USDC_FEED) and `XAUT_REF_ORACLE` (`keccak(XAUT,USDC)`) or the first refBand≠0 asset (USDT) reverts the whole
   broadcast; `getMark` fresh on all 10 primary feeds.
8. **refBand SSoT flat-100.** Hold the LIVE flat 100 bps for all non-USDC stables + XAUT 200 (§6.4). Ensure
   `testnet-asset-params.json` is actually flat-100, NOT the retired graded schedule (USD1 150 / USDe 200). Open
   item: reconcile the SSoT file before deploy; do not let the graded values leak back in.
9. **Stable `minFeeHardMin`.** Carry the reseed `_fences` value **50** (§10). The live-patch scripts loosened it to
   25; do NOT carry 25 unless a price war needs the 1-PBPS lever.

**Live addresses (pre-redeploy):** Oracle `0xD91712c9F4037D0010041691Df191AB45994F2bF` (OLD_AC `0x626eb915…`),
Faucet `0x6a901982…`, Admin `0x71ad3486…`, STABLE pool `0xC954A27E…`, VOL pool `0x88d5EC4C…`,
USDC(base) `0x6dF80a29…`, USDC_FEED `0xdacab873…3ba17d`, WNATIVE `0xCAFE`, chainId 97. A fresh reseed deploys new
AC/Admin/Factory/pools; oracle + faucet + 10 mock tokens are KEPT.

---

## 12. What to watch on testnet

- **Coverage excursions per leg**: if a leg pins at the floor under sustained one-way flow, fix the keeper
  rebalance cadence (not the coverage band); confirm rebalancing stays ~2-4% of won volume.
- **θ freshness**: if realized LVR rises, tighten θ before touching fees. θ is the load-bearing LP shield.
- **USD1 feed**: youngest token; monitor NXR confidence + heartbeat, then tighten `plateau` W1 → `hyper` W0.5.
- **USDE depeg tail**: 477 bp historical; the wide `plateau` W2 shape + low cap + ±1% refBand + independent depeg
  breaker are the mitigation.
- **Post-testnet**: the structural edge (fresh-mark LVR recapture) pays far more in volatile pairs; the stable-core
  is the beachhead, the volatile-core is the revenue thesis.
