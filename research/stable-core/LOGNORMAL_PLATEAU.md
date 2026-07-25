# Split-family minimal-knot fee density: plateau stables, peaked volatiles (PREVIEW, unstaged)

Owner spec 2026-07-22 (log-normal-plateau) + owner SPLIT decision 2026-07-23. Status: prototype for
owner review. Nothing committed or staged. Artifacts: `lognormal_fit.py` (both optimizers, split
family) + `out/lognormal_fit.json` (unified emit incl referee J) · `referee_lognormal.py` +
`out/referee_lognormal.json` · `make_lognormal_overlay.py` + `out/density_overlay_lognormal.html` ·
`evm/test/gas/NUQuarticSetGas.t.sol` (measured gas). v4 candidates untouched
(`make_density_overlay.py` / `fit_results.json` / `referee_sim.py`).

## 0. The split (owner decision 2026-07-23)

The 07-22 referee showed the log-normal PLATEAU holds for stables but costs volatiles 79-96% of
fee-LVR J: the LN law has a crater at the mark (density -> 0 at 0 by construction) and replay fees
are a crossing measure concentrated near the mark, so the crater sheds exactly the depth that earns
(J-rank inverts KL-rank, known referee finding). Decision: SPLIT the shape family by asset CLASS,
both families inside the SAME sigma-ladder / minimal-knot / closed-form / soft-sat framework.

- STABLES -> PLATEAU family (unchanged): truncated log-normal target, m=3, pow2.0
  center-clustered knots.
- VOLATILES -> PEAKED family (new): center-peaked leptokurtic target = truncated Student-t core,
  nu = 1.5 (the referee-proven v4 lepto kernel, `spline_shared_grid.ts:175`), peak-width ratio
  c = 0.55·sigma_cell, ANCHORED so cell 0.40 gives c = 0.22 = the v4 lepto sFat/W exactly
  (BTC/ETH/BNB land on that cell: their continuous target IS v4 lepto). m=4, pow0.5 EDGE-clustered
  knots [0.1464, 0.5, 0.8536] (a peaked quantile curve is steep at the walls, not the center).
- Family choice is CLASS-GATED and deterministic (stable -> plateau, volatile -> peaked). It is
  NOT a per-asset argmin: no family flapping, no data-driven family switch on the keeper path.
- The peaked family is deliberately NOT a density match (klData 0.26-0.95 vs plateau 0.03-0.21):
  it is the fee-earning policy shape. The whole point of the split is that the referee J, not KL,
  arbitrates volatiles.

## 1. Spec (locked)

- Soft saturation Y = 2theta·tanh(d3/2theta) replaces the hard clip on BOTH families: clip-rail
  Dirac atoms gone, Hartigan dip p = 0.445-0.995 on all 11 assets, zero multimodal.
- ONE closed-form LN quantile fit drives scale + cell for BOTH families: mu = ln q50,
  sigma = ln(q90/q50)/1.2816, S_fit = exp(mu + 0.5244·sigma) (exact 30% tail cut by construction),
  S_dep = max(S_fit, 2·theta). Walls + minFee own the exceedance beyond S_dep.
- Both families' S-normalized quantile curves depend on sigma_cell ONLY (mu / S = pure scale,
  absorbed by S_dep): plateau via exp(sigma·(PPF(0.7v) - z70)); peaked via c·T_ppf((1 + v·F1)/2; nu)
  with c = 0.55·sigma_cell, F1 = 2·T_cdf(1/c; nu) - 1.
- Minimal knots: m=3 stables (2 interior), m=4 volatiles (3 interior) vs m=10 (9 interior) in v4.
  Good-enough gate: truncated-KL(family target || spline) <= 0.25 nats + single folded mode
  (mode counter is family-agnostic: even reflection at 0 + wall sentinels, so a CENTER mode
  counts 1, a wall pile counts 1, and a genuine M-shape counts 2).
- No search, no on-line RNG, no on-line BVLS, no on-line novel knots: keeper measures streaming
  quantiles -> closed-form (mu, sigma, S) -> sigma-cell snap -> pre-certified table lookup.
  Whitelist = ONE offline BVLS per (family, cell, m): 24 plateau cells (18 certified; 0.30 and
  0.35 low-m uncertifiable, no asset lands there) + 16 peaked cells (16/16 certified, klRepCell
  6e-05..0.0087, trough depth 1.0 = full center depth at the mark on every cell).
- minFee = 2·theta + excPrem, hard floors 50/100 pbps; dispRef 100/500; W ceil-ladder
  {0.5,1,2,5}; sigma freeze band [0.275, 0.675] (outside -> ship last-good + alert; PAXG today).
  Risk-param leg identical for both families (pure scalars, family-blind).

## 2. The two optimizers (prod, perpetual)

FEE-DENSITY leg (`lognormal_fit.py`, fam_pick): family = FAMILY[class] (deterministic gate);
sigma snaps to the nearest certified cell; the m-gate walks the class ladder (stables 3,4,5 on
plateau cells; volatiles 4,5 on peaked cells) and takes the FIRST m meeting the 0.25 gate with a
single folded mode; preset id = LN<cell>-m<m>[-wall] (plateau) / PK<cell>-m<m> (peaked). Keeper
never emits knots: shape updates are `requestUpdateProfile` repoints; `requestSetCurve` is the
offline library install path only. Volatiles also emit the plateau fit at the same S_dep/cell as
`altFit` (referee 3-way diagnostic, never shipped).

RISK-PARAM leg: unchanged from the 07-22 spec (W = ceil_ladder(S_dep); minDisp = round(S_dep·
dispRef/W); maxDispB99 wall floor; maxDisp HOLD ratchet; minFee = 2theta + excPrem; Hill
tail-alpha veto; dispatch = SLOW profile repoint / FAST bounded scalars, +-25% fences, seed
deadbands pending faithful_sim calibration).

Determinism: same input -> same output on both legs. Mirrors required byte-identical on fixtures:
py / pushsim.ts / keepers Rust.

## 3. Gas (measured, `evm/test/gas/NUQuarticSetGas.t.sol`, forge 2026-07-22)

Family does not change gas: cost is slots = 1 + 2m, identical for plateau and peaked at equal m.

| preset | segs | knots | slots | setCurve update | first-set |
|---|---|---|---|---|---|
| NEW stable plateau (m3) | 3 | 2 | 7 | 289,831 | 409,531 |
| NEW volatile peaked (m4) | 4 | 3 | 9 | 384,171 | 538,071 |
| OLD v4 (all 11 assets) | 10 | 9 | 21 | 951,321 | 1,310,421 |

Savings per update: stables -661,490 (-70%); volatiles -567,150 (-60%, CONFIRMED for the peaked
m4 presets: same slot count, family-blind); roster average (4 stable + 7 volatile) -63%. One-time
class library install now covers both families (8 plateau-m3 + 8 peaked-m4 cells per pool deploy).

## 4. Fit numbers (all 11 assets, `out/lognormal_fit.json`)

All: dip UNIMODAL (p 0.445-0.995), klRep <= 0.25 met at the class-default m, no m-escalation, no
gate failure. Peaked klRep is 2 orders tighter than plateau (0.000-0.002 vs 0.13-0.17): the m=4
edge-clustered quartic renders the t-core almost exactly, so the referee delta vs v4 is nearly
pure S_dep + m-approximation. klData on peaked is large BY DESIGN (policy shape, not a density
match). theta unchanged vs v4 on every asset (no theta bundle).

| asset | class | family | sigma -> cell | m | klRep | klData | dip p | S_dep bp | cut% |
|---|---|---|---|---|---|---|---|---|---|
| USDT | stable | plateau | .6012 -> 0.60 | 3 | .138 | .036 | .835 | .560 | 32 |
| USD1 | stable | plateau | .6235 -> 0.60 | 3 | .134 | .066 | .445 | .677 | 33 |
| USDE | stable | plateau | .5842 -> 0.60 | 3 | .141 | .206 | .475 | 1.006 | 29 |
| FDUSD | stable | plateau | .5357 -> 0.55 | 3 | .166 | .028 | .715 | .624 | 32 |
| BTC | volatile | peaked | .3852 -> 0.40 | 4 | .002 | .937 | .985 | 10.918 | 34 |
| ETH | volatile | peaked | .4134 -> 0.40 | 4 | .002 | .847 | .990 | 10.959 | 33 |
| BNB | volatile | peaked | .3852 -> 0.40 | 4 | .002 | .946 | .850 | 10.797 | 34 |
| CAKE | volatile | peaked | .5394 -> 0.55 | 4 | .000 | .436 | .940 | 15.502 | 32 |
| EURC | volatile | peaked | .5901 -> 0.60 | 4 | .000 | .255 | .870 | 10.0 (2theta floor) | 15 |
| XAUT | volatile | peaked | .4564 -> 0.45 | 4 | .001 | .677 | .995 | 10.966 | 33 |
| PAXG | volatile | (peaked, diag) | 1.011 OUT-OF-FAMILY | 4 | .035 | .635 | .955 | 17.96 | 15 |

PAXG: FREEZE at last-good + alert (sigma-hat outside [0.275, 0.675]); the peaked row is
diagnostic, not a ship candidate. EURC (4.5d tape) + XAUT (feed QC) remain PROVISIONAL.

## 5. Referee (damped fee-LVR replay, `referee_lognormal.py`, 3-way on volatiles)

referee_sim.py machinery verbatim: same tapes, push paths, h = theta + excPrem/2, crc32 seeds per
L{1,3,6} x T{0.25,1,4} cell. Harness validated (v4 USDT reproduces -121.4 exactly). Volatiles
replay BOTH the chosen peaked preset AND the altFit plateau preset at the same S_dep/cell, so the
J the plateau lost and the J the peaked recovers are measured in one run, shape-only delta.
Baseline = v4 as-deployed (candidates[0] in `out/referee_results.json`). The plateau leg
reproduces the 07-22 run exactly (48.0 / 528.4 / 226.4 / -5769.2).

Stables (plateau, unchanged from 07-22): USDT -141.0 vs -121.4 (-16%), USD1 -581.7 vs -554.0
(-5%), USDE -2347.0 vs -2439.8 (+4%), FDUSD -177.8 vs -152.5 (-17%). HOLD.

Volatiles (3-way, J APR pts):

| asset | J v4 (m10) | J plateau-LN (m4) | J peaked (m4) | peaked vs v4 | recovered vs plateau |
|---|---|---|---|---|---|
| BTC | 1211.1 | 48.0 (-96%) | 1147.0 | -64.1 (-5.3%) | +1099.0 |
| ETH | 2468.4 | 528.4 (-79%) | 2363.2 | -105.2 (-4.3%) | +1834.8 |
| BNB | 1320.3 | 226.4 (-83%) | 1266.0 | -54.3 (-4.1%) | +1039.6 |
| CAKE | -4779.3 | -5769.2 (-21%) | -4863.6 | -84.3 (-1.8%) | +905.6 |

HEADLINE: the peaked family RECOVERS the volatile J the plateau lost. Residual vs v4 is
-1.8..-5.3% (vs the plateau's -79..-96%), i.e. peaked ~= v4 lepto at the minimal-knot gas saving;
the residual is the m=10 -> m=4 approximation + the (slightly wider) closed-form S_dep, and it
sits inside the same -5..-17% band the stables already accepted as the gas trade. HONEST FLAGS:
(1) no volatile still loses materially, but none IMPROVES on v4 either - the split buys gas and
determinism, not J; (2) CAKE's v4 was platy, not lepto - the peaked cell 0.55 (wider peak,
c = 0.30) lands within 1.8% of it, which validates the c = 0.55·sigma_cell width map;
(3) EURC/XAUT/PAXG have no referee tape - peaked is applied there by class gate, unrefereed.

## 6. OLD vs NEW per asset

| asset | old (v4) | new preset | knots | slots | gas upd | W | minDisp | maxDisp | minFee pbps |
|---|---|---|---|---|---|---|---|---|---|
| USDT | plateau W0.5 | LN0.60-m3-wall | 9 -> 2 | 21 -> 7 | 951k -> 290k (-70%) | 0.5 -> 1 | 103 -> 56 | 6000 (HOLD) | 62 -> 61 |
| USD1 | flat W1 | LN0.60-m3-wall | 9 -> 2 | 21 -> 7 | -70% | 1 | 75 -> 68 | HOLD | 80 -> 80 |
| USDE | flat W1 | LN0.60-m3-wall | 9 -> 2 | 21 -> 7 | -70% | 1 -> 2 | 101 -> 50 | HOLD | 106 -> 106 |
| FDUSD | plateau W0.5 | LN0.55-m3-wall | 9 -> 2 | 21 -> 7 | -70% | 0.5 -> 1 | 107 -> 62 | HOLD | 63 -> 63 |
| BTC | lepto W5 | PK0.40-m4 | 9 -> 3 | 21 -> 9 | 951k -> 384k (-60%) | 5 | 1000 -> 1092 | HOLD | 1015 -> 1015 |
| ETH | lepto W5 | PK0.40-m4 | 9 -> 3 | 21 -> 9 | -60% | 5 | 1000 -> 1096 | HOLD | 1032 -> 1032 |
| BNB | lepto W5 | PK0.40-m4 | 9 -> 3 | 21 -> 9 | -60% | 5 | 1000 -> 1080 | HOLD | 1011 -> 1011 |
| CAKE | platy W5 | PK0.55-m4 | 9 -> 3 | 21 -> 9 | -60% | 5 | 1286 -> 1550 | HOLD | 1560 -> 1560 |
| EURC | lepto W5 | PK0.60-m4 | 9 -> 3 | 21 -> 9 | -60% | 5 | 1000 -> 1000 | HOLD | PROVISIONAL |
| XAUT | lepto W5 | PK0.45-m4 | 9 -> 3 | 21 -> 9 | -60% | 5 | 1000 -> 1097 | HOLD | PROVISIONAL |
| PAXG | lepto W5 | FREEZE last-good | (diag PK0.65-m4) | - | - | - | - | HOLD | FREEZE + alert |

4 old regimes (plateau/flat/lepto/platy in use) collapse to TWO class families x one sigma
continuum; the binary hyper/platy swing is dead. BTC/ETH/BNB all land on the peaked 0.40 cell
whose continuous target is v4 lepto exactly; CAKE's wider 0.55 cell absorbs the platy case.

## 7. Downstream regen list (IF adopted)

1. `make_density_overlay.py`: :350-351 clip -> tanh; :356-373 v4 argmin -> class-gated family +
   closed-form + snap; regen `out/fit_results.json`; re-merge `out/density_basis_v2.json`.
2. Preset library: 40-cell certified successor to `out/spline_shared_grid.json` (BVLS at cell
   centers, both families); `referee_sim.py` candidate source moves from the 9-catalogue to the
   family cell presets.
3. `back/services/collector/src/density/pushsim.ts`: mirror soft-sat + closed-form fit + family
   gate (byte-identical fixtures).
4. `keepers/src/risk/fit.rs` + `keepers/src/risk/fences.rs` (unbuilt): streaming quantiles,
   closed-form legs, class-gated family select, deadband/fence pre-tx mirror; arm
   `RISK_EXECUTE=1` only after faithful_sim.ts tau/halflife calibration (no-thrash).
5. `UPKEEP_FRAMEWORK.md`: sections 2.2/3/4 + tasks 12/17; minFee text 2theta -> 2theta + excPrem;
   document the family gate (class-static, not keeper-switchable).
6. evm scripts: Chapel/testnet preset install to the two-family cell library (`requestSetCurve`
   ids), pool deploy class-cell install; no interface/ABI change (presetId assignment only).
7. Adoption gates before any of the above: owner review -> referee J-replay on the certified
   cells (done for the 8 taped assets, this doc) -> faithful_sim tau calibration -> code deltas.

## 8. Verdict

ADOPT-WORTHY FOR BOTH CLASSES. Stables: -70% setCurve gas, 2-knot plateau presets, single-mode
confirmed, referee J within -5..-17% (one +4%). Volatiles: the class-gated peaked family (t-core
nu=1.5, c = 0.55·sigma_cell, m=4) RECOVERS the J the plateau lost (BTC 48 -> 1147 vs v4 1211;
ETH/BNB/CAKE analogous), landing within -1.8..-5.3% of v4 at -60% setCurve gas: peaked ~= v4
lepto at the minimal-knot saving. Referee-lock the split (this run) and proceed to the downstream
regen list on owner go. PAXG freezes out-of-family either way; EURC/XAUT ship class-gated peaked
provisionally pending feed QC + referee tape.
