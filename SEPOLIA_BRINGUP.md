# Sepolia bring-up: state of the stack

Single source of truth for the Ethereum Sepolia (chainId 11155111) deployment.
Chapel / BSC testnet 97 is retired. Incumbent DEX pools (Uniswap, Curve, Wombat)
are descoped: routing-competition research is not part of this testnet.

Status legend: LIVE = running and verified. READY = built, verified, not yet
deployed. BUILD = in progress. BLOCKED = waiting on a listed dependency.

## Top-down: what has to be true

```
NX-Rates (production, nxrates k0s)          BTR Sepolia (11155111)
  feeds -----------------------------> signing tier
                                              |
                                              v
                                        ExternalOracle  <---- oracle push daemon
                                              |                (theta triggers)
                                              v
                                   AccessControl + Admin/Flash/PoolAux/PoolFactory
                                              |
                                   +----------+----------+
                                   |                     |
                            stable core pool      volatile core pool
                                   |                     |
                                   +----------+----------+
                                              |
                                    keepers (liquidity + risk params)
                                              |
                                     front-end (btr.markets)
```

## Bottom-up: the layers

| L | Layer | What it is | Status |
|---|-------|-----------|--------|
| 0 | NX-Rates feeds | CEX + Pyth Lazer aggregation, TDWAP composite marks | LIVE |
| 1 | Signing tier | `udp_auth` sealed ingest, `signed_quotes`, 3 attester pods, 2-of-3 quorum | BUILD |
| 2 | ExternalOracle | 24 feeds, k-of-n signed marks, deviation + staleness guards | READY |
| 3 | Push daemon | dynamic theta triggers, cadence cap, trigger observability | READY |
| 4 | Core contracts | AccessControl, Admin, Flash, PoolAux, PoolFactory, Pool impl | READY |
| 5 | Pools | stable core (17 assets), volatile core (8 assets), EIP-1167 clones | BUILD |
| 6 | Keepers | liquidity + bot solvency, adaptive risk-param upkeep | BUILD |
| 7 | Bots | random-flow bot (arb bot retired: no incumbents, no counterparty) | BUILD |
| 8 | Front-end | btr.markets, Sepolia default, swap + faucet + pools + density | BUILD |
| 9 | Docs | generated deployments page, docs/code alignment | READY |

## Architecture note

There is no Diamond and there are no facets. Verified: `rg -l facet` over
`dex/evm` returns nothing. The system is:

- `AccessControl`: roles, including the guardian and risk roles.
- `Admin`, `Flash`, `PoolAux`, `PoolFactory`: singletons.
- `Pool`: one implementation, cloned per pool via EIP-1167 minimal proxy.

Any document or script describing a Diamond is wrong and predates verification.

## Asset composition

Base leg for both pools is USDC. Its mark is the identity 1.0 (USDC/USDC = 1),
seeded once and never pushed. It carries no market price feed. It is not exempt
from signing: the depeg guard and the USD reservation price both read a signed
USDC/USD reference feed at index 23.

- Stable core (17): USDT, USDC, USDe, USDS, DAI, USD1, USDG, PYUSD, RLUSD,
  syrupUSDC, USDf, U, GHO, TUSD, USDtb, FDUSD, AUSD.
- Volatile core (8): WETH, WBTC, cbBTC, BNB, XAUT, PAXG, EURC, USDT.

All assets are our own ERC-20 mocks with a faucet. Canonical testnet tokens are
not used: supply is unpredictable and unfundable at the sizes testing needs.

## Liquidity shape

Central-normal plateau, both pools. Keep only the centre of a normal
distribution and let the shoulders roll off:

- m = 3, two interior knots at +/- 0.7 sigma, u = {0.1314, 0.8686}.
- Truncated at the empirical q70 (an exact 30 percent tail cut).
- Density is flat and maximal at the mark. No crater, no second mode.
- Shape is cell-invariant. Asset classes differ only by width S_dep.
- Roughly 289k gas for `setCurve`, about 70 percent below the previous catalogue.

Constraints that hold regardless of fit: S_dep >= 2 theta, minFee = 2 theta +
E[(|G| - theta)+], in-range >= 99 percent, and hyper-concentration only behind a
kappa wall with `haircutSuppressor = 0`.

## Oracle push policy

Marks are pushed on deviation, not on a fixed clock:

- theta: 0.25 bp for stables, 5 bp for volatiles. Both are themselves part of the
  perpetually optimised risk-parameter set, not fixed constants.
- The allowed band widens with realised volatility and elapsed time, capped so a
  single push can never ratchet the band open.
- Cadence is capped near 100 pushes per hour. If a feed exceeds it, theta floats
  up rather than the cap being breached.
- A heartbeat push bounds staleness even when price is quiet.
- Every evaluation is recorded, pushed or not, with its reason: theta cross,
  heartbeat, confidence spike, cold start, or none.

A theta change never ships alone. It ships atomically with `minFee = 2 theta`,
a fence resync, and `minDisp`, because the keeper's own boot gate rejects a
configuration where `minFee < 2 theta`.

## Governance timing

Timelocks are shortened on testnets and full length on mainnet. Sepolia was
missing from that gate and has been added; without it, testnet operations such
as adding an asset or rotating a signer would have taken up to seven days.

Risk parameters are deliberately not timelocked. Adaptivity is the point: the
upkeep keeper adjusts fees and greeks continuously through a bounded-delta path.
The controls are the bounds themselves plus a dedicated risk role that can
freeze. Structural changes stay timelocked.

## Signing thresholds

Two governance principals, two different jobs, two different thresholds. Both are
external Safes; `owner()` is a single address by construction, so a Safe covers
every gated contract at once instead of each one growing its own proposal
plumbing.

- **Guardian: 1-of-n.** Guardian powers are halt-only and reversible: pause a
  feed, freeze an asset, tighten a deviation band, cancel a pending timelock.
  Every reverse stays with admin. A rogue halt costs downtime and is undone by
  one admin transaction; a halt that arrives late costs the pool. Speed wins.
  Raise to 2-of-n only if the guardian set grows past about five keys, or if a
  rogue halt is judged worse than a slow one. `AccessControl.guardianQuorumMax`
  holds the ceiling, default 1, hard maximum 2.
- **Admin: ceil(2n/3).** 2-of-3, 3-of-4, 4-of-5, 4-of-6, 11-of-16. Not n-1-of-n:
  n-1 is brittle, since one lost key at n=3 means 3-of-3 and no governance at
  all, and it is a magic number rather than a ratio, so adding a signer silently
  moves the policy from 83% to 88% to 94%. ceil(2n/3) holds a 66-80% band across
  the whole range and always tolerates floor(n/3) key losses.

The formula lives in `shared/evm/src/access/Quorum.sol` and is enforced, not
merely documented: `AccessControl` reads the Safe's live `getOwners()` and
`getThreshold()` and refuses any principal below policy. Invariants for n = 1..16
are in `shared/evm/test/Quorum.t.sol`.

`ExternalOracle` also runs a k-of-n, currently 2-of-3, but that is a separate
trust domain and is deliberately not reused for governance. It authenticates
price attestations from machine keys at high cadence, and dropping below its
threshold is a safe halt. Governance is cold, human, arbitrary-calldata, and
dropping below quorum bricks the protocol instead of safing it. Same primitive,
opposite failure preference.

## Handover ceremony

Ordering is load-bearing and enforced on-chain by
`AccessControl.armQuorumPolicy()`, which reverts if no guardian is appointed.

1. Deploy the guardian Safe (1-of-n) and the admin Safe (ceil(2n/3)).
2. `setGuardian(guardianSafe, true)`. **Guardians before armed, always.**
3. `bootstrapTreasuryOwner(adminSafe)`: one-shot and instant. After that
   `treasuryOwner` rotation is queue plus a 7-day timelock with an incumbent veto.
4. `adminSafe.requestOwnershipHandover()`, then
   `deployer.completeOwnershipHandover(adminSafe)`.
5. `setGuardian(<bootstrap EOA>, false)` to drop any deploy-key guardian.
6. `armQuorumPolicy()` from the admin Safe. This is the point at which the system
   is armed. It is a one-way latch: afterwards every principal must satisfy the
   formula and EOA principals are refused outright.

Monitor `quorumStatus()`. A Safe that lowers its own threshold after arming is
sovereign and invisible to any on-chain gate, so it has to be alerted on.

### Blocker: four roles, one key

Not a note. Verified live on both AccessControls: `treasury == treasuryOwner ==
owner == deployer EOA`. The design implies three separable authorities plus a fee
sink; today they are one private key. `_validateAddr` enforces `code.length > 0`
on *rotation* only, never on the constructor seed, so the EOA `treasury` was
accepted at deploy and no later check will object to it.

Consequences that are live right now, not hypothetical: the admin⊥treasury
separation the timelocks and the incumbent veto exist to protect does not exist;
`Distributor`, `GovTreasury` and `OpsTreasury` are gated on the same key as pool
params and oracle config; and protocol fees route to an EOA rather than a
contract.

The ceremony must split all four, and `armQuorumPolicy()` is what makes it
non-optional: it refuses to arm unless `owner` and `treasuryOwner` are each a
policy-compliant multisig, so `owner == treasuryOwner == EOA` cannot be carried
into an armed system. Note the one gap it does not close: `armQuorumPolicy` checks
the two *authorities*, not the `treasury` fee-sink address. Rotate `treasury` to
the OpsTreasury proxy via `queueTreasury`/`executeTreasury` (contract-enforced on
that path) and verify it explicitly — `cast call <ac> "treasury()(address)"` must
return a contract, and `pool.treasury()` must equal the OpsTreasury that will call
`Admin.collectProtocolFees`.

Current live state, verified on Sepolia: **zero guardians on either
AccessControl** (`0xc74f...49E27` and `0x9f1e...9fC30`, no `GuardianSet` event in
full history), both owned by the same EOA `0x57b3...B3Fe`, and `treasury` is that
same EOA rather than a contract. Every fail-safe lever in the fleet therefore
collapses onto one key that is also the entire attack surface. The deploy scripts
no longer permit this: `GUARDIAN` was `envOr(..., address(0))` with a silent skip
and is now `envAddress` with a hard require that it differs from the deployer.

## Security posture

- UDP price ingest is authenticated. Without it, any datagram reaching the
  aggregator becomes a signed mark and then an on-chain push. The boot guard
  that couples `signed_quotes` to `udp_auth` is correct and must not be relaxed.
- The cutover to authenticated ingest runs through a permissive mode that
  accepts sealed or raw frames, because every direct ordering drops the feed:
  strict core rejects raw frames, and sealed frames fail a raw decode.
- The three attester keys are the crown jewels. They are ECDSA privates bound to
  the on-chain signer set, and recovery runs through a timelocked grant. They are
  backed up before any oracle depends on them.
- The `udp_auth` HMAC keys are not crown jewels: they are symmetric and
  regenerable in minutes.
- Feed loosening is timelocked. `ExternalOracle.updateFeed` used to widen
  `maxDeviation` to 2000 bps and `ttl` to 65534 s instantly, owner-only, with no
  guardian veto, while the tightening twins `narrowMaxDeviation` and `pauseFeed`
  were guardian-able. That asymmetry was backwards for a money path: a 20% band on
  a fresh push is a single-transaction drain. `updateFeed` is now tighten-only;
  widening goes through `requestFeedWiden` → `BASE_TIMELOCK` →
  `executeFeedWiden`, with `cancelFeedWiden` open to guardians. Any tighten taken
  during the delay voids the pending widen rather than being reverted by it.
  **Sequencing, stated in the order that reads correctly: the redeploy ceremony is
  what unblocks this fix, not a constraint on it.** Step 1 of the ceremony seeds
  every feed at market, which is precisely what removes the dependency on the
  instant-widen hole. Until that lands, operations still lean on the hole to rescue
  a stranded feed, so the fix ships *with or after* the ceremony and never before:
  shipping it first would leave a bad seed with a 15-minute timelock as its only
  recovery. So the constraint is discharged by doing the ceremony, not worked around.

## Oracle redeploy ceremony

One ceremony, not a sequence of fixes. It exists because three needs collide and
each one alone would otherwise force its own migration:

1. **Seeds are unusable.** All 34 feeds have `sourceTs == 0` and seeds ~30 h stale
   and far off market (WBTC 65 020, WETH 1885). A first signed push has
   `dtSource == 0`, so its band is the `maxDeviation` floor exactly (50 bps stables
   / 100 bps volatiles) and **the first real push cannot land**.
2. **A ladder is not executable.** Walking a feed to market in band-sized steps
   needs a signed blob per rung, and NXR signs *market* marks, not ladder rungs.
   There is no `setPrice`. So the only routes are widening `maxDeviation` — which
   is exactly the hole the tighten-only change closes, and re-opening it under
   duress is not acceptable — or redeploying with correct seeds.
3. **`MAX_SIGNERS` was 6.** A 2-of-3 primary plus three distinct reference keys
   fills 6 exactly, so the deployed fleet could not express 5-of-8 at all. It is
   now 16, but the constant lives in a non-upgradeable contract, so it reaches the
   fleet only by redeploy.

Install the **full target signer set in the constructor**. Growing an existing set
is sequential — only one grant may be pending — so 3 → 8 signers is five
consecutive `SIGNER_GOV_TIMELOCK` waits.

**Review gate: this ceremony goes to an independent reviewer before execution.**
It is not executed on one author's plan.

### Step 0 — before anything on-chain

- [ ] ⚠ **`migrate-phantom-ids --apply` pass 1 — hard prerequisite, precedes
      everything else NXR-side.** `nxr` `exit(78)`s when a phantom-id shard exists
      without its migrated counterpart. Skipping this takes `api.nxrates.com` down
      while someone is trying to arm the oracle: the aggregator refuses to boot, the
      signed-quote endpoint 503s, and the ceremony stalls with feeds seeded and
      unpushed — the one state the whole plan exists to avoid.
      Authoritative dry-run scope: **28 of 210 symbols change ids, but only 11 have
      bytes to move** — 22 trees, 1 346 shard files, **4.176 GiB**. (Not 143.6 GiB;
      that is the whole native-`.idx` subset.) Bound by sha256 at a measured
      117 MiB/s and the tool hashes each shard three times, so **pass 1 is ~2 minutes,
      budget 5**. Renames are same-filesystem: **zero extra disk**.
      **Pass 1 unblocks the image deploy.** `core`'s boot gate is narrower than the
      audit query — it fires only when old-has-data AND new-has-none — so the deploy
      may proceed once pass 1 is clean. **Pass 2** (after UTC rotation, 22 files,
      seconds) retains the last closed day; it is a same-day follow-up, not a blocker.
      Verify: no phantom tree lacks its migrated counterpart, then `nxr` boots
      without `exit(78)` and `/v1/quote/signed` answers 200.
- [ ] ⚠ **Do NOT merge the migration cutover seam with `merge-idx`.** That tool opens
      its sources read-write and `set_len()`-truncates with **no today-guard**
      (`merge_idx.rs:379-403`), so pointing it at a live tree during the seam destroys
      data. The migration runbook says so; it is repeated here because this is exactly
      the shortcut an operator reaches for under pressure, mid-ceremony, when a seam
      looks like it just needs one more merge.
- [ ] The 14 stable symbol re-points are in the NXR manifest, or the feeds carry
      `single_source: true`. A manifest/keeper skew hard-fails every tick.
      Verify: `/v1/quote/signed/meta` feed list == keeper `[[feeds]]` idx set.
- [ ] `predictOracle` address written into **both** signer ConfigMaps before the
      signer pods boot. `deployOracle()` hard-asserts deployed == predicted, and a
      post-deploy pod restart re-runs the ~4 h σ warm-up.
      Verify: `signed_quotes.oracle` in each ConfigMap == the predicted address.
- [ ] ⚠ **CREATE2 recompute.** Removing chain 97 from `isShortTimelockTestnet`
      changes the bytecode of every `govDelay` consumer, so any precomputed CREATE2
      address shifts. Nothing was renamed — this is a recompute, not a break.
      Verify: recomputed addresses match the deploy script's expectations.

### Step 1 — deploy

- [ ] Deploy `ExternalOracle` with correct seeds taken at market, `MAX_SIGNERS = 16`,
      and the full signer set + threshold in the constructor.
      Verify: `cast call <oracle> "MAX_SIGNERS()(uint8)"` == 16;
      `signerCount()` / `signerThreshold()` == intended; `signers(<addr>)` true for
      each intended key and false for every retired one.
- [ ] Same for the reference oracle, with its **own disjoint** key set.
      Verify: no address is a signer on both oracles.

### Step 2 — feeds

- [ ] `addFeed` × 25 (primary) and × 9 (reference), seeds at market.
- [ ] **Freeze `getFeedIds()` order first, then byte-compare after.** `idx` is the
      wire key both the NXR manifest and the keeper toml are pinned to; a reordering
      silently mis-prices every feed.
      Verify: `cast call <oracle> "getFeedIds()(bytes32[])"` byte-identical to the
      frozen list, and `feedIds(idx) == feed_id` for every keeper entry.
- [ ] Per feed: `getFeed(<id>)` decodes to the intended seed, `ttl > maxRelayLagSecs`,
      `maxDeviation != 0`.

### Step 3 — pools

- [ ] Re-point all 26 asset oracle configs via `Admin.requestOracleUpdate` →
      `BASE_TIMELOCK` → `executeOracleUpdate`.
      Verify per asset: `primary`, `refPrimary`, `feedId`, `refFeedId`, `refBandBps`
      read back as intended, and `refPrimary != primary`.
- [ ] **`verify-sepolia-venue.ts` — REQUIRED, not optional.** Validates 24 tokens,
      15 contracts and 24 feed ids against the deployment source of truth. Run it and
      require a clean pass before arming anything.

### Step 4 — arm and prove liveness

- [ ] Scale the signer tier up; confirm `/v1/quote/signed` returns 200 (not 503).
- [ ] First push lands: `getFeed` shows `sourceTs != 0` advancing and
      `isFeedFresh(<id>) == true` for every served feed.
- [ ] Post-deploy verification list from the connector work. The two sharpest items,
      both cheap and both proving the new image actually took rather than the old one
      still serving: **`nxr_provider_ticks_total{bitunix}` non-zero** (the connector
      is live, not merely configured) and **ascendex's 40 870 log lines stopping**.

### Blockers, with current status

- **`active_count >= 2` — MOOT for declared feeds.** The declared single-source tier
  (`SignedFeedYml::single_source`, pegged-only, enforced at boot and again in the
  mainnet gate) lets a declared stable sign at one live leg. No stable needs
  dropping. Residual risk is documented at
  `SINGLE_SOURCE_MIN_ACTIVE_PROVIDERS`: for a wrong-but-in-band single-source mark
  nothing in NXR catches it, and the on-chain per-push deviation band is the only
  remaining bound.
- **kraken `/USDC` tick flow — STILL A PREREQUISITE**, but only for feeds that
  actually rely on 2-venue coverage (the volatiles, and any stable left undeclared).
  Breadth has improved materially: `USDT/USD` went from 4 trustworthy providers to
  9 after two symbol-mangling fixes.

### Chapel: two allow-lists, in two different repos

Killing Chapel means removing chain 97 from **both**, and they are not in the same
place — a sweep that fixes one reads as complete:

1. **Solidity**, `shared/evm/src/access/../Constants.sol::isShortTimelockTestnet` —
   governs *timelock shortening*. A sweep found exactly two chain-97 gates in
   Solidity: this one, and `UniPoolOracle`'s constructor, now deleted outright
   (which also removed a flash-manipulable `slot0()` spot oracle). **There is no
   chain-97 signing-gate list in Solidity.**
2. **Rust**, `nx-rates core/src/main.rs::RELAXED_GATE_CHAIN_IDS` — governs *relaxed
   signing gates* (`min_accepted_providers`, composite freshness, `udp_auth`
   frame age).

Left in either, a chain we claim not to support keeps relaxed timelocks *or*
relaxed signing gates. Both lists are positive allow-lists, so an unknown chain
correctly defaults to strict — which is also why a stale entry is invisible until
someone deploys to it.

## Open items

Tracked live in the session task board: signing tier (#56), oracle and DEX
deploy (#57), keepers and bots (#58), front-end (#59), docs (#60), repo
hygiene (#61).
