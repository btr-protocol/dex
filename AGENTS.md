# BTR DEX: contributor guide

Solidity AIMM under `evm/`, Rust reference model under `sim/`, studies under `research/`. Product docs: https://br.market/docs (not in this repo).

Siblings (some may stay private): `shared` (required to build), `sdk`, `keepers`, `back`, `front`, `docs`.

## Code style
- Hyper-concise. Deletion beats addition. Boring beats clever.
- Reuse before adding. No unrequested abstractions. One implementation, not two.
- Comments carry only constraints the code cannot show. No commented-out code.
- Never cut validation, error handling, or security checks at trust boundaries.
- `forge fmt` de-braces single-line `if`/`for`/`while`. Expand braces yourself when a guarded block has two statements.

## Contributing
- Conventional Commits: `feat|fix|docs|refac|ops|test`.
- Linear history: rebase onto `main`. `git add <path>` by explicit path. Never `git add -A`.
- No AI/model names in commits, code, or docs. No co-author trailers.

## Repo facts
- Requires sibling `shared`: `@btr-shared/` → `../../shared/evm/src/`. Never vendor a copy.
- `foundry.lock` and `.deps/` are committed. `cd evm && forge build && forge test`.
- ABIs live in the `sdk` sibling. CREATE2: `bytecode_hash = "none"`, `cbor_metadata = false`.
- No defaults on deploy inputs.
