# Protocol Internals & Auto-Updated Variables

**Last Updated:** 2025-01-15

This document describes internal variables that are **auto-updated** by the protocol and **not directly configurable** by governance. For configurable parameters, see [`PARAMETERS.md`](./PARAMETERS.md).

---

## Table of Contents

1. [Asset State](#asset-state)
2. [LP Token State](#lp-token-state)
3. [Oracle Accumulators](#oracle-accumulators)
4. [Cached Values](#cached-values)
5. [Decay State](#decay-state)
6. [Protocol Invariants](#protocol-invariants)

---

## Asset State

### Reserves & Liabilities

| Variable | Type | Description | Updated By |
|----------|------|-------------|------------|
| `reserves` | uint128 | Physical tokens in pool (assets) | Swaps, deposits, withdrawals, fees |
| `liabilities` | uint128 | LP claims in token units (Wombat-style) | Deposits, withdrawals, decay |

**Invariant:** `reserves ≥ minLiquidity` (enforced on withdrawals)

**Coverage Ratio:** `C = reserves / liabilities`
- `C < 1`: Under-collateralized (withdrawal haircut applies)
- `C = 1`: Fully collateralized
- `C > 1`: Over-collateralized (target is usually 1.05)

---

## LP Token State

### Liquidity Index (Rebasing)

| Variable | Type | Description | Updated By |
|----------|------|-------------|------------|
| `totalScaledSupply` | uint128 | Sum of scaled balances (constant except mint/burn) | Deposits, withdrawals |
| `liquidityIndex` | uint128 | Rebasing multiplier (starts at 1e12) | Fee accumulation, index bumps |

**Formula:**
```solidity
balanceOf(user) = scaledBalance[user] * liquidityIndex / PRECISION
```

**Index Growth:**
- Swap fees → index bump (all LPs earn proportionally)
- Deposit fees → index bump (existing LPs earn)
- Withdrawal fees → index bump (remaining LPs earn)

**Initial Value:** `1e12` (allows ~3.4e26× growth before uint128 overflow)

---

## Oracle Accumulators

### Internal Oracle (Accumulator-Based)

| Variable | Type | Description | Updated By |
|----------|------|-------------|------------|
| `currentPrice` | uint64 | Current spot price (B64 format) | `updateOracle()` |
| `priceAccumulator` | uint256 | Σ(price × timeElapsed) | Every oracle update |
| `fastAccumSnapshot` | uint256 | Accumulator at fast snapshot | When fast window elapsed |
| `slowAccumSnapshot` | uint256 | Accumulator at slow snapshot | When slow window elapsed |
| `fastSnapshotTime` | uint32 | Timestamp of fast snapshot | When fast window elapsed |
| `slowSnapshotTime` | uint32 | Timestamp of slow snapshot | When slow window elapsed |
| `lastOracleUpdate` | uint32 | Timestamp of last update | `updateOracle()` |
| `fastVol` | uint32 | Fast volatility EMA (1e6 base) | Every oracle update (EMA) |
| `slowVol` | uint32 | Slow volatility EMA (1e6 base) | Every oracle update (EMA) |

**TWAP Calculation:**
```solidity
fastTWAP = (priceAccumulator - fastAccumSnapshot) / (now - fastSnapshotTime)
slowTWAP = (priceAccumulator - slowAccumSnapshot) / (now - slowSnapshotTime)
```

**Volatility EMA:**
```solidity
returns = abs(currentPrice - slowTWAP) / slowTWAP
fastVol = (fastVol * weight + returns * (100 - weight)) / 100
slowVol = (slowVol * weight + returns * (100 - weight)) / 100
```

### External Oracle (Push-Based)

| Variable | Type | Description | Updated By |
|----------|------|-------------|------------|
| `fastTWAP` | uint64 | Fast TWAP (B64 format) | Oracle role (off-chain computed) |
| `slowTWAP` | uint64 | Slow TWAP (B64 format) | Oracle role (off-chain computed) |
| `fastVol` | uint32 | Fast volatility (1e6 base) | Oracle role (off-chain computed) |
| `slowVol` | uint32 | Slow volatility (1e6 base) | Oracle role (off-chain computed) |
| `lastUpdate` | uint32 | Timestamp of last push | `updateOracle()` or `batchUpdateOracles()` |

**Rate Limiting:** Min interval between updates (configurable via `staleAfter`)

---

## Cached Values

### Pool-Level Caches (Delta-Based)

| Variable | Type | Description | Updated By |
|----------|------|-------------|------------|
| `cachedTotalValue` | uint256 | Delta-based TVL cache (WAD) | Every swap/deposit/withdrawal |
| `cachedTotalLiabilities` | uint256 | Delta-based total liabilities (WAD) | Every swap/deposit/withdrawal |

**Purpose:** Avoid full summation over all assets for global metrics

**Update Pattern:**
```solidity
cachedTotalValue += delta * assetPrice
cachedTotalLiabilities += liabilityDelta * assetPrice
```

**Staleness:** Drift accumulates due to price changes. Recompute periodically off-chain or via governance function.

---

## Decay State

### Liability Time Decay (Per-Asset)

| Variable | Type | Description | Updated By |
|----------|------|-------------|------------|
| `isActive` | bool | Decay currently running | Automatic (coverage check) |
| `startTime` | uint64 | When decay started | Automatic (coverage drops) |
| `aboveThresholdSince` | uint64 | When coverage crossed above threshold | Automatic (coverage recovers) |
| `liabilityAtStart` | uint128 | Snapshot of liabilities when decay started | Automatic (decay start) |
| `coverageAtStart` | uint64 | Coverage ratio when decay started (bps) | Automatic (decay start) |

**Activation:** When `coverage < decayStartRatioBps` (e.g., 98%)

**Formula:**
```solidity
t_norm = (now - startTime) / decayEnd  // [0, 1]
decay_factor = t_norm^n                 // n = decayAmplification / 10000
liabilities_new = liabilities_old * (1 - decay_factor * (1 - coverageAtStart))
```

**Termination:** When `coverage ≥ targetCoverageRatio` (e.g., 1.05)

---

## Protocol Invariants

### Safety Invariants (Always Enforced)

1. **Min Liquidity:**
   ```solidity
   reserves - amountOut ≥ minLiquidity  (on withdrawals)
   ```

2. **Fee Bounds:**
   ```solidity
   totalFeeBps ≤ MAX_FEE_BPS (65000 = 6.5%)
   protocolFeeBps ≤ BPS_PRECISION (1_000_000 = 100%)
   ```

3. **Coverage Haircut:**
   ```solidity
   if (reserves < liabilities) {
       amountOut = amountOut * reserves / liabilities
   }
   ```

4. **Oracle Freshness:**
   ```solidity
   (now - lastUpdate) ≤ staleAfter  (else revert)
   ```

5. **Circuit Breakers:**
   - **CB#1 (Absolute):** `currentPrice ≥ reservePrice` (if set)
   - **CB#2 (Relative):** `|return_asset - return_ref| ≤ maxDeviationBps`

### Accounting Invariants (Verified Off-Chain)

1. **LP Token Backing:**
   ```solidity
   Σ(balanceOf(user)) = totalScaledSupply * liquidityIndex / PRECISION
   ```

2. **Global Coverage:**
   ```solidity
   GlobalCoverage = Σ(reserves * price) / Σ(liabilities * price)
   ```
   - **Not used for fees** (only per-asset coverage affects fees)
   - Tracked for analytics/monitoring only

3. **Fee Accrual:**
   ```solidity
   reserves_new = reserves_old + feesAccrued (minus protocol fees withdrawn)
   ```

---

## Auto-Update Triggers

| Event | Updated Variables |
|-------|------------------|
| **Swap** | reserves (both assets), liabilities (decay check), cachedTotalValue, oracle accumulator |
| **Deposit** | reserves, liabilities, totalScaledSupply, liquidityIndex (if deposit fee), cachedValues |
| **Withdrawal** | reserves, liabilities, totalScaledSupply, liquidityIndex (if withdrawal fee), cachedValues |
| **Oracle Update** | currentPrice, priceAccumulator, fastVol, slowVol, snapshots (if window elapsed) |
| **Decay Tick** | liabilities, coverageAtStart, isActive, startTime |
| **Flash Loan** | reserves (in/out cancel), liquidityIndex (if flash fee) |

---

## Storage Layout Notes

### Asset Struct (5 Slots)

- **Slot 0:** reserves (128) + liabilities (128)
- **Slot 1:** mainOracle (160) + fallbackOracle (160) + minLiquidity (96) [spans 2 slots]
- **Slot 2:** fees (6×32) + targetCoverageRatio (32) + decimals (8) + segmentCount (8) + flags (8) + reservePrice (64) + pad (8)
- **Slot 3:** hooks (160) + feedId (256) [spans 2 slots]
- **Slot 4:** liquidity profile (weights + offsets + breadth params)
- **Slot 5:** staleAfter (32) + pad (224)

**Optimization:** Tight packing minimizes storage SLOADs in hot paths (swaps)

---

## Related Docs

- **Configurable Parameters:** [`PARAMETERS.md`](./PARAMETERS.md)
- **Fee Model:** [`FEES.md`](./FEES.md)
- **Oracle System:** [`ORACLE.md`](./ORACLE.md)
- **ALM & Coverage:** [`ALM_AND_COVERAGE.md`](./ALM_AND_COVERAGE.md)
- **Liability Decay:** [`LIABILITY_TIME_DECAY.md`](./LIABILITY_TIME_DECAY.md)
