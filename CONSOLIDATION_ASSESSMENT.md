# BTR / NX Rates — Hyper-Consolidation Assessment Brief

> Self-contained context for a fresh expert team (unfamiliar with either codebase) to
> independently assess DRY / genericity / dead-code / over-packaging across the full stack.
> Goal: the smallest, most generic, most concise codebase that preserves all behavior.

---

## 0. The ask (one paragraph)

We believe we have **too many lines of code, across too many packages, across too many
files, with significant remaining redundancy**. We want an aggressive, professional
metaprogramming / genericity review: find *every* loose consolidation opportunity — dead
code, duplicated logic (intra- and cross-crate, and cross-language Rust↔TS), near-cousin
functions collapsible to one generic impl, over-abstraction that should be deleted,
thin/over-fragmented packages that should merge, and ceremony an HFT/embedded codebase
should not carry. Produce a ranked, **adversarially-verified** plan: every finding must be
challenged by ≥2 independent reviewers (4+ eyes per line) and reach consensus before it is
called safe. We are not afraid of large refactors, but each change must be behavior-preserving
and build-verified.

---

## 1. What the two systems are

**NX Rates (NXR)** — a multi-exchange market-data aggregator (the data *producer*). Owns all
exchange connections. Forwarders (crypto CEX WS adapters; FX via an MT4/Wine bridge) push
pre-aggregated MITCH `Index` frames over UDP to a core sink, which runs cross-provider TDWAP
aggregation every ~200ms and serves composite indexes via REST + WebSocket + UDP multicast.
Persistence is **append-only binary `.idx` shards** (memory-mapped, MITCH wire format) —
no ClickHouse/Parquet. Also produces OHLC bars (17 timeframes s10..d3), Renko bars
(volatility-calibrated brick size `k`), and synthetic cross-rates (triangulation).

**BTR** — a quant-trading *consumer* of NXR data, plus an on-chain DeFi protocol. It does not
own exchange connections; it consumes NXR via a `prime-nxr` WebSocket/UDP path. Two halves:
- `prime/` — Rust quant pipeline (signal research, GBM walk-forward optimization, backtest).
- The DeFi stack (TS + Solidity): an ALM (automated liquidity manager), a DEX, a swap
  aggregator, a front-end, a docs site, and a shared SDK.

The two are deliberately split: **NXR owns all market-data; BTR consumes it.** Do not propose
merging them.

---

## 2. Repository / package map (with current size)

### NX Rates — single Cargo workspace at `~/Work/nx/nx-rates`
| Crate | Path | LOC | Files | Role |
|---|---|---|---|---|
| `nxr` (core) | `core/` | 7,624 | 18 | aggregator + REST/WS/UDP server (the sink binary) |
| `nxr-sdk` | `sdk/rust/` | 11,997 | 43 | shared lib: MITCH types, IPC/.idx, agg, TDWAP, renko, parkinson, resolver, config, consumer client. **Git submodule.** |
| `nxr-sdk-python` | `sdk/python/` | 1,257 | 7 | pyo3 wheel over nxr-sdk |
| `nxr-crypto` / `nxr-fx` | `crypto/` | 3,943 | 40 | CEX + FX forwarder binaries (2 bins, 35+ exchange WS adapters) |
| `nxr-weights` | `weights/` | 507 | 3 | TDWAP weight scraper (1 bin; **deployed as k0s CronJob `ln` from a dedicated image** — see §5) |
| `series-factory` | `series-factory/` | 15,804 | 36 | offline tools: backfill, resample, migrate, calibrate, ~19 binaries |
| `mitch` | `mitch/impl/rust` | 3,430 | 16 | MITCH wire protocol crate. **Git submodule. Shared types — source of truth.** |

`mitch` is also driven by CSV data files (`mitch/data/*.csv`) compiled via `build.rs` into
`OUT_DIR` — a deliberate single-source pattern. NXR Rust total: **~44.6k LOC / 163 files / 7 crates.**

### prime — Cargo workspace at `~/Work/btr/prime`
| Crate | Path | LOC | Files | Role |
|---|---|---|---|---|
| `prime-core` | `crates/core/` | 424 | 6 | range/tick/force math primitives |
| `btr` (bin) | `crates/bin/` | 1,308 | 3 | CLI entrypoints |
| `prime-runtime` | `crates/runtime/` | 1,510 | 10 | live runtime, execution, lifi provider |
| `prime-backtest` | `crates/backtest/` | 849 | 2 | walk-forward backtest engine |
| `prime-ml` | `crates/ml/` | 2,996 | 10 | GBM model + trainer + renko features |

prime total: **~7.1k LOC / 31 files / 5 crates.** Consumes `nxr-sdk` + `mitch` by path.
(A wave-1 cleanup already removed ~114 LOC of dead code here — commit `abd7527`.)

### BTR TS/Solidity — sibling repos at `~/Work/btr`
| Repo | LOC (ts/svelte) | Role |
|---|---|---|
| `sdk/` | 27,850 | `@btr-protocol/sdk` — ABIs + eth RPC client + shared types. **Single source for ABIs.** |
| `swap/` | 6,846 | `@btr-supply/swap` — standalone swap-aggregator SDK |
| `back/` | 14,664 | Bun monorepo: `services/{swap,collector,agents,docs,envio}` + `shared/utils` |
| `front/` | 14,223 | Preact + Vite SPA |
| `dex/` | 2,203 | Solidity (`evm/`) + Bun keeper(s) |
| `alm/` | 66 | Solidity (`evm/`) + Bun keeper(s) |

BTR TS total: **~65.9k LOC.** Solidity LOC not counted here (separate audit lineage).
`sdk/` at 27.8k is the single largest TS surface and a prime consolidation target.

**Cross-cutting:** the same domain concepts (MITCH types, ticker-id resolution, timeframe
enums, synth/triangulation paths, plan-tier taxonomy) exist in **both Rust and TS** — a known
cross-language duplication seam.

---

## 3. Design invariants the team MUST NOT break

1. **NXR/BTR split** — NXR owns all exchange connections; BTR consumes via `prime-nxr`. Never merge.
2. **MITCH is the shared type source of truth** — driven by `mitch/data/*.csv` + `build.rs`.
   Don't re-hardcode what the CSVs already generate. (We already moved constants → CSV-driven.)
3. **`@btr-protocol/sdk` is the single ABI source** — no other package may re-duplicate ABIs.
4. **Binary `.idx` mmap storage only** — no ClickHouse/Parquet. The shard format is load-bearing.
5. **Zero-hardcoded mandate** — CSV/YAML are the sole source of truth for symbols/params;
   config-as-data, not config-as-code.
6. **HFT/embedded mindset** — fewer compilation units, fewer heavy deps, no abstraction that
   doesn't earn its keep. But the hot path (TDWAP aggregation, UDP recv, shard writes) must
   stay correct and not regress in latency.

---

## 4. What "consolidation" means here (the lenses)

Explore *all* of these, exhaustively:
- **Dead code/files** — unused pub fns/structs/traits (zero refs workspace-wide AND cross-repo),
  dead private helpers, never-read struct fields, orphan modules, scratch/backup artifacts.
- **Dead deps** — unused Cargo/npm deps; inert `[workspace.dependencies]` entries no member consumes;
  two libs doing the same job (multiple hashers, async runtimes, serde variants).
- **Intra/inter-crate duplication** — near-cousin functions, copy-pasted shard IO / MITCH
  encode-decode / config parsing / error taxonomies / bar construction → collapse to one generic impl.
- **Cross-language duplication (Rust↔TS)** — concepts implemented twice; can one be the
  generator/single-source for the other (codegen from CSV/schema)?
- **Genericity / metaprogramming** — where N near-identical impls could become one generic
  (traits, macros, build.rs codegen, const generics). Be aggressive but prove the win is real.
- **Over-abstraction to DELETE** — traits with one impl, builders on trivial structs, forwarding
  newtypes, never-instantiated generics, premature config-driven indirection.
- **Package/crate over-fragmentation** — thin crates/modules that should fold into a sibling,
  redundant TS packages, redundant build steps.

---

## 5. Hard constraints on *executing* changes (deployment coupling)

Some "obvious" merges are deployment-coupled and cannot be landed as a pure source edit:
- `nxr-weights` is built into a **dedicated container image** (`registry.nxrates.com/ln`) and
  deployed as k0s CronJob `ln`. Folding it into another crate requires also retargeting that
  image's in-cluster BuildKit build — which must be done in-cluster (the build host is amd64;
  the dev Mac is arm64) and cannot be verified locally. Flag such items as **"needs paired
  infra change"** rather than landing them blind.
- All container images are built **in-cluster via a BuildKit Job**, never on the Mac, never
  `podman build` on the prod node. A source refactor that changes a deployed binary's build
  target must be paired with the corresponding image change, operator-supervised.

---

## 6. Methodology we want (consensus, 4+ eyes per finding)

Each cohort = **5–6 engineers**, expert in genericity / metaprogramming / DRY. For every
finding: **≥2 independent reviewers** challenge it (does it really reduce LOC/build time? does
it over-couple? does it break an invariant in §3? is the cited evidence real?). A finding is
"safe" only on **consensus**. Pipeline per slice:

1. **Survey** — structural map of the target (files, module graph, dep edges, build-time hogs).
2. **Hunt** — parallel cohorts, each a different lens (§4), grounded by the survey. Every item
   cites real `file:line` evidence actually read (rg/AST), not speculation.
3. **Challenge (adversarial)** — ≥2 skeptics per finding independently re-grep across **both**
   `~/Work/nx/nx-rates` and `~/Work/btr` for any live reference; default to *not-safe* when
   uncertain; reject anything that breaks an invariant or whose evidence is wrong.
4. **Synthesize** — ranked, execution-ready plan with exact edit specs, grouped by repo/crate,
   independent edits first. Explicitly list rejected items + the live ref that saved each.

Execution gate (when we act on the plan): apply edits → `cargo check --workspace --tests`
(Rust) / `tsc`/build (TS) must be green → commit on the working branch. Never land a
deployment-coupled change without its paired infra change.

---

## 7. Progress so far (so a fresh team can pick up without re-doing it)

- **NXR axum feature-gate** (`sdk` `db1dce2` + `crypto` `f2d4ed0`): `axum` is now behind a
  `server-metrics` feature (default off); `crypto` is the sole opt-in consumer of the shared
  `/metrics` server. Result: `axum`+`tower`+`hyper` no longer compiled by `nxr-weights`,
  `nxr-sdk-python`, `series-factory`, or `prime`. Verified via `cargo tree -i axum`.
- **prime wave-1 dead-code cleanup** (`abd7527`, −114 LOC + 184MB scratch): removed the dead
  Vec `train`/`predict` family + `to_col_major` (model.rs), a dead `meta_model` field
  (trainer.rs), unused `range_divergence`/`range_to_ticks` (range.rs), and inert
  `memmap2`/`prime-runtime` workspace dep-aliases (Cargo.toml).
- **In flight (wave-2 workflow):** prime 2nd-pass tail + NXR `sdk`/`core`/`crypto` deep
  conciseness + two deferred merge candidates (inline `execution::lifi`; collapse
  `renko_features` alias module).
- **Known big targets not yet attacked:** `series-factory` (15.8k LOC / ~19 bins — likely a
  dispatcher-collapse candidate); BTR `sdk/` TS (27.8k LOC); the `nxr-sdk` net-module feature
  split (gate `tokio(net)`/`reqwest`/`tungstenite` behind a `client` feature so math-only
  consumers shed the HTTP/WS tree — same pattern as the axum gate, wider blast radius);
  cross-language Rust↔TS concept duplication.
- **Verdict'd build-NEGATIVE in an earlier review (do not re-propose without new evidence):**
  certain codegen single-source schemes (#17–20 in that pass) and a generic
  `RotatingShardWriter` — they added build cost/indirection without net win.

---

## 8. The deliverable we want back from a fresh team

A ranked, consensus-verified consolidation roadmap that:
1. States total packages/crates that can disappear, est. total LOC killed, est. build-time
   reduction — up front, in a few lines.
2. Tiers the work: T0 = mechanical/safe-now; T1 = focused refactor; T2 = architectural (crate
   merges, codegen single-source, cross-language unification).
3. Gives exact edit specs (file + text) for the safe set, grouped so independent edits land first.
4. Lists rejected proposals + why (the live ref or invariant that saved each), so we don't retry.
5. Calls out every deployment-coupled item separately (needs paired infra change).

Be ruthless. We would rather see 200 small DRY wins fully verified than 5 vague suggestions.
