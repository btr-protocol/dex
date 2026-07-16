# BTR DEX

Adaptive multi-asset AMM with hub-and-spoke routing, dynamic fees, a keeper-relayed external-mark oracle, an internal non-transferable LP ledger (per-user `lpBalances` mapping + liquidity index — not an ERC-1155/ERC-20 token), and a piecewise bonding curve. The lean `Pool` implementation is shared by ERC-1967 beacon proxies; cold paths delegate to `PoolAux`. There is no Diamond or ERC-7201 namespacing.

## Repo scope

This repo = Solidity contracts (`evm/`) + simulation harness. Keepers (oracle pusher + executor) are Rust, in the sibling `~/Work/btr/keepers` repo. Other concerns live in sibling repos under `~/Work/btr/`:

| Concern | Repo |
|---|---|
| dApp UI | `front` (`@btr-protocol/front`) |
| Off-chain services (collector, agents, docs, envio) | `back` (`@btr-protocol/back`) |
| Shared TS types + ABIs + RPC client | `sdk` (`@btr-protocol/sdk`) |
| Product + protocol docs | `docs` |
| ALM vaults (consume DEX via `BtrPoolAdapter`) | `alm` |
| Shared Solidity primitives (AccessControl, Treasury, Staking, GovToken, StakedAsset, PriceProvider, Errors, Constants) | `shared` (`@btr-shared/` remap) |

Local layout:
- `evm/` - Solidity (Foundry). Contracts + tests.
- `sim/` - Rust AIMM simulation crate (`aimm-sim`): `src/amm/` mirrors `evm/src/libraries/Pricing.sol` (aimm + Curve/Uni/Wombat/A-S baselines); tests replay real NX tapes.
- `research/` - AMM research studies (stable-core, pool-fees LVR, peer architectures); data blobs gitignored.
- `scripts/` - tooling (search index, slot computation, plotting, local dev orchestrator).
- `salts/` - CREATE3 salt registry for deterministic addresses.

## On-chain surface (DEX-local)

| Contract | Role |
|---|---|
| `Pool.sol` | Flat AMM pool. Hot-path entries (swap, deposit, withdraw, fast views); cold paths dispatched via `fallback` -> `PoolAux`. |
| `PoolAux.sol` | Singleton cold-path dispatcher (admin setters + flash send/account). DELEGATECALL'd by every Pool clone via `fallback`. |
| `PoolFactory.sol` | Deterministic ERC-1967 beacon-proxy deployer. A 7-day timelock upgrades the entire pool fleet atomically after immutable-wiring validation. |
| `Admin.sol` | Per-chain singleton: protocol-fee collection, risk-flag/fee curation, pool-side admin setters. |
| `Flash.sol` | ERC-3156-style (postFlashLoan variant) flash-loan singleton — loans a pool's reserves (no minting); repay by raising the pool's token balance. |
| `oracles/ExternalOracle.sol` | Permissionless relay of EIP-712 NXR-signed mark/σ/confidence records. Authenticated source time, immutable relay-lag ceiling, monotonic replay protection, deviation clamps, and TTL gates fail closed. No Chainlink or lagging price EMA is in the quote path. |

On-chain `Router` was retired (see `AUDIT_REPORT.md` cycle 4) — routing is off-chain by design: route-finding in `sdk/src/amm` (`rankSwap`, direct + 2-hop routes across BTR's own pools) + execution calldata in `sdk/src/router` (`planToLegs` + `buildSwapCalls`).

Cross-cutting singletons (`AccessControl`, `Treasury`, `Staking`, `Distributor`, `GovToken`, `StakedAsset`, `Bridge`, `tokens/BridgeableERC20`) live in `~/Work/btr/shared` and are consumed via `@btr-shared/` remap. `Bridge.sol` = LayerZero OFT bridge; `BridgeableERC20` = ERC-7802 bridgeable token mixin.

## Libraries (`evm/src/libraries/`)

`AdminTimelock`, `AnchorTree`, `Constants`, `Maths`, `Oracle`, `PoolAdmin`, `PoolAdminWrite`, `PoolBatch`, `PoolDecay`, `PoolEdge`, `PoolIO`, `PoolLiquidity`, `PoolSwap`, `PoolView`, `Pricing`, `Spline`, `TransientCache`.

`PoolSwap` inlines post-quote `PoolIO.exec` (former `PoolSwapQuote` trampoline removed — EIP-170 headroom remains on `PoolSwap`).

## Build & test

```bash
cd evm
forge build
forge test
```

## Local dev stack

```bash
bun install
bun run dev          # anvil BSC fork + deploy + collector
bun run dev --reset  # clear state, redeploy from scratch
```

Anvil `:8545`. Collector `:3001`. Front (`:3000`) served from `~/Work/btr/front`. Test account `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` / pk `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`.

### CREATE3 deploys

Salt = `keccak256(DEPLOYER || NONCE)`. Deployer `0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3`. CreateX factory `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` (Anvil 31337 / BNB 56 / ETH 1 / Base 8453 / Arbitrum 42161). Same address per salt across chains.

Salt files: `salts/b712_b712.txt` (Pool Zero / Stable / Treasury / Bridge); `salts/bbbb_bb.txt` (mocks).

## Security

`DEPLOYER_PK` controls all CREATE3 deploys across chains. Never commit. Use `.env.local` (gitignored) or a secret manager. `.env.example` is the template.

Only standard, non-rebasing ERC-20s without sender/receiver transfer taxes may be listed. Inflow accounting supports received-amount tokens, but output minimums and reserve debits intentionally use nominal amounts to keep the swap hot path lean.

## Troubleshooting

- Anvil port stuck: `lsof -ti:8545 | xargs kill -9`.
- Manual deploy: `forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast --code-size-limit 100000`.

## Documentation

Canonical docs in `~/Work/btr/docs/`: `dex/`, `protocol/`, `legal/`, `security/`, `concepts/`, `reference/`.
