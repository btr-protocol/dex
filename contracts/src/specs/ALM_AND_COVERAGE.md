# Coverage Ratio-Based ALM Model

## Overview

BAMM implements a **Wombat-inspired coverage ratio system** for Active Liquidity Management (ALM). The coverage ratio tracks the health of each asset pool and automatically adjusts fees to incentivize rebalancing.

---

## Core Concepts

### Coverage Ratio Definition

```solidity
Coverage Ratio (C) = reserves / liabilities

Where:
- reserves  = actual tokens in the pool (assets)
- liabilities = total deposited amounts (LP claims in token units)
```

### Target Coverage Ratio

Each asset has a configurable **target coverage ratio** that defines the desired over-collateralization level:

```solidity
targetCoverageRatio = 10500  // 105% in basis points (10,000 = 100%)
```

**Purpose:**
- Target > 1.0 (e.g., 1.05 = 105%) seeks over-collateralization
- Excess reserves (when C > 1.0) accumulate as protocol revenue and LP fees
- Tri-factor fee model uses target as reference point for inventory factor

### States

| State | Condition | Description |
|-------|-----------|-------------|
| **Healthy** | C ≥ target | Pool is properly collateralized with target safety buffer |
| **Acceptable** | 1.0 ≤ C < target | Pool is fully collateralized but below target buffer |
| **Under-collateralized** | C < 1.0 | Pool has insufficient reserves to cover all LP claims |

---

## Liability Tracking

### Deposits

When an LP deposits tokens:

```solidity
asset.reserves += amount;
asset.liabilities += amount;
```

**Result**: Coverage ratio remains unchanged (both increase equally)

### Withdrawals

When an LP withdraws tokens, they receive their liability claim **multiplied by the coverage ratio clamped to [0, 1]**:

```solidity
// Calculate LP's proportional share of liabilities (their claim)
liabilityShare = (lpTokens / totalLPTokens) * totalLiabilities

// Calculate coverage ratio, clamped to [0, 1]
coverageRatio = min(1.0, reserves / liabilities)

// Apply haircut
amountOut = liabilityShare * coverageRatio

// Update state
asset.reserves -= amountOut
asset.liabilities -= liabilityShare
```

**Key Points:**
- **C ≥ 1.0**: LP receives full claim (100%), no haircut
- **C < 1.0**: LP receives partial claim (C * 100%), haircutted at coverage ratio
- **C > 1.0**: LP still receives 100% of claim (excess reserves stay in pool)
- Coverage ratio is maintained after withdrawal (fair pro-rata loss sharing)

### Withdrawal Examples

**Example 1: Healthy Pool (C = 1.05)**
```
Pool state:
- reserves = 1050 USDC
- liabilities = 1000 USDC
- C = 1.05 (105%)

LP withdrawal:
- LP owns 10% of pool
- LP's liability share = 100 USDC
- Coverage ratio (clamped) = min(1.05, 1.0) = 1.0
- LP receives: 100 * 1.0 = 100 USDC (full claim, no haircut)

After withdrawal:
- reserves = 950 USDC
- liabilities = 900 USDC
- C = 950 / 900 = 1.056 (still healthy)
```

**Example 2: Under-collateralized Pool (C = 0.7)**
```
Pool state:
- reserves = 700 USDC
- liabilities = 1000 USDC
- C = 0.7 (70%)

LP withdrawal:
- LP owns 10% of pool
- LP's liability share = 100 USDC
- Coverage ratio (clamped) = min(0.7, 1.0) = 0.7
- LP receives: 100 * 0.7 = 70 USDC (30% haircut)

After withdrawal:
- reserves = 630 USDC
- liabilities = 900 USDC
- C = 630 / 900 = 0.7 (coverage maintained)
```

**Example 3: Severely Under-collateralized Pool (C = 0.5)**
```
Pool state:
- reserves = 500 USDC
- liabilities = 1000 USDC
- C = 0.5 (50%)

LP withdrawal:
- LP owns 10% of pool
- LP's liability share = 100 USDC
- Coverage ratio (clamped) = min(0.5, 1.0) = 0.5
- LP receives: 100 * 0.5 = 50 USDC (50% haircut, unfortunate but fair)

After withdrawal:
- reserves = 450 USDC
- liabilities = 900 USDC
- C = 450 / 900 = 0.5 (coverage maintained)
```

### Swaps

Swaps affect only reserves, not liabilities:

```solidity
assetIn.reserves += amountIn
assetOut.reserves -= amountOut
// liabilities unchanged
```

**Result**: Coverage ratios change based on pool imbalance and fees earned

---

## Tri-Factor Fee Model Integration

The coverage ratio system integrates with the tri-factor fee model through the **inventory factor**:

### Inventory Factor (Coverage-Based)

```solidity
// Current asset value share
v = (reserves * price) / totalReserves

// Target share (based on liabilities)
t = (liabilities * price) / totalLiabilities

// Normalized divergence
x = min(1, |v - t| / max(t, ε) / x_inv,max)

// Multiplier
if (v < t) {
    // Under target: linear rebate (encourage inflows)
    m_inv = 1 - (1 - m_inv,min) * x
} else {
    // Over target: linear penalty (discourage outflows)
    m_inv = 1 + (m_inv,max - 1) * x
}
```

**Key Points**:
- Uses actual reserves vs. liabilities (Wombat-style)
- Linear rebates when under target (encourages deposits/inflows)
- Linear penalties when over target (discourages outflows)
- Target coverage ratio (e.g., 1.05) serves as reference for "over target"
- Minumum fee multiplier (m_inv,min) applies when pool is over-collateralized (C > target)
- No hardcoded thresholds - all configurable parameters

---

## Why No Circuit Breakers for Withdrawals?

BAMM **does NOT implement automatic withdrawal pausing** based on coverage ratio thresholds.

### Rationale

**1. Fairness to LPs:**
- LPs deposit in good faith and should always be able to exit
- Pausing withdrawals when coverage < threshold is effectively a rugpull
- Better to allow fair (potentially reduced) withdrawals than trap LPs

**2. Bank Run Prevention Paradox:**
- If users know withdrawals CAN be paused → they rush to exit at first sign of trouble
- **This creates the bank run** the circuit breaker was meant to prevent
- Better to allow orderly exits with coverage ratio haircut

**3. Natural Protection Through Fees:**
- Withdrawal fees can increase when assets are imbalanced (configurable 0-5%)
- Tri-factor fee model makes large trades expensive when coverage is low
- High fees naturally slow activity without explicit pausing
- This is **economically enforced** (not governance-enforced)

**4. Proper Invariant Design Philosophy:**
- If a protocol needs circuit breakers to survive, **the economic model is broken**
- Better to design fees/invariants such that C cannot drop below critical levels naturally
- Current model: reserves depleted → fees spike → activity slows → pool rebalances

**5. Emergency Controls We DO Have:**

| Control | Scope | Blocks Withdrawals? | Purpose |
|---------|-------|---------------------|---------|
| `freezeAsset()` | Per-asset | ❌ No | Freeze swaps only (oracle failure, token issue) |
| `pausePool()` | Entire pool | ❌ No | Pause swaps + deposits (withdrawals still work) |
| `rescueERC20()` | Stuck tokens | ❌ No | Recover tokens sent by mistake (timelock required) |

**Even in emergencies, withdrawals remain enabled** to honor LP claims with fair haircut.

---

## Parameter Defaults

### Target Coverage Ratio (Per Asset)
```solidity
targetCoverageRatio = 10500  // 105% (seeking 5% over-collateralization)
```

### Inventory Factor Parameters
```solidity
invMinMult = 20           // 0.2x min multiplier (applies when C > target)
invMaxMult = 10000        // 100x max penalty when over target
invMaxDivergence = 5000   // 50% max divergence for full scale
```

### Global Fee Caps
```solidity
minMult = 20              // 0.2x global min (allows inventory rebates)
maxMult = 10000           // 100x global max
```

---

## Integration with Delta-Based Caching

The coverage ratio system works seamlessly with O(1) delta-based value caching:

```solidity
// Deposits
oldReserves = asset.reserves;
asset.reserves += amount;
asset.liabilities += amount;
int256 delta = int256(asset.reserves) - int256(oldReserves);
cachedTotalValue = updateTotalValueDelta(cachedTotalValue, asset, delta);

// Withdrawals (with coverage haircut)
oldReserves = asset.reserves;
asset.reserves -= amountOut;  // haircutted amount
asset.liabilities -= liabilityShare;  // full liability share
int256 delta = int256(asset.reserves) - int256(oldReserves);
cachedTotalValue = updateTotalValueDelta(cachedTotalValue, asset, delta);
```

---

## Security Considerations

### 1. Liability Overflow Protection

```solidity
asset.liabilities = (asset.liabilities + amount).toUint128();
```

Safe cast with overflow check ensures liabilities can't exceed uint128.

### 2. Division by Zero Protection

```solidity
uint256 liabilitiesSafe = liabilities > 0 ? liabilities : 1;
uint256 coverageRatio = (reserves * PRECISION) / liabilitiesSafe;
```

### 3. Reserve Availability Check

```solidity
if (amountOut > asset.reserves) revert InsufficientReserves();
```

Ensures withdrawals cannot exceed available reserves.

### 4. Fee-on-Transfer Token Protection

Existing fee-on-transfer protection adjusts both reserves AND liabilities:

```solidity
if (actualAmountIn < amount) {
    uint256 deficit = amount - actualAmountIn;
    asset.reserves -= deficit;
    asset.liabilities -= deficit;  // Keep coverage ratio accurate
}
```

---

## Gas Optimization

### Deposit/Withdraw Complexity

| Operation | Coverage Tracking | No Coverage Tracking |
|-----------|-------------------|----------------------|
| Deposit   | O(1) + 2 SSTORE  | O(1) + 1 SSTORE     |
| Withdraw  | O(1) + 2 SSTORE  | O(1) + 1 SSTORE     |

**Cost**: ~5,000 additional gas per deposit/withdrawal (negligible)

### Swap Complexity

Swaps don't touch liabilities:

| Operation | Coverage Tracking | No Coverage Tracking |
|-----------|-------------------|----------------------|
| Swap      | O(1)             | O(1)                 |

**Cost**: No additional gas cost

---

## Key Takeaways

1. **Coverage ratio = reserves / liabilities** (inspired by Wombat model)
2. **Withdrawal haircut = min(C, 1.0)** - fair pro-rata loss sharing when C < 1
3. **Target coverage ratio** (e.g., 1.05) defines desired over-collateralization
4. **Natural rebalancing incentives** via tri-factor fee model (higher fees when imbalanced)
5. **O(1) complexity** with delta-based caching
6. **Zero breaking changes** to external interfaces
7. **Negligible gas cost** (~5k additional per deposit/withdraw)
8. **LP-friendly design**: Withdrawals always enabled with fair haircut; no arbitrary pausing

**The system promotes fairness and transparency while maintaining proper coverage ratio tracking and seeking healthy over-collateralization.**
