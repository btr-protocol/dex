# BTR DEX — corrections to the auditor's understanding (verified against code, 2026-07-07)

The auditor's technical read is largely accurate. Two headline items are wrong; both are corrected below with
file:line evidence. (Verification ran as an agent over the real Solidity; nothing here is from the READMEs.)

## ✅ CORRECT (no change)
- **No Chainlink in the DEX.** `rg chainlink|latestRoundData|AggregatorV3` over `dex/evm/src` = 0 hits. The
  "external oracle" is a **keeper-push** oracle (`ExternalOracle.sol`, `onlyOracle` modifier :52, push :121 /
  batch :132). *Nuance:* the sibling `shared/evm/src/oracle/PriceProvider.sol` has Chainlink feeds, but it is
  **not imported** in the DEX quote path — `dex/evm/src` is 100% keeper-push.
- **Swaps price off the fresh keeper mark (`lastPriceB64`), not the EMA.** `Oracle.mark()` = `b64To1e18(lastPriceB64)`
  (Oracle.sol:12-15); `Pricing.sol:433/506` quote off it on every leg. Quoting the fresh mark (not a lagging
  internal EMA) is what kills LVR. The `emaPriceB64` is a servable reference only; pricing σ = on-chain σ-EMA
  (`getSigma`), never the raw keeper sample.

## ❌ WRONG #1 — "keeper code lives in dex/ and should move to keepers/"
**There is NO keeper code in `dex/` to move.** The push daemon already lives in the sibling repo:
`keepers/src/oracle/{mod,config,b64,nxr}.rs` — deviation-θ + heartbeat ExternalOracle push, per-feed
`theta_bps` + `heartbeat_s` (config.rs:19-20, mod.rs:44-47). In `dex/`: `scripts/` = docs/build/plot tooling,
`evm/script/*.s.sol` = Foundry deploys, `evm/src/testnet/` = TestnetERC20+Faucet. The only oracle thing in `dex`
is the **on-chain receiving side** (`ExternalOracle.sol`, the `onlyOracle` push endpoint) — which correctly
belongs in the contracts repo. **Repo separation is already correct.**

## ❌ WRONG #2 — "the pool keeps the SAME FROZEN PRICE between two pushes"
Only the **MARK (anchor) is frozen** between pushes. The **quoted price drifts with order flow**:

    P = mark · (1 + ψ(coverage)) ± halfSpread

Every swap mutates reserves (PoolIO.sol:104-105) → coverage `c = R/L` shifts → skew
`ψ = γ·100·(1−c)/(1−c_min)`, clamp ±100 (Pricing.sol:35-55) → price offset = `ψ·κ/100` (`_skewToPrice` :245).
So arbs **already drag the pool toward external truth between pushes, via inventory** — this is the
Avellaneda-Stoikov reservation price. The oracle push just **re-centers** the mark.

**Consequence for the arb surface** (the auditor's real interest): the exploitable gap is NOT "the whole
between-push window at a fixed price." It's bounded to the **mark error ≤ θ** (deviation threshold) until the
next push, and the inventory skew **partially recaptures** the arb's edge into the pool (recovered LVR) —
informed flow pays a skew toll ∝ `κ·displacement²` (Glosten-Milgrom), noise flow pays ~only `minFee`
(MIN_FEE_PBPS=1 = 0.01bp, sub-1bp vs the PCS-v3 1bp incumbent). Backstops past skew saturation (±κ): σ√staleness
premium (Pricing.sol:374-383) + hard TTL halt (:598-601). The **skew steepness κ** is the competitive-vs-defensive
lever, not a flat fee.

## Doc hygiene — FIXED (commit 001955c)
The auditor was partly misled by stale READMEs. Corrected: `dex/CLAUDE.md`, `dex/README.md`, `dex/evm/README.md`
no longer say "dual-EMA internal oracle" / "Chainlink-style adapter" / list the deleted `PoolOracle`. Remaining
cosmetic follow-up (NOT done — money-path file, needs build+test): `Pricing.sol` still NAMES the mark variable
`twap` (stale; it is the keeper mark, not a TWAP) at :62,111,161,196,202,205,471,502,506.

## What to build next for the arb study (auditor's own question)
The edge timing = keeper **push cadence**. That lives in `keepers/src/oracle/` (θ per feed + heartbeat). The
signal to watch off-chain = the `Pushed` event (per-feed price update = the clock) + `Swapped` (spread+fees).
