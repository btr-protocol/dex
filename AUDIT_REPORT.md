# BTR DEX Audit — From Scratch (2026-07-10)

> **Team review packet:** [`AUDIT_TEAM_BRIEF.md`](AUDIT_TEAM_BRIEF.md) (file map, verify commands, Slack blurb).  
> This file is the cycle-by-cycle auditor ledger.

> Scope: `dex/evm/src/**` (excl. `incumbents/`, `testnet/`) + `keepers/src/oracle/**` +
> `keepers/src/executor.rs`. Method: each **cycle** = 3 independent Grok 4.5 cohorts
> (Security / Gas-swap / Lean) → adversarial challenge (≥2/3) → confirmed findings fixed +
> regression-tested → re-audit. Iterated until a full cohort batch surfaces no new actionable
> BUG/SECURITY/GAS (≥200 warm swap).
>
> Prior converged report (cycles 1–5, 12 findings) is **known-fixed baseline only** — this run
> starts from scratch on the current working tree and does not re-flag those items unless
> regressed.

## Headline

- **0 CRITICAL · 0 HIGH · 0 MED** actionable after convergence.
- **3 cycles** · gas-first + security + lean · **warm 1-hop swap −6.3k to −8.0k gas** vs baseline.
- Peak new severity this run: **Low** (batchSwap unwrap asymmetry; decay re-enable catch-up).
- Cycle 3 batch: **CONVERGED** (INFO residuals only).

## Gas delta (GasProbe, warm exact-in)

| Probe | Baseline | Post C1 | Post C2 (final) | Δ vs baseline |
|---|---:|---:|---:|---:|
| `swap_base_spoke_warm` | 61 243 | 55 219 | **54 890** | **−6 353 (−10.4%)** |
| `swap_spoke_base_warm` | 55 827 | 49 812 | **49 499** | **−6 328 (−11.3%)** |
| `swap_spoke_spoke_warm` | 83 952 | 76 428 | **75 978** | **−7 974 (−9.5%)** |
| `swap_base_spoke_cold` | 176 007 | 162 665 | 162 336 | −13 671 |
| `swap_spoke_spoke_cold` | 224 971 | 205 292 | 204 842 | −20 129 |

Bytecode (post-C2): `PoolSwap` 16 159 B (EIP-170 headroom ~8 KB); `Pool` 21 633 B.

---

## Cycle 1

3 cohorts → challenge → **fixes applied**.

| # | Sev/Class | Location | Finding | Verdict | Disposition |
|---|---|---|---|---|---|
| G-1/L-1 | GAS/LEAN | `PoolSwapQuote` | DELEGATECALL trampoline + ABI-encode `SwapQuote` on every swap | REAL 2/2 | **FIXED** — deleted library; inline `PoolIO.exec` in `PoolSwap` |
| G-2 | GAS | `Pricing._quotePath` | `routeHops`/`hopAmounts` always allocated on exec | REAL | **FIXED** — allocate only when `analytics` (view path) |
| G-4 | GAS | `PoolSwap` + `PoolDecay` | `checkRisk` + `applyDecay` each SLOAD `riskConfigs` | REAL | **FIXED** — `checkRiskFlags` + `applyDecay(asset, rc)` |
| G-5 | GAS | `PoolSwap` | Post-exec `minLiquidity` check dominated by `exec` | REAL | **FIXED** — removed |
| G-6/G-9 | GAS | `Pricing` | Full `OracleConfig`/`RiskConfig` memory copies | REAL | **FIXED** — storage refs |
| G-7 | GAS | `PoolIO.exec` | `protocolFees +=` even when `protoFee==0` | REAL | **FIXED** — guarded |
| L-4 | LEAN | `IExchange.sol` | Empty alias | REAL | **FIXED** — deleted |
| L-6 | LEAN | `PoolIO.checkRisk` | Dead `FLASH_ENABLED` branch | REAL | **FIXED** — removed |
| L-12 | LEAN | `Pricing.calculateDepth` | `liabilities==0 ? 1 : 1` | REAL | **FIXED** |
| A-07 | Low/BUG | `PoolBatch` | Always unwraps `wnative` → ETH | REAL Fix-now | **FIXED** — unwrap only if packed `SC.NATIVE`. Regression: `BatchSwapNativeParity.t.sol` |

Refuted / deferred this cycle: A-01 UniPoolOracle (non-prod primary), A-02/A-03/A-09 owner trust, A-04 bootstrap seal (accepted), A-05 CI halt (accepted pusher), A-06 flashAccount (Flash immutable), A-08 keeper TTL (bounded), L-2/L-3 storage layout (Chapel live), G-3/G-8 overstated, NatSpec cosmetics.

**Tests:** 318+ green (excl. env-gated `DeployScript`).

---

## Cycle 2 (re-audit)

| # | Sev/Class | Location | Finding | Verdict | Disposition |
|---|---|---|---|---|---|
| A2-1 | Low/BUG | `PoolDecay` / `setRiskConfig` | Re-enabling decay charged `dt` across the disabled window | REAL Fix-now | **FIXED** — seed `lastUpdate` in `initAsset`; reset clock on decay (re)enable in `setRiskConfig`. Hot path stays 0-SSTORE when off. Regression: `test_applyDecay_noRetroactiveCatchUpAfterReenable` |
| G2-4 | GAS | `PoolIO.exec` | Re-bound `$.assets[]` despite warm refs in `PoolSwap` | REAL | **FIXED** — `exec(..., aIn, aOut)` overload |
| G2-5 | GAS | `PoolBatch` / `swapLiability` | Still dual risk SLOAD | REAL | **FIXED** — shared flags+decay |
| L2-1 | LEAN | `Pricing._legMarkAndFees` | Dead `profileAsset==base` branch (depth-1 star) | REAL | **FIXED** — removed |

Overstated / deferred: A2-2 base `SWAP_ENABLED` (hub kill = HALT by design), G2-1/2/3 micro-opts (<200 or API ripple).

**Tests:** 332 green. Warm swap −300 to −450 vs post-C1.

---

## Cycle 3 (convergence)

Full Security+Gas+Lean batch → **0 Fix-now**. **CONVERGED.**

INFO residuals (not defects):

1. Batch hub decay omitted when base is interior-only (κ_base≡0; pricing unaffected).
2. Payable ERC-20 entrypoints can strand accidental `msg.value` (no ETH sweep).
3. `flashFeeBps` unbounded in `setFeeParams` (admin misconfig → flash DoS, not drain).

---

## Accepted design decisions

- Single oracle pusher key + on-chain `maxDeviation` / 1-push-per-feed-per-block (P4).
- Owner = pauser (dedicated pauser role = mainnet hardening).
- Untimelocked `setAssetParams` / `setFlowCooldown` (owner trust).
- Bootstrap `addAsset` until `sealBootstrap`.
- Hub inventory stop = `HALT_MASK`, not `SWAP_ENABLED` on base.
- `UniPoolOracle` spot adapter is **not** a production primary (keeper `ExternalOracle` is).

## Deferred (pre-mainnet / layout)

- Storage: init `liquidityIndex`, drop `lastLPStakeTime` (breaks Chapel clones).
- NatSpec archaeology trim; OpType dead variants (ABI ordinals).
- Optional: hoist `baseToken`, fixed `RoutePath`, EndpointCache mark pass (≤500 gas).
- Keeper: sync on-chain mark after `PENDING_TTL`; clamp push confidence.

---

## Convergence summary

| Cycle | Confirmed & fixed | Peak sev | Warm swap Δ (base→spoke) |
|---|---|---|---|
| 1 | 10 (gas/lean) + A-07 | Low | −6.0k |
| 2 | A2-1 + 3 gas/lean | Low | −6.3k cumulative |
| 3 | **0** | — | interim converge |
| 4 | 3 lean deletes | — | lean only |
| 5 | **0** | — | **CONVERGED** |

**5 cycles · Grok 4.5 only · 0 CRITICAL/HIGH · warm swap ≈ −10% · cycles 4–5 zero Fix-now security/gas.**

_Method: auditors/challengers read-only; engineer applied fixes; each cycle re-audited the fixed tree. `GasProbe.t.sol` is the gas SSoT._

---

## Cycle 4 (post-push re-audit)

Security cohort: **CONVERGED_SECURITY** (0 new BUG/SECURITY).

Gas/Lean: G4-1/G4-2 overstated by challenger (≤350, deferred). Lean deletes confirmed:

| # | Class | Location | Disposition |
|---|---|---|---|
| L4-1 | LEAN | `PoolIO.exec` 4-arg overload | **FIXED** — deleted (all callers pass Asset refs) |
| L4-2 | LEAN | `Oracle.getBaseFeed` | **FIXED** — deleted; tests use `getPegFeed` |
| L4-3 | LEAN | `AnchorTree.isRoot` | **FIXED** — deleted; harness/test trimmed |

**Result:** actionable lean cleaned; no new gas Fix-now.

---

## Cycle 5 (convergence)

Combined Security+Gas+Lean auditor + independent challenger → **CONVERGED** (0 Fix-now BUG/SECURITY/GAS≥200).

INFO residuals unchanged: batch hub decay, stranded accidental ETH, unbounded `flashFeeBps`.

---

## Cycle 6 (2026-07-16) — multi-model cohort campaign

Method: 4 primary cohorts (AMM / oracle / access / gas-lean) on distinct models → 2 adversarial challengers → engineer fixes → go-hard delta re-audit → patch follow-ups.

### Headline after Cycle 6

- **0 CRITICAL** permissionless fund-loss in production `ExternalOracle` + Pool path.
- **H-INT-01 / B-02 FIXED** (withheld signed quote relabel): `Oracle.observedAt` ages off `sourceTs`; `maxRelayLagSecs` is an **immutable ctor param** (nonzero + ≤`MAX_RELAY_LAG_SECS` (1d), no setter — loosening requires oracle redeploy + timelocked `requestOracleUpdate` per asset, so pick the prod value generously); `isFeedFresh` aligned; TestnetDeploy sets lag=120. ⚠ ttl/lag coupling: a feed with `ttl ≤ maxRelayLagSecs` can land already-stale (aged from `sourceTs`) — `addFeed`/`updateFeed` now enforce `ttl > maxRelayLagSecs`.
- **H-INT-02 FIXED**: ERC4626 `_venueDeposit` requires `reportedShares == mintedShares` (strict equality — fee-on-deposit/nonstandard-accounting vaults revert) and `convertToAssets ≥ 99.99%` of assets (`MAX_DEPOSIT_LOSS_BPS = 1`).
- **N-1 FIXED**: `priceBandGuard` gates every cache miss.
- **A-02 FIXED**: `PoolSwap` + `PoolBatch` revert on `amountOut==0`.

### Challenger downgrades (not Fix-now)

| ID | Initial | Final | Reason |
|---|---|---|---|
| B-01 UniPoolOracle spot | HIGH | INFO / deploy invariant | Chapel piggyback only; never prod primary |
| ~~B-03 single signer~~ | HIGH | **HIGH (re-rated 2026-07-16)** | ⚠ downgrade REVERSED. maxDeviation/σ-floor/1-per-block are per-BLOCK RATE limits, NOT a cumulative loss bound: a compromised signer walks the mark ~maxDev/block (prod 500bps @ TTL 600s), compounding `1.05^N` → ~10× true price in ~48 blocks (~2.5 min BSC), each block's σ-floor still only the per-block move so spread stays ~5% while extracting the cumulative ~90% mispricing = full drain. refBand=0 on volatile assets + refFeedId co-signed by the same key ⇒ no cumulative cap; only backstop = manual guardian revokeSigner (too slow). **k-of-n signing is NOT optional — it is the fix.** See residual #1 (now MANDATORY pre-mainnet) + [[oracle-ostium-hardening]]. |
| F-02 rebasing | MED | INFO | Listing policy |
| Hook `requireNoFlash` | LOW | REJECTED | `pull` + `nonReentrant` already cover |
| Transient cache TOCTOU | LOW | INFO | Mid-tx pause needs guardian |

### Residual backlog (pre-mainnet)

1. ⚠ **MANDATORY (not optional): k-of-n oracle signing** — single-key compromise = full drain via mark-walk (see re-rated B-03). Also: never wire `UniPoolOracle` as primary (no on-chain check; enforce in deploy validation).
2. F-01 admin force write-down / hook eviction if venue NAV view reverts (unguarded call `PoolHooks.sol:48`; live DoS surface on a bad ERC4626 venue).
3. ~~M-INT-03 base-oracle re-pin timelock~~ **DONE / CLOSED (2026-07-16)** — the only writer of `OracleConfig.primary/feedId` is `PoolAux.adminSetOracleConfig` (onlyAdmin=immutable `admin`), reachable only via `requestOracleUpdate`→`executeOracleUpdate` gated by `BASE_TIMELOCK` (2d prod). Nonzero→nonzero re-pin is already timelocked; only open question is duration (2d vs 7d).
4. ~~Storage pack: drop `uint8[]` pads~~ **DONE this cycle** — Asset pads + `baseTokenOracle`/`baseTokenFeedId` removed ⇒ **layout break vs live Chapel fleet**: the current Chapel beacon MUST NOT be upgraded in place (would misread `assetHooks`/`invested`/`factory` slots + Asset packing); next Chapel push = full fleet **redeploy** (planned testnet redeploy anyway).
5. Deviation band growth still uses landing `dt` (not source-time); old-first relay grief.
6. ERC4626 99.99% floor (`MAX_DEPOSIT_LOSS_BPS = 1`) + strict `reportedShares == mintedShares`: venue share-price rounding / entry fees → deposit DoS (preferable to silent loss; allowlist venues).

### Tests

`ExternalOracle*` 45 green (incl. `test_gate_agesOffSourceTs_notLandingTime`). Core pool/hooks/coverage/invariants suite green.

_Method: multi-model cohorts + cross-challenge; not a substitute for a professional firm engagement._
