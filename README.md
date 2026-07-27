# BTR

Adaptive multi-asset AMM (AIMM): hub-and-spoke routing, dynamic fees, keeper-relayed external-mark oracle, internal non-transferable LP ledger, piecewise bonding curve.

Product docs: **[br.market/docs](https://br.market/docs)**. Protocol documentation is not maintained in this repository.

## This repository

| Path | Contents |
|---|---|
| `evm/` | Solidity contracts + Foundry tests (AIMM pools, oracle, admin, flash) |
| `sim/` | Rust reference model (`aimm-sim`) mirroring `Pricing.sol` |
| `research/` | AMM research notebooks and studies |
| `scripts/` | Local tooling (plots, anvil helpers) |
| `salts/` | CREATE3 salt registry |

## Related repositories

Some siblings may remain private.

| Concern | Repo |
|---|---|
| Shared Solidity primitives (`@btr-shared/`) | [`btr-protocol/shared`](https://github.com/btr-protocol/shared) (required to build) |
| ABIs + TS client | `btr-protocol/sdk` |
| Keepers (oracle pusher) | `btr-protocol/keepers` |
| dApp | `btr-protocol/front` |
| Off-chain services | `btr-protocol/back` |
| Product docs (served at br.market/docs) | `btr-protocol/docs` |

## Build & test

`evm/foundry.toml` remaps `@btr-shared/` to a sibling `shared` checkout (`../../shared/evm/src`). A lone clone of this repo does not build. Clone `shared` next to `dex`; do not vendor a copy (that forks deployed singletons).

```bash
git clone git@github.com:btr-protocol/shared.git
git clone git@github.com:btr-protocol/dex.git
cd dex/evm
forge build
forge test
```

## Security

Never commit private keys or env files. Use `.env.example` as the template only. Only standard, non-rebasing ERC-20s without transfer taxes may be listed.
