# BTR DEX

Adaptive multi-asset AMM with hub-and-spoke routing, dynamic fees, dual-EMA internal oracle, rebasing ERC-1155 LP tokens, and a piecewise bonding curve. Post Phase 42H: flat-`Pool` architecture (no Diamond, no PoolProxy, no ERC-7201 namespaced storage) + dedicated singleton contracts (`Admin`, `Staking`, `Distributor`, `Flash`) + EIP-1167 minimal-proxy pools via `PoolFactory`.

## Project structure

This repo = **Solidity contracts (`evm/`) + Bun keepers + simulation harness ONLY** (post Phase 30 split). Front / back / SDK / docs live in sibling repos under `~/Work/btr/`:

| Concern | Repo |
|---|---|
| dApp UI | `~/Work/btr/front` (`@btr-protocol/front`, SvelteKit) |
| Off-chain services (swap gateway, collector, agents) | `~/Work/btr/back` (`@btr-protocol/back`, Bun monorepo) |
| Shared TS types + ABIs + EVM RPC client | `~/Work/btr/sdk` (`@btr-protocol/sdk`) |
| Cross-chain swap aggregator SDK | `~/Work/btr/swap` (`@btr-supply/swap`) |
| Product + protocol documentation | `~/Work/btr/docs` (markdown, served via `back/services/docs`) |
| ALM vault contracts (consumes BTR DEX via `BtrPoolAdapter`) | `~/Work/btr/alm` |
| Shared Solidity primitives (AccessControl, PriceProvider, Errors) | `~/Work/btr/shared` (`@btr-shared/` foundry remap) |

Local layout:
- `evm/` - Solidity contracts (Foundry). Main protocol implementation + tests.
- `sim/` - Off-chain simulation harness (Zig) for parameter sweeps + invariant probes.
- `scripts/` - Bun + Python tooling (search index build, slot computation, parameter plotting, local dev orchestrator).
- `front/` - Symlink target for the SvelteKit dev surface only; canonical source is `~/Work/btr/front`.
- `salts/` - CREATE3 salt registry for deterministic cross-chain addresses.

## On-chain surface

| Contract | Role |
|---|---|
| `Pool.sol` | Flat AMM pool (multi-asset hub-and-spoke). Dual-EMA oracle, piecewise bonding curve, dynamic fees, ERC-1155 rebasing LP. No proxy indirection. |
| `PoolFactory.sol` | EIP-1167 minimal-proxy pool deployer. CREATE3-deterministic addresses. |
| `Admin.sol` | Per-chain singleton: roles (Owner / Guardian / Treasury), pause, blacklist, upgrade timelock, fee curation. |
| `Staking.sol` | BTR staking singleton (liquid staking, voting / earning power damping). |
| `Distributor.sol` | Reward distributor singleton (Merkle epoch payouts). |
| `Flash.sol` | Flash-loan singleton (cross-pool flash mints). |
| `Treasury.sol` | Treasury sink + fee router. |
| `Router.sol` | Hub-and-spoke swap router. |
| `Bridge.sol` + `tokens/BridgeableERC20.sol` | LayerZero OFT bridge surface + ERC-7802 bridgeable token mixin. |
| `oracles/ExternalOracle.sol` | External Chainlink-style oracle adapter used as a sanity bound on the internal dual-EMA mark. |
| `libraries/` | `AnchorTree`, `Maths`, `Oracle`, `PoolAdmin`, `PoolDecay`, `PoolOracle`, `Pricing`, `Spline`, `TransientCache`, `Constants`. |

UUPS upgrades are gated by an Admin-side timelock; the upgrade path (`G18`) and LayerZero peer registration (`G19`) were hardened in Phase 42H.D round 5.

## Build & test

```bash
cd evm
forge build
forge test
```

The test suite covers the Phase 42H flat-Pool design (`Phase42HB3dPoolTest`, `Phase42HB3eR*Test`), per-library units (`PoolDecay`, `PoolAdmin`, `PoolOracle`), storage-layout invariants (`PoolStorageLayout`, `PoolConstantsMirror`), the Bridge peer timelock, the UUPS upgrade timelock, and the end-to-end deploy script. Current suite: 286 tests passing.

## Development (local dev stack)

```bash
bun install
bun run dev          # anvil BSC fork + deploy + collector
bun run dev --reset  # clear state, redeploy from scratch
```

Anvil: `:8545`. Collector: `:3001`. Front (`:3000`) is served from `~/Work/btr/front` via its own `bun run dev`. Pre-funded test account: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` / pk `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`.

### CREATE3 deterministic deploys

Salt = `keccak256(DEPLOYER || NONCE)`. Deployer `0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3`. CreateX factory `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` (Anvil 31337, BNB 56, ETH 1, Base 8453, Arbitrum 42161). Same address per salt across chains.

Salt files: `salts/b712_b712.txt` (Pool Zero / Stable / Treasury / Bridge); `salts/bbbb_bb.txt` (mock tokens).

### Mock tokens (dev only)

`evm/src/mocks/MockERC20.sol` exposes public `mint(addr, amt)` + `faucet(amt)`. Symbols prefixed `m*` (`mUSDC`, `mWETH`, ...). Pool Zero: USDC / USDT / WETH / WBTC / WBNB / SOL / ZEC / PAXG. Pool Stable: DAI / TUSD / FDUSD / USDD / USDP / crvUSD / lisUSD / AUSD / frxUSD. Initial dev balances: 100k stables, 100 majors, 10 WBTC.

```bash
cast send <token> "mint(address,uint256)" <addr> 1000ether \
  --private-key <key> --rpc-url http://localhost:8545
```

### Security

- `DEPLOYER_PK` controls all CREATE3 deploys across all chains. **Never** commit. Use `.env.local` (gitignored) or a secret manager in production.
- `.env` is gitignored; `.env.example` is the template.

### Troubleshooting

- Anvil port stuck: `lsof -ti:8545 | xargs kill -9`.
- Manual deploy: `cd evm && forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast --code-size-limit 100000`.
- Front cannot find contracts: verify deployment artifacts are written by the dev script and the front config points at chainId 31337.

## Documentation

Canonical documentation lives in `~/Work/btr/docs/` (Phase 40C consolidation):

- `~/Work/btr/docs/dex/` - protocol mechanics, modules, integration.
- `~/Work/btr/docs/supply/` - BTR Supply ALM (sibling product).
- `~/Work/btr/docs/swap/` - BTR Swap aggregator.
- `~/Work/btr/docs/legal/` - terms, privacy, geographic policy.
- `~/Work/btr/docs/shared/` - cross-product foundations, manifesto, glossary.
- ADRs: `~/Work/btr/docs/shared/` (`ADR-001` per-contract upgrade strategy, `ADR-002` Phase 42H singleton split).

Docs are built into a search index by `~/Work/btr/back/services/docs/build/`.

## License

BTR Supply Dual License: Business Source License 1.1 until Change Date, MIT thereafter. See https://btr.supply/licences.
