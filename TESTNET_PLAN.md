# BTR DEX → BNB Testnet — Master Plan (team lead: Claude, owner OOO)

> Durable source of truth. Survives session resets. Owner mandate: aggressively opinionated, LEAN/CLEAN,
> nuke anything unneeded, hyper-generic, gas/time/space/storage optimized, ponytail-nerd code. Challenge
> every design, take nothing for granted. Delegate to best-in-class experts. Deploy to BNB testnet with a
> stable-core + volatile-core pool, mock ERC20s + faucet, K0S oracle pushing NX marks (deviation θ +
> heartbeat), a tester-key keeper generating realistic trades (volumes INFERRED from real BNB DEX
> activity), and a MATURE DEX-only UI. End state: a shareable testnet demo to pitch VCs/LPs/traders.

## LOCKED DECISIONS (team lead calls — do not relitigate without new evidence)
- **Feed rework = OPTION A (full migration).** External-keeper mark + on-chain EMA replace the
  **write-on-swap TDWAP accumulator** (midPrice→lastPriceB64, getFastTWAP→emaPriceB64, drop per-swap
  pushOracle write, migrate harness). Rationale: keeper-mark quoting kills LVR vs lagging internal discovery.
- **FeedData = 8 fields, ONE slot (256b):** `{lastPriceB64; emaPriceB64; sigmaEma; updatedAt; ttl; confidence; tau; tauSigma}`. Keeper pushes NXR mark + σ **sample** + CI; chain folds σ-EMA. Quote = lastPrice; pricing σ = sigmaEma.
  The on-chain EMA is a manipulation-bounded servable reference; confidence = 1σ CI (bps) → surcharge
  + halt; sigma = realized volatility. See memory project_dex_feed_ema_design.
- **On-chain EMA:** single, time-decayed (α=min(Δt/τ,1)), RATE-clamped (band=k·confidence, cap
  MAX_BAND_BPS=2000; rate-clamp NOT absolute → dodges LUNA/Venus minAnswer brick). k=8, τ default 1800s.
- **Delete (no-deferred):** Δ/U momentum surcharge (directional=RW), fastOffset/slowOffset/slowVolEMA,
  covPremiumBps + RiskConfig{premCapBps,covFlags}, write-on-swap TDWAP accumulator machinery.
  **Keep:** `ORACLE_MODE_INTERNAL` constant-peg (optional; not configured at stable-core launch).
- **Keep:** flash-inflight pool-wide guard (safer than token-key; audit ruled optimization not fix);
  depeg price band (reservationPrice/Max + refFeedId/refBandBps); HALT_MASK pause; staleness premium;
  depth-1 star topology (validated — correlated clusters priced per-spoke, band halts depeg).
- **Topology: flat depth-1 star** (deep tree ruled out — wrapper relative rate info-free → deep = short-vol
  the depeg tail). No LSTs at launch (on-chain-illiquid).
- **Testnet chain: BNB testnet (chapel, id 97).**
- **Feed IDs = `keccak256(abi.encodePacked(base, quote))`** on `ExternalOracle` (code won: `ExternalOracle.addFeed` derives the id; keeper maps MITCH tickers → keccak ids off-chain, see `keepers/oracle.example.toml`). ~~MITCH ticker u64 both sides~~ — superseded.
- **Heartbeat = staleness bound, not liveness watchdog.** `heartbeat_s` is the max
  interval between on-chain price pushes per feed. The same K0S oracle keeper
  pushes NX marks when `|Δ|>θ` **or** heartbeat elapsed — not a separate “keeper
  alive” process. Size on-chain `ttl` relative to heartbeat (`ttl ≈ 2·heartbeat`).
- **Stable-core oracle mode at launch:** all stable-core assets **EXTERNAL** (keeper
  mark + on-chain EMA). INTERNAL constant-peg (`ORACLE_MODE_INTERNAL`) stays in
  contract but is **not** configured at testnet deploy.

## OPS (oracle keeper + HA)

### Push triggers (single keeper)
One `btr-keeper oracle` per cluster instance. Per feed, push when:
- cold-start (no prior on-chain mark), **or**
- `|m − p_last| / p_last > θ` (±0.25 bp stables, ±5 bp volatiles), **or**
- `heartbeat_s` elapsed since last on-chain push for that feed.

Heartbeat is the staleness ceiling the keeper enforces — not an independent
watchdog. Missed heartbeats widen spreads via on-chain staleness premium until
`ttl`; do not conflate with process health checks.

### ttl vs heartbeat
- Volatile feeds: ttl SHORT (120–300s) so staleness grace = ttl/2 ≈ 60–150s ≈ keeper
  heartbeat — closes the dead-keeper pick-off window. Stables can keep longer ttl.
- Enforce ops rule **ttl ≈ 2·heartbeat** (see deploy params below).

### Testnet vs mainnet keeper topology
- **Testnet:** single keeper instance on K0S; monitoring + alerts preferred over
  redundant pushers (extra pushes = gas with no demo benefit).
- **Mainnet (FUTURE OPS — not implemented in code):** primary / secondary / tertiary
  pushers with **θ-gated failover** — secondary acts only if primary has not landed
  a mark within θ+heartbeat; tertiary as last resort. Economic tradeoff: HA
  redundancy costs gas on every θ/heartbeat cycle if all tiers push blindly; gate
  failover on upstream silence, not parallel triple-push.

## POOLS (BNB testnet, base = USDC for both)
- **Stable core (FINAL, 5 tokens, 2026-07-08):** USDC(base), USDT, USD1, USDE, FDUSD — **USDS dropped** (no approved NXR mark / negligible BSC flow). All 5 are priced from **NXR** marks pushed by the keeper to `ExternalOracle`. θ stables = **0.25 bp** (2026-07-12: 0.1 was ~118/h NXR jitter). SSoT: `dex/evm/deploy/testnet-asset-params.json` + `keepers/oracle.chapel.toml`.
- **Volatile core:** USDC(base), USDT, BTCB(=BTC), ETH, WBNB(=BNB), CAKE, XAUT(gold, fallback PAXG).
  θ=**5 bp**, heartbeat=**300 s** (ttl/2). (CAKE = PancakeSwap native; XAUT = tokenized gold.)
- Testnet = MOCK ERC20s mirroring real symbols/decimals; oracle pushes REAL NX prices for them.

## PHASES + TO-DO (checkbox = open)

### Phase 1 — DEX CODE PERFECTION (on-chain + keeper + NX). Gate before testnet.
- [x] **Feed rework (Option A)** — 8-field 1-slot FeedData, σ-EMA v2, on-chain price EMA, confidence
      surcharge+halt, ExternalOracle mocks migrated, sdk ABIs regen'd. 268 forge tests green.
- [x] **Confidence plumbing end-to-end:** keeper `confidence_from_mark_uncertainty` (interim 25%·σ);
      Pricing spread += confidence-widen + halt if confidence>maxConfBps.
- [x] **Min fee path:** MIN_FEE_PBPS=1, Pricing spread rounding fix, deploy SSoT `testnet-asset-params.json`.
- [ ] **Re-run AAA audit** on the final code (prev audit outputs may be lost to session reset — see memory
      project_dex_phd_review + the wf outputs if present). Fix all confirmed findings (≥2 auditors each).
      Known-open from last audit: none critical outstanding; verify HALT_MASK/staleness/band all intact
      post-feed-rework.
- [ ] **Lean/clean sweep** (ponytail): dead code zero-tolerance, consolidate, gas pass (SLOAD/SSTORE/
      calldata), storage packing, comment trim. style-reviewer + /simplify.
- [x] **Keeper (btr-keeper):** pushFeed/batchPush use NXR priceB64, sigma and confidence;
      deviation-trigger (|Δ|>θ: ±0.25bp stable, ±5bp volatile) + heartbeat push loop.
- [ ] **NX Rates:** confirm it emits per-asset {mid→b64, Parkinson σ, 1σ CI (ci), MITCH ticker id};
      wire the BNB-testnet asset set (mocks map to real NX symbols; wrappers→underlying ticker).
- [ ] **Docs sync** (owner flagged lag): FeedData spec, spread model (drop U/Δ, add confidence), oracle/
      feed doc, keeper API, FEED.md (EMA recurrence + trust model + consumer guide), anchor (done), band (done).

### Phase 2 — UI MATURITY (front, DEX-only). Gate before testnet.
- [ ] Archive done (front archive/pre-dex-pivot). Strip ALM + external-aggregator pages; dedicate to DEX.
- [ ] Swap page → OUR pools; off-chain split-router in back/services/swap (repurpose btr-swap core) + on-chain
      Router min-out executor; fallback route.
- [ ] Pools page (LP add/remove, per-pool APR/util/fees). Vaults → DEX-only (single-asset APR-routing).
- [ ] Displayed prices = NX marks. Safety Control Center (built, feat/dex-safety-control-center) — merge.
- [ ] Faucet UI (claim testnet mocks). Testnet network add (chapel) in-app.
- [ ] Mature + polished (owner: UI must be sharp for VC/LP/trader pitch) BEFORE testnet deploy.

### Phase 3 — BNB TESTNET DEPLOYMENT.
- [x] **Deploy script:** `TestnetDeploy.s.sol` — mocks + Faucet + ExternalOracle + 2 pools + seed liquidity + JSON.
- [ ] Deploy mock ERC20s (symbols/decimals mirror real) + a Faucet contract (rate-limited claim).
- [ ] Deploy DEX (PoolFactory, Pool impl, PoolAux, Admin, ExternalOracle, Router, singletons) via
      script/Deploy.s.sol adapted for chapel. Create the 2 pools; add assets (stable-core: all
      EXTERNAL mode — do not configure INTERNAL constant-peg); seed liquidity.
- [ ] **Oracle on K0S** (nxrates cluster): ExternalOracle keeper service pushing marks per θ+heartbeat
      rules. Feed IDs = keccak256(base, quote) (keeper maps tickers off-chain). In-cluster BuildKit build (never Mac/prod-node podman).
- [ ] **Simulation keeper** (BTR tester key): artificial trades sized so pool util/APY/volume MATCH real BNB
      DEX activity — infer per-pair daily volume from PancakeSwap v3 + Infinity, Uni v3/v4, Curve on BNB
      (via their subgraphs / on-chain). NOT guessed. Feeds the UI's util/APY/TVL charts.
- [ ] E2E smoke: claim from faucet → swap on both pools via UI → see live util/APY/price(NX).
- [ ] Share the app (claim + swap) for VC/LP/trader demos.

## OPEN QUESTIONS / RISKS
- Prev auditor + workflow outputs may be lost to session reset → re-run audit on final code, don't trust
  memory of "all fixed" — verify against source.
- BNB-testnet token final list needs a liquidity check (CAKE/XAUT/FDUSD/USD1/USDE availability + real-mainnet
  volume for the sim inference).
- Keeper key mgmt: KEEPER_PRIVATE_KEY never logged; tester key for the sim keeper is separate.
- Router/solver off-chain = centralization; needs min-out guard + fallback (built into the plan).

## AUDIT + PAPER OUTCOMES (2026-07-05)
Feed rework landed (8-field 1-slot FeedData `{lastPriceB64; emaPriceB64; sigmaEma; updatedAt; ttl; confidence; tau; tauSigma}`, on-chain rate-clamped EMA, confidence surcharge/halt, internal-
oracle deleted, quote off fresh mark). Dead-config cleanup landed. Adversarial 7-dim audit (findings refuted 2×)
+ 3-paper validation (Bergault/Swaap line: arXiv 2212.00336, 2405.03496, Swaap v2 WP) run. dex @ 248 tests green.

**Fixed (committed):** depeg-band B64 raw-compare bypass (efe7aa7) · withdrawTo halt bypass (d872486) ·
input-fee double-count LP drain (1500869) · batchSwap frozen-base transit (f7c2f6d) · setRiskConfig clobbering
halt bits (d142d8c) · refFeed no-staleness-gate (3c551e1) · conf=0 EMA freeze (6e0a314).

**Verdict:** AIMM = faithful implementation of the paper line (external-mark quoting kills CFMM-LVR; linear skew
+ σ-spread + spline VWAP = their optimal-quote forms). Detail in memory project_aimm_paper_validation.

**DEPLOY PARAMS derived from the papers (set these at addFeed / addAsset — code is correct, params must be right):**
- Volatile feeds: ttl SHORT (120–300s) so staleness grace = ttl/2 ≈ 60–150s ≈ keeper heartbeat — closes the
  dead-keeper pick-off window (papers: minutes-scale lag destroys LP economics). Stables can keep longer ttl.
  Enforce ops rule ttl ≈ 2·heartbeat.
- Volatile minFee floor: **1 PBPS (0.01 bp)** via `MIN_FEE_PBPS` + `setAssetParams`; size production
  fees to 2·(θ + z·σ√δ) when LVR requires (may land ~19 bp ETH-class). Stables same floor.
  Canonical table: `dex/evm/deploy/testnet-asset-params.json` (JSON SSoT — sim yaml mirrors it).

**OWNER DESIGN DECISIONS (flagged):**
- D1 On-chain push deviation clamp — **RESOLVED / SHIPPED (46fab34, 2026-07-08)**: opt-in per-feed
  `maxDeviations[feedId]` clamp enforced in `_pushInternal` — an in-heartbeat push moving the mark
  > maxDeviation bps vs the last on-chain mark REVERTS (fail-closed; last good mark survives; post-TTL
  re-sync may jump). Bounds a stolen key to maxDeviation/push. Remaining mainnet item: 2-of-N pusher
  (plan: Safe multisig as the granted oracle key).
- D2 Δ/U toxic-flow surcharge: dropped from Solidity (directional=RW + no-deferred) but the fees paper endorses
  a Z-Hawkes trend-widening term as adverse-selection premium (distinct from directional alpha). KEEP-deleted
  (sVol+staleness already widen on vol) vs PORT-back (paper-optimal). Currently sim-only → aimm.rs header made
  honest; keep/port pending your call.

## STATUS LOG (append as we go)
- 2026-07-05: Plan created. Decisions locked. Feed rework (A) delegated to worktree agent on HEAD.
- 2026-07-05: Feed rework + cleanup + audit + paper validation done (248 green). Depth-viz + order-book terminal
  UI in flight. Keeper oracle-daemon WIP stashed (feat/keeper-oracle-push). Deploy params + 2 design calls above.
- 2026-07-05 (orchestration): DEX-only pivot across keepers/sdk/docs/front. Triple audit → 1 new fix
  (withdrawTo priceBandGuard bypass, `c267c0f`/`5f0f4be`). Front UI owner checklist closed (7 commits).
  Keepers: ALM→archive, oracle-daemon+Dockerfile. SDK: ALM archived, ABIs regen, AccessControl restored.
  Docs: ALM/Prime archived, oracle modes clarified. Internal-oracle stableswap landed (`42b2e0c`…`1ba27fd`, **255/255**).
- 2026-07-05: Locked heartbeat semantics (staleness bound, not liveness watchdog), stable-core EXTERNAL-only
  at testnet deploy, mainnet keeper HA pattern documented as future ops (single keeper on testnet).
- 2026-07-06: Chapel params SSoT `testnet-asset-params.json` (`1b0a381`); minFeePath σ=0 fix (`478f608`);
  oracle perf series.
- 2026-07-07: σ-EMA v2 + `MIN_FEE_PBPS=1` (`f659706`); `TestnetDeploy.s.sol` + Faucet (`fd1644b`); PR#3.
- 2026-07-08: Pure-view quote (`5daf76c`); **deviation clamp SHIPPED** (`46fab34` — resolves D1 above);
  hub-neutral cross (`1241099`/`e79d955`); `requestUpdateProfile` (`9eb780e`); **stable-core finalized:
  5 tokens (USDS dropped), θ=0.3bp, NXR marks** (`1dd2e28`); Distributor propose/finalize root
  cooldown (`44024fd`); sim params (`1a88b84`).
- 2026-07-09: Per-asset stable-core minFee/dispersion/refBand differentiation (`08bc838`).
- 2026-07-10: 7-day NXR 30s cadence replay rejected θ=0.1bp stable (+29% batched transactions);
  retained θ=0.3bp stable and moved volatile θ from 5bp to 10bp. Trade-driven bounded
  mean-reverting fair-value offset failed the LP/LVR and self-roundtrip falsification tests.
- 2026-07-12: Live Chapel cadence review — stable θ=0.1 was ~118/h on sub-bp NXR jitter → **θ=0.25 bp**;
  volatile θ=10 → **5 bp**, heartbeat kept **300 s** (ttl/2). SSoT: `oracle.chapel.toml` + `testnet-asset-params.json`.
- 2026-07-12b: Inventory drain postmortem — FDUSD ~0%, USDC-stable 284%, BTCB R≈1994 / L≈0.778 (real on-chain).
  Raised stable minFee **0.5 bp** (FDUSD **1 bp**), gamma **2×**, milder profile `[50,100,50]`. Bot mark-sanity
  + lower max_usd. Reseed after pause. See `research/oracle-price-discovery/results/LAUNCH_PARAMS.md`.
