# BTR Oracle Deployment System (Sepolia, config-driven, mainnet-replicable)

Master reference for the AIMM ExternalOracle push system: NXR signing tier ->
keeper relay -> on-chain oracle -> guard registry. Owner mandate 2026-07-22:
extremely strict, formalized as CONFIG, trivially replicable to mainnet.
Testnet -> mainnet promotion is a reviewed CONFIG DIFF, machine-checked; no new
code on the promotion path.

Companion docs (SoT per surface):
- Wire contract: `dex/ORACLE_SIGNED_PUSH_SPEC.md` (frozen; 24 B/feed records, EIP-712).
- Bring-up choreography: `nx/ops/k0s/nxr/SIGNING_TIER_RUNBOOK.md` (phases A-F, gates G1-G7).
- Guard registry: `keepers/GUARDS.md`.
- Observability: `keepers/OBSERVABILITY.md`.
- Sepolia stack: `dex/SEPOLIA_BRINGUP.md`.

## 1. Strict config-driven model

Every operational knob is config with a fail-closed validator. Zero
placeholders parse (schema-checkable pre-deploy) but can NEVER arm. No live
threshold exists as a code constant.

| Surface | File | Validator (fail-closed) |
|---|---|---|
| Keeper push policy | `keepers/oracle.sepolia.toml` | `src/oracle/config.rs` validate(): deny-unknown-fields; required `profile`, `chain_id`, `ci_spike_bps` (1..=100), per-feed `{idx, feed_id, theta_bps, heartbeat_s, min_push_gap_s}` + optional `max_age_ms` (1..=1500 freshness tier); zero oracle/feed_id/signer rejected; signer pin >= 3 distinct, threshold >= 2; gap < heartbeat |
| Keeper mainnet twin | `keepers/oracle.mainnet.toml` | same schema + `mainnet` profile gates: chain_id == 1, per-feed theta >= 7bp OR min_push_gap_s >= 30 (shipped: 7bp volatiles + 36s all feeds). Parity + tighter-direction vs Sepolia machine-enforced (`mainnet_sepolia_oracle_parity_and_tighter`) |
| Guard registry | `keepers/guards.sepolia.toml` / `guards.mainnet.toml` | `src/guards.rs`: deny-unknown at every level, EXACT per-kind trigger/bounds field sets, category->authority->lever->action->scope matrix, guardian root invariant (halt/tighten/cancel only), 17-row id pin (`EXPECTED_GUARD_IDS`), armed load rejects zero contract addresses, mainnet profile gates |
| NXR signing tier | `nx/ops/k0s/services/nxr-config-configmap.yaml` `signed_quotes:` (mirror-synced to `nx-rates/config.yml`) | `nxr-sdk pipeline_config.rs` (deny_unknown_fields on SignedQuotesYml/PeerYml/FeedYml) + runtime bounds in `core/src/server/signed.rs` (min_interval 1..=10, global mark_max_age 1..=500, per-feed `max_age_ms` tier 1..=1500, providers >= 2, freshness >= 9000, quorum >= 2) |
| Signer/keeper Deployments | `nx/ops/k0s/services/nxr-signer-{0,1,2}.yaml`, `btr-oracle-daemon-sepolia.yaml` | helm chart schema; per-pod single attester key Secret; /data on local-path PVC |
| On-chain deploy | `dex/evm/script/SepoliaOracleDeploy.s.sol` | Sepolia-only chainid require, seed plausibility bands, re-run guard, signer set env-overridable (`ORACLE_SIGNER_{0,1,2}`, canonical defaults), deployed == predicted hard assert |

Cross-file pin equality (one attester set, three carriers, byte-equal):
`signed_quotes.peers[].signer` == `oracle.sepolia.toml signers` ==
`SepoliaOracleDeploy` signer set == on-chain `signers[]`. Keeper startup
proves threshold/count/membership on-chain and re-reconciles every ~2s; any
mismatch fails closed.

Sepolia -> mainnet = config diff, enforced three ways:
1. `guards::tests::mainnet_sepolia_structural_parity`: same 17 rows, every numeric delta tighter.
2. `oracle::config::tests::mainnet_sepolia_oracle_parity_and_tighter`: same 22-feed manifest, theta/heartbeat/gap only tighter, PRE-MAINNET rate bound per feed.
3. `mainnet` profile validator gates in BOTH schemas (shared consts): testnet numbers cannot be promoted by copy-paste.

## 2. Deploy sequence (single ordered path to prices pushing)

Full commands: SIGNING_TIER_RUNBOOK.md section 5. Order is ttl-safety driven:
the first push must beat the seed band (50bp stable / 100bp volatile at
dtSource=0) and the volatile ttl (600s), so every slow step happens BEFORE the
on-chain deploy and signers boot exactly once with the final oracle address.

```
A. nx-rates image (gates G1-G3 code deltas -> BuildKit -> imageTag bumps)
B. precompute + signing-tier bring-up
   B4  predictOracle() -> $ORACLE_PRED (deployer 0x57b3 CREATE nonce+1;
       deployer sends NOTHING else until C completes)
   B5  uncomment signed_quotes block in the ConfigMap mirror (G1-G3 image
       live) + prefill oracle via keepers/scripts/fill-oracle-config.py
       --oracle $ORACLE_PRED; kubectl apply; mirror-sync config.yml
   B6  forwarder fan-out to the 3 signer sinks; restart nxr
   B7  helm install nxr-signer-{0,1,2}  [OWNER GATE 2 clears here]
   B8  sigma warm-up ~4h (once; /data PVC keeps shards) -> quote meta green,
       G5 feed-liveness audit green (22/22 legs provider_lag <= 500ms)
C. on-chain deploy (deployOracle; hard-asserts oracle == $ORACLE_PRED;
   seeds pulled <= 5 min pre-broadcast; GUARDIAN env or setGuardian next)
D. keeper fill (NO signer restart): fill-oracle-config.py --json
   11155111.deploy.json -> 22 feed_ids; cross-checks prefill
E. keeper: dry --once (full preflight) -> live --once -> getFeed verify ->
   helm install btr-oracle-daemon-sepolia (2 replicas)   <- PRICES PUSHING
F. guardian drill + monitors + guards file armed-validate; only then pools
```

Blocking gates before B can start (all verified in code, runbook section 2):
G1 peer self-filter, G2 keyless skip-arm, G3 forwarder fan-out (nx-rates
deltas + new image); G5 scraper coverage (2026-07-22 audit: 11/22 legs fresh;
all-or-nothing blob means ONE dark symbol 503s the whole quote); G6 idx 9
stays disabled (no syrupUSDC source).

## 3. Observability

Three layers, reconciled at keeper startup (hard-fail on mismatch):
1. Trigger policy: `GET /thresholds` per feed: config theta_bps, heartbeat_s,
   ci_spike_bps, min_push_gap_s x on-chain maxDeviation, ttl,
   heartbeat_le_half_ttl.
2. Decision history: one record per feed per relay decision (reason
   theta_cross | heartbeat | ci_spike | cold_start | none, deviation vs
   threshold, mode live | dry-run | standby, tx hash) -> append-only JSONL
   (`jsonl_max_mb` size-cap rotation to `<path>.1`) + in-memory ring via
   `GET /triggers?feed=SYM&limit=N`.
3. On-chain state: `getFeed(feedId)` polling. There is NO per-push event
   (deleted in the gas optimization, -25%/push); guard actions and admin
   lifecycle DO emit events, so protective firings are trustlessly auditable.

How to view (Sepolia): ClusterIP svc `btr-oracle-daemon-sepolia-svc.btr.svc.
cluster.local:80 -> 9464`; from the Mac:
`ssh -p 40022 nxrates.com 'sudo k0s kubectl -n btr exec deploy/btr-oracle-daemon-sepolia -- curl -s localhost:9464/triggers?limit=20'`.
Startup is fail-loud (JSONL probe + HTTP bind before the loop); runtime is
strictly off the money path. Public `/api/oracle/*` proxy = spec-only
(OBSERVABILITY.md), build when the front needs it.

## 4. Guard registry

17 declarative rows in `guards.sepolia.toml` (mainnet twin tighter), schema
`keepers/src/guards.rs`, docs `keepers/GUARDS.md`, and the guardian role matrix:
- security-guardrail (10): signer set reconcile/equivocation revoke, feed
  divergence pause, asset anomaly pause / drain freeze, band narrow
  (tighten-only), upgrade / signer-grant / threshold-decrease vetoes, manual
  halt macro.
- risk-param-update (6, risk-steward only): scale/fee fast retunes,
  reservation tighten, dispersion band + curve shape retunes (LOW timelock),
  atomic theta bundle (min_push_gap_s 36 mainnet).
- liveness (1): feed_liveness_pause at 2x heartbeat.
Root invariant (validator-enforced): guardian = freeze/tighten/cancel ONLY;
param writes are risk-steward; every reverse (unpause, widen, grant) is owner.
Validation gate: `btr-keeper guards --config guards.sepolia.toml [--unarmed]`;
armed boot requires filled contract addresses. Guard execution keeper is not shipped yet;
registry + validator + CI gate are
live today.

## 5. Owner-gated decisions (EXACT, nothing else blocks)

GATE 1 - Signer key custody (decision pending):
- As-deployed: 3 attester keys as RAW k8s Secrets in ONE single-node etcd
  (zero custody redundancy; node has DiskPressure history). Disk loss = full
  attester-set loss = feed halt until timelocked re-grant.
- Decision needed: approve the seal-to-git flow (install sealed-secrets
  controller, seal the 3 existing Secrets + cosign secret in place, commit
  sealed copies, owner holds the controller backup key) OR an alternative
  custody scheme. This is the FIRST action after the decision (runbook
  section 3), acceptable to defer through Sepolia bring-up, HARD-blocking for
  mainnet (fresh ceremony + sealed backups BEFORE first use).
- Also implied: "restore-canonical vs rotate" is resolved de facto (canonical
  keys provisioned + address-verified); any regeneration now is a deliberate
  rotation requiring new pins in 3 files + redeploy.

GATE 2 - Prod signing-tier bring-up authorization:
- Applying ANY of: uncommenting the signed_quotes block (+resync), deploying
  nxr-signer-{0,1,2}, forwarder fan-out change, the G1-G3 image rollout.
  These mutate the production NXR cluster that serves the public feed.
- Prerequisite work (not owner-gated, must be green first): G1-G3 nx-rates
  code deltas + image; G5 scraper coverage to 22/22 fresh legs + idx 0
  identity-feed decision (NXR-side delta either way).
- Until this gate: nothing on the cluster changes; every config stays inert
  (commented block, 0x0 placeholders, undeployed manifests).

Not owner-gated (ready, executes inside the runbook): Sepolia ETH deploy from
funded 0x57b3, keeper fill + keeper start, guardian drill, guards validation.

## 6. Ready-to-deploy vs gated (status 2026-07-22)

READY (authored, validated, staged; zero cluster mutation):
- `SepoliaOracleDeploy.s.sol` (predictOracle + assert), deployer funded.
- `oracle.sepolia.toml` + `oracle.mainnet.toml` (+ example aligned),
  `guards.sepolia.toml` + `guards.mainnet.toml`: all parse + validate
  (unarmed), 86/86 keeper tests green.
- Signer + keeper Deployment values files; ConfigMap mirror safe-to-resync
  (block commented); fill-oracle-config.py tested round-trip.
- nx-rates schema hardening (deny_unknown_fields) compiles; config.yml
  mirror-synced.

GATED:
- On-cluster: signer Secrets provisioning already done (verified); everything
  else NXR-side waits on GATE 2 + G1-G3/G5 engineering.
- Mainnet: GATE 1 custody + fresh key ceremony, real-token deploy script twin,
  refPrimary reference oracle, dedicated RPC, distinct relay keys.
