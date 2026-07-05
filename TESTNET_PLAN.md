# BTR DEX → BNB Testnet — Master Plan (team lead: Claude, owner OOO)

> Durable source of truth. Survives session resets. Owner mandate: aggressively opinionated, LEAN/CLEAN,
> nuke anything unneeded, hyper-generic, gas/time/space/storage optimized, ponytail-nerd code. Challenge
> every design, take nothing for granted. Delegate to best-in-class experts. Deploy to BNB testnet with a
> stable-core + volatile-core pool, mock ERC20s + faucet, K0S oracle pushing NX marks (deviation θ +
> heartbeat), a tester-key keeper generating realistic trades (volumes INFERRED from real BNB DEX
> activity), and a MATURE DEX-only UI. End state: a shareable testnet demo to pitch VCs/LPs/traders.

## LOCKED DECISIONS (team lead calls — do not relitigate without new evidence)
- **Feed rework = OPTION A (full migration).** External-keeper mark + on-chain EMA REPLACE internal-oracle
  mode everywhere (midPrice→lastPriceB64, getFastTWAP→emaPriceB64, drop per-swap pushOracle write, migrate
  harness). Rationale: external-keeper launch + ALM being phased out removes the main internal consumer.
- **FeedData = 7 fields, ONE slot (256b):** `{uint64 lastPriceB64; uint64 emaPriceB64; uint32 sigma;
  uint32 updatedAt; uint16 ttl; uint16 confidence; uint32 tau;}`. Quote off lastPrice (kills LVR); ema =
  on-chain manip-resistant reference (Pyth-parity, servable oracle); confidence = 1σ CI (bps) → surcharge
  + halt; sigma = realized vol (our edge vs Pyth/CL). See memory project_dex_feed_ema_design.
- **On-chain EMA:** single, time-decayed (α=min(Δt/τ,1)), RATE-clamped (band=k·confidence, cap
  MAX_BAND_BPS=2000; rate-clamp NOT absolute → dodges LUNA/Venus minAnswer brick). k=8, τ default 1800s.
- **Delete (no-deferred):** Δ/U momentum surcharge (directional=RW), fastOffset/slowOffset/slowVolEMA,
  covPremiumBps + RiskConfig{kappaCovBps,premCapBps,covFlags}, internal-oracle mode (after migration).
- **Keep:** flash-inflight pool-wide guard (safer than token-key; audit ruled optimization not fix);
  depeg price band (reservationPrice/Max + refFeedId/refBandBps); HALT_MASK pause; staleness premium;
  depth-1 star topology (validated — correlated clusters priced per-spoke, band halts depeg).
- **Topology: flat depth-1 star** (deep tree ruled out — wrapper relative rate info-free → deep = short-vol
  the depeg tail). No LSTs at launch (on-chain-illiquid).
- **Testnet chain: BNB testnet (chapel, id 97).**
- **Feed IDs = MITCH ticker u64** (same both sides, NX↔DEX).
- **Heartbeat = staleness bound, not liveness watchdog.** `heartbeat_s` is the max
  interval between on-chain price pushes per feed. The same K0S `oracle-daemon`
  pushes NX marks when `|Δ|>θ` **or** heartbeat elapsed — not a separate “keeper
  alive” process. Size on-chain `ttl` relative to heartbeat (`ttl ≈ 2·heartbeat`).
- **Stable-core oracle mode at launch:** all stable-core assets **EXTERNAL** (keeper
  mark + on-chain EMA). INTERNAL constant-peg (`ORACLE_MODE_INTERNAL`) stays in
  contract but is **not** configured at testnet deploy.

## OPS (oracle keeper + HA)

### Push triggers (single daemon)
One `btr-keeper oracle-daemon` per cluster instance. Per feed, push when:
- cold-start (no prior on-chain mark), **or**
- `|m − p_last| / p_last > θ` (±1 bp stables, ±5 bp volatiles), **or**
- `heartbeat_s` elapsed since last on-chain push for that feed.

Heartbeat is the staleness ceiling the daemon enforces — not an independent
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
- **Stable core:** USDC(base), USDT, USD1, USDE, USDS, FDUSD. (Most-liquid BNB stables.)
- **Volatile core:** USDC(base), USDT, BTCB(=BTC), ETH, WBNB(=BNB), CAKE, XAUT(gold, fallback PAXG).
  (CAKE = PancakeSwap native, top BNB liquidity; XAUT = tokenized gold. Verify final liquidity list.)
- Testnet = MOCK ERC20s mirroring real symbols/decimals; oracle pushes REAL NX prices for them.

## PHASES + TO-DO (checkbox = open)

### Phase 1 — DEX CODE PERFECTION (on-chain + keeper + NX). Gate before testnet.
- [ ] **Feed rework (Option A)** — redo on HEAD (prev worktree agent used wrong base f53d09b):
      slim FeedData 8→7, delete Δ/U + offsets + dual-vol, wire on-chain EMA (clamp+decay) into push path,
      wire confidence surcharge+halt, migrate midPrice/getFastTWAP→lastPrice/emaPrice, drop per-swap
      pushOracle, delete internal-oracle accumulator machinery, migrate 6-file test harness to
      ExternalOracle mocks. Build+test green each stage. Regen sdk ABIs.
- [ ] **Confidence plumbing end-to-end:** ExternalOracle.pushFeed carries real NX 1σ CI (drop hardcoded
      100); Pricing spread += confidence-widen + halt if confidence>maxConfBps (per-asset).
- [ ] **Re-run AAA audit** on the final code (prev audit outputs may be lost to session reset — see memory
      project_dex_phd_review + the wf outputs if present). Fix all confirmed findings (≥2 auditors each).
      Known-open from last audit: none critical outstanding; verify HALT_MASK/staleness/band all intact
      post-feed-rework.
- [ ] **Lean/clean sweep** (ponytail): dead code zero-tolerance, consolidate, gas pass (SLOAD/SSTORE/
      calldata), storage packing, comment trim. style-reviewer + /simplify.
- [ ] **Keeper (btr-keeper):** update push callers to new pushFeed sig (priceB64, sigma, confidence, tau@add);
      implement deviation-trigger (|Δ|>θ: ±1bp stable, ±5bp volatile) + heartbeat (≤3600s) push loop.
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
- [ ] Deploy mock ERC20s (symbols/decimals mirror real) + a Faucet contract (rate-limited claim).
- [ ] Deploy DEX (PoolFactory, Pool impl, PoolAux, Admin, ExternalOracle, Router, singletons) via
      script/Deploy.s.sol adapted for chapel. Create the 2 pools; add assets (stable-core: all
      EXTERNAL mode — do not configure INTERNAL constant-peg); seed liquidity.
- [ ] **Oracle on K0S** (nxrates cluster): ExternalOracle keeper service pushing NX marks per θ+heartbeat
      rules. Feed IDs = MITCH. In-cluster BuildKit build (never Mac/prod-node podman).
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
Feed rework landed (7-field 1-slot FeedData, on-chain rate-clamped EMA, confidence surcharge/halt, internal-
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
- Volatile minFee: 2·(θ + z·σ√δ) not just 2·θ. ETH-class on 2s chain ≈ 19bp (z=3) to cover latency-drift
  residual LVR (the 2θ knife-edge). Stables: 2·θ ≈ 2bp is exactly right. Per-asset minFee via setAssetParams.

**OWNER DESIGN DECISIONS (flagged, NOT auto-applied — need your call):**
- D1 On-chain push deviation clamp: quotes read the RAW pushed mark; EMA clamp protects only the servable
  reference. 3 sources flag it (audit + LVR paper manip-warning + Swaap Chainlink-anchor asymmetry). Stolen key
  ⇒ drain to confidence-halt limit. Testnet OK (trust the keeper). MAINNET-BLOCKING → add per-push |mark−ema|
  clamp on lastPrice, or 2-of-N pusher quorum, or optional Chainlink cross-check per feed.
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
