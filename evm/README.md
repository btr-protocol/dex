# BTR DEX — EVM Contracts

Solidity (Foundry) implementation of the BTR adaptive multi-asset AMM: hub-and-spoke routing, dynamic fees, keeper-pushed external-mark oracle, internal non-transferable LP ledger (`lpBalances` mapping + liquidity index — not an ERC-1155/ERC-20 token), piecewise bonding curve. Flat-`Pool` architecture: **no Diamond, no proxy indirection, no ERC-7201 storage namespacing**. EIP-1167 minimal-proxy clones via `PoolFactory`.

Solidity pragma: `=0.8.35` (exact, see `foundry.toml`). Solady is vendored under `.deps/solady/`.

## Core Features

- **Multi-asset hub-and-spoke** — All swaps route through a base token.
- **Dynamic fees** — Multi-factor adaptive fees driven by volatility, inventory, divergence.
- **Keeper-pushed external-mark oracle** — A keeper (`onlyOracle`, Safe multisig in prod) pushes a fresh mark per feed on a deviation-θ + heartbeat schedule. Swaps quote off that fresh mark (`lastPriceB64`), not a lagging internal EMA — this is what kills LVR. The contract folds an on-chain σ-EMA (pricing vol) + a servable price EMA (reference only). Between pushes the mark is fixed but the quoted price drifts with order flow via the inventory skew. No Chainlink in the quote path.
- **Rebasing LP accounting** — Auto-compounding internal LP shares (per-user `lpBalances` mapping, non-transferable) scaled by a per-asset liquidity index.
- **Piecewise bonding curve** — Adaptive liquidity distribution with volatility-based breadth.
- **Protocol fees** — Configurable split between LPs and treasury.
- **Risk + admin controls** — Per-pool freezes, circuit breakers, fee curation via the per-chain `Admin` singleton.

## Contract Layout

```
src/
├── Pool.sol              # Flat AMM pool. Hot paths: swap, deposit, withdraw, fast views.
├── PoolAux.sol           # Singleton cold-path dispatcher (admin setters + flash send/account).
│                         #   Pool fallback DELEGATECALLs PoolAux.
├── PoolFactory.sol       # EIP-1167 minimal-proxy pool deployer (CREATE2 cloneDeterministic).
├── Admin.sol             # Per-chain singleton: protocol-fee collection, risk/fee curation.
├── Flash.sol             # ERC-3156 flash-loan singleton (loans pool reserves; no minting).
├── Router.sol            # Hub-and-spoke swap router (batch + multi-leg).
├── interfaces/           # IPool, IPoolFactory, IPoolHooks, IAdmin, IFlash, IRouter, IOracle, …
├── oracles/
│   └── ExternalOracle.sol  # Keeper-push external oracle (onlyOracle); fresh pushed mark = quote source.
└── libraries/            # AdminTimelock, AnchorTree, Constants, Maths, Oracle, PoolAdmin, PoolAdminWrite,
                          # PoolBatch, PoolIO, PoolDecay, PoolEdge, PoolHookExec,
                          # PoolLiquidity, PoolSwap, PoolSwapQuote, PoolView,
                          # Pricing, Spline, TransientCache.
```

`PoolSwap` (entry + I/O) DELEGATECALLs into `PoolSwapQuote` (post-quote pipeline) so both fit under the EIP-170 24 576-byte cap (Phase 42K.10D.B2 split).

Shared cross-cutting singletons live in `~/Work/btr/shared/evm/src/` and are consumed via the `@btr-shared/` Foundry remapping (`evm/foundry.toml` / `remappings.txt` → `@btr-shared/=../../shared/src/`):

- `access/AccessControl.sol` — Owner / Keeper / Treasury / Swapper registry.
- `oracle/PriceProvider.sol` — Chainlink USD feeds + L2 sequencer guard.
- `Bridge.sol` + `tokens/BridgeableERC20.sol` — LayerZero OFT bridge + ERC-7802 token mixin.
- `Treasury.sol`, `Staking.sol`, `Distributor.sol`, `tokens/GovToken.sol`, `tokens/StakedAsset.sol`.
- `Errors.sol`, `Constants.sol`, `Timelock.sol`.

## Roles

Authority is centralized in the shared `AccessControl` singleton (one per chain).

- **Owner** — adds/removes assets, configures fee curves and circuit breakers, queues timelocked upgrades on the shared `Treasury` / `Bridge` / `AccessControl` (UUPS), updates pool-side admin parameters via `Admin` and `PoolAux`.
- **Keeper (oracle pusher)** — `grantOracle`'d addresses on `ExternalOracle` push mark + σ sample + confidence. That is the keeper's ONLY on-chain authority; fee curves, freezes, and risk flags are owner-only via `Admin`.
- **Treasury** — collects protocol fees; address resolved through `AccessControl`.

Pools themselves are not UUPS — they are EIP-1167 clones deployed by `PoolFactory`. UUPS upgradeability is reserved for the shared singletons.

## Quick Start

```sh
forge build
forge test
forge snapshot
```

Coverage / static analysis:

```sh
forge coverage --report lcov --no-match-coverage 'test/(Mocks|Setup|Helpers)'
forge test --gas-report
slither . --filter-paths 'test|.deps'
```

## Security

- Reentrancy: Solady `ReentrancyGuardTransient`.
- Safe transfers: Solady `SafeTransferLib`.
- Overflow protection: Solidity 0.8 checked arithmetic + explicit range checks/casts.
- Access control: role-based via shared `AccessControl`.
- Circuit breakers: manual owner-only freeze/pause via `Admin` (`freezeAsset`/`pauseAsset`/`batchRiskOp`); automatic gates = feed TTL staleness halt, confidence halt, depeg bands, opt-in per-feed push deviation clamp on `ExternalOracle`.
- All compiled artifacts ≪ 24 576-byte EIP-170 cap.

## License

BTR Supply Dual License: Business Source License 1.1 until Change Date, MIT thereafter. Source SPDX headers default to `MIT` for downstream forks; BSL 1.1 terms apply to deployed BTR Supply production instances. See https://btr.supply/licences for the canonical statement.
