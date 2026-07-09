# BTR DEX — agent guide

Custom AIMM: adaptive multi-asset AMM (hub-and-spoke routing, dynamic fees, keeper-pushed external-mark oracle, internal non-transferable LP ledger (`lpBalances` mapping + liquidity index — NOT an ERC-1155/ERC-20 token), piecewise bonding curve). Flat-`Pool` arch — no Diamond/proxy/ERC-7201; EIP-1167 clones via `PoolFactory`. Solidity contracts ONLY — front/back/sdk/docs live in sibling repos under `~/Work/btr/` (see `~/Work/btr/CLAUDE.md`); do NOT recreate them here.

## Layout
- `evm/`     — Solidity 0.8.35 (Foundry). `src/`, `test/`, `script/`. Deps: `@btr-shared/` → `../../shared/evm/src/` remap; `foundry.lock` symlinked to `../../alm/evm/foundry.lock`.
- `sim/`     — Rust AIMM simulation crate (`aimm-sim`). `src/amm/` = the reference model mirroring
  `evm/src/libraries/Pricing.sol` (aimm + Curve/Uni/Wombat/A-S baselines); `tests/amm_sim.rs` replays
  real NX tapes via `nxr-sdk::BarFile`. `cargo test` (data-backed tests skip if `../research/data` absent).
- `research/` — AMM research studies (stable-core, pool-fees LVR, peer-architecture notes). Py/TS analysis
  scripts; market-data blobs live under `research/data` (gitignored). Moved from prime 2026-07-09.
- `svm/`     — reserved Solana port (README only).
- `scripts/` — tooling: `dev.ts`/`prod.ts` (orchestrators), `start-anvil.sh` (mainnet-fork anvil), `build-search-index.ts`, `precompile-markdown.ts`, slot/plot/test-data py+sh.
- `salts/`   — CREATE3 salt registry (deterministic addresses).

## Build/test
```sh
cd evm && forge build && forge test    # via_ir, optimizer 10000; profiles: dev/debug
bun run lint | fmt                     # oxlint
bun run dev | prod | anvil             # scripts/ orchestrators
```

## Cross-repo
- ABIs single source = `~/Work/btr/sdk/src/abis/` — never duplicate here; regen after contract changes.
- ALM vaults consume DEX via `BtrPoolAdapter` (`~/Work/btr/alm`).

## Hard rules
1. `bun` exclusively — NEVER npm/yarn.
2. Git: user's identity only, no AI names/mentions in commits; atomic commits, prefixes `feat|fix|docs|refac|ops`.
3. Dead code = zero tolerance: delete unused/commented-out code immediately.
4. Comments explain WHY not WHAT; keep invariants/safety notes.
5. Responses SHORT. Unknown → WebSearch first, then ask.
