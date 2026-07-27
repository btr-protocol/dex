# BTR AIMM Upkeep Framework

Formal specification of the adaptive density to risk-param methodology, the tail-cut rule, the divergence-triggered update policy, the risk-param-upkeep keeper design, and the unified upkeep-task registry.

Scope: the perpetual off-chain automation that keeps the on-chain AIMM risk surface calibrated to the live tape, and the security guardrails that bound it. This is the single source of truth for what upkeep exists, what is built, and what remains to build (see [Implementation TODO](#implementation-todo)).

Grounded against source. Every lever named below is verified to exist on-chain:

- `keepers/src/main.rs` (single `OracleKeeper` subcommand today)
- `dex/evm/src/Admin.sol`, `dex/evm/src/libraries/AdminRiskSteward.sol`
- `dex/evm/src/oracles/ExternalOracle.sol`
- `dex/evm/src/libraries/NUQuartic.sol` (`set`, `_validate`, `FLAG_REQUIRES_WALL`)
- `dex/research/stable-core/RISK_PARAMS_TESTNET.md`, `push_sim.py`, `faithful_sim.ts`, `out/spline_shared_grid.json`

Cross-references:
- Risk-param tables and regime map: [`research/stable-core/RISK_PARAMS_TESTNET.md`](./research/stable-core/RISK_PARAMS_TESTNET.md)
- Curve validation and wall gate: [`evm/src/libraries/NUQuartic.sol`](./evm/src/libraries/NUQuartic.sol)
- Guardian fast-freeze levers: memory `project_btr_guardian_role_matrix`
- Pause scope model: memory `project_dex_pause_scope_settled`
- Risk-param governance (no timelock on risk params, dedicated risk role): memory `project_btr_risk_param_governance`

---

## 1. Methodology: adaptive density to risk-param

### 1.1 The estimand is offset-from-pushed-mark, not bar-return

The keeper measures the signed relative offset of the traded price from the last pushed mark:

```
d_t = (P_t - M_t) / M_t          # signed relative offset [pbps], center identically 0
```

Center is 0 by construction. The mark absorbs drift on every theta-crossing, so A-S inventory skew carries the asymmetry, not the density. The fit is symmetric and there are no `skew_*` presets.

This is the single load-bearing methodology fix. It replaces the `RISK_PARAMS_TESTNET.md` sections 3 and 4 single-bar-return tables (the `heartbeat -> 0` degenerate limit) with a deterministic replay of the live trigger. The mark path is reconstructed exactly as the push keeper produces it, reading the live trigger config from `oracle.chapel.toml`:

```
M <- p_0
for each tick p_t:
    if |ln(p_t / M)| > theta  OR  (t - t_last) >= heartbeat  OR  CI-spike:
        M <- p_t;  t_last <- t
    record d_t = (p_t - M) / M
```

Reuse `research/stable-core/push_sim.py`, ported to Rust sharing `nxr-sdk::BarFile`. Sample `d_t` at real swap timestamps when available, else uniform wall-clock time. Sampling at swap times auto age-weights the between-push horizon: one offset density at native resolution is the correct multi-horizon composite, with no hand-blended multi-TF.

### 1.2 Two windows

Per asset, two windows run in parallel:

- Fast body window: EWMA, halflife H_body around 2 to 3 days. Adaptive params breathe here.
- Long safety window: `max(all-history, 60-90d)`, unweighted. Floors ratchet here. This window must remember rare depegs that the body EWMA forgets.

Rule: adaptive params breathe on the fast window; safety floors ratchet on the long window, tighten-only.

### 1.3 Estimators

- Body / sigma: Parkinson-EWMA, never raw stdev. MAD / IQR-core for dispersion.
- Shape: Student-t / NIG MLE on the trimmed core, giving `kurt`, `skew` (test sign-stability across TF).
- Tail: GPD peaks-over-threshold for smooth `b95 / b99 / pegMaxDev` quantiles, not the noisy empirical max.
- Tail index: Hill on top order stats, threshold by Hill-plot / AMSE-min, bootstrap CI on alpha.

Cleaning: drop `tick_count == 0` synth-fill bars; Hampel/MAD filter k=7; cross-estimator convergence gate. Accept rvol only where close-to-close, Parkinson, and IQR-core converge, else quarantine (the XAUT discipline: do not seal contamination).

Feature vector: `{sigma_body, kurt, tailalpha + CI, skew_stable?, b99, pegMaxDev, X_tail}` where `X_tail = Pr[|d| > b99_live(W)]` is the observed mass beyond the installed wall.

---

## 2. The tail-cut rule

Tail-cut is truncate-and-renormalize on the vol-normalized offset density (the conditional distribution `D_risk`). `tau` is the ONE per-asset policy scalar: the central-mass retention target. Operator sets `tau = 0.30` (keep inner 70%):

```
W*     = |delta| quantile of D_risk at central-mass (1 - tau)    # tau=0.30 -> keep inner 70% -> W* = |delta|@q0.85
rho*(d)= rho(d) / (1 - tau)  on |delta| <= W*,  0 outside        # renormalize central density x1/(1-tau) = x1.43
W_land = ceil_ladder( max(theta, W*) )                          # snap UP to {0.5,1,2,5}, never inside theta
```

Because `tau` applies to the vol-normalized offset (support around theta), a fixed 30% is self-normalizing: it auto-widens volatile legs and auto-tightens stable ones. The shipped `W >= b99` sizing is just `tau` around 1% (the containment end); the operator's 30% is the concentration end, the same knob.

### 2.1 Two levers, only one actually cuts the tail

- W-tier drop (5 -> 2 -> 1 -> 0.5): moves hard support inward. This is the REAL tail-cut. It needs a new fitted preset via `requestUpdateProfile`. `hyper@W0.5` is the maximal cut.
- dispRef drop at fixed W: linear y-scale only (`Pricing._scaleY`). Raises the peak but does NOT move x-support. Amplitude only, NOT a tail-cut.

### 2.2 Safety gate (hard)

Any `tau` above roughly 1% is kappa-gated. Emit only for coverage-walled legs (`kappa > 0`), and assert `haircutSuppressor = 0 AND depthAmp = 0` (the coverage-wall-bypass fix). An un-walled trimmed tail is a hard price cliff an informed trader arbs. The operator's 30% trim is a milder hyper and inherits hyper's `FLAG_REQUIRES_WALL` gate (`NUQuartic.sol:27`). Coverage-lost equals `tau`: roughly 30% of between-push excursions fill at the wall, which is LP-protective versus informed flow and forgoes the tail fee.

Action space is the finite pre-certified whitelist ONLY (`spline_shared_grid.json`: 9 regimes x W in {0.5, 1, 2, 5}). The keeper SELECTS a cell; it NEVER emits novel knots. On-chain `NUQuartic._validate` plus the hyper kappa-gate would revert a novel curve anyway. This is the reproducibility and on-chain-enforced safety guarantee.

---

## 3. Density to shape map

Regime classification (thresholds in YAML, zero-hardcoded):

```
tailalpha lower-CI < 2                              -> VETO tight; plateau @ wider W   (USD1, XAUT knife-edge)
walled & kurt<=6 & tailalpha-CI>2.5 & W<=1          -> hyper                           (only USDT clears)
kurt hi & tailalpha in [2.5,3.2]                    -> lepto                           (BTCB/ETH/WBNB)
soft-peg + rolloff                                  -> plateau                         (USD1/USDE/FDUSD)
kurt approx 3, thin                                 -> meso
broad low-conviction                                -> platy (posture)                 (CAKE)
dispRef <- regime default: hyper 50 / flat,plateau 100 / meso 200 / lepto,platy 500   [pbps]
```

`risk/fit.rs` classifies regime from `{kurt, tailalpha + CI, skew-stable?, b99, pegMaxDev}` then selects a pre-certified whitelist cell. It never emits novel knots.

---

## 4. Divergence-triggered update policy

Not periodic. Divergence-gated, hysteresis, asymmetric. A reduced sufficient-stat vector (cheaper and less noisy than full density distance):

```
D_scale  = |ln(sigmahat / sigma_live)|             D_tail  = b99hat / b99_live(W) - 1
D_regime = 1[argmax regime != presetId_live]        D_fee   = |ln(minFee* / minFee_live)|
X_tail   = Pr[|d| > b99_live(W)]    # one-sided SAFETY veto
```

- TIGHTEN (widen shape / raise fee): any `D > tau_tight`, small deadband. Seed: `D_scale 0.22`, `D_tail > 0`, `D_fee 0.18`.
- LOOSEN (to hyper / drop fee): any `D > tau_loose` AND dwell N cycles, large deadband. Seed: `D_scale ln(1.5) approx 0.41`, `D_tail -0.30`, `D_fee 0.41`.
- SAFETY: `X_tail > tau_safe` (roughly 2x expected) tightens NOW, bypasses dwell, routes to guardian levers.
- W1(p_obs, curve-density) is dashboard telemetry only (bps units), NOT the gate. KL rejected (unbounded).

### 4.1 Anti-thrash: damped proportional controller, gain < 1

1. EWMA stats, no window-cliff.
2. Asymmetric deadband.
3. Dwell: shape >= 24h, band >= 1h.
4. RiskFences +/-25% saturation.
5. One-pending-per-key plus <= 1 profile/day/asset.

Stability condition: EWMA halflife >> loop period AND per-step clamp < deadband-recovery. Calibrate `tau_*` and halflives on `faithful_sim.ts` (11.5M-swap replay) to this loop-stability condition before arming.

---

## 5. Risk-param-upkeep keeper design

### 5.1 Placement

New `Command::RiskKeeper{config, execute, once}` in `keepers/src/main.rs` beside `OracleKeeper`. This is a sibling slow-scheduler keeper, NOT the 5ms push loop.

- Dry-run default. LIVE gated by `--execute AND RISK_EXECUTE=1` (distinct from `KEEPER_EXECUTE`).
- Signs with a dedicated risk-steward multisig cosigner key, never the hot money-path `KEEPER_PRIVATE_KEY`.
- Reuses existing `plan.rs` (`ActionPlan` / `TxSpec`) and `executor.rs`. `protocols/dex.rs` (40 loc today) gains the risk-lever call builders.

### 5.2 Modules (`keepers/src/risk/`)

- `density.rs`: subscribe to the push keeper's existing theta-trigger error stream (zero extra market-data cost); EWMA-accumulate `p_obs` and sufficient stats; log W1 telemetry.
- `fit.rs`: stats to preset cell via the section 3 map plus `spline_shared_grid.json` cell selection (hyper veto on tailalpha-CI < 2, kappa wall-gate).
- `fences.rs`: off-chain mirror of `AdminRiskSteward._relOk` (+/-25%) plus deadband / dwell / rate-limit state; reject sub-deadband BEFORE building a tx.
- `submit.rs`: two plan builders, `setAssetParamsBounded` (fast, fenced) and `requestUpdateProfile` / `requestSetCurve` (slow, one-pending check); route X_tail to guardian levers via `protocols/dex.rs`.

### 5.3 Loop cadence (slow scheduler, NOT 5ms)

Hourly stat-accumulate. Daily eval and regime-classify. Daily act on fast scalars, weekly act on shape and bands. Shape dwell >= 24h, band dwell >= 1h.

### 5.4 Staging a shape update (slow path)

`fit.rs` classifies regime from `{kurt, tailalpha + CI, skew-stable?, b99, pegMaxDev}`, selects a pre-certified whitelist cell (9 regimes x W in {0.5, 1, 2, 5}), and NEVER emits novel knots. Tail-cut is the one per-asset policy scalar `tau` (section 2). It builds `requestUpdateProfile(presetId)` / `requestSetCurve` under LOW timelock (1d / 5m Chapel) plus dwell plus one-pending-per-key check.

### 5.5 Fail-safes (hard invariants: reject the update if violated)

- NEVER widen a safety floor. `maxDeviation` is tighten-only-auto (`narrowMaxDeviation`, guardian); widening is owner via `updateFeed` (BASE timelock). `refBand` and reservation bands NEVER auto-widen; reservation is clamped by `_relOkReservation` even on tighten (cannot disable the depeg breaker in one call).
- NEVER auto-move a static param. `MIN_EXEC_PRICE_BPS` / `SPLINE_MIN_OFFSET_PBPS` are compile consts; coverage band, kappa-wall, depthAmp, haircut are owner-only via `requestUpdateRiskConfig`.
- Coupling gates:
  - `minFee_vol >= 2*theta` (between-push mean-arb).
  - theta updates ONLY via the atomic (theta, minFee=2theta, fence resync, minDisp) bundle (section 5.6); a
    lone `oracle.*.toml` edit is a violation the sigma-PoC test and keeper 2theta boot-gate reject.
  - `hyper` implies `kappa > 0 AND tailalpha-lowerCI > 2` (finite variance).
  - `kappa > 0` implies `depthAmp = 0 AND haircutSuppressor = 0` (coverage-wall-bypass fix).
  - Any `tau` above ~1% is kappa-gated to coverage-walled legs only.
  - `maxDeviation > b99 * margin`; `refBand > pegMaxDev`.
- Guardian veto: the routine runs UNDER the RiskFences (`AdminRiskSteward`: `maxDeltaBps` +/-25%, `minFeeHardMin/Max`, `maxFeeHardMax`, tighten-exempt via `paramTighten`) plus the `_onlyGuardianOrAdmin` overlay the money-path already ships. Guardian can `freezeAsset` / `batchRiskOp` anything the routine proposes. They meet only at the tighten direction.
- F4 landmine: a matured `executeUpdateRiskConfig` writes the WHOLE struct and silently wipes pause/frozen bits. Queued RiskConfig ops MUST re-assert live pause/freeze bits (or cancel pending timelocks before pausing).

### 5.6 Full upkept risk-param set

Class legend: CONT = on-chain automatic (no keeper act); FAST = hot scalar, `setAssetParamsBounded`, RiskFences +/-25%, no timelock (GOV-04 adaptivity edge); SLOW = shape/band, `requestUpdateProfile`/`setCurve`, LOW timelock (1d / 5m Chapel) + dwell; TIGHTEN = one-way auto; NEVER = static floor, auto-move forbidden.

| Param | Density-adaptive? | Cadence | Class | Bounded-delta clamp |
|---|---|---|---|---|
| sigma (sigmaEma) | YES (Parkinson-EWMA) | per-push | CONT (oracle task) | push band; k-of-n signers |
| dispersion (live width) | via sigma*vega, auto | every quote | CONT | on-chain `_calculateDispersion`, no act |
| spline preset + W + dispRef | YES (kurt/tailalpha/skew -> regime, b99/q99 -> W, sigma -> dispRef) | weekly / regime-flip | SLOW | whitelist cell + kappa-gate + dwell>=24h + <=1 profile/day/asset + one-pending-per-key |
| minDisp / maxDisp band | YES (rvol quantiles) | weekly | SLOW | LOW timelock, dwell>=1h, +/-25% |
| vega | YES (kurt/tailalpha -> fee-widen speed; realized LVR/sigma) | daily | FAST | RiskFences +/-25% + hard vegaMin 5000 / vegaMax |
| gamma (inv-skew) | WEAK (drain-freq / inventory-turn; control-loop) | weekly/manual | FAST (cautious) | fences 5000-40000 + +/-25% |
| minFee floor | YES (rvol + pegMaxDev / adverse-sel) | weekly (daily D_fee) | FAST | +/-25% + HARD minFeeHardMin 50 stable/100 vol; invariant minFee >= 2*theta (vol) NEVER dropped |
| maxFee ceiling | WEAK (raising = defensive) | rare | FAST | +/-25% + hard ceiling |
| deposit-cap tier | NO (TVL-driven) | as TVL fills | FAST (admin) | schedule, `setAssetParams(minLiquidity)` |
| maxDeviation | INFORMED (b99+margin) but SAFETY | event / X_tail | TIGHTEN-ONLY auto | `narrowMaxDeviation` guardian tighten / `updateFeed` owner widen; NEVER auto-widen |
| refBand (cumulative depeg breaker) | SEMI (pegMaxDev) but SAFETY | manual | NEVER auto | `requestOracleUpdate`, BASE timelock (2d/15m), owner |
| reservationPrice / ...Max | NO (depeg breaker) | event (tighten) | TIGHTEN-only; hard bounds NEVER | `setAssetParamsBounded` always relatively-clamped even on tighten |
| MIN_EXEC_PRICE_BPS / SPLINE_MIN_OFFSET_PBPS | NO | - | NEVER (compile const) | hard exec-price backstops |
| coverage band | NO (sim: non-load-bearing) | manual | NEVER auto | owner, `requestUpdateRiskConfig` |
| kappa wall + depthAmp + haircut | NO (structural invariant) | manual | NEVER auto | owner; enforce kappa>0 implies depthAmp=0 AND haircut=0 |
| theta (feed deviation threshold) + heartbeat | YES (ADAPTIVE, owner mandate: theta sets push cadence, cadence sets the offset-density basis, the basis sets every curve param; recomputed JOINTLY with curve params by the divergence keeper, NOT the price-push keeper) | weekly (with task 12 fit) | FAST (off-chain toml + on-chain bundle) | bounded delta (RiskFences-style): max +/-25% per update, cadence cap 100/h, floor = spec class theta; heartbeat <= ttl/2; ships ONLY as the atomic (theta, minFee=2theta, fence resync, minDisp) bundle below |
| ttl | NO (safety envelope for theta/heartbeat) | rare | OFF-CHAIN, push keeper owns | `oracle.*.toml`; heartbeat <= ttl/2 hard-enforced at keeper boot |
| signer set / threshold | NO (security) | event/rare | NEVER | guardian revoke instant / owner grant BASE |

Theta coupling (HARD): theta and the curve params are one optimization variable, not two. A theta change moves
the push cadence, which moves the offset-from-mark density the presets are fitted to, so the risk keeper
recomputes theta jointly with (regime, W, S, minDisp) and ships the result ATOMICALLY as one bundle of three
artifacts: (1) keeper trigger config `keepers/oracle.*.toml` (theta + heartbeat per feed), (2) on-chain
`minFee = 2*theta` via `setAssetParamsBounded`, (3) RiskFences resync (`setRiskFences` minFee bands) + the
`minDisp >= 2*theta` floor via `requestUpdateProfile`. Partial deploys silently break the between-push
discipline; the sigma-PoC test and the keeper 2theta boot-gate already enforce the parity invariant at startup.

---

## 6. Unified upkeep-task registry

Three categories:

- SECURITY-GUARDRAIL: guardian authority, tighten/cancel-only, instant, fail-safe (every reverse is owner-only).
- RISK-PARAM-UPDATE: risk-steward, bidirectional, bounded-delta, no-timelock (fast) / LOW (slow), fail-adaptive.
- LIVENESS: oracle / ops.

adapt-class: CONT (on-chain auto), FAST (hot scalar, RiskFences), SLOW (shape/band, LOW timelock), TIGHTEN (one-way auto), NEVER (static/owner-only).

| # | task | CATEGORY | trigger | cadence | on-chain lever | authority / timelock | adapt-class | status |
|---|---|---|---|---|---|---|---|---|
| 0 | mark push (sigma-EMA carried) | liveness | \|D\|>theta or heartbeat or CI or cold | theta-event / 5ms poll | `batchPushSigned` | k-of-n (2-of-3, `signer_threshold=2`); relay gas-only; none | CONT | built (OracleDaemon) |
| 1 | signer reconcile | security-guardrail | on-chain set != pinned | ~2s | `revokeSigner` enforce | guardian revoke instant / owner grant BASE | NEVER | partial |
| 2 | feed pause | security-guardrail | staleness / anomaly | event | `pauseFeed` | guardian instant, fail-closed | TIGHTEN | built (lever) |
| 3 | asset pause | security-guardrail | leg anomaly | event | `pauseAsset` | guardian instant | TIGHTEN | built |
| 4 | asset freeze | security-guardrail | drain / outlier | event | `freezeAsset` / `batchRiskOp` | guardian instant | TIGHTEN | built |
| 5 | narrow push band | security-guardrail | X_tail / key-compromise | event | `narrowMaxDeviation` | guardian tighten-only | TIGHTEN | built (lever) |
| 6 | revoke signer | security-guardrail | attester compromise | event | `revokeSigner` | guardian instant | NEVER | built |
| 7 | upgrade veto | security-guardrail | rogue op | event | `guardianCancelUpgrade` / `cancel*` | guardian cancel-only | NEVER | built |
| 8 | halt-pool/protocol macro | security-guardrail | incident | event | off-chain Safe MultiSend -> `batchRiskOp` (bit6) | guardian multisig | TIGHTEN | partial (off-chain macro) |
| 9 | gamma/vega/minFee/maxFee retune | risk-param-update | D_scale / D_fee / X_tail | daily/weekly | `setAssetParamsBounded` | risk-steward; RiskFences +/-25% + tighten-exempt; hard vegaMin/`minFeeHardMin`/`maxFeeHardMax` | FAST | TODO (lever built, routine not) |
| 10 | reservation-band tighten | risk-param-update | X_tail / depeg | event | `setAssetParamsBounded` | risk-steward; `_relOkReservation` always-clamped even on tighten; hard lo/hi owner-only | TIGHTEN | TODO (lever built) |
| 11 | dispersion band endpoints (minDisp/maxDisp) | risk-param-update | D_scale | weekly | `requestUpdateProfile` | risk-steward; LOW timelock (1d/5m) + dwell>=1h | SLOW | TODO (lever built) |
| 12 | curve shape (preset+W+dispRef) | risk-param-update | D_regime dwell + D_tail | weekly / regime-flip | `requestUpdateProfile` / `requestSetCurve` | risk-steward; LOW timelock + wall-gate + kappa-gate + <=1/day/asset | SLOW | TODO (lever built; params derived once offline) |
| 13 | deposit-cap tier raise | risk-param-update | TVL fills | as TVL fills | `setAssetParams(minLiquidity)` | admin; schedule | FAST | TODO |
| 14 | RiskConfig (coverage / kappa / depth / haircut) | risk-param-update | listing change | manual | `requestUpdateRiskConfig` | owner; LOW timelock; F4 re-assert pause bits | NEVER (auto) | built (lever, manual) |
| 15 | refBand / oracle cfg widen | security-guardrail (floor) | never auto | manual | `requestOracleUpdate` / `updateFeed` | owner; BASE timelock (2d/15m) | NEVER | built (lever) |
| 16 | rebalance (coverage restore) | liveness | coverage skew | continuous | swap / rebalance | keeper (~2-4% won vol) | CONT | partial |
| 17 | theta / heartbeat retune (merged into the density -> risk-param-update group, joint with task 12 fit) | risk-param-update | joint optimizer divergence (D_scale / D_fee / X_tail) | weekly | atomic bundle: `oracle.*.toml` theta/heartbeat + `setAssetParamsBounded` (minFee=2theta) + `setRiskFences` resync + `requestUpdateProfile` (minDisp 2theta floor) | risk-steward; bounded +/-25%/update, cadence cap 100/h, floor = spec class theta, heartbeat <= ttl/2 | FAST | TODO (`keepers/src/risk/`) |

### 6.1 No duplication

The risk-param routine (tasks 9-14) runs UNDER the RiskFences plus the guardian overlay the money-path already built (tasks 1-8, 15). Guardian is the orthogonal fail-safe that can freeze anything recalibration proposes. They meet only in the tighten direction.

`maxDeviation` is the single seam: density-informed (task 9 computes b99) but a security floor. The routine may propose tightening via guardian's `narrowMaxDeviation`, never widens.

### 6.2 Status summary

All 18 on-chain LEVERS exist and are verified in source. What is built: the guardian/oracle security half (tasks 0-8, 14-15 levers) plus offline-derived static params. What is TODO: the entire adaptive `keepers/src/risk/` keeper (tasks 9-13 + 17 automation) and the offset-density methodology fix to `RISK_PARAMS_TESTNET.md` sections 3/4. Nothing is partial-built on the risk-param automation side. The hooks are ready; the perpetual keeper is not written.

Key source paths:
- `keepers/src/main.rs` (add `RiskKeeper`)
- `dex/evm/src/Admin.sol` + `dex/evm/src/libraries/AdminRiskSteward.sol` (levers + fences)
- `dex/evm/src/oracles/ExternalOracle.sol` (push / pause / narrow)
- `dex/evm/src/libraries/NUQuartic.sol` (`set` / `_validate` / `FLAG_REQUIRES_WALL`)
- `dex/research/stable-core/{push_sim.py, faithful_sim.ts, out/spline_shared_grid.json, RISK_PARAMS_TESTNET.md}`

---

## Implementation TODO

Single source of truth for every unbuilt keeper/upkeep task. Levers marked built exist on-chain; the automation that drives them is what remains. Ordered by dependency.

### A. Methodology prerequisite (blocks all risk-param automation)

- [ ] **Offset-density methodology fix.** Replace `RISK_PARAMS_TESTNET.md` sections 3/4 single-bar-return tables with the push-simulated offset density (section 1). This is the one load-bearing change; everything downstream depends on it. Retain the section 0 mapping rules.
- [ ] Port `push_sim.py` mark-path reconstruction to Rust, sharing `nxr-sdk::BarFile`.
- [ ] Build the estimator stack: Parkinson-EWMA sigma, Student-t/NIG MLE shape, GPD tail quantiles, Hill tail-index with bootstrap CI, cross-estimator convergence gate.

### B. Risk-param-upkeep keeper (`keepers/src/risk/`) - entirely unbuilt

- [ ] `Command::RiskKeeper{config, execute, once}` in `keepers/src/main.rs`, dry-run default, gated by `--execute AND RISK_EXECUTE=1`.
- [ ] Dedicated risk-steward multisig cosigner key wiring (never `KEEPER_PRIVATE_KEY`). Confirm multisig membership and auto-submit-vs-propose (pending owner call).
- [ ] `risk/density.rs`: subscribe to push keeper theta-trigger error stream; EWMA-accumulate p_obs + sufficient stats; W1 telemetry.
- [ ] `risk/fit.rs`: stats -> regime -> whitelist cell selection from `spline_shared_grid.json`; hyper veto on tailalpha-CI < 2; kappa wall-gate.
- [ ] `risk/fences.rs`: off-chain mirror of `AdminRiskSteward._relOk` (+/-25%) + deadband/dwell/rate-limit state; reject sub-deadband before tx build.
- [ ] `risk/submit.rs`: `setAssetParamsBounded` (fast) + `requestUpdateProfile`/`requestSetCurve` (slow, one-pending) plan builders; route X_tail to guardian levers.
- [ ] Add risk-lever call builders to `protocols/dex.rs`.
- [ ] Implement the divergence trigger (section 4): D_scale/D_tail/D_regime/D_fee/X_tail with asymmetric deadband + dwell.
- [ ] Implement the tail-cut rule (section 2) with the kappa-gate safety enforcement.
- [ ] Encode all coupling invariants (section 5.5) as pre-submit rejection checks, including the F4 re-assert-pause-bits guard on queued RiskConfig ops.
- [ ] **Registry task 9** (FAST scalar retune: gamma/vega/minFee/maxFee) - automation.
- [ ] **Registry task 10** (reservation-band tighten) - automation.
- [ ] **Registry task 11** (minDisp/maxDisp band) - automation.
- [ ] **Registry task 12** (curve shape preset+W+dispRef) - automation.
- [ ] **Registry task 13** (deposit-cap tier raise) - automation.
- [ ] **Registry task 17** (theta/heartbeat joint retune): recompute theta jointly with the task-12 fit
      (theta -> cadence -> offset basis -> params) and build the atomic bundle plan (toml emit + minFee=2theta +
      fence resync + minDisp floor) with the bounded-delta guard (+/-25%, cadence cap 100/h, spec-theta floor).

### C. Calibration before arming

- [ ] Calibrate tau_tight / tau_loose / tau_safe deadbands + EWMA halflives on `faithful_sim.ts` (11.5M-swap replay) to the section 4.1 loop-stability condition.
- [ ] Derive b99_live(W) per wall tier from `spline_shared_grid.json`.
- [ ] Validate no-thrash on the full replay before enabling `RISK_EXECUTE=1`.

### D. Guardian / safeguard tasks still unbuilt or partial

- [ ] **Registry task 1** (signer reconcile): PARTIAL. Complete the ~2s on-chain-set-vs-pinned enforcement loop with guardian `revokeSigner` on drift.
- [ ] **Registry task 8** (halt-pool/protocol macro): PARTIAL. Off-chain Safe MultiSend macro exists; formalize the incident-triggered `batchRiskOp` (bit6) macro path and its runbook.
- [ ] **Registry task 16** (rebalance / coverage restore): PARTIAL. Continuous coverage-skew keeper (~2-4% won vol) not fully wired.

(Registry task 17 moved to section B: theta/heartbeat are ADAPTIVE risk params owned by the divergence keeper,
not a push-keeper liveness recommendation.)

### E. Built levers requiring only manual/ops procedure (no new keeper code)

- Registry tasks 2-7 (feed/asset pause, freeze, narrow push band, revoke signer, upgrade veto): guardian levers built. No automation intended; these are event-driven manual guardian actions.
- Registry tasks 14-15 (RiskConfig, refBand/oracle cfg): owner levers built, manual by design (NEVER auto). Document the F4 pause-bit re-assert procedure in the ops runbook.
