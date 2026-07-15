# BTR DEX Test Suite

Foundry tests for the AIMM contracts. Solidity `=0.8.35`, `via_ir`, feed-rework oracle model
(external keeper mark on `ExternalOracle`; no internal TWAP, no modules).

## Layout (26 `.t.sol` files, ~300 tests)

```
test/
├── unit/
│   ├── Maths.t.sol               B64 codec, arithmetic, 1e18 conversions
│   ├── Oracle.t.sol              mark decode, getSigma passthrough, peg feed, markMovePbps floor
│   ├── ExternalOracle.t.sol      admin feed mgmt (addFeed seed / updateFeed config, TTL, maxDeviation)
│   ├── InternalOracle.t.sol      ORACLE_MODE_INTERNAL constant-peg + fail-closed depeg gate
│   ├── Pricing.t.sol             spread (minFeePath + σ·vega + staleness + confidence), skew, depth
│   ├── Spline.t.sol              Fritsch-Carlson monotonicity, eval/area integration
│   ├── AnchorTree.t.sol          depth-1 star validation + routing (direct / sibling)
│   ├── CoverageProofs.t.sol      convex coverage toll (_covToll/_covQ) fuzz proofs
│   ├── CrossBaseImpact.t.sol     hub-neutral cross-spoke pricing
│   ├── AimmDecimals.t.sol        mixed-decimals legs (6/8/18)
│   ├── AimmExtraction.t.sol      round-trip / extraction resistance
│   ├── AimmInvariants.t.sol      reservation band, halt, accounting invariants
│   ├── Pool.coverage.t.sol       haircut (linear), donate index, liability swap
│   ├── PoolAdmin.t.sol           Admin singleton timelocks + pause/freeze/batchRiskOp
│   ├── PoolDecay.t.sol           coverage-gated liability decay
│   ├── PoolRepegExploit.t.sol    re-peg attack regressions
│   └── DeployScript.t.sol        deploy script wiring
├── PoolLifecycle.t.sol           end-to-end init → add assets → swap/deposit/withdraw
├── PoolBaseDepeg.t.sol           R44-2 base-token depeg halt (legacy / in-band / out-of-band)
├── PoolFlash.t.sol               ERC-3156 singleton flash loans (repay by raising pool balance)
├── PoolFlashExploit.t.sol        flash-in-flight guard (repay-via-deposit double-count)
├── PoolSwapAccounting.t.sol      swap token-conservation (R8): balance == reserves + protocolFees
├── PoolHooks.t.sol               hookless gas, flag skip, recall, MockVenus, spoof/writeDown/minLiq/flags/flash
├── PoolStorageLayout.t.sol       PoolStorage slot pins (append-only layout)
├── DistributorBridgeIntegration.t.sol  campaign propose→24h→finalize + bridge flows
└── fixtures/                     shared setup + mock tokens
```

## Run

```sh
forge test                                  # full suite
forge test --match-path 'test/unit/*'      # units only
forge coverage --report lcov --no-match-coverage 'test/(fixtures)'
```

Counts drift with development — trust `forge test` output, not this file.
