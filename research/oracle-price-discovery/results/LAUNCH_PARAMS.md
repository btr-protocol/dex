# Keeper + pool launch params (testnet)

SSoT live: `keepers/oracle.chapel.toml` + `dex/evm/deploy/testnet-asset-params.json`
(updated **2026-07-12** after NXR cadence review + inventory drain postmortem).

## Decision

Keep **hard NXR re-anchor**. Reject trade-offset / mark-smoothing / adaptive θ for launch.

Mean arb gate (launch): center error ≤ half one-sided fee. With fee charged =
`pathSpread/2`, one-sided ≈ `minFee/2`. **Post-drain revision:** stable minFee
**0.5 bp** (FDUSD **1 bp**) so fee ≫ θ; volatiles stay **10 bp** vs θ **5 bp**.
Hard worst-case prefers `minFee ≈ 2θ`; launch uses a soft mean gate but no longer
undercuts θ on stables.

## Keeper (`oracle.chapel.toml`)

| Class | θ | heartbeat | TTL |
|-------|---|-----------|-----|
| Stable | **0.25 bp** | **1800 s** | 7200 s |
| Volatile | **5 bp** | **300 s** | 600 s |

- Stable θ=0.1 was ~118 pushes/h/feed on sub-bp NXR jitter (2026-07-12 logs) → raised to **0.25 bp**.
- Volatile θ=**5 bp** + heartbeat **ttl/2 = 300 s**.
- Poll **12 s**. CI-spike ≥25 bp still in daemon.

Dedicated Chapel pusher (segregated from deployer):
`0xc4B4635B76ed49A7239291F6fbB33455D059a5B9` → ExternalOracle
`0xD91712c9F4037D0010041691Df191AB45994F2bF`.

## Pool floors (`testnet-asset-params.json`) — revision 2026-07-12b

| Pool | minFee | gamma | Shape |
|------|--------|-------|-------|
| Stable | **0.5 bp** (50 PBPS; FDUSD **1 bp**) | **2×** | Mild center bump `[50,100,50]` |
| Volatile | **10 bp** (1000 PBPS) | **2×** | Flat-ish knots (unchanged width) |

`kappaCovBps` stays **0** (coverage wall needs `depthAmplifier=0` — separate pass).

## 2026-07-12 inventory postmortem (Chapel)

On-chain `getAsset` (not a UI bug):

| Leg | Coverage | Note |
|-----|----------|------|
| FDUSD (stable) | **~0%** ($23 vs $50k L) | Peg ~0.997 + 0.1bp fee → one-way flight into USDC (284%) |
| USDC (volatile) | **~6.5%** | Drained while BTCB R exploded |
| BTCB (volatile) | **~256228%** | **R≈1994 BTC / L≈0.778** — real reserves, ~$128M TVL |

AIMM swaps move **reserves only** (liabilities fixed at seed). Seed was balanced
~$50k/token (`ChapelEnableSwaps`). Bots + thin fee/shape made directional dumps
cheap. BTCB size is **incompatible with extracting only ~$47k USDC at $64k/BTC**
(~0.7 BTC max) → likely a **broken mark / sizing window** (e.g. BTCB sized as if
mark≈$1) and/or faucet-mint dumps; bots now refuse marks ≫ off static ref.

**Remediation path**

1. Pause flow+arb pods.
2. Apply `ChapelApplyStableParams` (fees/gamma/profile) + volatile `setAssetParams` gamma=2×.
3. Reseed via `ChapelEnableSwaps` (new pools, 50k/token) + `propagate-deploy.ts 97`.
4. Redeploy bots image (mark-sanity + lower max_usd + FDUSD weight cut).
5. Metrics `/metrics` Venues tab: keeper wallets + routing pies (front) to watch PnL live.

## Cadence (order of magnitude)

- Live (2026-07-12): Stable θ=0.25 targets ~60–90/h/feed.
- Volatile θ=5 / hb300: ≥~12/h floor + deviation on ≥5 bp moves.

## Run keeper (cluster = canonical)

```bash
cd ~/Work/btr/keepers
./scripts/run-chapel-oracle.sh          # dry
~/Work/nx/ops/scripts/deploy-btr-oracle-daemon.sh
```
