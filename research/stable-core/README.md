# stable-core — BSC stableswap competitive study (2026-07)

Empirical 6-month study of BSC stable-stable DEX microstructure (PCS StableSwap/v3, Uniswap v3,
THENA, Wombat, Curve-BSC, DODO) via HyperSync, driving the BTR stable-core pool launch parameters:
per-asset deviation θ, minFee, spline/κ, deposit caps (min/max TVL), oracle push economics, and a
historical capture simulation (would-we-have-won-the-flow) against the real trade tape.

Reuses ../pool-fees/hs_pull.py (HyperSync client, token in ../pool-fees/hypersync.env — never print).
Run python via: uv run --with hypersync --with pyarrow python <script>. Data lands in data/ (gitignored).
