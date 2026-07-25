# Sepolia bring-up: state of the stack

Single source of truth for the Ethereum Sepolia (chainId 11155111) deployment.
Chapel / BSC testnet 97 is retired. Incumbent DEX pools (Uniswap, Curve, Wombat)
are descoped: routing-competition research is not part of this testnet.

Status legend: LIVE = running and verified. READY = built, verified, not yet
deployed. BUILD = in progress. BLOCKED = waiting on a listed dependency.

## Top-down: what has to be true

```
NX-Rates (production, nxrates k0s)          BTR Sepolia (11155111)
  feeds -----------------------------> signing tier
                                              |
                                              v
                                        ExternalOracle  <---- oracle push daemon
                                              |                (theta triggers)
                                              v
                                   AccessControl + Admin/Flash/PoolAux/PoolFactory
                                              |
                                   +----------+----------+
                                   |                     |
                            stable core pool      volatile core pool
                                   |                     |
                                   +----------+----------+
                                              |
                                    keepers (liquidity + risk params)
                                              |
                                     front-end (btr.markets)
```

## Bottom-up: the layers

| L | Layer | What it is | Status |
|---|-------|-----------|--------|
| 0 | NX-Rates feeds | CEX + Pyth Lazer aggregation, TDWAP composite marks | LIVE |
| 1 | Signing tier | `udp_auth` sealed ingest, `signed_quotes`, 3 attester pods, 2-of-3 quorum | BUILD |
| 2 | ExternalOracle | 24 feeds, k-of-n signed marks, deviation + staleness guards | READY |
| 3 | Push daemon | dynamic theta triggers, cadence cap, trigger observability | READY |
| 4 | Core contracts | AccessControl, Admin, Flash, PoolAux, PoolFactory, Pool impl | READY |
| 5 | Pools | stable core (17 assets), volatile core (8 assets), EIP-1167 clones | BUILD |
| 6 | Keepers | liquidity + bot solvency, adaptive risk-param upkeep | BUILD |
| 7 | Bots | random-flow bot (arb bot retired: no incumbents, no counterparty) | BUILD |
| 8 | Front-end | btr.markets, Sepolia default, swap + faucet + pools + density | BUILD |
| 9 | Docs | generated deployments page, docs/code alignment | READY |

## Architecture note

There is no Diamond and there are no facets. Verified: `rg -l facet` over
`dex/evm` returns nothing. The system is:

- `AccessControl`: roles, including the guardian and risk roles.
- `Admin`, `Flash`, `PoolAux`, `PoolFactory`: singletons.
- `Pool`: one implementation, cloned per pool via EIP-1167 minimal proxy.

Any document or script describing a Diamond is wrong and predates verification.

## Asset composition

Base leg for both pools is USDC. Its mark is the identity 1.0 (USDC/USDC = 1),
seeded once and never pushed. It carries no market price feed. It is not exempt
from signing: the depeg guard and the USD reservation price both read a signed
USDC/USD reference feed at index 23.

- Stable core (17): USDT, USDC, USDe, USDS, DAI, USD1, USDG, PYUSD, RLUSD,
  syrupUSDC, USDf, U, GHO, TUSD, USDtb, FDUSD, AUSD.
- Volatile core (8): WETH, WBTC, cbBTC, BNB, XAUT, PAXG, EURC, USDT.

All assets are our own ERC-20 mocks with a faucet. Canonical testnet tokens are
not used: supply is unpredictable and unfundable at the sizes testing needs.

## Liquidity shape

Central-normal plateau, both pools. Keep only the centre of a normal
distribution and let the shoulders roll off:

- m = 3, two interior knots at +/- 0.7 sigma, u = {0.1314, 0.8686}.
- Truncated at the empirical q70 (an exact 30 percent tail cut).
- Density is flat and maximal at the mark. No crater, no second mode.
- Shape is cell-invariant. Asset classes differ only by width S_dep.
- Roughly 289k gas for `setCurve`, about 70 percent below the previous catalogue.

Constraints that hold regardless of fit: S_dep >= 2 theta, minFee = 2 theta +
E[(|G| - theta)+], in-range >= 99 percent, and hyper-concentration only behind a
kappa wall with `haircutSuppressor = 0`.

## Oracle push policy

Marks are pushed on deviation, not on a fixed clock:

- theta: 0.25 bp for stables, 5 bp for volatiles. Both are themselves part of the
  perpetually optimised risk-parameter set, not fixed constants.
- The allowed band widens with realised volatility and elapsed time, capped so a
  single push can never ratchet the band open.
- Cadence is capped near 100 pushes per hour. If a feed exceeds it, theta floats
  up rather than the cap being breached.
- A heartbeat push bounds staleness even when price is quiet.
- Every evaluation is recorded, pushed or not, with its reason: theta cross,
  heartbeat, confidence spike, cold start, or none.

A theta change never ships alone. It ships atomically with `minFee = 2 theta`,
a fence resync, and `minDisp`, because the keeper's own boot gate rejects a
configuration where `minFee < 2 theta`.

## Governance timing

Timelocks are shortened on testnets and full length on mainnet. Sepolia was
missing from that gate and has been added; without it, testnet operations such
as adding an asset or rotating a signer would have taken up to seven days.

Risk parameters are deliberately not timelocked. Adaptivity is the point: the
upkeep keeper adjusts fees and greeks continuously through a bounded-delta path.
The controls are the bounds themselves plus a dedicated risk role that can
freeze. Structural changes stay timelocked.

## Security posture

- UDP price ingest is authenticated. Without it, any datagram reaching the
  aggregator becomes a signed mark and then an on-chain push. The boot guard
  that couples `signed_quotes` to `udp_auth` is correct and must not be relaxed.
- The cutover to authenticated ingest runs through a permissive mode that
  accepts sealed or raw frames, because every direct ordering drops the feed:
  strict core rejects raw frames, and sealed frames fail a raw decode.
- The three attester keys are the crown jewels. They are ECDSA privates bound to
  the on-chain signer set, and recovery runs through a timelocked grant. They are
  backed up before any oracle depends on them.
- The `udp_auth` HMAC keys are not crown jewels: they are symmetric and
  regenerable in minutes.

## Open items

Tracked live in the session task board: signing tier (#56), oracle and DEX
deploy (#57), keepers and bots (#58), front-end (#59), docs (#60), repo
hygiene (#61).
