# pool-fees — real v3 fee/liquidity indexer (Ponder, RPC mode, keyless)

Reconstructs 2-yr Uniswap-v3-style **Swap / Mint / Burn** history for the deep,
active pools BTR provides liquidity into, so `prime` can compute the **exact
per-range fee APR** (vs the hand-set `f0`) and the real **fees-vs-LVR**.

**Keyless / local / free:** Ponder in **RPC mode** (public RPC, no HyperSync
token, no Envio cloud) + **PGlite** embedded DB (no Postgres/Docker/podman).
HyperSync was ruled out (free tier caps at 100k events; needs a token — see
`memory/project_real_fees_indexer`).

## Pools (deepest + most-active per pair)
| pair | dex / chain | address | TVL / vol24h |
|---|---|---|---|
| BTC | Aerodrome Slipstream cbBTC/USDC · Base | `0x4e962BB3889Bf030368F56810A9c96B83CB3E778` | ~$10.2M / ~$79M |
| ETH | Aerodrome Slipstream WETH/USDC · Base | `0xb2cc224c1c9feE385f8ad6a55b4d94E92359DC59` | ~$9.5M / ~$100M |
| BNB | PancakeSwap-v3 USDT/WBNB 0.01% · BSC | `0x172fcd41e0913e95784454622d1c3724f546f849` | ~$16.3M / ~$84M |

Coverage varies (cbBTC ~Oct-2024 → ~1.5yr; WETH/Aero ~2.2yr; PCS USDT/WBNB 2yr+).

## Run
```
cd prime/research/pool-fees
npm install          # ponder + viem
npm run codegen      # validate config/schema
npm run dev          # RPC backfill → PGlite (.ponder/), follows head when caught up
```
Then export the `swap` + `liquidity_event` tables (PGlite/SQL) → `prime` reads them
for the v3 fee model: `realFee = Σ_{swaps, price∈[pl,ph]} (|amountIn|·feeTier)·L_pos/(L_active+L_pos)`.

⚠ Research tooling — keep out of the Rust build; gitignore `.ponder/`, `node_modules/`.
