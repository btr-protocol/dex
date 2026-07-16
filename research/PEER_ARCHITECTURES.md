# BTR AIMM vs Peer Oracle/RFQ AMMs — Architecture Comparison

*Scope: DoDo (PMM), Lifinity (oracle-AMM), Hashflow (signed RFQ) — the three venues the auditor
named — versus the BTR AIMM. Every BTR claim is verified against `dex/evm/src/**` at the cited
`file:line`. Peer claims are cited to public docs (Sources at end). Date: 2026-07-08.*

---

## 0. BTR AIMM — verified reference (what we actually built)

| Axis | BTR AIMM | Code proof |
|---|---|---|
| **Price source** | Keeper-pushed **external mark**, quoted **FRESH** (the last pushed price, *not* an EMA). "Quoting off this (not the EMA) kills LVR." | `Oracle.mark()` returns `lastPriceB64`; `Oracle.sol:12-15`. Leg reads it via `_legMarkAndFees` → `Oracle.mark(feed)`, `Pricing.sol:519-521`. |
| **Push policy** | Deviation-θ + heartbeat: keeper snaps mark only when truth drifts past a per-asset θ *or* the heartbeat elapses ⇒ steady-state stale gap bounded to θ. | Sim reference `OracleMode::Deviation`, `aimm.rs:33,423-434`. |
| **Inventory / skew** | **Avellaneda-Stoikov linear skew** ψ from coverage `c=R/L`, mapped to a start position on the depth axis; **Hermite-spline VWAP** over the traversed depth band (exact analytic integral); **convex coverage wall** toll on the drained output. | `computeInventorySkew` `Pricing.sol:35-55`; `_traverseSplineByVolume` `:148-207` + `Spline.area` `:44`; `_covToll`/`_covQ` `:653-668`, Q(c)=ln c−c+1. |
| **Multi-asset topology** | **Hub-and-spoke shared pool**, depth-1 star: one base hub, N spokes each anchored to base. Cross = spoke→base→spoke, both legs real edges. One shared reserve set. | `AnchorTree.MAX_DEPTH=1` `:14`; `validateAnchor` `:17-30`; `findRoutingPath` `:34-61`. |
| **Per-asset oracle mode** | **EXTERNAL** (quote off keeper mark) or **INTERNAL** (quote off fixed peg `pegB64`, synthetic never-stale feed; external feed retained only as depeg breaker). | `OracleConfig.mode` `IPool.sol:57-71`; `_fetchFeed` `Pricing.sol:616-618` → `Oracle.getPegFeed`. |
| **On/off-chain quoting** | **Fully on-chain** quote *and* settlement. Keeper only pushes a mark (an oracle write); the entire quote law (spline VWAP, skew, spread, toll, fee split) runs in `Pricing.getAnchorPathQuote`. No signed quotes, no off-chain pricing function. | `PoolSwap.swap → Pricing.getAnchorPathQuote` `PoolSwap.sol:39`, `Pricing.sol:287-332`. |
| **Trust model** | Keeper/oracle role pushes the mark (single trusted writer per feed today). Defended by: TTL staleness revert, confidence-halt, σ√τ staleness premium, per-asset depeg breakers, base-depeg halt. Open-source. | `_fetchFeed` gates `:607-627`; `_pathSpread` staleness/confidence `:376-397`; `_readBasePriceOrHalt` `:438-452`. |
| **LVR handling** | External fresh-mark quoting removes the CFMM-LVR channel *structurally* (paper-validated). Residual keeper-lag pick-off is priced by the σ√τ staleness premium; `minFee≈2θ` makes the θ-gap pick-off unprofitable. | Staleness premium `_staleTerm` `:388-397`; memory `project_aimm_paper_validation`. |
| **Permissionless** | Trading permissionless; LP permissionless (deposit/withdraw; internal non-transferable LP ledger + liquidity index); pools via factory. Keeper is a trusted infra role, but the quote is fully on-chain verifiable. | `IPool.deposit/withdraw/swap` `IPool.sol:248-298`. |

---

## 1. DoDo — Proactive Market Maker (PMM)

- **Price source.** External **on-chain oracle** = the *guidance price* `i` (Chainlink `latestAnswer()`,
  updates on 0.5% deviation or 1h). PMM concentrates liquidity around `i`.
- **Inventory / skew — the `i`/`k`/`R` law.** Price is a closed-form function of inventory ratio
  `R = B/B₀` (current base ÷ equilibrium target) and a slippage/liquidity parameter `k ∈ (0,1)`:
  - base in **excess**: `P = i·(1 − k + k·(B₀/B)²)`
  - base in **deficit**: `P = i / (1 − k + k·(B/B₀)²)`
  - `k→0` = flat price / infinite depth at `i`; `k→1` ≈ constant-product. Slippage ≈ `k·(ΔB/B₀)²`.
  This is a **single-parameter inventory-guidance** curve: one shape knob `k`, one center `i`.
- **Multi-asset topology.** **Isolated pools, one per pair** (a base-token pool + quote-token pool
  coupled only through the PMM formula). No shared hub; a cross is an aggregator hopping two pools.
- **On/off-chain.** Fully **on-chain** quoting + settlement; the curve is evaluated in the contract,
  the oracle read is on-chain.
- **Trust.** Chainlink (+ optional Band backup) oracle; LPs. Pool creation is **permissionless**
  (DPP/DVM/DSP pool types).
- **LVR.** Concentrating around `i` cuts slippage, but the Chainlink feed is coarse (0.5% / 1h) ⇒
  large stale-gap windows ⇒ the on-chain curve is arbitraged on every oracle lag; `k` only trades
  depth for that exposure. No staleness-priced spread.

## 2. Lifinity — oracle AMM / Delta-Neutral MM (DNMM)

- **Price source.** **Pyth** on-chain oracle, pushed **every slot (~0.4s) with a confidence
  interval**. Lifinity is "the first oracle-based DEX on Solana" — it prices off Pyth, not off pool
  balances, which is what removes reliance on arbitrageurs to move the price.
- **Inventory / skew.** Concentrates liquidity **around the Pyth price** and rebalances on every trade
  / every oracle move. **v2 (DNMM)** targets the *originally deposited* base amount and rebalances to
  50/50 only after the price has moved a set amount ⇒ inventory-aware "buy-low/sell-high" that can
  *reverse* IL. This is neither a PMM-`i` curve nor an explicit A-S reservation price — it is
  oracle-centered concentration + a rebalancing target. Pyth confidence widens the effective spread /
  front-run resistance.
- **Multi-asset topology.** **Isolated pairs** (per-pool), not a shared hub.
- **On/off-chain.** Fully **on-chain** Solana program; oracle is Pyth's on-chain push.
- **Trust.** Pyth oracle + **Protocol-Owned Liquidity**: external LPs *cannot* add liquidity —
  liquidity is protocol-owned and backs LFNTY; governance (veLFNTY) controls pools.
- **LVR.** Per-slot Pyth updates + concentration + delta-neutral rebalancing minimize IL/LVR
  structurally; the sub-second cadence is the main LVR defense. No explicit σ√τ staleness spread —
  it leans on Pyth freshness + confidence.
- **Permissionless.** **No** — LPing is closed (POL), pool set is curated. Trading is open.

## 3. Hashflow — signed RFQ

- **Price source.** A **cryptographically signed RFQ quote** from a professional market maker. There
  is **no on-chain oracle and no AMM curve** — the MM computes price off-chain with its own model.
- **Inventory / skew.** **None on-chain.** All inventory/skew logic lives inside the MM's private
  off-chain pricer; the chain only verifies a signature.
- **Multi-asset topology.** **RFQ-per-pair**: the taker requests a quote for a specific pair; the MM
  holds inventory (possibly on multiple chains, enabling bridgeless cross-chain swaps).
- **On/off-chain.** **Quoting off-chain, settlement on-chain**: the settlement contract validates the
  MM signature and executes. Off-chain pricing ⇒ quotes never hit the mempool ⇒ MEV-resistant.
- **Trust.** **Permissioned market makers** (Hashflow core-team due-diligence, KYC, legal contracts,
  allowlist). The taker trusts the MM's signed quote; the quote is **firm for its validity window**
  (the MM bears the volatility risk during that window — no taker-side slippage). Signer = MM key.
- **LVR.** No curve ⇒ **no CFMM LVR by construction**; the MM internalizes adverse selection and
  prices it into the RFQ spread. Taker sees **zero slippage / guaranteed execution**.
- **Permissionless.** **No** on the MM side (KYC/allowlist); taker side is open. Stated long-term goal
  is permissionless MMs.

---

## 4. Where BTR DIFFERS / is the SAME

| Axis | DoDo (PMM) | Lifinity | Hashflow | **BTR AIMM** | BTR verdict |
|---|---|---|---|---|---|
| Price source | On-chain oracle `i` (Chainlink, coarse) | On-chain Pyth (per-slot) | Off-chain signed MM quote | Keeper-push external mark, **fresh** | **SAME** family as DoDo/Lifinity (oracle-priced), **NOT** RFQ |
| Mark freshness | 0.5%/1h feed | per-slot | per-request | deviation-θ + heartbeat, quoted fresh | **DIFFERS**: tightest oracle-lag bound of the on-chain three |
| Inventory law | PMM `i,k,R` closed form | oracle-centered + DNMM rebalance | off-chain (opaque) | **A-S skew + Hermite-spline VWAP + convex wall** | **DIFFERS**: explicit, shaped, per-asset; strictly richer than PMM's single `k` |
| Topology | isolated pairs | isolated pairs | RFQ per pair | **hub-and-spoke shared pool** | **DIFFERS** from all three (only BTR shares one reserve set across N assets) |
| Quoting | on-chain | on-chain | off-chain | **on-chain** | **SAME** as DoDo/Lifinity; **DIFFERS** from Hashflow |
| Settlement | on-chain | on-chain | on-chain | on-chain | **SAME** (all four) |
| Trust anchor | Chainlink + LP | Pyth + POL | permissioned MM signer | **keeper mark writer** (+ on-chain breakers) | Closest to Lifinity (oracle-trust), but LP-open |
| LVR defense | curve arb'd on lag | per-slot freshness | no curve (MM eats it) | **structural (fresh mark) + σ√τ premium + minFee≈2θ** | **DIFFERS**: only BTR explicitly *prices* residual keeper-lag |
| LP model | permissionless | POL (closed) | MM inventory | **permissionless (internal LP ledger)** | **SAME** as DoDo; **DIFFERS** from Lifinity/Hashflow |
| Permissionless MM/keeper | oracle | oracle | permissioned | keeper (trusted, but law is on-chain-verifiable) | Between: oracle-trust like DoDo/Lifinity, verifiable like neither RFQ |
| Per-asset peg mode | no | no | n/a | **EXTERNAL \| INTERNAL(peg)** | **UNIQUE** to BTR |

**One-line synthesis.** BTR is an **oracle-priced, on-chain, fully-settled AMM** like DoDo/Lifinity
(not an off-chain RFQ like Hashflow), but it is the **only one with a shared hub-and-spoke pool**, the
**only one that prices off a fresh (non-EMA) deviation-gated mark with an explicit σ√τ staleness
premium**, and the **only one with a shaped A-S/spline/convex-wall inventory law plus a per-asset
external|peg mode**. It keeps DoDo's permissionless LP while gaining Lifinity's oracle-freshness idea
and Hashflow's "no-CFMM-LVR" property (via fresh marks rather than off-chain signing).

---

## 5. OWNER GOAL — spoke→spoke crosses must not be hub-double-taxed

**Context.** In the stable-core pool USDC is the base, but the dominant flow is between *non-base*
stables (USDT↔USD1↔USDe). Every such trade is a `spoke→base→spoke` cross. The requirement: a cross
`USDT→USD1` must trade on **the two spokes' coverage only**, with the base hub a **net-neutral
pass-through** — never charged twice.

### 5.1 Already-verified as single / hub-neutral (recap, not re-derived)

A cross walks 2 legs (`_walkLegs → _executeLeg → _priceEdgeHop`, `Pricing.sol:457,475,550`), each
leg's `amountOut` feeding the next. Then `_settleQuote` (`:337`) applies, **once at path level**:

1. **ONE path spread** `_pathSpread(acc, cacheIn, cacheOut)`, taken once on the final output
   (`:344,358`). It is the **max** (not sum) of the two legs' minFee/σ (`:379-385`, accumulated by
   `max` at `:468-470`) — so a cross is keyed to the *worse* spoke, never the sum of both.
2. **ONE convex coverage toll** `_covToll(cacheOut, …)` on the **output spoke only** (`:350`); base
   `kappaCov=0` = "numeraire never walled" (`:422`).
3. **Inventory skew on the two endpoint spokes only** (`cacheIn`/`cacheOut`, `:361-362`); the interior
   base hub is **only halt/depeg-checked, never skewed or tolled** (`:319-323`).

So SPREAD, TOLL, SKEW are already single and hub-neutral. ✔

### 5.2 The open question — the base-transit spline impact — ANSWERED

**Verdict: the base contributes ZERO spline price impact, and its reserves are never even touched.
Option (c) in your framing is correct: the base is a flat numeraire pass-through; only the two spoke
splines are traversed, once each. No double-charge — not by cancellation, but by construction.**

Two independent code facts prove it:

**(a) The base is never a `profileAsset` ⇒ no base spline is ever built or traversed.**
In `_executeLeg` (`Pricing.sol:482-483`):
```solidity
bool isUpward = $.assets[from].anchor == to;
address profileAsset = isUpward ? from : to;
```
In a depth-1 star every edge is spoke↔base, so exactly one endpoint is a spoke and one is the base:
- **Leg 1** `X→base`: `from=X`, `X.anchor==base` ⇒ `isUpward=true` ⇒ `profileAsset = X` (spoke).
  Priced on **X's** spline, X's reserves/liabilities, X's mark (selling X).
- **Leg 2** `base→Y`: `from=base`, `base.anchor==Y` is **false** (base's anchor is `address(0)`) ⇒
  `isUpward=false` ⇒ `profileAsset = Y` (spoke). Priced on **Y's** spline (buying Y).

`profileAsset` is **always the spoke**. `$.profiles[base]` is **never read** on any edge; the base has
no `LiquidityProfile`/spline traversed. Total price impact = **X sell-spline (leg1) + Y buy-spline
(leg2)**, each once. The intermediate "base amount" (leg1 out = leg2 in) is a memory-only accounting
quantity chaining the two splines; it carries value X→Y at the two spoke marks with **no curve of its
own**. This holds regardless of the base's price level (works for a WETH base too, not just a ≈1
stable) — the base is a *unit of account*, not a priced leg.

**(b) Settlement is endpoint-only ⇒ base reserves don't move ⇒ no transient base coverage change.**
`PoolSwap.swap` settles via `PoolIO.exec($, tk[0], tk[1], actualIn, q, …)`
(`PoolSwap.sol:47`, inlined post-C1) with `tk[0]=tokenIn (X)`, `tk[1]=tokenOut (Y)` — the two **endpoints**.
`PoolIO.exec` (`PoolIO.sol:88-109`) does only:
```solidity
aIn.reserves  += amtIn;                    // X += amountIn
aOut.reserves -= (q.amountOut + protoFee); // Y -= amountOut
```
The base hub's reserves are **never mutated** on a cross. So the base is not "drained by leg1 then
refilled by leg2" that must net to zero — it is genuinely untouched. Base coverage `c_base=R/L` is
invariant across the cross; there is no transient wall/skew to double-count even in principle.

**Net cost comparison (USDC = base):**

| Trade | Splines traversed | Path spread | Coverage toll | Fee |
|---|---|---|---|---|
| Direct base leg `USDT→USDC` | 1 (USDT sell) | 1 | 0 (base out, κ=0) | 1 |
| Cross `USDT→USD1` | 2 (USDT sell + USD1 buy) | 1 | 1 (USD1 out only) | 1 |
| Two separate swaps `USDT→USDC`, `USDC→USD1` | 2 | **2** | 1 | **2** |

The cross differs from a direct base leg by **exactly the second spoke's own spline + its output-side
wall** — the *legitimate* cost of moving USD1's inventory — and **nothing for the hub**. Versus doing
the two hops manually, the atomic cross **saves one spread and one fee**. Your goal is met: each spoke
leg of the cross is priced identically to that spoke as a standalone direct-to-base leg, and the base
middle is free.

### 5.3 How Curve / Balancer price the same non-numeraire↔non-numeraire swap (topology contrast)

- **Curve StableSwap.** A single invariant `D` over *all* coin balances. A cross `USDT→USD1` in an
  n-coin pool is priced **directly on the two coins' balances** through the shared `D`, with **one
  fee**, **no intermediate hop**. There is no numeraire and no "middle asset" to tax; the other coins
  enter only through the aggregate `D`.
- **Balancer weighted-product.** Spot `= (Bᵢ/Wᵢ)/(Bⱼ/Wⱼ)`; any pair swaps **directly** on just those
  two token balances/weights, **one swap fee**, no hop.

**Contrast.** Curve/Balancer charge **one** joint-curve impact on a cross; BTR charges **two**
independent spoke splines (X and Y) but makes the hub itself **zero-cost**. So BTR has already
eliminated the *double-numeraire tax* the auditor worried about — the base is free. The remaining
structural difference is **1 joint impact (Curve) vs 2 half-impacts (BTR spokes)**, which is a
*calibration* question, not an architectural double-tax:

- BTR's per-asset splines are strictly **richer** than Curve's blended `D` — each stable carries its
  own σ, peg (`pegB64`), depth (`depthAmplifier`), spline weights/knots, and convex wall — so a cross
  can be priced with per-asset precision Curve cannot express, and the covToll can protect a single
  scarce stable without walling the whole pool.
- The cost of that richness: a cross traverses two spoke curves. To make a cross **competitive with a
  Curve single-hop**, calibrate each spoke's spline shallow/wide enough that *two spoke half-impacts ≈
  one Curve joint impact* at the size distribution from the stable-core tape. Concretely: since a
  direct base leg is already one spoke spline, and a cross adds exactly the second spoke spline, the
  lever is per-spoke `depthAmplifier` / `min–maxDispersion` / `weights` (flatter central knots ⇒ near-
  zero impact for in-band stable sizes). This is the `LAUNCH_PARAMS` calibration target of
  `project_stable_core_study` (heavy spoke↔spoke flow expected), not a code change.

### 5.4 Bottom line for the owner

- **No hub double-tax exists.** Spread, toll, skew are single and hub-neutral (5.1); the base
  contributes **zero** spline impact and its reserves are **untouched** (5.2). The hub is a true
  net-neutral pass-through **by construction**, not by fragile cancellation.
- A cross = the two spoke legs priced exactly as they would be as direct base legs, minus the double
  spread/fee you'd pay doing them separately.
- The only thing standing between "a cross" and "a single direct base leg" is the **second spoke's own
  spline** — irreducible (you *are* moving a second asset) and correct. Match Curve-single-hop
  competitiveness by **calibrating per-spoke depth/dispersion**, not by touching the routing law.

---

## Sources

**BTR (code, this repo):** `dex/evm/src/libraries/Pricing.sol`, `Oracle.sol`, `AnchorTree.sol`,
`PoolIO.sol`, `PoolSwap.sol`, `Spline.sol`; `dex/evm/src/interfaces/IPool.sol`;
`prime/crates/ml/src/amm/aimm.rs`. Memory: `project_stable_core_study`, `project_aimm_paper_validation`.

**DoDo (PMM):** DODO Docs — PMM Algorithm <https://docs.dodoex.io/en/product/pmm-algorithm>;
BlockEden DeFi course 5.8 <https://blockeden.xyz/course/defi/5.8/>; Gate Learn "What is DODO"
<https://www.gate.com/learn/articles/what-is-dodo/626>.

**Lifinity:** lifinity.io <https://lifinity.io/>; Lifinity Docs <https://docs.lifinity.io/>;
Pyth × Lifinity <https://www.pyth.network/blog/pythiad-to-lifinity-and-beyond>; DefiLlama Lifinity v2
<https://defillama.com/protocol/lifinity-v2>.

**Hashflow:** Consensys overview
<https://consensys.io/blog/hashflow-a-dex-for-bridgeless-cross-chain-swaps-zero-slippage-and-mev-protected-trades>;
Messari "Certainty in Execution" <https://messari.io/report/hashflow-certainty-in-execution>;
Hashflow market-making docs <https://docs.hashflow.com/hashflow/market-making/getting-started-api-v3>;
LogRocket "How to market make and transact with Hashflow"
<https://blog.logrocket.com/how-to-market-make-transact-hashflow/>.

**Curve / Balancer:** Curve StableSwap whitepaper (single-invariant `D`); Balancer weighted-math docs.
