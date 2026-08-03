# BTR — EVM Contracts

Solidity (Foundry) AIMM implementation. Product docs: https://br.market/docs

Solidity pragma: `=0.8.35` (exact, see `foundry.toml`). Solady is vendored under `.deps/solady/`.

## Core Features

- **Multi-asset hub-and-spoke** — All swaps route through a base token.
- **Dynamic fees** — Multi-factor adaptive fees driven by volatility, inventory, divergence.
- **Signed external-mark oracle** — Any relayer may submit an EIP-712 batch signed by an authorized NXR source. Swaps quote off `lastPriceB64`; signed σ is floored by realized mark movement. Authenticated source time, an immutable relay-lag bound, monotonic replay protection, TTL/confidence gates, and per-push deviation limits fail closed. No Chainlink or price EMA is in the quote path.
- **Rebasing LP accounting** — Auto-compounding internal LP shares (per-user `lpBalances` mapping, non-transferable) scaled by a per-asset liquidity index.
- **Piecewise bonding curve** — Adaptive liquidity distribution with volatility-based breadth.
- **Protocol fees** — Configurable split between LPs and treasury.
- **Risk + admin controls** — Per-pool freezes, circuit breakers, fee curation via the per-chain `Admin` singleton.
- **Per-asset hooks (dual ledger)** — Optional `IPoolHooks` (`preOutflow`, `postDeposit`) for physical rehypothecation; `YieldHook` family (`CompoundV2`/`VenusHook`, Aave V3, **experimental** Aave V4 Spoke (no mainnet pin), ERC4626/Morpho Vault/Felix Vanilla, Morpho Blue, Euler V2). Incentives sweep to treasury (no in-hook swaps). Harvest credits capped by `maxHarvestCreditBps` (default 100). Morpho Blue NAV = virtual shares only (no IRM accrual in view). Pricing uses full economic reserves; executable cash is liquid reserves (`reserves − invested`).

## Off-chain reads (no storage getters)

**Policy:** do **not** add Solidity `view` getters that merely mirror storage for indexers /
frontends. Keep the Pool bytecode minimal (EIP-170) and Solana-style: off-chain readers hit
deterministic `PoolStorage` slots via `eth_getStorageAt`.

| Layer | Responsibility |
|-------|----------------|
| **On-chain views** | Only what **other contracts** need (Flash, VenusHook, ALM adapters): `getAsset`, `getRiskFlags`, `getFeeParams`, `getLiquidReserves`, `getInvested`, `getLPBalance`, identity (`baseToken` / `wnative` / …), plus **computational** previews (`getSwapQuote`, `previewWithdraw`). |
| **Off-chain** | Profile / full `RiskConfig` / `OracleConfig` → SDK `@sdk/pool/storage` (`readLiquidityProfile`, `readRiskConfig`, `readOracleConfig`). Native (EIP-7528 / `address(0)`) is remapped to `wnative` before the mapping key. |
| **Coverage** | Prefer `R/L` from `getAsset` (or ΣR/ΣL off-chain). `getCoverageRatio` is a convenience view — not required for front quoting. |
| **Protocol fees** | Accrued protocol fees are collected via **Admin / Treasury** (`getProtocolFees` lives on the fee-collector path, not as a Pool storage-mirror getter for the front). |

Layout (pinned by `test/PoolStorageLayout.t.sol`):

```
slot 0  baseToken + initialized
slot 1  wnative
slot 2  treasury
slot 3  assets                 mapping
slot 4  oracleConfigs          mapping
slot 5  riskConfigs            mapping
slot 6  curves                 mapping
slot 7  __reserved_lpBalances  reserved pin, never read
slot 8  protocolFees           mapping
slot 9  feeParams
slot 10 flowCooldownSeconds + factory (address @ byte offset 2)
slot 11 assetHooks             mapping
slot 12 invested               mapping
slot 13 lpTokens               mapping
```

LP shares are **not** in pool storage: each leg has its own ERC-20 receipt (`LPToken`, an EIP-1167
clone with immutable args, address in `lpTokens`). Read balances from the receipt, or from the
proxying `Pool.getLPBalance` view. Slot 7 is a reserved pin so `protocolFees` stays at 8.

Mapping entry base = `keccak256(abi.encode(token, mappingSlot))`. Do not reorder fields
before the mappings (append-only rule in `IPool.PoolStorage`).

## Contract Layout

```
src/
├── Pool.sol              # Flat AMM pool. Hot paths: swap, deposit, withdraw, fast views.
├── PoolAux.sol           # Singleton cold-path dispatcher (admin setters + flash send/account).
│                         #   Pool fallback DELEGATECALLs PoolAux.
├── PoolFactory.sol       # Deterministic ERC-1967 beacon proxies + timelocked fleet upgrades.
├── Admin.sol             # Per-chain singleton: protocol-fee collection, risk/fee curation.
├── Flash.sol             # ERC-3156 flash-loan singleton (loans pool reserves; no minting).
├── interfaces/           # IPool, IPoolFactory, IPoolHooks, IAdmin, IFlash, IOracle, …
├── hooks/                # BasePoolHook, VenusHook, MockVenus, VenusAddresses (BSC Core pins)
├── oracles/
│   └── ExternalOracle.sol  # Permissionless relay of authenticated NXR-signed mark batches.
└── libraries/            # AdminTimelock, AdminHooks, AdminRisk, AnchorTree, Constants, Maths, Oracle,
                          # PoolAdmin, PoolAdminWrite, PoolBatch, PoolHooks, PoolIO, PoolDecay, PoolEdge,
                          # PoolLiquidity, PoolSwap, PoolView, Pricing, Spline, TransientCache.
```

`PoolSwap` inlines `PoolIO.exec` after quoting (EIP-170 headroom on `PoolSwap` ~8 KB; `Pool` stays near the 24 576-byte cap so the Pool→PoolSwap DELEGATECALL remains).

Shared cross-cutting singletons live in the sibling `btr-protocol/shared` repo (`shared/evm/src/`) and are consumed via the `@btr-shared/` Foundry remapping (`../../shared/evm/src`):

- `access/AccessControl.sol` — Owner / Keeper / Treasury / Swapper registry.
- `oracle/PriceProvider.sol` — Chainlink USD feeds + L2 sequencer guard.
- `Bridge.sol` + `tokens/BridgeableERC20.sol` — LayerZero OFT bridge + ERC-7802 token mixin.
- `Treasury.sol`, `Staking.sol`, `Distributor.sol`, `tokens/GovToken.sol`, `tokens/StakedAsset.sol`.
- `Errors.sol`, `Constants.sol`, `Timelock.sol`.

## Roles

Authority is centralized in the shared `AccessControl` singleton (one per chain).

- **Owner** — adds/removes assets, configures fee curves and circuit breakers, queues timelocked upgrades on the shared `Treasury` / `Bridge` / `AccessControl` (UUPS), updates pool-side admin parameters via `Admin` and `PoolAux`.
- **Oracle signer / relayer** — Authorized signers authenticate mark + σ + confidence + source time. Relayers are permissionless and have no pricing authority. Operational keepers may relay and hold only their separately assigned `AccessControl` keeper permissions.
- **Treasury** — collects protocol fees; address resolved through `AccessControl`.

Pools are ERC-1967 beacon proxies deployed by `PoolFactory`; the owner can request a fleet-wide implementation upgrade, subject to a 7-day delay and a 7-day execution window. Shared singletons may use their own UUPS mechanisms.

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

- Reentrancy: Solady `ReentrancyGuardTransient` (Pool hot paths + PoolAux hook ledger writers share the guard under DELEGATECALL; blocks double-book during `postDeposit` / `preOutflow` Δbalance booking).
- Safe transfers: Solady `SafeTransferLib`.
- Overflow protection: Solidity 0.8 checked arithmetic + explicit range checks/casts.
- Access control: role-based via shared `AccessControl`.
- Circuit breakers: manual owner-only freeze/pause via `Admin` (`freezeAsset`/`pauseAsset`/`batchRiskOp`); automatic gates = feed TTL staleness halt, confidence halt, depeg bands, and mandatory non-zero per-feed push deviation clamps on `ExternalOracle`. Hook invested NAV: no on-chain breaker — harvest SLA / pause is ops control for stale book.
- Token compatibility: list only standard, non-rebasing ERC-20s without sender/receiver transfer taxes. Output delivery deliberately avoids balance-delta calls on the hot path.
- All compiled artifacts ≪ 24 576-byte EIP-170 cap (`forge build --sizes`; `ContractSizeTest` asserts Pool / PoolAux / Admin / Flash / YieldHook adapters).

## License

BTR Dual License: Business Source License 1.1 until Change Date, MIT thereafter. Source SPDX headers default to `MIT` for downstream forks; BSL 1.1 terms apply to deployed BTR production instances. See https://btr.markets/licences for the canonical statement.
