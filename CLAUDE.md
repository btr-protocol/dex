# BTR DEX -agent guide

## Scope (post Phase 30 split)
This repo = **Solidity contracts + Bun keepers ONLY**. No front/back/SDK colocated.

| Sibling repo | Path | Role |
|---|---|---|
| sdk   | `~/Work/btr/sdk`   | `@btr-protocol/sdk` -ABIs, eth RPC client, shared TS types |
| swap  | `~/Work/btr/swap`  | `@btr-supply/swap` -aggregator SDK |
| back  | `~/Work/btr/back`  | Bun monorepo: `services/{swap,collector,agents}` |
| front | `~/Work/btr/front` | Preact + Vite SPA |

If you need to edit dApp UI / off-chain services / SDK types → go to the sibling repo. Do NOT recreate `front/`, `back/`, or `sdk/` here.

## Local content
- `evm/` -Solidity (Foundry). Main protocol impl + tests.
- `circuits/` -zkSNARK circuits (dark pool privacy).
- `keeper/`   -off-chain guardian (circuit breakers, oracle updates).
- `sim/`      -simulation harness.
- `specs/`    -canonical technical specs.
- ~~`docs/`~~ -**MOVED** to `~/Work/btr/docs/` (Phase 40C). Three product surfaces consolidated under one tree (swap/dex/supply/legal + protocol-wide). Build scripts now live at `~/Work/btr/back/services/docs/build/`.

## Build/test
```sh
cd evm && forge build && forge test
```

## Cross-repo refs
- ABIs consumed by `front` via `@btr-protocol/sdk/abis` -do not duplicate ABIs here. After contract changes, regenerate ABIs in `~/Work/btr/sdk/src/abis/`.
- Keeper services may live here OR migrate to `~/Work/btr/back/services/` (TBD).

## Historical
Previous monorepo layout (front/back/sdk colocated) deprecated in Phase 30. See sibling READMEs.
