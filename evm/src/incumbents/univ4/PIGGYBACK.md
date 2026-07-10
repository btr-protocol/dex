# Uni piggyback (Chapel testnet)

Lean parasitic design: BTR volatile pools can quote off the **same spot** as a Uni-style ±10% range pool, so capital-efficiency comparisons are apples-to-apples.

## Why not real Uniswap V4?

- BSC **mainnet** has PoolManager `0x28e2Ea090877bF75740558f6BFB36A5ffeE9e9dF`.
- **Chapel (97)** has **no** V4 PoolManager bytecode at that address (or elsewhere we found).
- Full `v4-core` + CREATE2 hook flags + PositionManager is too heavy for this experiment.

So we ship a **V4-shaped** single-range CLAMM (`RangeCLPool`) with a shared `RecenterHook` and `sqrtPriceX96` encoding compatible with Uni V3/V4 oracles.

## Bunni v2 inspiration (conceptual only)

From [Bunni v2](https://github.com/Bunniapp/bunni-v2) / bunni.pro we reuse **one idea**:

> After a swap, if spot has drifted too far from the active liquidity midpoint, **shift** the range (burn old band → mint a fresh band around spot).

We do **not** vendor BunniHub, LDF curves, or their withdraw accounting (exploited Sep 2025). No off-chain rebalance keeper.

| Param | Value |
|-------|-------|
| Range width | ±10% of mid (`RANGE_BPS = 1000`) |
| Recenter trigger | \|spot − mid\| / mid > 5% (`DRIFT_BPS = 500`) |
| Hook | One `RecenterHook` address shared by all volatile pools |

## Contracts

| Contract | Role |
|----------|------|
| `RecenterHook` | Shared `afterSwap` → `recenterIfNeeded` |
| `RangeCLPool` / `RangeCLFactory` | Single-range CLAMM + hook callback |
| `UniPoolOracle` | `IOracle` pull adapter: `getFeed` ← `slot0().sqrtPriceX96` |
| `SqrtPrice` | Q64.96 encode/decode + range math |

## Compare BTR vs Uni (same price)

1. Deploy piggyback (below) → get `oracle` + pool addresses in `deployments/97.uni-piggyback.json`.
2. Point each BTR volatile asset’s `OracleConfig.primary` at `UniPoolOracle` and `feedId` at the matching feed (same `keccak256(base, quote)` as ExternalOracle).
3. Trade / quote on BTR volatile pool and on the Uni-range pool — both marks come from the Uni spot.
4. Measure inventory / depth / slippage for the same notional.

### Manual Admin wiring (Chapel — re-queued 2026-07-10 after piggyback redeploy)

**Live Admin** (`0x35c625…`) was compiled with prod `BASE_TIMELOCK = 2 days` — ETA is baked
into `pendingOps` and cannot be shortened without redeploying Admin **and** every Pool
clone (`Pool.admin` is immutable). `sealBootstrap` is already latched; there is no
untimelocked `setOracleConfig` for listed assets.

**Source (next Chapel Admin deploy):** `Constants.govDelay` shortens tiers on chainid 97
only — CRITICAL 1h / HIGH 30m / BASE 15m / LOW 5m (docs §7.2). Anvil + mainnet unchanged.

**Redeploy note:** first queue targeted old `UniPoolOracle` `0xdC6E…803F` (obsolete). Fresh
`requestOracleUpdate` ops overwrite `pendingOps` → new primary below.

Queued on volatile pool `0xEaB818235028bE378c92115099fF206EBb11B621` → primary `UniPoolOracle`
`0x93D3760b533283Fb471d735C9cA8438860f627bC`, feedIds + RangeCL pools from
`97.uni-piggyback.json` (oracle `getPool(feedId)` already wired at deploy — no `setPool`).

| Asset | RangeCL pool | feedId |
|-------|--------------|--------|
| BTCB | `0xf5Dd80e903158153D4d32E6C66518730251D694F` | `0xec5caa…822` |
| ETH | `0x444a77748082031a1E05750E7ee46206292aA063` | `0xe51c61…029` |
| WBNB | `0xf76993bdFD2d8F4a5257eE6b02B5752DfC232d9a` | `0x4b303e…7ab` |
| XAUT | `0xB779B6fB35A3b1053f8ac4F2067BC1929Ed6F382` | `0x00683c…dfc` |

USDC/USDT stay on `ExternalOracle`. XAUT `refFeedId`/`refBandBps` cleared (USDC ref
feed is not registered on UniPoolOracle).

ETA ≈ **2026-07-12 14:27 UTC**. After ETA (within 7d grace):

```bash
cd dex/evm && set -a && source .env.chapel && set +a
RPC=https://data-seed-prebsc-2-s1.bnbchain.org:8545
GAS=100000000
ADMIN=0x35c625c07ed4a9123ab863f6e8722c9210c808A3
POOL=0xEaB818235028bE378c92115099fF206EBb11B621

for tok in \
  0xd719319e853670ac938e426fbdB70CFdb34c11Fa \
  0x24Ff1aCD4e8fdBFEBee2e7e63ad36B1E72821189 \
  0x31B7DCA9e901F7D34fb4a3Ee07eD2994de16685D \
  0xd384aC4696FA230c9049F6534Fc35aC3af586073
do
  cast send $ADMIN "executeOracleUpdate(address,address)" $POOL $tok \
    --private-key $DEPLOYER_PK --rpc-url $RPC --gas-price $GAS --legacy
  sleep 2
done

# Verify UniPoolOracle still reads RangeCL spot
UNI=0x93D3760b533283Fb471d735C9cA8438860f627bC
cast call $UNI "getFeed(bytes32)((uint64,uint64,uint32,uint32,uint16,uint16,uint16,uint16))" \
  0xec5caa54d94920f87579a1524cd9b1528084d8fdc2b7652944a4fbad1bd78222 --rpc-url $RPC
```

Request txs (new oracle): BTCB `0x480636f6…`, ETH `0x57c9fa1a…`, WBNB `0x5f9e9ed4…`, XAUT `0x62e1e24a…`.

Leave the keeper `ExternalOracle` intact for assets you still want NXR-pushed. Do **not** kill `btr-keeper oracle-daemon` while testing — just stop using its feeds for the piggybacked assets.

## Broadcast (Chapel)

```bash
cd dex/evm
set -a && source .env.chapel && set +a
forge script script/incumbents/UniPiggybackDeploy.s.sol:UniPiggybackDeploy \
  --sig deployPiggyback \
  --rpc-url https://data-seed-prebsc-2-s1.bnbchain.org:8545 \
  --broadcast \
  --with-gas-price 100000000
```

Writes `deployments/97.uni-piggyback.json`.

## Tests

```bash
forge test --match-contract UniPiggybackTest -vv
```
