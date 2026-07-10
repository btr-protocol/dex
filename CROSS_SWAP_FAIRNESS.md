# Cross-Swap Fairness — spoke→spoke is NOT hub-double-taxed

*Owner question: in the stable-core pool (USDC = base) the dominant flow is between non-base stables
(USDT↔USD1↔USDe). Every such trade is a `spoke→base→spoke` cross. Requirement: a cross must trade on
the **two spokes' coverage only**, with the base hub a **net-neutral pass-through** — never charged
twice. Does the current AIMM double-tax the hub?*

**Date: 2026-07-08. All BTR claims verified against `dex/evm/src/**` at cited `file:line`. Backed by
the measured decomposition in `dex/evm/test/unit/CrossBaseImpact.t.sol`.**

---

## 1. VERDICT — decisive

| Question | Answer |
|---|---|
| Is the cross double-tax real? | **NO.** |
| Base-impact verdict | **Flat numeraire, zero impact.** The base is never priced and its reserves never move on a cross. |
| Are crosses discriminated vs a direct base leg? | **No.** A cross is priced identically to the two spoke legs it contains, each as a standalone direct-to-base leg. |
| Residual base double-tax | **≈ 0 bps.** Not "small" — structurally zero. |
| Net effect vs two manual hops | A cross is **~5.5 bps CHEAPER** (one path spread + one fee, not two). |

**Your instinct is already the implemented behavior — and by construction, not by fragile
cancellation.** You wanted the hub to contribute nothing and only the two spokes to be priced. That
is exactly what the code does. There is no leg1-cost-offsets-leg2-credit balancing act to worry about;
the base simply never enters the price and its inventory is never touched.

**Numbers (balanced 10M pool, USDC base, measured):**

| Size | X-spline (leg1, USDT sell) | Y-spline (leg2, USD1 buy) | base impact | path spread | output toll |
|---|---|---|---|---|---|
| 100k (1% depth) | ~0 bps | ~0 bps | **0** | 5.5 bps (once) | 0 (κ=0 default) |
| 3M (30% depth) | 1.48 bps (444.0e18) | 1.48 bps (443.87e18) | **0** | 5.5 bps (once) | 0 (κ=0 default) |

Cross @3M ≈ 8.5 bps total. Two separate hops @3M ≈ 14 bps. The two spoke splines are symmetric
(444.0e18 vs 443.87e18) — pure two-spoke pricing, no third term. The decomposition closes exactly
(`assertEq legX + legY + spread == amt - amountOut`).

---

## 2. Why crosses are hub-neutral — "your instinct is already built in"

A cross walks 2 legs (`_walkLegs → _executeLeg → _priceEdgeHop`, `Pricing.sol:457,475,550`); each
leg's `amountOut` feeds the next. Then `_settleQuote` (`:337`) applies, **once at path level**, the
spread, toll, and skew. The four settlement terms were already confirmed single/hub-neutral; the one
open question was the per-leg **spline price impact** on the base transit. It is provably zero, for two
independent reasons.

### 2a. The base is never a `profileAsset` ⇒ no base spline is ever built or traversed

`_executeLeg` picks which asset's curve prices the leg (`Pricing.sol:482-483`):

```solidity
bool isUpward = $.assets[from].anchor == to;
address profileAsset = isUpward ? from : to;
```

In a depth-1 star (`AnchorTree.MAX_DEPTH = 1`) every edge is spoke↔base, so exactly one endpoint is a
spoke and one is the base — and the base's anchor is `address(0)`, so it is never the "up" target:

- **Leg 1 `X→base`:** `X.anchor == base` ⇒ `isUpward = true` ⇒ `profileAsset = X` (the spoke).
  Priced on **X's** spline / reserves / mark (selling X). Base is only the leg's `to` endpoint — it
  caps the output (`_legScaleOut:506`) and gates depeg (`:322`); it has **no spline of its own**.
- **Leg 2 `base→Y`:** `base.anchor == Y` is false ⇒ `isUpward = false` ⇒ `profileAsset = Y` (the
  spoke). Priced on **Y's** spline (buying Y). Base is the `from` endpoint, consumed at par (mark ≡ 1
  / its own depeg breaker).

`profileAsset` is **always the spoke.** `$.profiles[base]` is never read on any edge (the
`profileAsset == baseToken` branch at `:515` is unreachable in a depth-1 star). Total price impact =
**X sell-spline (leg1) + Y buy-spline (leg2)**, each once. The intermediate "base amount"
(leg1-out = leg2-in) is a memory-only accounting quantity that chains the two splines at par — a
**change of numeraire**, not a priced hop. This holds for any base (a WETH base too, not just a ≈1
stable): the base is a *unit of account*, never a priced leg.

### 2b. Settlement is endpoint-only ⇒ base reserves don't move ⇒ no transient base coverage change

`PoolSwapQuote.processSwap` settles via `PoolIO.exec($, tk[0], tk[1], …)` with `tk[0] = tokenIn (X)`,
`tk[1] = tokenOut (Y)` — the two **endpoints** — and `PoolIO.exec` mutates only:

```solidity
aIn.reserves  += amtIn;                     // X += amountIn
aOut.reserves -= (amountOut + protoFee);    // Y -= amountOut
```

**The base hub's reserves are never written on a cross.** So there is no "drained by leg1, refilled by
leg2 that must net to zero" — the base is genuinely untouched. Base coverage `c_base = R/L` is
invariant across the cross; there is no transient wall or skew to double-count, even in principle.

### 2c. Spread / toll / skew are single and hub-neutral (recap)

1. **ONE path spread** `_pathSpread(acc, cacheIn, cacheOut)`, taken once on the final output
   (`:344, :358`). It is the **max** (not sum) of the two spokes' minFee/σ/confidence
   (`:379-385`) — a cross keys to the *worse* spoke, never the sum.
2. **ONE convex coverage toll** `_covToll` on the **output spoke only** (`:350, :653`); base
   `kappaCovBps = 0` ⇒ "numeraire never walled" (`:427`).
3. **Inventory skew on the two endpoint spokes only** (`cacheIn`/`cacheOut`, `:362-363`); the interior
   base hub is only halt/depeg-checked, never skewed or tolled.

### 2d. Net cost — a cross is cheaper than doing it manually

| Trade | Splines | Path spread | Coverage toll | Fee |
|---|---|---|---|---|
| Direct base leg `USDT→USDC` | 1 (USDT sell) | 1 | 0 (base out, κ=0) | 1 |
| **Cross `USDT→USD1`** | 2 (USDT sell + USD1 buy) | **1** | 1 (USD1 out only) | **1** |
| Two separate swaps | 2 | **2** | 1 | **2** |

A cross differs from a direct base leg by **exactly the second spoke's own spline + its output-side
wall** — the legitimate cost of moving USD1's inventory — and **nothing for the hub**. Versus doing the
two hops manually, the atomic cross **saves one spread and one fee**. Goal met: each spoke leg of a
cross is priced identically to that spoke as a standalone direct-to-base leg, and the base middle is
free.

### 2e. Contrast with Curve / Balancer

- **Curve StableSwap:** single invariant `D` over all balances; a cross prices **directly on the two
  coins' balances** through the shared `D`, one fee, no middle asset to tax.
- **Balancer:** spot `= (Bᵢ/Wᵢ)/(Bⱼ/Wⱼ)`; any pair swaps **directly**, one fee, no hop.

Curve/Balancer charge **one** joint-curve impact; BTR charges **two** independent spoke splines (X and
Y) but makes the hub **zero-cost**. So BTR has already eliminated the double-numeraire tax. The only
structural difference is **1 joint impact (Curve) vs 2 half-impacts (BTR spokes)** — a *calibration*
question (see §4), not an architectural double-tax. If anything BTR's two splines are **additive** (base
held flat ⇒ no coupling cross-term), so on large size a BTR cross is marginally *cheaper* than the
compounding joint curve, never an over-charge.

---

## 3. Peer comparison — BTR vs DoDo / Lifinity / Hashflow

Full write-up (cited, code-verified) in `dex/research/PEER_ARCHITECTURES.md`.

| Axis | DoDo (PMM) | Lifinity | Hashflow | **BTR AIMM** | Verdict |
|---|---|---|---|---|---|
| Price source | On-chain oracle `i` (Chainlink, coarse 0.5%/1h) | On-chain Pyth (per-slot) | Off-chain signed MM quote | Keeper-push external mark, **fresh (non-EMA)** | SAME family as DoDo/Lifinity; **NOT** RFQ |
| Mark freshness | 0.5%/1h feed | per-slot | per-request | deviation-θ + heartbeat, quoted fresh | **DIFFERS**: tightest oracle-lag bound of the on-chain three |
| Inventory law | PMM `i,k,R` (1 knob) | oracle-centered + DNMM rebalance | off-chain (opaque) | **A-S skew + Hermite-spline VWAP + convex wall** | **DIFFERS**: explicit, shaped, per-asset; richer than PMM's single `k` |
| Topology | isolated pairs | isolated pairs | RFQ per pair | **hub-and-spoke shared pool** | **DIFFERS from all** — only BTR shares one reserve set across N assets |
| Cross pricing | aggregator hops 2 pools | aggregator hops 2 pools | RFQ per pair | 2 spoke splines, **hub free** (this doc) | Hub-neutral by construction |
| Quoting | on-chain | on-chain | off-chain | **on-chain** | SAME as DoDo/Lifinity; DIFFERS from Hashflow |
| Settlement | on-chain | on-chain | on-chain | on-chain | SAME (all four) |
| Trust anchor | Chainlink + LP | Pyth + POL | permissioned MM signer | **keeper mark writer** + on-chain breakers | Closest to Lifinity; LP-open |
| LVR defense | curve arb'd on lag | per-slot freshness | no curve (MM eats it) | **fresh mark + σ√τ premium + minFee≈2θ** | **DIFFERS**: only BTR explicitly *prices* residual keeper-lag |
| LP model | permissionless | POL (closed) | MM inventory | **permissionless (internal LP ledger)** | SAME as DoDo; DIFFERS from Lifinity/Hashflow |
| Per-asset peg mode | no | no | n/a | **EXTERNAL \| INTERNAL(peg)** | **UNIQUE to BTR** |

**One-liner:** BTR is oracle-priced + fully on-chain like DoDo/Lifinity (not RFQ like Hashflow), but is
the only one with a shared hub-and-spoke pool, the only one quoting off a fresh deviation-gated mark
with an explicit σ√τ staleness premium, and the only one with a shaped A-S/spline/convex-wall law plus
per-asset external|peg mode — while keeping DoDo's permissionless LP.

---

## 4. Fix status — no launch-blocking code fix; one optional tune

**No code fix is warranted.** There is no base double-tax to remove: the base-profile branch is
unreachable in a depth-1 star, base `kappaCov = 0`, the base only clamps/gates, base reserves never
move, and the decomposition closes exactly. `Pricing.sol` already satisfies the owner's requirement.
**Ship the stable pool as-is on this axis — it is NOT launch-blocking.**

Two genuine non-idealities exist. Neither is a tax; neither blocks launch.

**(A) Calibration TUNE (recommended, not code) — "2 spoke half-impacts ≈ 1 Curve joint hop".**
A BTR cross traverses two spoke curves where Curve traverses one joint curve. To be competitive with a
Curve single-hop at the stable-core size distribution, calibrate each spoke **shallow/wide** enough
that the two half-impacts sum to ≈ one Curve impact. Lever = per-spoke `depthAmplifier` /
`minDispersion`–`maxDispersion` / spline weights (flatter central knots ⇒ near-zero impact for in-band
stable sizes). This is a **`LAUNCH_PARAMS` calibration target for `project_stable_core_study`**, driven
by the BSC stable tape, **not** a `Pricing.sol` change. Classification: **tune, pre-launch, data-driven.**

**(B) Optional code lever (NOT recommended now) — path-spread blend.**
The single path spread is the path-**max** of the two spokes' minFee/vega/confidence (`:379-385`), not
a size-weighted blend. For a homogeneous stable basket (all spokes identical params) `max` == the
common value, so a cross pays exactly one spread at the same rate as a direct base leg — the owner's
case is already exact parity. Only if heterogeneous spoke params + strict cross==direct-leg parity are
ever wanted would you swap the path-max in `_pathSpread` for a size-weighted mean of the two legs' fee
floors (still charged once, still hub-neutral). **Not recommended:** `max` is safer under keeper lag /
feed uncertainty (quote uncertainty bounded by the least-certain leg), and the stable-core basket is
homogeneous. Classification: **deferred, not needed for launch.**

**Regression guard:** `dex/evm/test/unit/CrossBaseImpact.t.sol` already asserts the exact decomposition
(zero base impact, symmetric two-spoke splines, single spread, closure). Keep it green as the invariant
lock. If a maintainer ever wants tighter coverage, extend it with a heterogeneous-decimals case
(6dec↔18dec spokes) and a κ>0 output-toll case — **as tests, next; no `Pricing.sol` edit needed.**

---

## 5. Bottom line

- **No hub double-tax.** Spread, toll, skew are single and hub-neutral; the base contributes **zero**
  spline impact and its reserves are **untouched**. The hub is a true net-neutral pass-through by
  construction.
- A cross = the two spoke legs priced exactly as direct base legs, minus the double spread/fee you'd
  pay doing them manually.
- The only irreducible cost above a direct base leg is the **second spoke's own spline** — correct, not
  a tax (you *are* moving a second asset).
- **Not launch-blocking.** Match Curve-single-hop competitiveness by calibrating per-spoke
  depth/dispersion in `stable-core` `LAUNCH_PARAMS`, not by touching the routing law.
