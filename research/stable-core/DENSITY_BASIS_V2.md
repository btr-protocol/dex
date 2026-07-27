# DENSITY BASIS v2: reconciled fee-kernel estimator (proposal)

Status: REFEREED 2026-07-22 (section 8) + ADOPTED into canon same day. The
consumption-sim referee scored every v2 candidate by replayed fee-minus-LVR J; verdict:
ADOPT v2 for USD1 + USDE only, KEEP v3 shapes everywhere else. The two-kernel estimator
below is now the CANONICAL shape basis: folded into `make_density_overlay.py` (gen v4 ->
`out/fit_results.json` + `out/density_overlay.html`), with deployed params frozen to the
referee decisions in `out/density_basis_v2.json`. The standalone prototype
`density_basis_v2.py` was removed after the fold (single script, no parallel estimators).
Referee: `referee_sim.py` -> `out/referee_results.json` + `referee` fields merged into
`out/density_basis_v2.json`; rerun it before adopting any preset/theta/cadence change.

## 1. The formula

Two kernels, ONE deployed density. Both verdicts (quant arbitration + MM) agree on the
split; this locks their intersection.

FEE kernel (spline SHAPE target): law of the tethered quote offset,

    ell_hat = law of |G + U + Y|        (independent draws, N = 400k, seed 7;
                                         equals convolution g_theta * U(-h,h) * pi_clip)

    G ~ v3 push_offsets law, UNCHANGED (uniform draws over bar-close samples of
        1e4*(ln P - ln M), M = theta_final-cross + heartbeat push sim). Carries the
        reset-bridge tent, overshoot, heartbeat, tape quantization. This is how the
        CURRENT MARK enters: fast kernel of the convolution, never a 4th mixture member.
    U ~ Uniform(-h, +h), h = minFee/2 = theta_final. Arb tether: pool mid floats freely
        inside the half-spread of truth (Pricing.sol:198-200), no arb corrects within it.
    Y ~ clip(d_tau, +-2*theta_final), drawn with prob proportional to dt*sigma2
        (level-crossing weighting of the SLOW kernel only). d = 1e4*(ln P - ln C_tau);
        C = winsorized flow-EMA gravity center (two-pass: pass1 raw -> h_w = q70|d|;
        pass2 winsorizes the center input at +-h_w). Equal-weight mixture over
        tau in {tau_inv/2, tau_inv, 2*tau_inv}. The clip is the AIMM restoring band
        (restoring-band invariant): quote offsets beyond minFee/2 + theta = 2*theta_final
        are arb-restored, so channel divergence beyond the band piles up AT the rail
        (shoulder mass), it cannot occupy larger offsets.

Fit: existing v3 machinery unchanged. Truncated-KL, bins 61/81/101, cut band 25-35%,
segment/W tie-break, hyper behind the kappa-wall (stables only). S_dep = max(S_fit,
2*theta_final).

LVR kernel (tails, wall, floors): UNCHANGED v3, exceedance-only, never dwell:
wall floor = max(push-instant exceedance q99, b99_6min, session-open b99 [fx branch]);
maxDispB99 = band top containing b99_6min; minFee = 2*theta_final. Rationale: zero
benign crossings beyond theta in truth-vs-mark (counter_offset_decomp, 0/33537), so
dwell histograms are silent past theta at push instants; channel q99 undersizes depeg
walls 35-40% (USDE chan 5.3 vs push-exc 8.6).

## 2. Constants (every one auto or protocol-derived, zero hand-tuning)

| constant | value | how set |
|---|---|---|
| theta_final | per asset | v3 cadence-cap ladder: max(spec theta, theta@100/h), from fit_results.json |
| tether h | theta_final | protocol identity minFee = 2*theta -> h = minFee/2 |
| rail clip | 2*theta_final | restoring-band restoring band = minFee/2 + theta |
| tau_inv | 4h stable / 1h volatile / 2h fx-metal | iteration-0 class defaults; derive TVL*dc_band/flow once pool flow data exists |
| TFs | tau_inv * {1/2, 1, 2} | robustness ensemble around unknown tau_inv |
| winsor h_w | q70(|d|) pass-1, per (asset, tau) | containment-70 = the 30% cut target |
| sigma2 EWMA halflife | 30*tf (300 s) | << tau_inv; measured insensitivity: ell q50 moves <2.5% over {15,30,90}*tf on all 3 assets |
| burn-in | 3*max(tau) | center convergence |
| dt cap / glitch clip / bins / cut band / tie-break / S_dep floor | v3 values | unchanged |

## 3. Why it beats offset-from-mark (v3 basis)

1. v3 measures the PUSH POLICY, not the asset: the offset-from-mark core is the Green's
   function of theta-killed BM (tent, width set by theta + cadence). Proof in-tape:
   hyper (which fits the tent spike) is no longer near the top on the new target for
   USDT; it fit the artifact, not the dwell.
2. Fees are a crossing/occupation measure of the QUOTE offset, which carries the arb
   tether (U) and the persistent inventory-skew offset (Y) stacked on the moving mark.
   v3's |G| alone puts 65-93% of mass inside 1*theta while the measured traded-volume
   dwell there is only 12-25% (band tables below).
3. The raw channel (owner v1 proposal) is the right slow variable but the wrong
   coordinate unclipped: it equals a lagged-mark reparametrization (+-8-15% on 4 assets)
   and strands mass at mechanically unreachable offsets (BTC 26% beyond push q99).
   The 2*theta rail clip fixes both: rail-excess dwell (53-69% dt-weighted) is
   collected AT the shoulder where the pool actually earns it.
4. Tails stay exceedance-owned: new-basis mass beyond the push-exceedance q99 is
   0.14-0.67% (vs 26% for the unclipped channel on BTC) - no dead capital, no
   dwell-sized walls.

## 4. Validation (14d tapes, 10s bars)

Distribution stats, OLD = v3 |offset-from-mark|, NEW = ell_hat (same binning for H):

| asset | basis | q10 | q25 | q50 | q70 | q90 | q99 | exKurt | H nats |
|---|---|---|---|---|---|---|---|---|---|
| USDT (theta 0.257) | OLD | 0.024 | 0.07 | 0.168 | 0.297 | 0.602 | 1.407 | 6.1 | 3.348 |
| | NEW | 0.096 | 0.232 | 0.438 | 0.616 | 0.913 | 1.639 | 0.7 | 3.878 |
| BTC (theta 5.0) | OLD | 0.30 | 0.78 | 1.74 | 2.78 | 4.53 | 8.36 | 397.7 | 3.021 |
| | NEW | 3.22 | 6.02 | 9.19 | 11.62 | 14.78 | 18.97 | 2.0 | 4.121 |
| PAXG (theta 5.0) | OLD | 0.17 | 0.57 | 1.72 | 3.40 | 36.5 | 167.0 | 25.1 | 1.754 |
| | NEW | 5.01 | 7.41 | 10.66 | 13.43 | 38.2 | 166.6 | 22.5 | 2.454 |

Flatter/wider CONFIRMED: q50 x2.61 / x5.27 / x6.18, entropy +0.53 / +1.10 / +0.70 nats,
kurtosis collapses (BTC 398 -> 2.0). Moderately peaked, not uniform: q50 = 1.7-2.1 theta,
matching the arbitration's 1.55-1.75 theta prediction (sigma2 Y-weighting adds the rest).

Dwell reflection CONFIRMED (mass % in theta-unit bands [0-1, 1-2, 2-4, >4]; ACT = where
price actually traded = volume-weighted channel offset, tau_inv TF, unclipped,
constructed independently of G, U and the clip):

| asset | ACT (volume) | ACT (sigma2) | OLD basis | NEW basis |
|---|---|---|---|---|
| USDT | 25 / 21 / 28 / 26 | 22 / 19 / 27 / 32 | 65 / 21 / 11 / 3 | 28 / 31 / 34 / 7 |
| BTC | 16 / 13 / 16 / 55 | 10 / 10 / 10 / 70 | 93 / 7 / 0 / 0 | 19 / 38 / 43 / 1 |
| PAXG | 12 / 11 / 23 / 53 | 3 / 3 / 6 / 89 | 79 / 5 / 3 / 13 | 10 / 35 / 41 / 14 |

Traded-volume dwell captured inside the fitted support: USDT 26.7% -> 52.8%, BTC 9.9% ->
32.9%, PAXG 10.1% -> 33.6%. The remaining >4 theta ACT mass is mechanically unreachable
(rail): it trades against the shoulder/wall, where NEW places 34-43% of its mass vs OLD's
0-11%. Dead capital beyond the push-exceedance q99: 0.67% / 0.14% / 0.18%.

Policy probes: theta x2 moves NEW q50 by x1.5 / x1.86 / x1.92 (levers h and rail scale
with theta BY DESIGN = policy covariance, sub-linear vs the x2 lever; residual structure
rail% and alpha are theta-free). sigma2-halflife {15,30,90}*tf moves q50 <2.5%.
alpha (dwell tau-scaling): USDT 0.30 (stationary peg structure), BTC 0.62, PAXG 0.53
(RW: unclipped dwell width would be pure horizon artifact; the rail clip is what makes
the slow kernel usable for them). Rail fraction (dt / sigma2-weighted): USDT 53/58%,
BTC 60/81%, PAXG 69/94%.

## 5. Refit deltas (v3 optimizer machinery on the new target)

| asset | v3 deployed | v3 KL on new target | v2 pick | v2 KL | S_dep bp | minDisp |
|---|---|---|---|---|---|---|
| USDT | plateau W0.5, S_dep 0.513 | 0.0361 | flat W1 | 0.0175 | 0.513 -> 0.626 (+22%) | 103 -> 63 |
| BTC | lepto W5 (forced), S_dep 10.0 | 1.0144 | flat W1 | 0.112 | 10.0 -> 12.0 (+20%) | 1000 -> 1201 |
| PAXG | lepto W5 (forced), S_dep 10.0 | 1.489 | flat W1 | 0.3302 | 10.0 -> 14.3 (+43%) | 1000 -> 1428 |

Shape change: the tethered composite is flat-topped across +-2 theta with rail
shoulders, so the whole flat family (W1/W2/W5 within 3%) wins; plateau W0.5 is the
close runner (USDT 0.0236). Hyper is gone from the leaderboard (it fit the v3 tent
artifact). Support widens +20-43%, in line with the arbitration's +13-23% (stables) /
+3-20% (volatiles) envelope plus the sigma2 shoulder weighting. Wall/maxDisp move NOT
AT ALL: BTC maxDispB99 3657 (36.6bp) and PAXG wall floor 254bp come from the unchanged
LVR kernel. PAXG stays PROVISIONAL (KL 0.33 = mismatch tier; indicative-feed noise,
q99.9 |r1| ~286bp; keep v3 deploy until feed QC).

## 6. Open before adoption (owner + referee)

1. Consumption-sim referee (A1): replay J = fee - LVR per $ for v2 pick vs v3 deployed
   vs plateau runner, damped fixed-point (1-2 iters, Y replaced by replayed skew dwell),
   latency x turnover sweep. Both verdicts make this the ground truth, KL is projection
   only. Regime call flat-vs-plateau lands here. RESOLVED: section 8.
2. W-tier decision for volatiles: flat W1 drops the lepto W5 gap-day wings; wall
   containment moves entirely to maxDispB99 + minFee. LP-safety call, needs the referee.
   RESOLVED: referee keeps lepto W5 (J gap +778..+1328 APR pts over flat/plateau).
3. tau_inv derivation from TVL*dc_band/flow (replaces class defaults).
4. Trade-size distribution for outer-band fee credit (large sweeps are the only fee
   source beyond the rail).
5. PAXG/XAUT/EURC: rerun after NXR feed QC; EURC 2*theta floor likely still binds.

## 7. Downstream to regenerate if adopted

1. `make_density_overlay.py`: swap the shape-target basis to ell_hat (LVR half stays); regen
   `out/fit_results.json` + `out/density_overlay.html` for ALL assets including fallback rows.
2. Back density service TS port: `back/services/collector/src/density/pushsim.ts` + `service.ts`.
3. Sepolia risk params: `evm/deployments/sepolia-risk-params.json` (live deploy SoT).
4. Rerun `consumption_sim.py` referee on the adopted presets before any param freeze.

## 8. REFEREE: damped consumption replay, FINAL per-asset params (2026-07-22)

Referee = `referee_sim.py` on the consumption_sim mechanism: real theta-trigger +
heartbeat push (keeper latency L bars: crossing-time value lands L-1 bars later), arb
tether at half-fee h, two-sided uninformed noise flow, 14d NXR 10s tapes. The
density-match KL of sections 4-5 is a proxy; the objective is replayed
J = (fee_captured - LVR) / TVL, annualized %, averaged over the robustness sweep
latency {1,3,6} bars x turnover {0.25,1,4} x TVL/day (9 cells, noise seeds fixed per
cell and shared across candidates). Fee floor h = minFee/2 = theta + E[(|G|-theta)+]/2
(protocol minFee identity, exceedance premium measured per asset from the L=1 mark
-offset law). Dynamic vol-scaled fees are NOT modeled: J is the minFee-floor lower
bound. Candidates per asset: v3 deployed + v2 pick + shippable close runners (equal-S
flat-family W tiers dedupe: same regime at equal S_dep is the same bp-space curve).

Damping (MANDATORY; the undamped projection loop flips netAPR -284 -> +683): each
fixed-point round replays, blends (1-l) deployed + l measured consumption density with
l = 0.4, projects onto the preset library (v3 truncated-KL machinery), redeploys.
4 rounds at the central cell per candidate. CONVERGENCE: projections stabilize by
round 2 on every asset x candidate (fp_stable true 24/24), no oscillation; round-drift
of netAPR <= 17 APR pts on stables. Fixed points: stables -> flat W1 at the 2-theta
floor; BTC/ETH/BNB -> plateau W0.5 at S 10; CAKE -> flat W1 at 12.86. The projection
fixed point is NOT the J optimum (see finding 2): it is a stability check only.

### Final decision table (gates: J>0 / q50-theta-covariance / dwell-improves / wall>=exc-q99)

| asset | decision | regime | W | S_dep bp | minDisp | maxDispB99 | J APR% | J vs v3 | why this over runner-up | gates |
|---|---|---|---|---|---|---|---|---|---|---|
| USDT | KEEP v3 | plateau | 0.5 | 0.513 | 103 | 370 | -121.4 | 0 | narrow beats wide plateau S0.633 (-131.2) in all 9 cells, gap 10.8 > 5% tol | F/P/P/P |
| USD1 | ADOPT v2 | flat | 1 | 0.748 | 75 | 437 | -567.2 | -13.2 | J-tie with v3 (gap < 27.7 tol) -> KL tie-break 0.0365 vs 0.0446; dwell 52.0 -> 60.5% | F/P/P/P |
| USDE | ADOPT v2 | flat | 1 | 1.008 | 101 | 864 | -2381.3 | +58.5 | only stable where widening pays (depeg-tail tape, b99_6 7.07); flat W5 runner within 3.8 (tie) -> seg/W tie-break | F/P/P/P |
| FDUSD | KEEP v3 | plateau | 0.5 | 0.534 | 107 | 500 | -152.5 | 0 | beats wide plateau S0.691 (-164.8) by 12.3 > 7.6 tol | F/P/P/P |
| BTC | KEEP v3 | lepto | 5 | 10.0 | 1000 | 3657 | +1211.1 | 0 | concentration wins: plateau S12 +394.5, flat S12 +372.1; 3.1x runner-up J | P/P/P/P |
| ETH | KEEP v3 | lepto | 5 | 10.0 | 1000 | 5074 | +2468.4 | 0 | +1328 over plateau S12.06; every cell positive | P/P/P/P |
| BNB | KEEP v3 | lepto | 5 | 10.0 | 1000 | 3152 | +1320.3 | 0 | +777.7 over plateau S11.98 | P/P/P/P |
| CAKE | KEEP v3 | platy | 5 | 12.863 | 1286 | 5758 | -4779.3 | 0 | least-bad of set (+708.6 over plateau S16.8); deficit is cadence, not shape | F/P/P/P |
| EURC | keep v3, PROVISIONAL | lepto | 5 | 10.0 | 1000 | 1223 | n/a | n/a | fx feed QC pending (session gaps, indicative pricing) | not refereed |
| XAUT | keep v3, PROVISIONAL | lepto | 5 | 10.0 | 1000 | 4927 | n/a | n/a | metal feed QC pending (held per wizard review) | not refereed |
| PAXG | keep v3, PROVISIONAL | lepto | 5 | 10.0 | 1000 | 22804 | n/a | n/a | indicative-feed noise (q99.9 |r1| ~286bp), KL mismatch tier | not refereed |
| U/USDG/USDF/USDTB | class default, PROVISIONAL | plateau | 1 | 0.73 | 73 | n/a | n/a | n/a | no referee tape | not refereed |

maxDispB99 of winners recomputed as max(ceil(wall_floor * dispRef / W), minDisp),
wall_floor = max(push-exceedance q99, b99_6min, session-open b99) per the unchanged
LVR kernel; wall span >= push-exceedance q99 verified on every refereed asset.

### Findings

1. J>0 exactly on the cadence-unconstrained assets: BTC 24.4, BNB 21.3, ETH 39.9
   pushes/h pass; every cadence-capped asset (4 stables + CAKE pinned at the 100/h
   cap) runs a structural LVR deficit at the minFee floor (-121 USDT to -4779 CAKE).
   With theta_final inflated by the cap, the pool pays adverse edge faster than floor
   fees accrue. Levers are fee/cadence, not shape: dynamic vol fees (unmodeled here),
   push-cost reduction to relax the cap, or wider minFee. Shape deltas move J by <15%
   of the deficit.
2. The v2 dwell-matching basis systematically over-widens: on 6/8 refereed assets the
   J-ranking inverts the KL-ranking (v3 lepto W5 scores KL 0.93-1.05 on the new target
   yet beats the KL-optimal flat W1 by +778..+1328 APR pts). Fees are a crossing
   measure concentrated near the mark; depth at the dwell shoulders earns fewer
   crossings per unit depth. Density-match stays a diagnostic, not the deploy criterion.
3. J improves with keeper latency on cadence-capped assets (USDT L1 -157 -> L6 -48):
   each landed push re-anchors the curve and forces an arb round-trip (re-peg churn),
   so fewer landed pushes lose less. Volatiles: L1 is the worst cell but stays
   positive (BTC +832).
4. Turnover {0.25..4}xTVL/day moves J by <5 APR pts: floor noise-fee revenue
   (3.65 * T * h_bp % APR) is negligible vs arb flow. Floor J is arb-economics-driven.
5. theta x2 probe: fitted q50 (projected preset S x shape-q50) tracks the lever within
   3.3% on all refereed assets (policy covariance, not tape artifact).
6. Caveat: the replay books flow-LVR (arb edge on executed volume) only; inventory
   mark-to-market while wall-pinned is unbooked. Pinned share: volatiles <=0.4%,
   stables 3-11%, narrow > wide by ~1.5pt, so the narrow-stable J edge is slightly
   flattered; the USDT/FDUSD gaps (10.8, 12.3) exceed this.

### Downstream (supersedes the section 7 scope)

Adoption = USD1 + USDE rows only. Regen limited to: `out/fit_results.json` USD1/USDE
rows, collector density TS mirror (2 rows), and Sepolia risk-param rows for those assets.
All other assets keep v3 params unchanged; the fee-kernel estimator stays as the diagnostic
layer. The consumption-sim referee is the param freeze gate: rerun `referee_sim.py` on any
preset, theta ladder, or feed-cadence change.

2026-07-22 addendum: the 23-asset Sepolia roster was completed in `fit_results.json` via
UNREFEREED v4 fits (USDS/DAI/PYUSD/RLUSD/GHO/TUSD/AUSD, fresh 14d tapes), a NAV-aware
widened class-default fallback (syrupUSDC) and routed rows (WETH/WBTC/cbBTC = ETH/BTC
feed params), all pending tape maturity + adaptive-keeper refit + a referee_sim run.
