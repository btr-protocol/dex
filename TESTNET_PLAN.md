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
      script/Deploy.s.sol adapted for chapel. Create the 2 pools; add assets; seed liquidity.
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

## STATUS LOG (append as we go)
- 2026-07-05: Plan created. Decisions locked. Feed rework (A) delegated to worktree agent on HEAD.
