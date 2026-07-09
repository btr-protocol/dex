# Stable-core oracle feed sources (2026-07-08)

Verified live via Hermes API (`curl hermes.pyth.network/v2/price_feeds?query=<SYM>&asset_type=crypto`
+ cross-checked `/v2/updates/price/latest?ids[]=...`, all 5 returned fresh prices same slot 301271469,
tight conf ~0.05-0.13% of price). Pyth confirmed live on BSC mainnet (contract
`0x4D7E825f80bDf85e913E0DD2A2D54927e9dE1594`, ERC1967Proxy → impl references `pyth-sdk-solidity`;
Pyth blog "Data is Live on BNB Chain" corroborates). Feed ids are global (Wormhole-attested), not
per-chain — BSC availability = "is the contract deployed + do you push the update", not a separate id.

| Token | Pyth feed? | Feed ID (0x…) | Symbol | Caveat | → SOURCE |
|---|---|---|---|---|---|
| USDC | yes | `eaa020c61cc479712813461ce153894a96a6c00b21ed0cfc2798d1f9a9e9c94a` | `Crypto.USDC/USD` | clean, tightest conf (~0.09%) | **Pyth** |
| USDT | yes | `2b89b9dc8fdf9f34709a5b106b472f0f39bb6ca9ce04b0fd7f2e971688e2e53b` | `Crypto.USDT/USD` | clean; note separate `USDT0`/`USDTB` feeds exist too, don't confuse | **Pyth** |
| USDe (Ethena) | yes | `6ec879b1e9963de5ee97e9c8710b742d6228252a5e2ca12d4ae81d7fe5ee8c5d` | `Crypto.USDE/USD` | clean; sister feed `Crypto.SUSDE/USD` (staked) exists separately, not needed here | **Pyth** |
| USD1 (World Liberty Financial) | **yes** — prior wrong | `0a2425d43486780990d8b63543029e20556be51fd756cca584212f4d539611d4` | `Crypto.USD1/USD` | feed exists + live/fresh, but no public Pyth announcement found for it (quiet add); token itself is young (launched Mar 2025) — treat as thinner/less battle-tested source, keep an eye on conf width in prod | **Pyth** (fallback: stand up NX-Rates feed if conf/heartbeat degrades) |
| FDUSD (First Digital USD) | yes | `ccdc1a08923e2e4f4b1e6ea89de6acbc5fe1948e9706f5604b8cb50bc1ed3979` | `Crypto.FDUSD/USD` | widest conf of the 5 (~0.13% of price) but still tight/usable | **Pyth** |

## Summary
All 5 stables have live Pyth Hermes feeds w/ fresh, tight-confidence prices — **0 need a new NX-Rates feed**.
Prior assumption that USD1 lacks Pyth coverage was wrong (confirmed via direct Hermes query, not just docs
page) — USD1 is live but quietly-added/young-token, so it's the one to watch if conf/staleness misbehaves
in prod; keeper can source all 5 off-chain via Hermes and push to `ExternalOracle` as planned.
