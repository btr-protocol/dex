# Keeper + pool launch params (testnet)

SSoT live: `keepers/oracle.chapel.toml` + `dex/evm/deploy/testnet-asset-params.json`
(updated **2026-07-12** after NXR cadence review).

## Decision

Keep **hard NXR re-anchor**. Reject trade-offset / mark-smoothing / adaptive θ for launch.

Mean arb gate (launch): center error ≤ half one-sided fee. With fee charged =
`pathSpread/2`, one-sided ≈ `minFee/2` → keep `minFee ≈ θ` on the floor class for
stables is soft (minFee 0.1 bp, θ 0.25 bp). Volatiles: minFee **10 bp** with θ **5 bp**
(marks fresher than fee floor; fee still gates mean arb). Hard worst-case prefers
`minFee ≈ 2θ`; launch uses the softer mean gate for competitiveness.

## Keeper (`oracle.chapel.toml`)

| Class | θ | heartbeat | TTL |
|-------|---|-----------|-----|
| Stable | **0.25 bp** | **1800 s** | 7200 s |
| Volatile | **5 bp** | **300 s** | 600 s |

- Stable θ=0.1 was ~118 pushes/h/feed on sub-bp NXR jitter (2026-07-12 logs) → raised to **0.25 bp**.
- Volatile θ=10 left mid moves to the 300 s heartbeat; θ=**5 bp** catches mid moves; heartbeat stays **ttl/2 = 300 s**.
- Poll **12 s**. CI-spike ≥25 bp still in daemon.

Dedicated Chapel pusher (segregated from deployer):
`0xc4B4635B76ed49A7239291F6fbB33455D059a5B9` → ExternalOracle
`0xD91712c9F4037D0010041691Df191AB45994F2bF`.

## Pool floors (`testnet-asset-params.json`)

| Pool | minFee | Why |
|------|--------|-----|
| Stable | **0.1 bp** (10 PBPS; USDe/FDUSD 0.15) | Competitiveness; θ=0.25 is mark cadence |
| Volatile | **10 bp** (1000 PBPS) | Mean-gate vs θ=5; fee 5 bp fails mean gate at higher θ |

## Cadence (order of magnitude)

- Historical 7d NXR replay (pre-2026-07-12): Stable θ=0.1 ~1.3k batched txs/day class-wide; θ=0.3 ~825.
- Live (2026-07-12): Stable θ=0.1 ~118/h/feed; θ=0.25 targets ~mid of 0.1/0.5 band (~60–90/h).
- Volatile θ=5 / hb300: ≥~12/h floor (heartbeat) + deviation on ≥5 bp moves.

## Run keeper (cluster = canonical)

```bash
# Local: dry-run / --once only (validation). Do NOT leave a live laptop pusher.
cd ~/Work/btr/keepers
./scripts/run-chapel-oracle.sh          # dry
./scripts/run-chapel-oracle.sh --live   # emergency / one-shot debug only

# Production path: BuildKit image → ConfigMap from oracle.chapel.toml on nxrates k0s
~/Work/nx/ops/scripts/deploy-btr-oracle-daemon.sh
```
