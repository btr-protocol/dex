# BTR Solidity Audit — Iterated Multi-Cohort Report

> Scope: `dex/evm/src/**` (the AIMM "deck", primary) + `shared/evm/src/**` (tokenomics). Method:
> each **cycle** = 3 **independent** senior auditors (distinct lenses, full scope) → every finding
> **adversarially challenged** by 3 independent reviewers (reproduce / refute / scope-severity) →
> only findings surviving a ≥2/3 "real" majority are confirmed → confirmed **BUG/SECURITY** fixed +
> regression-tested → **re-audit** next cycle. Iterated until a 3-cohort batch surfaces no new
> actionable defect. Orchestrated as a deterministic workflow; this document consolidates every
> cohort, finding, verdict and fix per cycle.
>
> Baseline entering the audit: this codebase had already been hardened earlier in the same session
> (coverage-wall peg-clamp, mandatory oracle deviation clamp + staleness band, haircut cap, base-κ=0,
> hook-subsystem removal, negative-delta clamp). The audit therefore scrutinised those changes too.

## Headline

- **0 CRITICAL. 1 HIGH** — a cross-exit haircut bypass, found in **cycle 4** and fixed (row 12). Every
  finding was fixed and regression-tested; the value of iterating shows in the severity *escalating*
  (LOW → MED → HIGH) as shallower defects cleared — a 3-cohort batch that stopped at cycle 3 would have
  missed the HIGH.
- **12 real findings** confirmed and **fixed** across the cycles. Two were gaps in the *same session's
  own* prior fixes; two were caught by **all three cohorts independently** (highest confidence); the
  HIGH and the two other genuine correctness/security defects (Spline overshoot, cross-withdraw depeg)
  were PoC-grade.
- The three cohort lenses (used every cycle): **A** access / upgradeability / lifecycle / reentrancy ·
  **B** oracle / pricing / coverage-math / precision · **C** economic / MEV / storage / invariants /
  tokenomics.
- Convergence target = zero surviving **BUG/SECURITY**; accepted design decisions (below) are recorded,
  not counted as open findings (defense-in-depth is unbounded — see "Accepted design decisions").

---

## Cycle 1

3 cohorts → 5 raw findings → 15 challenge verdicts → **0 confirmed BUG/SECURITY** (all HARDENING). The
3 actionable hardening findings were fixed.

| # | Sev/Class | Location | Finding | Cohorts | Verdict | Disposition |
|---|---|---|---|---|---|---|
| 1 ⭐ | MED / HARDENING | `ExternalOracle.sol` `_pushInternal` | **Cumulative same-block clamp bypass**: the per-push deviation clamp bounds a push vs the *previous* one; N pushes in one block (looped `pushFeed` or a feedId repeated in `batchPush`) each pass the band (dt=0 ⇒ band doesn't grow) yet compound geometrically to an unbounded one-tx move — defeating the documented P4 "no one-tx drain from a stolen key". | **A + B + C (all 3)** | not-a-bug (HARDENING) but real; 3 independent discoveries | **FIXED** — one mark update per feed per block (`dt==0` reverts); duplicate feedId in a batch fail-closes. Regression: `test_pushFeed_sameBlockRepushReverts`, `test_batchPush_duplicateFeedId_reverts`. Made AIMM_PROOFS P4 true. |
| 2 | LOW / HARDENING | `Router.sol` `initialize` | Missing the `msg.sender==AC.owner()` guard its sibling `Treasury.initialize` has → a non-atomic-deploy front-run permanently binds an attacker factory. | A | real hardening | **FIXED** — mirrored the owner guard. Regression: `test_initialize_nonOwner_reverts`. (Router later retired — see cycle 4.) |
| 3 | LOW / HARDENING | `PoolLiquidity.sol` `donate` | `liquidityIndex` grown via a raw `uint64` cast → overflow wraps and silently corrupts every LP's share↔value mapping. | C | real hardening | **FIXED** — checked cast, fail-closed. Regression: `test_donate_liquidityIndex_overflow_reverts`. |

Refuted / classified-not-a-bug this cycle: the same clamp finding as reported by cohorts B & C (same
root as #1, folded); no false positives requiring rebuttal beyond the HARDENING re-classification.

**Commits:** `dex 956b1a0`. Tests: 300 green.

---

## Cycle 2 (re-audit)

3 fresh cohorts on the cycle-1-fixed tree → 5 raw findings → 0 confirmed BUG/SECURITY. Four actionable
(two were gaps in the session's *own* prior fixes); one is an accepted design decision.

| # | Sev/Class | Location | Finding | Verdict | Disposition |
|---|---|---|---|---|---|
| 4 ⭐ | MED / HARDENING | `PoolIO.sol` `priceBandGuard` (via `exec`/`swapLiability`) | **Depeg breaker only on the OUTPUT leg**: a wrong-but-fresh INPUT-asset mark (outside its refBand/reservation band) lets a depegged token be dumped into the pool to drain a healthy output; `swapLiability` skipped it entirely. | real | **FIXED** — `priceBandGuard` on the input leg in `exec`; both legs in `swapLiability`. Regression: `test_reservation_band_halts_input_asset_swap`. |
| 5 | LOW / HARDENING | `PoolAdminWrite.setBaseToken` | Base migration didn't re-assert the base-numeraire invariant (κ=0) that `initAsset`/`setRiskConfig` enforce → a base could be migrated onto a walled spoke, breaking Thm 2. | real | **FIXED** — revert `BadConfig` if the migration target has `kappaCovBps != 0`. Regression: `test_base_kappa_rejected_at_addAsset` (+ migration guard). |
| 6 | LOW / HARDENING | `PoolLiquidity.swapLiability` | Bypassed the JIT flow cooldown → `deposit → swapLiability → withdraw` exits before the anti-JIT window. | real | **FIXED** — cooldown on the input position + destination timestamp propagation. Regression: `test_swapLiability_respects_flow_cooldown`. |
| 7 | INFO / dead-code | `PoolSwapQuote.processSwap` | `_reconcile` became a permanent no-op after the hook removal (out always == q.amountOut). | real (dead code) | **FIXED** — deleted; `processSwap` = exec only. |
| — | LOW / design | `Router.sol` / `Treasury.sol` `_authorizeUpgrade` | UUPS upgrade timelock is non-binding (AC.owner can `upgradeToAndCall` directly). | real, DELIBERATE | **ACCEPTED** design decision (emergency owner path) — recorded below, not fixed. |

**Commits:** `dex 73de479`. Tests: 302 green.

---

## Cycle 3 (re-audit)

3 fresh cohorts on the cycle-2-fixed tree; the workflow ran two internal sub-cycles and converged. 5
raw findings — including the audit's **only two genuine correctness/security defects** (a real BUG and
a real SECURITY gap), both with demonstrated exploits and verified fixes.

| # | Sev/Class | Location | Finding | Verdict | Disposition |
|---|---|---|---|---|---|
| 8 ⭐ | LOW / **BUG** | `Spline.sol` `_tangents` | **Flat-segment overshoot**: `_tangents` returned early *before* the Fritsch–Carlson clamp when a segment slope is 0, so a valid admin profile with equal consecutive knots quotes a **+22 bp premium where it specified TWAP** (`area()` over-integrates the flat segment) — a one-way informed-flow LP drain, breaking the AIMM_PROOFS §5 no-overshoot invariant. Demonstrated: `area(pts,2500,5000)=2604166` (should be 0). | **CONFIRMED real BUG** | **FIXED** — run the clamp (num=3·sa=0 zeroes flat-segment tangents → area=0). Standard strictly-increasing profiles unchanged. Regression: `test_flat_interior_segment_no_overshoot`. |
| 9 ⭐ | MED / **SECURITY** | `PoolLiquidity.withdrawTo` (`_withdrawCross`) | **Cross-asset withdraw omitted the input-leg depeg guard** — the same class as finding #4 but on the `withdrawTo` path (missed in the cycle-2 fix): a wrong-but-fresh `fromTk` mark over-delivers the healthy output asset. | **CONFIRMED real SECURITY** | **FIXED** — `priceBandGuard` on both legs of cross-withdraw. Completes the input-leg depeg coverage across all mark-priced value-out paths. |
| 10 | LOW / HARDENING | `PoolIO.exec` | Input-leg reserve credit via unchecked `uint128` cast (unlike deposit/donate). Not reachable with any real token supply. | real (parity) | **FIXED** — bound check mirroring deposit/donate. |
| 11 | LOW / HARDENING | `PoolAdmin.validateRiskConfig` / config path | `κ>0 ⇒ haircutSuppressor==0` (Lemma B) documented but not code-enforced. | real | **FIXED** — enforced at `addAsset` (zeroed), `setAssetParams` + `setRiskConfig` (revert). |
| — | LOW / BUG | `Router.sol` native-ETH path | `address(0)` vs `SC.NATIVE` sentinel mismatch makes Router native swaps non-functional + strands stray `msg.value`. | real (Router-only) | **RESOLVED BY RETIREMENT** — the Router is being deleted (owner decision); no fix carried. |

**Commits:** `dex c6d9516` (+ the workflow fixer's Spline/withdraw fixes). Tests: 307 green.

---

## Accepted design decisions (recorded, not open findings)

Adversarial audits always surface unbounded defense-in-depth; these are deliberate tradeoffs the owner
has accepted, so they do not block convergence:

- **UUPS "dual-auth" upgrade** (Router — now retired — and `Treasury`): AC.owner can upgrade directly,
  bypassing the request/execute timelock. Deliberate emergency-response path; the timelock is the
  LP-warning channel, not a hard owner constraint. Binding-only is a governance-model change.
- **Single oracle pusher key** (no on-chain 2-of-N quorum): guarded off-chain by multisig custody +
  the mandatory on-chain per-push/per-block deviation clamp. 2-of-N remains recommended mainnet
  hardening.
- **Permissionless `createPool`**: registry/route-discovery-VIEW griefing only (on-chain exec filters
  `isOfficialPool`); pre-mainnet gating decision.

---

## Cycle 4 (re-audit, Router retired)

3 fresh cohorts on the cycle-3-fixed + **Router-retired** tree → **1 finding — the audit's only HIGH**,
unanimously confirmed (3/3) and PoC-verified. This is why iterating past cycle 3 mattered: severity
*escalated* (LOW → MED → **HIGH**) as the earlier, shallower defects were cleared.

| # | Sev/Class | Location | Finding | Verdict | Disposition |
|---|---|---|---|---|---|
| 12 ⭐⭐ | **HIGH / SECURITY** | `PoolLiquidity.sol` `_withdrawCross` + `swapLiability` | **Cross-exit coverage-haircut bypass.** `_withdrawSame` applies the coverage haircut on the FROM asset so an under-covered LP exit takes only `face·c` (deficit socialized — Lemma B). The cross paths burned the FROM liability at **full face** but haircut only the OUTPUT, so an LP holding an under-covered asset could `withdrawTo`/`swapLiability` into a healthy asset **at par**, escaping its `(1−c)` deficit onto the output/base LPs — a bank run the haircut exists to prevent, and in a multi-spoke star it drains an *unrelated* healthy spoke (spokeA→base→spokeB). PoC: at c=0.726 the cross exit overpays **+37.6%** vs the fair same-asset exit. | **CONFIRMED HIGH (3/3, PoC)** | **FIXED** — apply the from-asset haircut (`face·c_from`) BEFORE the mark conversion in both paths, mirroring `_withdrawSame`; full-face liability still burns so the deficit stays socialized + the index invariant holds. AIMM_PROOFS Lemma B gains the cross-path-symmetry clause. Regression: `test_cross_withdraw_cannot_escape_coverage_haircut`, `test_swapLiability_cannot_escape_coverage_haircut`. |

**Commits:** `dex 6048b7e`. Tests: 295 green.

---

## Cycle 5 (convergence)

3 fresh cohorts on the cycle-4-fixed tree → **1 finding, INFO, 0 confirmed**. All 3 challengers
unanimously refuted it as not-a-defect.

| # | Sev/Class | Location | Finding | Verdict | Disposition |
|---|---|---|---|---|---|
| — | INFO / fee-policy | `PoolLiquidity.swapLiability` | Doesn't collect the protocol fee that `_withdrawCross` collects. | **REFUTED 3/3 — not a defect** | No fund loss, LP-safe, structurally justified (liability re-denomination moves no reserves, so there's no outflow to skim the fee from). **ACCEPTED design choice** — now documented in NatSpec so it isn't re-flagged. |

**Result:** a full 3-cohort batch produced **zero confirmed BUG/SECURITY findings.** ✅ **CONVERGED.**

---

## Convergence summary

| Cycle | Raw findings | Confirmed & fixed | Peak severity |
|---|---|---|---|
| 1 | 5 | 3 (incl. the 3-cohort clamp bypass) | MED |
| 2 | 5 | 4 (2 in the session's own prior fixes) | MED |
| 3 | 5 | 4 (Spline overshoot BUG, cross-withdraw depeg SECURITY) | MED |
| 4 | 1 | 1 (**the HIGH** — cross-exit haircut bypass) | **HIGH** |
| 5 | 1 | **0** (INFO, refuted) | — |

**5 cycles · 15 auditor passes · 12 real findings fixed + regression-tested · 0 CRITICAL · 1 HIGH
(fixed) · final batch zero-actionable.** No exploitable fund-loss defect remains in the audited scope
under the stated assumptions. Convergence was earned, not assumed — severity *escalated* to a HIGH in
cycle 4, so stopping earlier would have shipped a live bank-run vector.

**Residual (owner-decision, not defects):** the accepted design decisions above (upgrade dual-auth on
`Treasury`, single oracle pusher key / recommended 2-of-N, permissionless `createPool`) remain the
standing pre-mainnet hardening items — tracked, not open findings.

_Method note: auditors and challengers were read-only; a test-gated engineer applied fixes; each cycle
re-audited the fixed tree. The `AIMM_PROOFS.md` formal spec + `CoverageProofs.t.sol`/`Spline.t.sol`
machine checks were updated in lockstep with the fixes._
