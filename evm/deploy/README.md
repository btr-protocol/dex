# Deploy & asset params

**Single source of truth:** [`evm/deploy/testnet-asset-params.json`](../evm/deploy/testnet-asset-params.json)

JSON holds per-asset fees, oracle θ/heartbeat/ttl, Hermite spline knots/weights, risk config, and depeg bands for BNB Smart Chain testnet (chainId **97**, alias **chapel**).

## Why JSON only (not YAML + JSON)

| Format | Role |
|--------|------|
| **JSON** (`testnet-asset-params.json`) | Deploy scripts, SDK, front, keeper config generation — machine-readable, no ambiguity |
| **YAML** (`sim/config.example.yaml`) | Simulation harness only (time series, liquidity, trader toxicity) — human-edited scenario files |

Sim YAML references JSON for fee floors; it does not duplicate the full asset table.

## Units

- On-chain `Asset.minFeeBps` = **PBPS** (parts per million of 100%)
- **100 PBPS = 1 bp = 0.01%**
- **1 PBPS = 0.0001% = 0.01 bp** — protocol floor (`Constants.MIN_FEE_PBPS`)

Spread at σ=0 equals `minFeePath` (max of leg minFee values). σ, confidence, and staleness widen above this floor.

## Oracle trust (v2)

- Keeper pushes: mark + Parkinson σ **sample** + mark **confidence** (decoupled from σ).
- Chain: price EMA + **σ-EMA** (asymmetric bands + mark-move evidence floor).
- Pricing reads: `lastPriceB64` (quote), `sigmaEma` (spread/dispersion/staleness).
- **Pusher:** testnet = single EOA via `grantOracle`; mainnet = Gnosis Safe 2-of-3 as oracle address (no contract fork).

See `docs/dex/1. AIMM/1.2. Modules/1.2.2. Internal Oracle.md`.

## batchPush gas scaling (steady-state)

Benchmarks: `evm/test/unit/ExternalOracleGas.t.sol` — warm slots, non-zero→non-zero SSTORE, `dt > tau`.

| Feeds (N) | Total gas | Marginal ~gas/feed |
|-----------|-----------|-------------------|
| 1 | ~18k | ~18k (fixed overhead) |
| 6 | ~59k | ~10k |
| 8 | ~75k | ~9k |
| 10 | ~91k | ~9k |
| 12 | ~107k | ~9k |
| 20 | ~171k | ~9k |
| 30 | ~252k | ~8k |

**Scaling:** O(N) linear. Fixed cost ~18k (auth + loop + slim `BatchPushed(count,pusher)` event). Marginal ~8–10k/feed. At 30 feeds ≈252k gas — comfortable headroom on BSC.

**On-chain optimizations (commit `4a2b223`):** raw `calldataload` loop, manual one-slot `FeedData` codec, slim `BatchPushed` event (~16% marginal savings vs prior). Prior: dedup B64 decode, α=0 fast path, single SSTORE.

**Keeper-side:** skip unchanged feeds per tick — no on-chain benefit pushing identical mark/σ/conf.

## Chapel deploy (chainId 97)

```bash
cd evm
export DEPLOYER_PK=0x...          # funded chapel key
export ORACLE_PUSHER=0x...        # optional; defaults to deployer (grantOracle on deploy)
forge script script/TestnetDeploy.s.sol:TestnetDeploy \
  --sig deployTestnet \
  --rpc-url chapel \
  --broadcast \
  --verify  # optional

# Propagate addresses → env + token map
bun scripts/propagate-deploy.ts 97
# → deployments/97.env, deployments/97.tokens.json
```

Artifacts: `deployments/97.deploy.json` (router, factory, admin, oracle, faucet, pools, tokens, feed ids).

Keeper (Chapel): SSoT `keepers/oracle.chapel.toml` (feeds + θ/heartbeat). Dedicated
pusher `0xc4B4635B…a5B9` (secrets in `keepers/.env.chapel`, gitignored) — not the
deployer. Runtime = nxrates k0s Deployment (`keepers/k8s/oracle-daemon.yaml`);
BuildKit image only, then `keepers/scripts/apply-chapel-oracle-k8s.sh <tag>`.

## Contract verification (Chapel / BscScan)

Pool clones are **EIP-1167** minimal proxies (impl embedded in bytecode). Wallets (Rabby, MetaMask) only decode `Pool.swap` calldata when the **implementation** (and ideally the clone as proxy) is verified on [testnet.bscscan.com](https://testnet.bscscan.com). Until then, sequential swap txs look like raw hex — that is wallet display, not leftover `wallet_sendCalls`.

Status as of 2026-07-11 (Sourcify chain 97): **not verified** for live addresses in `97.deploy.json` / front `CHAPEL_BTR` — stable/volatile pools, Pool impl `0x6281c177…76629`, Admin `0x71ad3486…B7Fb`, Factory, AC, oracle.

`forge script … --verify` needs an Etherscan API key (BscScan is on the Etherscan v2 API). No `[etherscan]` block in `foundry.toml` yet; `ETHERSCAN_API_KEY` / `BSCSCAN_API_KEY` were unset in the investigation env.

```bash
cd evm
export ETHERSCAN_API_KEY=...   # https://etherscan.io/apidashboard (works for chainid 97)
# Live Chapel Pool impl (factory.referencePool) — verify this first so wallets decode clone swaps:
forge verify-contract \
  --chain-id 97 \
  --watch \
  0x6281c177fC5Aaf293be6a759E44535E1F2E76629 \
  src/Pool.sol:Pool \
  --constructor-args $(cast abi-encode "constructor(address,address,address,address)" \
    0x626eb915d4a4136F7c00352A54378d3A322488da \
    0x71ad34866B2bB0E99478297DA735E9b94922B7Fb \
    0xbd00b8718cf82d0d1b93ec2460b97a0774f15d6f \
    0x2a05ef641d01c85461085a1d2ce99711cda7b4a6)

# Also verify Admin (full contract, not a clone):
forge verify-contract --chain-id 97 --watch \
  0x71ad34866B2bB0E99478297DA735E9b94922B7Fb src/Admin.sol:Admin \
  --constructor-args $(cast abi-encode "constructor(address)" 0x626eb915d4a4136F7c00352A54378d3A322488da)

# Optional: on BscScan UI, mark pool clones as EIP-1167 proxies → impl 0x6281c177…6629
#   stable  0xC954A27E69ae7C9d10a136c4f7F3910b38F09324
#   volatile 0x88d5EC4C0c83391a9C84Bc196911084D7179AA40
```

If keys are missing, skip — UX impact is decode-only; swaps still execute via sequential `eth_sendTransaction` when Batch approve + tx is off.
