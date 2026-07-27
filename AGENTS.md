# BTR DEX: contributor guide

## What this is
BTR DEX is the adaptive multi-asset AMM (AIMM): hub-and-spoke routing, dynamic fees, a keeper-pushed external-mark oracle, and an internal non-transferable LP ledger. Contracts are Solidity under `evm/`, the Rust reference model mirroring `evm/src/libraries/Pricing.sol` is `sim/` (`aimm-sim`), and AMM studies are in `research/`.

Siblings live under the same parent directory: `shared` (Solidity primitives, required to build), `sdk` (ABIs and RPC client), `back`, `front`, `docs`, and `keepers` (the oracle mark pusher). No front end or back end lives here.

## Code style
- Hyper-concise, zero redundancy. Deletion beats addition. Boring beats clever.
- Reuse before adding: grep the repo first, then consolidate loosely related functions into one generic.
- No unrequested abstractions: no single-implementation interfaces, no config for constants, no scaffolding "for later".
- One implementation, not two. One behaviour change should touch one place.
- Comments carry only constraints the code cannot show. Commented-out code is deleted, not kept.
- Never cut input validation at trust boundaries, error handling, or security checks.
- Mechanical formatting belongs to `forge fmt`, not to review prose.
- WARNING: `forge fmt` de-braces single-line `if`/`for`/`while` bodies. On a guarded block holding two statements that makes the second unconditional. Expand the braces yourself and diff after running it.

## Contributing
- Conventional Commits: `feat|fix|docs|refac|ops|test`.
- No dangling, untracked, or dead code in a commit.
- Linear history: rebase onto `main`, never merge a feature branch back.
- `git add <path>` by explicit path. Never `git add -A`.
- Never stage another contributor's hunks. If the tree holds someone else's in-flight work, stage only your own paths.
- No co-authoring or attribution trailers, and no assistant or model names in commits, code, or docs.

## Repo facts
- Solidity only, under `evm/`. Front end, back end, SDK, and docs are sibling repos under `~/Work/btr/`. Do not recreate them here.
- Requires a sibling `shared` checkout: `@btr-shared/` remaps to `../../shared/evm/src/`, out of tree. A lone clone of this repo does not build. Fix that by cloning `shared` as a sibling, never by vendoring a copy: a second copy silently forks the singletons the deployed system shares.
- `foundry.lock` and `.deps/` are committed, so dependencies resolve without a network fetch. Build and test with `cd evm && forge build && forge test`.
- ABIs have a single source, `../sdk/src/abis/`. Regenerate after contract changes; never duplicate an ABI here.
- CREATE2 addresses derive from bytecode. `bytecode_hash = "none"` and `cbor_metadata = false` are mandatory, and renaming a deployed `contract`/`library` symbol changes its address.
- No defaults on deploy inputs. A defaulted liquidity seed put 40x the intended amount on Sepolia, and a defaulted oracle seed priced a peg asset at 1.0. A default makes a missing input indistinguishable from a decision, so require every one.
