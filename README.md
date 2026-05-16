# BTR DEX

Adaptive multi-asset AMM with hub-and-spoke routing, dynamic fees, dual-EMA internal oracle, ERC-1155 rebasing LP, and a piecewise bonding curve. Flat-`Pool` architecture: no Diamond, no proxy indirection, no ERC-7201 storage namespacing. EIP-1167 minimal-proxy clones via `PoolFactory`.

## Repo scope

This repo = Solidity contracts (`evm/`) + Bun keepers + simulation harness. Other concerns live in sibling repos under `~/Work/btr/`:

| Concern | Repo |
|---|---|
| dApp UI | `front` (`@btr-protocol/front`) |
| Off-chain services (swap, collector, agents) | `back` (`@btr-protocol/back`) |
| Shared TS types + ABIs + RPC client | `sdk` (`@btr-protocol/sdk`) |
| Cross-chain swap aggregator | `swap` (`@btr-supply/swap`) |
| Product + protocol docs | `docs` |
| ALM vaults (consume DEX via `BtrPoolAdapter`) | `alm` |
| Shared Solidity primitives (AccessControl, Treasury, Staking, GovToken, StakedAsset, PriceProvider, Errors, Constants) | `shared` (`@btr-shared/` remap) |

Local layout:
- `evm/` - Solidity (Foundry). Contracts + tests.
- `sim/` - off-chain simulation harness (Zig).
- `scripts/` - tooling (search index, slot computation, plotting, local dev orchestrator).
- `salts/` - CREATE3 salt registry for deterministic addresses.

## On-chain surface (DEX-local)

| Contract | Role |
|---|---|
| `Pool.sol` | Flat AMM pool. Hot-path entries (swap, deposit, withdraw, fast views); cold paths dispatched via `fallback` -> `PoolAux`. |
| `PoolAux.sol` | Singleton cold-path dispatcher (admin / staking / flash / oracle pokes / feed updates). DELEGATECALL'd by every Pool clone. |
| `PoolFactory.sol` | EIP-1167 minimal-proxy pool deployer. CREATE3-deterministic. |
| `Admin.sol` | Per-chain singleton: protocol-fee collection, risk-flag/fee curation, pool-side admin setters. |
| `Flash.sol` | Flash-loan singleton (cross-pool flash mints). |
| `Router.sol` | Hub-and-spoke swap router (batch + multi-leg). |
| `oracles/ExternalOracle.sol` | Chainlink-style adapter; bounds the internal dual-EMA mark. |

Cross-cutting singletons (`AccessControl`, `Treasury`, `Staking`, `Distributor`, `GovToken`, `StakedAsset`, `Bridge`, `tokens/BridgeableERC20`) live in `~/Work/btr/shared` and are consumed via `@btr-shared/` remap. `Bridge.sol` = LayerZero OFT bridge; `BridgeableERC20` = ERC-7802 bridgeable token mixin.

> Kill-revert symmetry (Pass-5 W2-L2 + Pass-7): `assetValue` / `vaultAssets` revert `Err.Killed_` on both `Dex.sol` and the sibling `BtrPoolAdapter.sol` so ALM vaults observe identical fail-loud semantics on kill. Pass-7 C1 adds timelocked `queueUnkill` / `executeUnkill` to `BtrPoolAdapter` for recovery.

## Libraries (`evm/src/libraries/`)

`AnchorTree`, `Constants`, `Maths`, `Oracle`, `PoolAdmin`, `PoolAdminWrite`, `PoolBatch`, `PoolDecay`, `PoolEdge`, `PoolHookExec`, `PoolLiquidity`, `PoolOracle`, `PoolSwap`, `PoolSwapQuote`, `PoolView`, `Pricing`, `Spline`, `TransientCache`.

`PoolSwap` (entry + I/O) DELEGATECALLs into `PoolSwapQuote` (post-quote pipeline) so both fit under EIP-170 (Phase 42K.10D.B2 split).

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

## Troubleshooting

- Anvil port stuck: `lsof -ti:8545 | xargs kill -9`.
- Manual deploy: `forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast --code-size-limit 100000`.

## Documentation

Canonical docs in `~/Work/btr/docs/` (Phase 40C consolidation): `dex/`, `supply/`, `swap/`, `legal/`, `shared/`. ADRs under `docs/shared/`.
