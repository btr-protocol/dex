# Protocol Configuration Parameters

**Last Updated:** 2025-01-15

This document provides a comprehensive reference of ALL configurable parameters across the entire protocol, including factories, pools, assets, oracles, and DarkPool.

---

## Table of Contents

1. [Parameter Conventions](#parameter-conventions)
2. [Factory Level](#factory-level)
3. [Pool Level (Global)](#pool-level-global)
4. [Tri-Factor Fee Parameters](#tri-factor-fee-parameters)
5. [Asset Level](#asset-level)
6. [Liquidity Profile](#liquidity-profile)
7. [Oracle Parameters](#oracle-parameters)
8. [Circuit Breakers](#circuit-breakers)
9. [Liability Decay](#liability-decay)
10. [DarkPool](#darkpool)
11. [Governance Summary](#governance-summary)

---

## Parameter Conventions

### Naming Prefixes
- `cov*` - Coverage/inventory factor (formerly `inv*`)
- `vol*` - Volatility factor
- `dev*` - Price deviation factor (formerly `pd*`)
- `base*` - Base fee parameters
- `min*/max*` - Bounds
- `fast*/slow*` - Time windows

### Precision Standards
- **BPS (Basis Points)**: 100,000 = 100% (10× finer than standard 10k)
  - 1 unit = 0.0001% = 0.01 bps
  - Examples: 100 = 1 bps, 10000 = 10%, 100000 = 100%
- **Multipliers**: 100 = 1× (for fee/coverage multipliers)
- **WAD**: 1e18 = 1.0 (for coverage ratios)
- **Volatility**: 1e6 = 1% (for oracle volatility values)
- **B64 Prices**: Custom 64-bit fixed-point (see oracle docs)

### Governance Levels
- **Owner**: DAO/multisig (long timelock recommended)
- **Guardian**: Fast response team (24h cooldown recommended)
- **Treasury**: Fee collector (no parameter control)
- **Oracle**: Trusted price feed updater

---

## Factory Level

### BAMMFactory

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| DarkPool Factory Address | `darkPoolFactory` | address | Factory for deploying DarkPool instances | - | Owner | 48h | - | - | 1 |
| Default Verifier Address | `defaultVerifier` | address | Default Groth16 verifier for DarkPools | - | Owner | 48h | - | - | 1 |

**Setters:**
- `setDarkPoolFactory(address)` - Owner only
- `setDefaultVerifier(address)` - Owner only

---

### DarkPoolFactory

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Verifier Address | `verifier` | address | Groth16 verifier (per DarkPool instance) | - | Init-only | - | - | - | 1 |

**Note:** Set at deployment via `createDarkPool()`, not governable post-deployment.

---

## Pool Level (Global)

### BAMM/BAMMManagement

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Base Token | `baseToken` | address | Pool's pricing/quote currency (e.g., USDC) | Init | Owner | 48h | - | - | 1 |
| Pool Paused | `isPoolPaused` | bool | Emergency pause flag | false | Owner | 0h | - | - | 2 |
| Fast TWAP Weight | `fastTWAPWeight` | uint8 | Fast vol EMA weight (0-100) | 90 | Owner | 24h | 1 | 100 | 2 |
| Slow TWAP Weight | `slowTWAPWeight` | uint8 | Slow vol EMA weight (0-100) | 95 | Owner | 24h | 1 | 100 | 2 |
| Cached Total Value | `cachedTotalValue` | uint256 | Delta-based TVL cache | 0 | Auto | - | - | - | 2 |
| Cached Total Liabilities | `cachedTotalLiabilities` | uint256 | Delta-based liabilities cache | 0 | Auto | - | - | - | 2 |

**Setters:**
- `pausePool()` / `unpausePool()` - Owner only (emergency)
- `updateVolatilityWeights(uint8, uint8)` - Owner only (24h cooldown recommended)
- `migrateBaseAsset(address, bytes)` - Owner only (pauses pool during migration, 48h timelock)

**Validation:**
- `fastTWAPWeight < slowTWAPWeight` (fast must respond quicker)
- Both weights ≤ 100

---

## Tri-Factor Fee Parameters

### LibPricing.FeeParams

Used for swap fee calculation (coverage × volatility × deviation factors).

#### Coverage Factor (ALM)

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Coverage Min Multiplier | `covMinMult` | uint16 | Min rebate when under-collateralized (×100) | 20 (0.2×) | Owner | 24h | 1 | covMaxMult | 2 |
| Coverage Max Multiplier | `covMaxMult` | uint16 | Max penalty when over-collateralized (×100) | 10000 (100×) | Owner | 24h | covMinMult | 100000 | 2 |
| Coverage Under Max | `covUnderMax` | uint256 | Max under-coverage for full rebate (WAD) | 0.5e18 (50%) | Owner | 24h | 0.01e18 | 1e18 | 2 |
| Coverage Over Max | `covOverMax` | uint256 | Max over-coverage for full penalty (WAD) | 0.5e18 (50%) | Owner | 24h | 0.01e18 | 10e18 | 2 |

**Notes:**
- Uses **per-asset coverage** (reserves/liabilities in token units), NOT global pool coverage
- Post-swap coverage for inflows (penalties), pre-swap for outflows (rebates)

#### Volatility Factor

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Volatility Beta | `volBeta` | uint16 | Volatility shock sensitivity (×100) | 150 (1.5×) | Owner | 24h | 10 | 1000 | 2 |
| Volatility R Max | `volRMax` | uint16 | Max shock ratio (fast/slow) (×100) | 1000 (10×) | Owner | 24h | 100 | 10000 | 2 |
| Volatility Max Multiplier | `volMaxMult` | uint16 | Max volatility multiplier (×100) | 10000 (100×) | Owner | 24h | 100 | 100000 | 2 |
| Volatility Epsilon | `volEpsilon` | uint16 | Min volatility for ratio calc (1e6 base) | 1000 (0.1%) | Owner | 24h | 1 | 1000000 | 2 |

**Notes:**
- No vol clamping (volFloor/volMax removed) - uses raw oracle values
- Shock ratio: `r = min(volRMax, volFast / max(volSlow, volEpsilon))`

#### Price Deviation Factor

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Dev D1 Max | `devD1Max` | uint16 | Max spot-vs-fast deviation threshold (bps) | 1000 (10%) | Owner | 24h | 10 | 10000 | 2 |
| Dev D2 Max | `devD2Max` | uint16 | Max fast-vs-slow deviation threshold (bps) | 1500 (15%) | Owner | 24h | 10 | 10000 | 2 |
| Dev Alpha | `devAlpha` | uint16 | Deviation multiplier weight (×100) | 50 (0.5×) | Owner | 24h | 1 | 200 | 2 |
| Dev Max Multiplier | `devMaxMult` | uint16 | Max deviation multiplier (×100) | 10000 (100×) | Owner | 24h | 100 | 100000 | 2 |

**Notes:**
- `d1 = |poolPrice - fastTWAP| / fastTWAP`
- `d2 = |fastTWAP - slowTWAP| / slowTWAP`
- `x_dev = min(1, max(d1/devD1Max, devAlpha × d2/devD2Max))`

#### Base Fee

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Base K | `baseK` | uint16 | Base fee slope multiplier (×100) | 100 (1.0×) | Owner | 24h | 1 | 10000 | 2 |
| Base Min | `baseMin` | uint16 | Min base fee (bps, 100k precision) | 100 (1 bps) | Owner | 24h | 1 | 65535 | 2 |

**Notes:**
- Base fee: `f_base = max(baseMin, (volBaseline × baseK) / 1e6)`
- No upper clamp on base fee (global `asset.maxFeeBps` applies to final fee)

#### Global Caps

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Min Multiplier | `minMult` | uint16 | Global min multiplier (×100) | 20 (0.2×) | Owner | 24h | 1 | maxMult | 2 |
| Max Multiplier | `maxMult` | uint16 | Global max multiplier (×100) | 10000 (100×) | Owner | 24h | minMult | 100000 | 2 |
| Max TWAP Change | `maxTWAPChange` | uint16 | Max price change per update (bps) | 500 (5%) | Owner | 24h | 10 | 10000 | 2 |
| Protocol Fee BPS | `protocolFeeBps` | uint16 | Protocol fee % of swap fees (bps, 100k precision) | 10000 (1%) | Owner | 48h | 0 | 100000 | 2 |
| Withdrawal Fee BPS (Global Default) | `withdrawalFeeBps` | uint16 | Default withdrawal fee (bps, 100k precision) | 0 | Owner | 24h | 0 | 100000 | 2 |

**Setter:**
- `updateFeeParams(FeeParams)` - Owner only
- Validates all constraints via `_validateFeeParams()`

---

## Asset Level

### IBAMM.Asset / IBAMM.FeeConfig

Per-token configuration when adding assets via `addAsset()`.

#### Reserves & Liabilities

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Reserves | `reserves` | uint128 | Physical tokens in pool (assets) | 0 | Auto | - | 0 | 2^128-1 | 2 |
| Liabilities | `liabilities` | uint128 | LP claims (Wombat-style, in token units) | 0 | Auto | - | 0 | 2^128-1 | 2 |

**Note:** Auto-updated via swaps/deposits/withdrawals/decay.

#### Oracles

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Main Oracle | `mainOracle` | address | Main oracle (address(this)=internal, else=IOracle) | From config | Owner | 24h | - | - | 1 |
| Fallback Oracle | `fallbackOracle` | address | Fallback oracle (address(0)=disabled) | From config | Owner | 24h | - | - | 1 |
| Feed ID | `oracleId` | bytes32 | keccak256(token, baseToken) | Auto | - | - | - | - | 1 |
| Stale After | `staleAfter` | uint32 | Max oracle age before stale (seconds) | 86400 (24h) | Owner | 12h | 60 | 2592000 | 2 |

**Setters:**
- `updateOracleConfig(address, address, address)` - Owner only
- `updateStaleAfter(address, uint32)` - Owner only

#### Liquidity Bounds

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Min Liquidity | `minLiquidity` | uint96 | Min reserves that must remain | From config | Owner | 12h | 1 | 2^96-1 | 2 |

**Setter:**
- `updateMinLiquidity(address, uint128)` - Owner only

#### Fee Configuration

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Min Fee BPS | `minFeeBps` | uint16 | Min swap fee (bps, 100k precision) | 100 (1 bps) | Owner | 24h | 1 | maxFeeBps | 2 |
| Max Fee BPS | `maxFeeBps` | uint16 | Max swap fee (bps, 100k precision) | 50000 (500 bps) | Owner | 24h | minFeeBps | 100000 | 2 |
| Protocol Fee BPS | `protocolFeeBps` | uint16 | Protocol fee % of swap fees (bps, 100k precision) | 10000 (1%) | Owner | 48h | 0 | 100000 | 2 |
| Deposit Fee BPS | `depositFeeBps` | uint16 | Deposit fee (MEV protection) (bps, 100k precision) | 0 | Owner | 12h | 0 | 100000 | 2 |
| Withdrawal Fee BPS | `withdrawalFeeBps` | uint16 | Withdrawal fee (MEV protection) (bps, 100k precision) | 0 | Owner | 12h | 0 | 100000 | 2 |
| Flash Fee BPS | `flashFeeBps` | uint16 | Flash loan fee (bps, 100k precision) | 0 (launch), 50 target | Owner | 24h | 0 | 100000 | 2 |
| Target Coverage Ratio | `targetCoverageRatio` | uint16 | Target reserves/liabilities (bps, 100k precision) | 105000 (1.05) | Owner | 24h | 100000 | 200000 | 2 |

**Setters:**
- `updateAssetFeeBounds(address, uint16, uint16)` - Owner only (min/max swap fees)
- `setAssetFees(address, FeeConfig)` - Owner only (all fees)
- `updateFlashFee(address, uint16)` - Owner only

**Notes:**
- Deposit/withdrawal fees default to 0 (haircut is sufficient); set to ~20 bps for MEV/JIT protection
- Flash fee target 50 bps (0.5 bps) = 10× cheaper than Aave (9 bps)

#### Liquidity Profile

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Decimals | `decimals` | uint8 | Token decimals | From ERC20 | - | - | 0 | 18 | 1 |
| Segment Count | `segmentCount` | uint8 | Active segments (2-32) | From config | Guardian | 12h | 2 | 32 | 2 |
| Flags | `flags` | uint8 | bit0=frozen, bit1=flash, bit2=FOT | 0 | Mixed | - | - | - | 2 |
| Reserve Price | `reservePrice` | uint64 | Reserve price floor (B64, Circuit Breaker #1) | 0 (disabled) | Owner | 24h | 0 | 2^64-1 | 2 |

**Setters:**
- `freezeAsset(address, string)` - Owner or Guardian (0h cooldown for Guardian)
- `unfreezeAsset(address)` - Owner only (24h cooldown)
- `enableFlashLoans(address)` - Owner only (12h cooldown)
- `disableFlashLoans(address)` - Owner only (0h cooldown)
- `updateReservePrice(address, uint64)` - Owner only (24h cooldown)

#### Hooks

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Hooks Contract | `hooks` | address | Hook contract (IBAMMHooks) | address(0) | Guardian | 24h | - | - | 1-2 |

**Setter:**
- `updateHooks(address, address)` - Guardian only

---

## Liquidity Profile

### IBAMM.LiquidityProfile

Piecewise linear curve configuration (updated via `updateLiquidityProfile()`).

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Segment Weights | `segmentWeights` | uint8[32] | Weight per segment (sum=255, 31 segments) | From config | Guardian | 12h | 5 each | 255 total | 2 |
| TWAP Offsets | `twapOffsets` | int8[33] | Price offset points (base 100, 32 boundaries) | From config | Guardian | 12h | -100 | +100 | 2 |
| Min Price Step | `minPriceStep` | uint32 | Min breadth at vol=0 (1M precision, 0.0001%) | 500 (0.5%) | Guardian | 12h | 1 | maxBreadth | 2 |
| Max Breadth | `maxBreadth` | uint32 | Max breadth cap (1M precision, 0.0001%) | 100000 (100%) | Guardian | 12h | minPriceStep | 1000000 | 2 |

**Setter:**
- `updateLiquidityProfile(address, LiquidityProfileParams)` - Guardian only
- Validates: weights normalized, offsets monotonic, breadth bounds

---

## Oracle Parameters

### Internal Oracle (InternalOracle)

Accumulator-based TWAP oracle. Per-asset state in `LibStorage.OracleEntry`.

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Current Price | `currentPrice` | uint64 | Current spot price (B64 format) | From init | Owner | 0h | 1 | 2^64-1 | 2 |
| Price Accumulator | `priceAccumulator` | uint256 | Σ(price × timeElapsed) | 0 | Auto | - | - | - | 2 |
| Fast Accum Snapshot | `fastAccumSnapshot` | uint256 | Accumulator at fast snapshot | 0 | Auto | - | - | - | 2 |
| Slow Accum Snapshot | `slowAccumSnapshot` | uint256 | Accumulator at slow snapshot | 0 | Auto | - | - | - | 2 |
| Fast Snapshot Time | `fastSnapshotTime` | uint32 | When fast snapshot taken | block.timestamp | Auto | - | - | - | 2 |
| Slow Snapshot Time | `slowSnapshotTime` | uint32 | When slow snapshot taken | block.timestamp | Auto | - | - | - | 2 |
| Last Oracle Update | `lastOracleUpdate` | uint32 | Timestamp of last update | block.timestamp | Auto | - | - | - | 2 |
| Fast Window | `fastWindow` | uint32 | Fast TWAP window (seconds) | 21600 (6h) | Init-only | - | 60 | 86400 | 2 |
| Slow Window | `slowWindow` | uint32 | Slow TWAP window (seconds) | 604800 (7d) | Init-only | - | 86400 | 2592000 | 2 |
| Fast Volatility | `fastVolatility` | uint32 | Fast vol EMA (1e6 base) | From init | Owner | 0h | 0 | 100000000 | 2 |
| Slow Volatility | `slowVolatility` | uint32 | Slow vol EMA (1e6 base) | From init | Owner | 0h | 0 | 100000000 | 2 |
| Max TWAP Change | `maxTWAPChange` | uint16 | Max price change per update (bps) | From config | Init-only | - | 10 | 100000 | 2 |

**Setters:**
- `updateOracle(address, uint64, uint32)` - Owner only (updates currentPrice and lastOracleUpdate)
- `resetOracle(bytes32, uint64, uint32, uint32)` - Internal (called during base migration)

**Notes:**
- Windows (`fastWindow`, `slowWindow`) set at init, not changeable (requires oracle reset)
- Volatility values auto-updated via EMA on each oracle update

---

### External Oracle (ExternalOracle)

Multi-asset push oracle with role-based updates.

#### Global Config

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Min Update Interval | `minUpdateInterval` | uint32 | Rate limit between updates (seconds) | From constructor | Owner | 12h | 0 | 3600 | 2 |
| Stale After | `staleAfter` | uint32 | Max age before oracle stale (seconds) | From constructor | Owner | 12h | 60 | 2592000 | 2 |

**Setter:**
- `updateGlobalConfig(uint32, uint32)` - Owner only

#### Per Feed ID (bytes32)

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Fast TWAP | `fastTWAP` | uint64 | Fast TWAP (B64 format) | From init | Oracle | 0h | 1 | 2^64-1 | 2 |
| Slow TWAP | `slowTWAP` | uint64 | Slow TWAP (B64 format) | From init | Oracle | 0h | 1 | 2^64-1 | 2 |
| Fast Volatility | `fastVolatility` | uint32 | Fast vol (1e6 base) | From init | Oracle | 0h | 0 | 100000000 | 2 |
| Slow Volatility | `slowVolatility` | uint32 | Slow vol (1e6 base) | From init | Oracle | 0h | 0 | 100000000 | 2 |
| Last Update | `lastUpdate` | uint32 | Timestamp of last update | block.timestamp | Auto | - | - | - | 2 |
| Max Deviation BPS | `maxDeviationBps` | uint16 | Max price change per update (bps) | From config | Owner | 12h | 10 | 100000 | 2 |

**Setters:**
- `addOraclePair(bytes32, uint64, uint64, uint32, uint32, uint16)` - Owner only
- `updateOracleConfig(bytes32, uint16)` - Owner only (updates maxDeviationBps)
- `updateOracle(bytes32, uint64, uint64, uint32, uint32)` - Oracle role only
- `batchUpdateOracles(bytes32[], uint64[], uint64[], uint32[], uint32[])` - Oracle role only
- `grantOracleRole(address)` / `revokeOracleRole(address)` - Owner only

---

## Circuit Breakers

### IBAMM.CircuitBreaker

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Reference Asset (CB#2) | `referenceAsset` | address | Reference asset for relative return deviation | address(0) | Owner | 24h | - | - | 1 |
| Max Deviation (CB#2) | `maxDeviation` | uint16 | Max relative return divergence (bps) | From config | Owner | 24h | 10 | 10000 | 2 |
| Reserve Price Floor (CB#1) | `reservePrice` (in Asset) | uint64 | Absolute price floor (B64 format) | 0 (disabled) | Owner | 24h | 0 | 2^64-1 | 2 |

**Setters:**
- `updateCircuitBreaker(address, address, uint16)` - Owner only
- `checkCircuitBreaker(address)` - Guardian only (triggers freeze if violated)

**Notes:**
- **CB#1 (Absolute)**: Triggers if `currentPrice < reservePrice` (set in `Asset.reservePrice`)
- **CB#2 (Relative)**: Triggers if `|return_asset - return_reference| > maxDeviation`

---

## Liability Decay

### IBAMM.LiabilityDecayConfig

Time-based liability decay to restore coverage ratio when reserves < liabilities.

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| Decay Start Ratio | `decayStartRatioBps` | uint16 | Coverage threshold to activate decay (bps) | 0 (disabled) | Owner | 48h | 0 | 100000 | 2 |
| Decay Amplification | `decayAmplification` | uint16 | Curve exponent n × 10000 | 15000 (1.5) | Owner | 48h | 10000 | 30000 | 2 |
| Decay T Max | `decayTMaxSeconds` | uint32 | Time to reach terminal state (seconds) | - | Owner | 48h | 86400 | 31536000 | 2 |
| Recovery Lockout | `recoveryLockout` | uint32 | Time above threshold before stopping (seconds) | 86400 (24h) | Owner | 24h | 3600 | 604800 | 2 |

**Notes:**
- Currently no public setter in IBAMM interface (would require adding governance function)
- See `specs/LIABILITY_TIME_DECAY.md` for decay curve formulas

---

## DarkPool

### DarkPool

| Full Name | Variable | Type | Description | Default | Governed | Timelock | Min | Max | Usage |
|-----------|----------|------|-------------|---------|----------|----------|-----|-----|-------|
| BAMM Pool Address | `bammPool` | address | Associated BAMM pool | From init | - | - | - | - | 1 |
| Verifier Address | `verifier` | address | Groth16 verifier contract | From init | - | - | - | - | 1 |
| Paused | `flags` (bit0) | bool | Emergency pause flag | false | Owner | 0h | - | - | 2 |
| Require ASP | `flags` (bit1) | bool | Require Association Set Proofs | false | Owner | 12h | - | - | 2 |
| ASP Root Expiry | `aspRootExpiry[aspRoot]` | uint256 | Timestamp when ASP root expires | 0 | Owner | 12h | 0 | 2^256-1 | 1 |

**Setters:**
- `setPaused(bool)` - Owner only
- `setRequireASP(bool)` - Owner only
- `setASPRootApproved(bytes32, bool)` - Owner only
- `setASPRootWithExpiry(bytes32, uint256)` - Owner only

**Constants (Not Configurable):**
- `TREE_HEIGHT = 32`
- `ROOT_HISTORY_SIZE = 100`
- `NOTE_TYPE_TOKEN = 0`, `NOTE_TYPE_LP = 1`
- `ACTION_TRANSFER/SWAP/LP_DEPOSIT/LP_WITHDRAW = 0/1/2/3`

---

## Governance Summary

### By Role

| Role | Parameter Count | Examples | Typical Timelock |
|------|----------------|----------|------------------|
| **Owner** | ~70 | Fee params, oracle configs, asset management, circuit breakers | 24-48h |
| **Guardian** | ~5 | Asset freeze, blacklist, hooks, liquidity profiles | 0-24h |
| **Treasury** | 0 | (Fee collector only, no parameters) | - |
| **Oracle** | ~5 | External oracle updates (price/volatility feeds) | 0h (real-time) |
| **Auto-Updated** | ~15 | Reserves, liabilities, accumulators, timestamps | - |

### By Sensitivity (Recommended Timelocks)

| Timelock | Parameters | Rationale |
|----------|------------|-----------|
| **0h (Immediate)** | Oracle updates, emergency pause/freeze, flash loan disable | Security/responsiveness |
| **12h** | Min liquidity, deposit/withdrawal fees, staleness thresholds | Moderate risk |
| **24h** | Tri-factor fee params, asset fees, circuit breakers, hooks | Significant economic impact |
| **48h** | Protocol fee, base asset migration, factory configs, decay params | Critical protocol changes |

### Total Configurable Parameters

- **Owner-governed:** ~70
- **Guardian-governed:** ~5
- **Oracle-governed:** ~5
- **Auto-updated (non-governed):** ~15
- **Init-only (not changeable):** ~10

**Grand Total:** ~105 parameters across all levels

---

## Naming Inconsistencies to Fix

### Coverage/Inventory Naming

**Issue:** Codebase uses `inv*` (inventory) but specs use `cov*` (coverage).

| Current Code | Proposed Rename | Reason |
|--------------|-----------------|--------|
| `invMinMult` | `covMinMult` | Aligns with "coverage ratio" terminology |
| `invMaxMult` | `covMaxMult` | Consistent with ALM coverage concepts |
| `invUnderMax` | `covUnderMax` | Matches spec language |
| `invOverMax` | `covOverMax` | Clearer intent (coverage over-collateralization) |

**Action:** Rename in LibPricing.sol, BAMMManagement.sol, update specs.

---

### Volatility Floor/Max Removal

**Issue:** Spec lists `volFloor`/`volMax` but code doesn't use them (removed for direct oracle usage).

**Status:** ✅ **Spec updated** to remove these parameters. Code is correct.

---

### Default Value Mismatches (Code vs Spec)

See issue list in previous analysis. Key discrepancies:

| Parameter | Spec Default | Code Default | Recommended |
|-----------|-------------|--------------|-------------|
| `volBeta` | 100 (1×) | 150 (1.5×) | **150** (more conservative) |
| `volRMax` | 500 (5×) | 1000 (10×) | **500** (safer shock cap) |
| `volMaxMult` | 500 (5×) | 10000 (100×) | **500** (avoid extreme fees) |
| `devD1Max` | 500 (5%) | 1000 (10%) | **500** (tighter deviation) |
| `devD2Max` | 200 (2%) | 1500 (15%) | **200** (detect regime shifts) |
| `devMaxMult` | 300 (3×) | 10000 (100×) | **300** (reasonable penalty) |
| `baseK` | 30 (0.3%) | 100 (1%) | **30** (competitive base fees) |

**Recommendation:** Update code defaults to match more conservative spec values OR update spec to document current aggressive defaults with rationale.

---

## Next Steps

1. **Fix naming:** `inv*` → `cov*` in code
2. **Align defaults:** Decide on conservative (spec) vs aggressive (code) defaults
3. **Add missing setters:** Liability decay governance functions
4. **Document timelocks:** Add on-chain timelock enforcement
5. **Add events:** Emit `ParameterUpdated(name, oldValue, newValue)` for all setters
