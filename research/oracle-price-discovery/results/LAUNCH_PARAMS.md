# Keeper + pool launch params (testnet)

## Decision

Keep **hard NXR re-anchor**. Reject trade-offset / mark-smoothing / adaptive θ for launch.

Mean arb gate (launch): center error ≤ half one-sided fee. With fee charged =
`pathSpread/2`, one-sided ≈ `minFee/2` → keep `minFee ≈ θ` on the floor class.
Hard worst-case prefers `minFee ≈ 2θ`; launch uses the softer mean gate for
competitiveness.

## Keeper (`oracle.chapel.toml`)

| Class | θ | heartbeat | TTL |
|-------|---|-----------|-----|
| Stable | **0.1 bp** | **1800 s** | 7200 s |
| Volatile | **10 bp** | **300 s** | 600 s |

Stable θ=0.1 roughly doubles stable updates vs 0.3 — accepted for tighter quotes.
Poll **12 s**. CI-spike ≥25 bp still in daemon.

Dedicated Chapel pusher (segregated from deployer):
`0xc4B4635B76ed49A7239291F6fbB33455D059a5B9` → ExternalOracle
`0xD91712c9F4037D0010041691Df191AB45994F2bF`.

## Pool floors (`testnet-asset-params.json`)

| Pool | minFee | Why |
|------|--------|-----|
| Stable | **0.1 bp** (10 PBPS; USDe/FDUSD 0.15) | Matches θ; mean-gate launch |
| Volatile | **10 bp** (1000 PBPS) | Matches θ; fee 5 bp fails mean gate |

## Cadence (order of magnitude)

- Stable θ=0.1: ~1.3k batched txs/day class-wide on 7d NXR replay (vs ~825 at 0.3)
- Volatile θ=10 / hb300: ~360–430 updates/feed/day

## Run keeper (cluster = canonical)

```bash
# Local: dry-run / --once only (validation). Do NOT leave a live laptop pusher.
cd ~/Work/btr/keepers
./scripts/run-chapel-oracle.sh          # dry
./scripts/run-chapel-oracle.sh --live   # emergency / one-shot debug only

# Production path: BuildKit image → apply on nxrates k0s
./scripts/apply-chapel-oracle-k8s.sh <git-sha>
```
