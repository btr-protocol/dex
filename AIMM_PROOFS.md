# AIMM Inventory-Safety Proofs

> Formal properties of the deployed pricing/inventory mechanism (`evm/src/libraries/Pricing.sol` @ `main`,
> 2026-07-09). Written to answer the standing objection: *"oracle-anchored AMMs are flawed for volatile
> assets — inventories deplete and coverage never returns to 1."* Every theorem states its assumptions
> against exact code lines; every gap is listed in §8. Machine-checked counterparts live in
> `evm/test/unit/CoverageProofs.t.sol` (§9 maps theorem → test).

## 0. Model and notation

Per asset `a`: reserves `R` (uint128), liabilities `L` (uint128), coverage `c = R·WAD/L`
(`Pricing.calculateCoverage`, Pricing.sol:686). Units: `BPS = 10^4`, `PBPS = 10^6`, `WAD = 10^18`
(shared `Constants.sol`). Oracle mark `m` is frozen between keeper pushes (`ExternalOracle.sol`,
quote source = `lastPriceB64`). Spread `S` in PBPS, `S ∈ [minFee, maxFee]` (`_pathSpread`,
Pricing.sol:381–391). Coverage-wall strength `κ = kappaCovBps ∈ [0, 65535]` per asset
(`IPool.RiskConfig`).

State transitions (exact, from code):

| op | reserves | liabilities | code |
|---|---|---|---|
| swap, out-leg | `R −= (out + protoFee)`; `out = g − T − fee`, `lpFee` retained | — | PoolIO.sol:104–106 |
| swap, in-leg | `R += amountIn` (full) | — | PoolIO.sol:104 |
| deposit | `R += a` | `L += a` | PoolLiquidity.sol:64–65 |
| same-asset withdraw | `R −= w·(1 − (1−c)·f)`, `f = 1 − s/20000` | `L −= w` | PoolLiquidity.sol:174–183 |
| cross-withdraw | out-asset `R −= (amt + protoFee)` | from-asset `L −= w` | PoolLiquidity.sol:185–208 |
| swapLiability | — | `L_in −= liabIn`; `L_out += liabOut` | PoolLiquidity.sol:235–236 |

All value-out paths (swap, batch swap, cross-withdraw, swapLiability) route through the single quote
choke `Pricing.getAnchorPathQuote` → `_settleQuote` → `_covToll` (Pricing.sol:342–368). The toll `T`
is charged on the drained OUTPUT side, before fees, and is **retained in the output reserve**
(never credited to the trader): Pricing.sol:351–355.

Toll definition (Pricing.sol:658–673), with `c₀ = R·WAD/L`, `c₁ = (R−g)·WAD/L`, gross output `g`:

```
Q(c)  = lnWad(c) − c + WAD                       (≤ 0, max 0 at c = 1, → −∞ as c → 0)
dQ    = Q(c₀) − Q(c₁)
T(g)  = 0                        if κ = 0 ∨ L = 0 ∨ g = 0
      = g                        if g ≥ R          (full-drain wall)
      = min(g, ⌊dQ·κ·L/(BPS·WAD)⌋)  if dQ > 0
      = 0                        if dQ ≤ 0         (charge-only)
```

## 1. Lemma A — deposits restore coverage

For `c < 1` and deposit `a > 0`: `c′ = (R+a)/(L+a) ∈ (c, 1)`, strictly increasing in `a`,
`c′ → 1` monotonically. Symmetrically `c > 1 ⇒ c′ ∈ (1, c)`. *Proof:* `(R+a)/(L+a) − R/L =
a(L−R)/(L(L+a))`, sign of `L−R`. ∎ (Donate is the same transition: PoolLiquidity.sol:91–92.)

Every deposit, on either side of the peg, moves coverage toward 1. This is one of the two
restoration channels (§6 gives the other).

## 2. Lemma B — the haircut makes same-asset withdrawal coverage-neutral iff s = 0

`applyHaircut` (PoolLiquidity.sol:30–43) pays `amt = w·(1 − (1−c)·f)` against a liability
reduction of `w`, where `f = 1 − s/20000` and `s = haircutSuppressor`.

- **s = 0** (`f = 1`): `amt = w·c`, so `c′ = (R − wc)/(L − w) = c` exactly. Withdrawal runs
  cannot move coverage at all — an LP exit at `c < 1` takes exactly its pro-rata share of the
  deficit.
- **s > 0**: `c′ − c = −w·(1−c)·(s/20000)/(L−w) < 0` for `c < 1`. Each withdrawal leaks
  coverage at rate `∝ s`. At the code default `s = 10000` (PoolAdmin.sol:110) the leak factor is
  `(1−c)/2` per unit withdrawn.

**Policy consequence (normative):** walled assets (κ > 0, i.e. stables) MUST run
`haircutSuppressor = 0`, otherwise same-asset withdrawal is a toll-exempt coverage-declining
path that bypasses the wall of Theorem 1. This is a configuration requirement, not a code
change; it is asserted in the deploy checklist. Note the leak is not value-extraction — the
withdrawer receives strictly less than face value (`amt < w` whenever `c < 1`) — it only
weakens the *floor*, not LP solvency ordering.

**Cross-path symmetry (code-enforced).** The same `face·min(1,c_from)` haircut is applied on the
*input* leg of the cross exits (`_withdrawCross`, `swapLiability`: PoolLiquidity.sol) BEFORE the
mark conversion, while the from/in liability still drops by the full face. Without it an
under-covered LP exits into a healthy asset at par, escaping its `(1−c)` deficit onto the output
asset's LPs (a bank run onto the base/stable reserves) — the precise mechanism the haircut exists
to prevent. A cross exit therefore never credits more value than the fair same-asset exit.

## 3. Lemma C — toll well-formedness

For all inputs: `0 ≤ T(g) ≤ g`; `T = 0` when `κ = 0`; `T = 0` when `dQ ≤ 0` (draining an
over-covered asset toward the peg is free); `T = g` when `g ≥ R`. On `c₁ ∈ (0, c₀]`, `Q` is
strictly increasing below 1 (`Q′(c) = 1/c − 1 > 0`), so `dQ > 0` for any drain below the peg and
`T` is strictly increasing in `g`. *Proof:* direct from the definition; the clamp gives `T ≤ g`,
`dQ ≤ 0 ⇒ T=0` gives `T ≥ 0`. Monotonicity: `∂T/∂g = (κ/BPS)·(1/c₁ − 1) ≥ 0` for `c₁ ≤ 1`. ∎

Edge case (fail-closed): if a fill would leave `0 < R−g` with `(R−g)·WAD/L = 0` after integer
division (only possible when `L > (R−g)·WAD`), `lnWad(0)` reverts — the swap fails rather than
under-tolls. A trader can always fill a smaller size.

## 4. Theorem 1 — hard coverage floor under the convex wall

**Statement.** Let `c* = κ/(κ + BPS)` (both in bps). For every tolled drain (swap out-leg,
batch, cross-withdraw, swapLiability) on an asset with `κ > 0`:

```
c_after ≥ min(c_before, c*) − ε_dust
```

and by induction over any finite sequence of pool operations that excludes s>0 same-asset
withdrawals (Lemma B) and admin re-configuration:

```
c_t ≥ min(c_initial, c*) − ε_dust   for all t.
```

`ε_dust` collects integer floor-division slack; it is ≤ a few wei-equivalents of coverage
(`≈ 4·WAD/L`), i.e. economically nil for any funded pool, and is fuzz-bounded in §9.

**Proof.** The trader receives net `n(g) = g − T(g)` (fees only reduce `n` further and `lpFee`
stays in reserve; `protoFee ≤ feeOut` leaves — both absorbed into `ε` conservatively, since
`feeOut ≥ protoFee` is charged *on top of* the toll: PoolIO.sol:104–106). Reserve after:
`R₁ = R₀ − n(g)`. Define `φ(g) = R₀ − g + T(g)` (continuous relaxation). Then
`φ′(g) = −1 + (κ/BPS)(1/c₁(g) − 1)` with `c₁(g) = (R₀−g)/L` strictly decreasing in `g`, so `φ′`
is strictly increasing: `φ` is convex with unique minimum where `c₁ = c*`, since
`(κ/BPS)(1/c* − 1) = 1` exactly at `c* = κ/(κ+BPS)`.

Case `c₀ > c*`: the minimum of `φ` is attained at `g*` with `c₁(g*) = c*`, and
`φ(g*) = R₀ − g* + T(g*) ≥ (R₀ − g*) = c*·L`, so `c_after = φ(g*)/L ≥ c* + T(g*)/L > c*`.
Case `c₀ ≤ c*`: `φ′(0) = −1 + (κ/BPS)(1/c₀ − 1) ≥ 0`, so `φ` is non-decreasing on the whole
domain and the drain-minimizing choice is `g = 0`: **swaps cannot decrease coverage at all once
it sits at or below the floor.**

`swapLiability` is dominated by the same bound: it raises `L_out` instead of draining `R_out`,
and for `c < 1`, `(R−out)/L < R/(L+out)`, so the toll — computed on the reserve-drain form —
over-charges relative to the true potential change (conservative direction). The in-leg of
`swapLiability` only *raises* `c_in`. Deposits (Lemma A) and s=0 withdrawals (Lemma B) never
lower `min(c, c*)`. Induction over the op sequence completes the claim. Integer rounding: `T` is
floored once and `c₁` is floored once per op — each error ≤ 1 unit, absorbed in `ε_dust`;
sub-toll dust grinding is bounded by 1 wei per op and costs gas ≫ value. ∎

**Sizing rule (design output).** `κ = BPS·c*/(1 − c*)`:

| target floor c* | κ (bps) | representable in uint16? |
|---|---|---|
| 0.50 | 10 000 | ✓ |
| 0.667 | 20 000 | ✓ |
| 0.80 | 40 000 | ✓ |
| 0.868 | 65 535 | ✓ (max) |
| 0.90 | 90 000 | **✗ — exceeds uint16** |

**Finding (P2):** `kappaCovBps` as `uint16` caps the provable floor at ≈ 0.868. If the stable-core
wants a 0.90+ hard floor, widen the packed field in a predeploy ABI break or accept 0.868
plus the economic defenses of §6. The wall is *not* the only defense — spread, skew premium and
`minLiquidity` (PoolSwap.sol:43) stack on top — but 0.868 is the honest ceiling of *this*
theorem today.

**Assumptions.** (i) `depthAmplifier = 0` whenever `κ > 0` — enforced at config
(PoolAdmin.sol:46); (ii) base asset un-walled — currently a convention (Pricing.sol:427 comment),
see finding P3 in §8; (iii) `haircutSuppressor = 0` on walled assets (Lemma B).

## 5. Bounded assurance claim — immediate round-trip non-extraction

**Scoped statement.** Within one block (mark `m`, σ, confidence frozen; skew/reserves live), the
tested two-swap cycle `token → base → token` does not profit over the bounded states and sizes in
`test_fuzz_roundtrip_never_profits`. This is strong regression evidence, not a proof for every finite
multi-asset sequence or every uint256 state.

**Continuous argument + discrete regression anchor.**
1. *Charge-only toll can only hurt the trader.* `T ≥ 0` is subtracted from output and retained in
   reserves; there is no rebate path (Pricing.sol:627), so removing the toll upper-bounds the
   attacker. It therefore suffices to show the κ=0 pricer is non-extractable.
2. *The κ=0 pricer integrates one monotone curve both ways.* Execution price is the exact
   Hermite-spline VWAP over the depth band the trade traverses (`_traverseSplineByVolume`,
   Pricing.sol:153–212), around the frozen mark. Knot monotonicity is enforced at config
   (PoolAdmin.sol:34) and the Fritsch–Carlson tangent clamp (Spline.sol:128–151) makes the
   interpolant monotone — no overshoot. A sell traverses the band downward (discount side); the
   buy-back traverses the same monotone curve upward. In the continuous re-anchoring limit the
   two VWAPs are equal and the round trip loses exactly `2 × spread/2 + tolls ≥ minFee`.
3. *Observed discretization favors the pool in the tested domain.* Skew is computed pre-trade and re-anchored between trades
   (Pricing.sol:565). Splitting a sell into n parts re-anchors each part at a *more adverse*
   band position (selling raises the sold asset's coverage → skew falls → next part starts lower
   on the curve); symmetrically for buys. The regression fuzzes a pre-drain up to `SEED/2` and an
   attacker size from `1e12` through `SEED/4` at the fixture's fixed κ/profile/dispersion. It does
   not sweep arbitrary κ, dispersion, route length, or multi-asset cycles.
4. Fees are strictly positive (`minFeeBps ≥ MIN_FEE_PBPS = 1` enforced at config) and the
   haircut is ≥ 0. A universal discrete no-cycle theorem remains open (P5).

Caveats: 1-wei rounding dust per op (gas-dominated); cross-asset cycles through the base hub
inherit the same argument per leg because the base leg is the numeraire (`p ≡ 1`,
`_readBasePriceOrHalt`) — provided the base is un-walled and un-skewed, which holds for a
stable base with `κ_base = 0` (finding P3).

## 6. Theorem 3 — volatile assets: no adversarial depletion channel, and the restoring band

Volatile spokes run `κ = 0` (the wall is a stable-asset device — sim-validated that walling a
volatile bleeds LP: it forces re-pegging a legitimately moving inventory). Their protection is
economic, and it is exactly quantifiable from code:

**(a) Informed-flow drain is closed by the deviation-push policy.**
Per-trade, the trader pays `feeOut = out·S/(2·PBPS)` (half the quoted spread, one side:
Pricing.sol:363). An arb's edge against the frozen mark is `G = |truth − m|/m`. Under the
keeper policy (push when `G > θ` or heartbeat), `G ≤ θ + z·σ·√δ` where `δ` = keeper
reaction+inclusion delay. The arb nets

```
edge ≤ G − S/2 ≤ (θ + z·σ·√δ) − minFee/2
```

**Corollary (deploy rule):** `minFee ≥ 2·(θ + z·σ·√δ)` ⇒ adversarial edge ≤ 0 on every trade ⇒
informed flow cannot systematically drain reserves. With `θ = 5 bp`, `σ = 60%/yr ≈ 0.11%/√min`,
`δ ≈ 4 s`, `z = 3`: `minFee ≥ 2·(5 + 3·0.11%·√(4/60) min-units) ≈ 2·(5 + 2.6) ≈ 15 bp`. Setting
`minFee = 2θ = 10 bp` exactly is the knife-edge the paper review flagged; the σ-term is the
margin. (Stables: `δ`-term ≈ 0, `minFee = 2θ` is right.)

**(b) The skew premium is a restoring force with a computable equilibrium band.**
Under-coverage moves the quoted mid *against* further drain and *in favor of* replenishment:
skew `= γ·100·progress/BPS` (clamped ±100, Pricing.sol:57), mapped through the profile to a mid
offset of up to `±dispersion` PBPS at full skew. Replenishing arb (selling the scarce asset to
the pool at its premium) is profitable exactly when

```
offset(c) > S/2 + θ      where offset(c) = (skew(c)/100)·dispersion
```

Solving at γ = BPS (1×), linear profile: the coverage band outside which rational arbs restore is

```
|1 − c| ≤ (minFee/2 + θ)/dispersion · (1 − covMin)
```

Worked: stables (dispersion floor 1000 PBPS = 10 bp, θ = 1 bp, minFee = 2 bp, covMin = 0.5):
band ≈ `(1+1)/10 · 0.5 = 0.10` → arbs alone hold `c ≥ 0.90`; the wall (Theorem 1) and deposits
(Lemma A) tighten from there. Volatiles (dispersion scales with σ: `1000 + σ·vega/(1000·BPS)`):
the band *tightens* as vol rises — at σ = 60% and vega = 1× the restoring premium dwarfs
`minFee/2 + θ`, so coverage excursions are arb-corrected quickly; what remains is inventory
*noise*, not drift. Combined with (a) — no negative drift channel — coverage is a mean-reverting
bounded process, not a depleting one. That is the formal answer to "coverage never returns
to 1": it returns to the band above, at arb speed, and cannot leave `[min(c₀,c*), ∞)` on walled
assets at all.

**(c) Hard backstops independent of economics:** output clamped to reserves (Pricing.sol:511–513)
— a swap can never overdraw; `minLiquidity` reverts any swap leaving `R` below the configured
floor (PoolSwap.sol:43–45); base-depeg halt (Pricing.sol:443–457); per-asset freeze + HALT_MASK.

## 7. Theorem 4 — delinquent keeper: bounded bleed, then halt

If the keeper stops pushing, staleness `τ` grows and three regimes apply in order
(Pricing.sol:393–412, 625–628):

1. `τ ≤ ttl/2` (grace): spread unchanged; gap bounded by `θ` at the moment of the last push plus
   drift `σ√τ`. Loss per pick-off ≤ `σ√τ − minFee/2` when positive.
2. `ttl/2 < τ ≤ ttl`: spread widens by `STALE_Z·σ·√(τ − ttl/2)/BPS` — the premium grows with the
   same `√τ` law as the drift it must cover, so the *marginal* pick-off edge is bounded by a
   constant times σ (it cannot accelerate).
3. `τ > ttl`: `_fetchFeed` reverts — trading halts. **Total worst-case bleed per incident is a
   finite integral over `[0, ttl]`**, per asset, and scales linearly in σ and in exposed depth.
   Halting > bleeding (fail-closed), and the premium turns the cliff (empirically −183% net at a
   30 s frozen mark without it) into a ramp.

Operational corollary: `ttl ≈ 2·heartbeat` must hold per feed (keeper-side startup check; see
keeper audit) — the grace is `ttl/2` by construction on-chain, so heartbeat > ttl/2 mis-sizes
regime 1.

## 8. What is NOT proven (honest gaps, ranked)

- **P1 — restoration to c = 1 exactly, for stables, by the wall alone.** Charge-only everywhere:
  the surplus-funded rebate was removed from the sim as well this cycle (`aimm.rs` `lp_surplus`
  deleted; the re-peg regression is charge-only), so no rebate variant exists anywhere in-tree.
  The wall *prevents* drain (Thm 1) but pays no one to restore; restoration relies on Lemma A
  (deposits) + §6(b) arb band (c ≥ ~0.90 at launch params). The historical `c → 0.9885`
  convergence figure belonged to the deleted rebate variant and is NOT claimed. If tighter stable
  re-peg is wanted later: re-build a surplus-capped rebate from scratch (extra state; extraction
  surface re-opens — needs its own proof).
- **P2 — uint16 κ ceiling** caps the provable floor at c* ≈ 0.868 (§4).
- **P3 — CLOSED.** Base `kappaCovBps == 0` is now enforced at `addAsset`/`setRiskConfig`
  (PoolAdminWrite.sol) — a walled base reverts `BadConfig`. the §5 bounded-assurance claim's cross-leg assumption is
  code-backed. (Skew-neutral base still holds by the base being the numeraire priced via
  `_readBasePriceOrHalt`, not the spline.)
- **P4 — single oracle key, now BOUNDED.** All economic theorems condition on an honest mark
  within θ of truth. A stolen pusher key can no longer drain in one tx: (a) the per-push deviation
  clamp is **mandatory non-zero** and its band grows only linearly with staleness
  (`maxDev·(1+dt/ttl)`, capped); (b) **at most one mark update per feed per block** — a same-block
  re-push reverts (`dt==0` guard in `_pushInternal`), and a duplicate feedId in a `batchPush`
  fail-closes the batch. Without (b), N same-block pushes each pass the band (dt=0 ⇒ band never
  grows) yet compound geometrically to an unbounded one-tx move — the cumulative bypass all three
  audit cohorts independently found (cycle 1). With (a)+(b) a compromised key is confined to a
  monitorable, one-band-per-block walk, and the confidence/TTL halts still fire. Full defeat still
  needs multisig compromise; **2-of-N pusher quorum remains recommended mainnet hardening**
  (defense-in-depth), no longer a single-point drain.
- **P5 — discrete decomposition gap** in §5 step 3 is fuzz-anchored, not closed-form.
- **P6 — sim numeric transfer.** Sim charges the full spread where the chain charges half
  (aimm.rs:371 vs Pricing.sol:363) and composes the fee floor differently — sim-tuned fee/vega
  values are structurally right but numerically ~2× optimistic on-chain; re-tune from chain
  semantics (tracked in parity audit).
- **P7 — multi-asset correlated shocks** (all spokes gapping together against the hub) are
  outside the per-asset model; the base-depeg halt and per-asset freezes are the current answer.

## 9. Machine-checked map (evm/test/unit/CoverageProofs.t.sol)

| claim | test |
|---|---|
| Lemma C bounds: 0 ≤ T ≤ g; κ=0 ⇒ 0; g ≥ R ⇒ T=g | `test_fuzz_toll_bounds`, `test_fuzz_toll_wall_blocks_full_drain` |
| charge-only: dQ ≤ 0 ⇒ T = 0 | `test_fuzz_toll_charge_only_overcovered` |
| toll monotone in g | `test_fuzz_toll_monotone_in_size` |
| split ≥ single (no split discount) | `test_fuzz_toll_split_no_discount` |
| Thm 1 floor, single swap, pool boundary | `test_fuzz_coverage_floor_single_swap` |
| Thm 1 floor, op sequences (handler invariant) | `invariant_coverage_floor` (CoverageFloorHandler) |
| Immediate round trip loses in fixture domain (pre-drain ≤ SEED/2; size ≤ SEED/4; fixed κ/profile) | `test_fuzz_roundtrip_never_profits` |
| Lemma B: s=0 withdraw coverage-neutral | `test_withdraw_coverage_neutral_when_suppressor_zero` |
| Lemma B cross-path: haircut not escapable via cross exit | `test_cross_withdraw_cannot_escape_coverage_haircut`, `test_swapLiability_cannot_escape_coverage_haircut` |
| Lemma A: deposit restores toward 1 | `test_deposit_restores_coverage` |
| §6(c) minLiquidity backstop | existing `PoolSwap` threshold revert + `test_fuzz_coverage_floor_single_swap` bound |

## 10. Full formal verification — feasibility verdict

Full-protocol FV (Certora/Halmos over every entrypoint + storage aliasing) is a multi-week,
tool-licensed effort and is **not** replaced by this document — §§1–4 give analytical coverage-wall
results, while §5 and several composition claims remain bounded fuzz/invariant assurance. The `lnWad`/`powWad`
transcendentals make SMT-based tools time out on precisely the interesting lemmas, so the
practical mainnet-grade path is: (1) this document + the fuzz/invariant suite now; (2) a scoped
Certora engagement pre-mainnet on `Pricing._covToll`/`_settleQuote`, `PoolLiquidity`, and the
`ExternalOracle` push state machine, using §§3–5 as the spec sheet. Do not attempt whole-protocol
symbolic proofs; scope beats coverage here.
