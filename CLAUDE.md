# BTR DEX -agent guide

## Scope (post Phase 30 split)
This repo = **Solidity contracts + Bun keepers ONLY**. No front/back/SDK colocated.

| Sibling repo | Path | Role |
|---|---|---|
| sdk   | `~/Work/btr/sdk`   | `@btr-protocol/sdk` -ABIs, eth RPC client, shared TS types |
| swap  | `~/Work/btr/swap`  | `@btr-supply/swap` -aggregator SDK |
| back  | `~/Work/btr/back`  | Bun monorepo: `services/{swap,collector,agents,docs,envio}` |
| front | `~/Work/btr/front` | Preact + Vite SPA |
| alm   | `~/Work/btr/alm`   | ALM vault contracts (consume DEX via `BtrPoolAdapter`) |
| shared | `~/Work/btr/shared` | Shared Solidity primitives (`AccessControl`, `Treasury`, `Staking`, `Distributor`, `Bridge`, `GovToken`, `StakedAsset`, `PriceProvider`, `Errors`, `Constants`, `Timelock`) consumed via `@btr-shared/` remap |
| docs  | `~/Work/btr/docs`  | Canonical product + protocol docs (Phase 40C consolidation) |

If you need to edit dApp UI / off-chain services / SDK types → go to the sibling repo. Do NOT recreate `front/`, `back/`, `sdk/`, or `docs/` here.

## Local content
- `evm/`     -Solidity (Foundry). Main protocol impl + tests.
- `sim/`     -off-chain simulation harness (Zig).
- `svm/`     -reserved for Solana port.
- `scripts/` -tooling (search index, slot computation, plotting, local dev orchestrator).
- `salts/`   -CREATE3 salt registry for deterministic addresses.

## Build/test
```sh
cd evm && forge build && forge test
```

## Cross-repo refs
- ABIs consumed by `front` via `@btr-protocol/sdk/abis` -do not duplicate ABIs here. After contract changes, regenerate ABIs in `~/Work/btr/sdk/src/abis/`.
- Keeper services may live here OR migrate to `~/Work/btr/back/services/` (TBD).

## Historical
Previous monorepo layout (front/back/sdk colocated) deprecated in Phase 30. See sibling READMEs.
