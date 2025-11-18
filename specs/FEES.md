# BAMM Fee System - Tri-Factor ALM Model

## Overview

BAMM implements a **tri-factor fee model** (coverage × volatility × deviation) with **unified volatility calculation** for maximum gas efficiency and direct ALM alignment.

### Fee Precision: 100,000 Base (Not Standard 10,000 BPS)

**Precision**: 1 unit = 0.0001% = 0.01 bps (`BPS_PRECISION = 100_000`)

**Why 10× finer precision than standard BPS:**

1. **Sub-bps fees**: Express 0.5 bps (0.005%) flash loans as 50 units—impossible with standard 10k base
2. **Tri-factor granularity**: Coverage, volatility, and divergence factors need fine-grained multipliers (0.01 precision instead of 0.1)
3. **Uint16 efficiency**: Max uint16 (65,535) = 6.5535%, well above theoretical 5% max; fits all fees in single 2-byte field
4. **Uint256 safety**: All fee calculations cast uint16 params to uint256 at computation time for summation/averaging—no overflow risk, clean math
5. **Competitive positioning**: 50 units (0.5 bps) for flash loans is 10× cheaper than Aave's 9 bps, enabling MEV and arbitrage use cases

**Examples**:
- Flash loan (target): 50 = 0.005% = 0.5 bps (vs Aave 9 bps)
- Min swap fee: 100 = 0.01% = 1 bps
- Typical swap fee: 3,000 = 0.3% = 30 bps
- Max swap fee: 50,000 = 5% = 500 bps
- Protocol take: 10,000 = 1% (NOT 10%—be careful!)

**Calculation**:
```solidity
uint256 feeAmount = (amount * feeBps) / BPS_PRECISION;  // BPS_PRECISION = 100_000
```

**Type safety**: All tri-factor computations explicitly cast uint16 fee params to uint256 before multiplication/division to prevent overflow in intermediate operations.

## Swap Routing Model

**All swaps follow hub-and-spoke routing** through the base token (typically USDC). For complete routing specification, including virtual depth mechanics and numéraire concepts, see **[SWAP.md](./SWAP.md)**.

### Direct vs Triangulated Swaps (Summary)

**Every swap has 2 legs**, but behavior differs based on whether base token is involved:

| Aspect | Direct (A ↔ base) | Triangulated (A → base → B) |
|--------|-------------------|------------------------------|
| **Base reserves** | Modified | **Unchanged** (virtual numéraire) |
| **Base LP fees** | Earned (50% of fees) | **Zero** (only A and B LPs earn) |
| **Virtual depth** | Not used | **Used** (path independence) |
| **Slippage source** | Both assets' curves | Only A and B curves |
| **Fee split** | 50/50 between A and base | 50/50 between A and B |

**See [SWAP.md](./SWAP.md) for detailed routing specification.**

## Table of Contents

1. [Key Principles](#key-principles)
2. [Unified Volatility System](#unified-volatility-system)
3. [Coverage-Only Inventory Factor](#coverage-only-inventory-factor)
4. [Tri-Factor Fee Model](#tri-factor-fee-model)
5. [Fee Model: Direct vs Triangulated](#fee-model-direct-vs-triangulated-swaps)
6. [Liquidity Breadth Integration](#liquidity-breadth-integration)
7. [Deposit and Withdrawal Fees](#deposit-and-withdrawal-fees)
8. [Parameter Configuration](#parameter-configuration)

---

## Key Principles

1. **All swaps have 2 legs** - Buy side (tokenIn) and sell side (tokenOut); distinction is direct vs triangulated
2. **Decode oracle once per asset** - Compute baseline vol and shock ratio once, reuse for both breadth and fees
3. **Per-asset coverage** - Uses raw `C = reserves / liabilities` with proper timing (post-swap for inflows, pre-swap for outflows)
4. **Three multiplicative factors** - Coverage, volatility shock, price divergence combined via geometric mean
5. **Simple 50/50 fee split** - `totalFeeBps / 2` per leg, no complex value conversions
6. **Virtual depth for triangulated** - Base acts as numéraire only, reserves unchanged, no base LP fees

### Why Per-Asset Coverage?

**Per-asset coverage (unit-based) is used instead of global pool coverage** because:
- Coverage = `reserves / liabilities` in token units (NOT value-weighted)
- Global pool coverage is for analytics only, NOT used in fee calculation
- Simpler math: no cross-asset value summation in fee path
- Direct ALM alignment: same per-asset coverage drives fees and incentives

---

## Unified Volatility System

### Design Goal

> Compute baseline vol and shock ratio **once per asset per leg**, then reuse those values for **both** piecewise price traversal (breadth) and fee computation.

This ensures:
- **Gas efficiency** - Single oracle decode, no redundant SLOADs
- **Consistency** - Breadth and fees see identical volatility state
- **Reactivity** - Latest oracle indices used for both calculations

### What to Compute Once

For each asset in the swap leg:

```solidity
// 1. Oracle bundle
fast TWAP: q_f (B64 decoded to 1e18)
slow TWAP: q_s (B64 decoded to 1e18)
fast vol: v_f (1e6 units)
slow vol: v_s (1e6 units)

// 2. Baseline vol (no clamping)
v_base = v_s  // Use raw slow vol

// 3. Shock ratio
r = min(r_max, v_f / max(v_s, ε))
```

### Parameters

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `volEpsilon` | uint16 | Denominator safety (1e6 units) | 1000 (0.001%) |
| `volRMax` | uint16 | Maximum shock ratio (100x precision) | 500 (5x) |

### Usage Pattern

```solidity
// Decode once
OracleData memory data = decodeOracle(oracleEntry);
// data.volBaseline, data.volFast, data.volSlow available

// Use in breadth
uint256 breadthBps = data.volBaseline * kappa / 1_000_000;

// Use in fees
uint256 baseFee = baseMin + (data.volBaseline * baseK) / 1_000_000;
uint256 shockMult = _volShock(data.volFast, data.volSlow, params);
```

---

## Per-Asset Coverage Factor

### Coverage Definition

```solidity
C = reserves (units) / liabilities (units)
```

- **Unit-based, NOT value-based**: Only token amounts matter (not value)
- **Price-invariant**: Only swap flows and deposits/withdrawals change $C$
- **Per-asset**: Each token has independent coverage
- **Global pool coverage NOT used**: Only per-asset coverage affects fees (global is analytics-only)
- **Safe denominator**: If `liabilities == 0`, treat `C = 1` for fees

### Coverage Multiplier

```solidity
// Under-collateralized (C < 1): linear rebate
if (C < 1e18) {
    δ_under = min(1e18, (1e18 - C) * 1e18 / covUnderMax);
    m_cov = 1e18 - (1e18 - covMinMult) * δ_under / 1e18;
}

// Over-collateralized (C >= 1): linear penalty
else {
    δ_over = min(1e18, (C - 1e18) * 1e18 / covOverMax);
    m_cov = 1e18 + (covMaxMult - 1e18) * δ_over / 1e18;
}
```

### Parameters

| Parameter | Type | Description | Default |
|-----------|------|-------------|---------|
| `covMinMult` | uint16 | Min rebate multiplier (100x) | 20 (0.2x) |
| `covMaxMult` | uint16 | Max penalty multiplier (100x) | 10000 (100x) |
| `covUnderMax` | uint256 | Max under-coverage to scale (WAD) | 0.5e18 (50%) |
| `covOverMax` | uint256 | Max over-coverage to scale (WAD) | 0.5e18 (50%) |

### Examples

| Coverage | δ | Multiplier | Effect |
|----------|---|------------|--------|
| 0.5 | 1.0 | 0.2x | Max rebate (under 50%) |
| 0.75 | 0.5 | 0.6x | Partial rebate |
| 1.0 | 0.0 | 1.0x | Neutral |
| 1.5 | 1.0 | 100x | Max penalty (over 50%) |
| 1.25 | 0.5 | 50x | Partial penalty |

---

## Tri-Factor Fee Model

### Per-Asset Multiplier

Each asset computes three independent factors:

```solidity
// 1. Coverage factor
m_inv = _coverageFactor(reserves, liabilities, params);

// 2. Volatility shock factor
r = min(volRMax, volFast * 1e18 / max(volSlow, volEpsilon));
m_vol = clamp(volBeta * r / 100, 1e18, volMaxMult * 1e18 / 100);

// 3. Price divergence factor
d1 = |poolPrice - oracleFast| / oracleFast;
d2 = |oracleFast - oracleSlow| / oracleSlow;
x_pd = min(1, max(d1 / pdD1Max, pdAlpha * d2 / pdD2Max));
m_pd = 1e18 + (pdMaxMult * 1e18 / 100 - 1e18) * x_pd;

// Combined per-asset multiplier
m_asset = clamp(m_inv * m_vol * m_pd / 1e36, minMult, maxMult);
```

### Single-Leg Fee (A ↔ base)

For swaps involving base token:

```solidity
// Per-leg multiplier (max of in/out assets)
m_leg = max(m_asset_in, m_asset_out);

// Baseline fee from slow vol
f_base = max(baseMin, baseK * volBaseline_avg / 1_000_000);

// Final fee
f_bps = clamp(f_base * m_leg / 1e18, asset.minFeeBps, asset.maxFeeBps);
```

---

## Fee Model: Direct vs Triangulated Swaps

**All swaps have 2 legs** (buy side + sell side). The distinction is:
- **Direct**: A ↔ base (one leg is base token)
- **Triangulated**: A → base → B (base is virtual numéraire)

### Coverage Timing (ALM Incentives)

**Critical**: Coverage must reflect the **marginal** state traders experience:
- **Inflows** (selling into pool): Use **post-swap** coverage `(reserves + amountIn) / liabilities` for penalties
  - Penalizes trades that increase imbalance
- **Outflows** (buying from pool): Use **pre-swap** coverage `reserves / liabilities` for rebates
  - Rewards trades that rebalance the pool

This timing ensures fees properly incentivize rebalancing toward target coverage.

### Fee Calculation: 50/50 Split for LP Fairness

```solidity
// 1. Compute total path fee from geometric mean of asset multipliers
m_in = m_cov(in, post-swap) * m_vol(in) * m_pd(in)
m_out = m_cov(out, pre-swap) * m_vol(out) * m_pd(out)
m_path = sqrt(m_in * m_out)  // Geometric mean for balanced incentives
totalFeeBps = baseFee * m_path / 1e18

// 2. Split 50/50 between legs for LP reward fairness
leg1FeeBps = totalFeeBps / 2
leg2FeeBps = totalFeeBps - leg1FeeBps  // Handle rounding

// 3. Apply to each leg's amount
feeIn = amountIn * leg1FeeBps / BPS_PRECISION
feeOut = amountOut * leg2FeeBps / BPS_PRECISION
```

**Why 50/50 split?**
- **LP fairness**: Equal rewards in value terms for both sides
- **Simple**: Single `totalFeeBps` visible to trader
- **Symmetric**: Same logic for direct and triangulated swaps
- **No complex conversions**: No cross-asset value weighting needed

**Why geometric mean?**
- Better balanced incentives than max() or addition
- Prevents one asset's extreme multiplier from dominating
- Smooth behavior when one asset is neutral

### Direct Swap: A ↔ base

```solidity
// Two legs: tokenIn and tokenOut (one is base)
// Volatility/deviation from non-base asset
// Coverage from both assets (post-swap for in, pre-swap for out)

totalFeeBps = computed as above
leg1FeeBps = totalFeeBps / 2
leg2FeeBps = totalFeeBps / 2

feeIn = amountIn * leg1FeeBps / BPS_PRECISION
feeOut = amountOut * leg2FeeBps / BPS_PRECISION
```

### Triangulated Swap: A → base (virtual) → B

```solidity
// Base is virtual numéraire (reserves unchanged)
// Virtual depth = effectiveDepth(A) for leg1, effectiveDepth(B) for leg2
// Fee computation same as direct, but base doesn't earn LP fees

totalFeeBps = computed from A and B multipliers
leg1FeeBps = totalFeeBps / 2
leg2FeeBps = totalFeeBps / 2

feeIn = amountIn * leg1FeeBps / BPS_PRECISION
feeOut = amountOut * leg2FeeBps / BPS_PRECISION

// Base earns zero LP fees (virtual routing)
// Protocol may still collect base protocol fees if desired
```

### Why This Model?

1. **Simple**: Just `totalFeeBps / 2` per leg, no value conversions
2. **Fair**: Equal LP rewards in value terms automatically
3. **Symmetric**: Same logic for direct and triangulated
4. **Correct timing**: Inflows penalized on post-swap coverage, outflows rebated on pre-swap
5. **Path independent**: Triangulated uses virtual depth, no base impact on slippage

---

## Liquidity Breadth Integration

### Virtual Depth for Path Independence

**Problem**: In A→base→B routing, base token depth shouldn't affect slippage when it's only a numéraire (denomination), not an input/output.

**Solution**: Use **virtual depth** where base appears as deep/shallow as the real economic assets (A or B), ensuring **path independence**: A→base→B has same slippage as direct A↔B.

#### Virtual Depth Calculation

```solidity
// Effective depth = reserves (or vol-adjusted)
function effectiveDepth(Asset storage asset) internal view returns (uint256) {
    return asset.reserves;  // Simple: just reserves
}

// Leg 1: A → base (virtual)
virtualBaseDepth1 = effectiveDepth(assetA);

// Leg 2: base (virtual) → B
virtualBaseDepth2 = effectiveDepth(assetB);
```

#### How Virtual Depth Works

```solidity
// Inside piecewise curve traversal for leg with virtualDepth
uint256 actualReserves = assetOut.reserves;
uint256 depthMultiplier = virtualDepthOut * 1e18 / actualReserves;

for (uint i = 0; i < segmentCount; i++) {
    uint256 segmentLiq = reserves * segmentWeights[i] / WEIGHT_SUM;
    uint256 virtualSegmentLiq = segmentLiq * depthMultiplier / 1e18;

    // Use virtualSegmentLiq for slippage calculation
    // But base reserves remain unchanged (virtual only)
}
```

**Virtual Depth Behavior**:
- When `virtualDepth > actualReserves`: Increases segment liquidity (base appears deeper)
- When `virtualDepth < actualReserves`: Decreases segment liquidity (base appears shallower)
- This is intentional for path independence, not a bug

**Example**:
- Asset A has 1000 reserves, base has 100 reserves
- Virtual depth for A→base leg = 1000 (base appears 10× deeper)
- This makes slippage identical to direct A↔B routing
- Base reserves remain unchanged (virtual only)

**Key properties**:
1. Base reserves are **read** but **never written** in triangulated swaps
2. Slippage comes entirely from A and B curves
3. Base acts purely as price denomination
4. Coverage already affects fees via $m_{\text{cov}}$—no double penalization

### Breadth Calculation

```solidity
// Reuse baseline vol from oracle decode
// uint32 precision: 1 unit = 0.0001%, base = 1_000_000 (100_000 = 100%)
breadthBps = minPriceStep + (volBaseline * 100) / 1000;
breadthBps = min(breadthBps, MAX_BREADTH_BPS);  // 1_000_000 (100%) cap
breadthBps = min(breadthBps, maxBreadth);       // per-asset cap
```

### Segment Traversal

```solidity
for (uint i = 0; i < segmentCount; i++) {
    int256 leftOffset = twapOffsets[i];
    int256 rightOffset = twapOffsets[i+1];

    // BPS_PRECISION = 1_000_000, breadthBps in same units
    leftPrice = slowTWAP * (BPS_PRECISION + leftOffset * breadthBps / 100) / BPS_PRECISION;
    rightPrice = slowTWAP * (BPS_PRECISION + rightOffset * breadthBps / 100) / BPS_PRECISION;

    segmentLiquidity = reserves * segmentWeights[i] / WEIGHT_SUM;
    // ... fill and traverse
}
```

---

## Deposit and Withdrawal Fees

### Design Philosophy

**Deposits and withdrawals use optional parametric fees for MEV/arbitrage protection, NOT for routine revenue.**

#### Deposit Fees

```solidity
// Default: 0 (no penalty for providing liquidity)
uint16 depositFeeBps = 0;  // Can be set to e.g., 20 (0.02%) to deter flash deposits

// Applied to actual received amount (after FOT handling)
uint256 depositFee = (actualAmount * asset.depositFeeBps) / BPS_PRECISION;
uint256 amountAfterFee = actualAmount - depositFee;

// Fee bumps liquidity index for existing LPs (not withdrawn)
if (depositFee > 0 && lpState.totalScaledSupply > 0) {
    lpState.liquidityIndex = oldIndex * (oldReserves + depositFee) / oldReserves;
}
```

**When to use:**
- Flash deposit/withdraw arbitrage attacks
- JIT liquidity sniping (deposit right before large swap, withdraw after)
- Typical value: 0.02% (20 bps) is dissuasive but not prohibitive

#### Withdrawal Fees

```solidity
// Default: 0 (coverage ratio haircut is primary mechanism)
uint16 withdrawalFeeBps = 0;  // Can be set to e.g., 20 (0.02%) for additional protection

// Applied AFTER coverage ratio haircut
if (asset.reserves < asset.liabilities) {
    amountOut = amountOut * (reserves / liabilities);  // Haircut first
}
uint256 withdrawalFee = (amountOut * asset.withdrawalFeeBps) / BPS_PRECISION;
amountOut -= withdrawalFee;

// Fee bumps liquidity index for remaining LPs (not withdrawn)
if (withdrawalFee > 0 && lpState.totalScaledSupply > 0) {
    lpState.liquidityIndex = oldIndex * (newReserves + withdrawalFee) / newReserves;
}
```

**Key properties:**
1. **Coverage haircut is primary** - Withdrawals already penalized when C < 1
2. **Parametric fee is optional** - Default 0, can be enabled for additional MEV protection
3. **No double-dipping** - Fee is `(amountOut_after_haircut * bps)`, not on original amount
4. **Stays in pool** - Fee redistributed to remaining LPs via index bump

**When to use:**
- Prevent rapid deposit→withdraw cycles exploiting price updates
- Deter flash withdraw arbitrage (withdraw before oracle update, re-deposit after)
- Typical value: 0.02% (20 bps) is empirically proven dissuasive

### Fee Accounting

Both deposit and withdrawal fees:
- **Stay in reserves** (not withdrawn to treasury)
- **Bump liquidity index** for existing/remaining LPs
- **Do NOT affect liabilities** (fees are pure dilution/bonus)

---

## Parameter Configuration

### Tri-Factor Fee Parameters (LibPricing.FeeParams)

Used for swap fee calculation (coverage, volatility, divergence factors).

```solidity
struct FeeParams {
    // Coverage (per-asset, NOT global pool coverage)
    uint16 covMinMult;         // 20 (0.2x) - min rebate
    uint16 covMaxMult;         // 10000 (100x) - max penalty
    uint256 covUnderMax;       // 0.5e18 - max under-coverage to scale
    uint256 covOverMax;        // 0.5e18 - max over-coverage to scale

    // Volatility (no clamping - use raw oracle values)
    uint16 volBeta;            // 100 (1x shock pass-through)
    uint16 volRMax;            // 500 (5x max shock ratio)
    uint16 volMaxMult;         // 500 (5x max vol multiplier)
    uint16 volEpsilon;         // 1000 (0.001% safety)

    // Price deviation
    uint16 devD1Max;           // 500 (5% threshold)
    uint16 devD2Max;           // 200 (2% threshold)
    uint16 devAlpha;           // 50 (0.5x weight on oracle drift)
    uint16 devMaxMult;         // 300 (3x max deviation multiplier)

    // Base fee (uint32, 1M precision: 1 unit = 0.0001%)
    uint16 baseK;              // 30 (slope: 0.3% per 1% vol)
    uint32 baseMin;            // 1000 (0.01% = 1 bps)

    // Bounds
    uint16 minMult;            // 10 (0.1x min total multiplier)
    uint16 maxMult;            // 10000 (100x max total multiplier)

    // Oracle
    uint16 maxTWAPChange;      // 500 (5% max TWAP change per update)

    // Protocol
    uint16 protocolFeeBps;     // 1000 (1% of swap fee)
    uint16 withdrawalFeeBps;   // 0 (global default, overridable per-asset)
}
```

### Per-Asset Fee Configuration (IBAMM.FeeConfig / Asset)

Used when adding assets via `addAsset()`.

```solidity
struct FeeConfig {
    uint16 minFeeBps;          // 100 (0.01% = 1 bps) - min swap fee
    uint16 maxFeeBps;          // 50000 (5% = 500 bps) - max swap fee
    uint16 protocolFeeBps;     // 1000 (1% of swap fees to treasury)
    uint16 depositFeeBps;      // 0 (default: no deposit penalty)
    uint16 withdrawalFeeBps;   // 0 (default: haircut is sufficient)
    uint16 flashFeeBps;        // 0 (default at launch, target 50 = 0.5 bps)
}
```

**Key distinction:**
- **FeeParams** (LibPricing): Global tri-factor swap fee calculation parameters
- **FeeConfig** (Asset): Per-asset fee overrides and flat fees (deposit/withdrawal/flash)

### Default Values

| Category | Parameter | Value | Meaning |
|----------|-----------|-------|---------|
| **Coverage** | covMinMult | 20 | 0.2x min rebate |
| | covMaxMult | 10000 | 100x max penalty |
| | covUnderMax | 0.5e18 | 50% under-coverage |
| | covOverMax | 0.5e18 | 50% over-coverage |
| **Volatility** | volBeta | 100 | 1x shock pass |
| | volRMax | 500 | 5x max shock |
| | volMaxMult | 500 | 5x max vol mult |
| **Deviation** | pdD1Max | 500 | 5% threshold |
| | pdD2Max | 200 | 2% threshold |
| | pdAlpha | 50 | 0.5x drift weight |
| | pdMaxMult | 300 | 3x max dev mult |
| **Base** | baseK | 30 | 0.3% per 1% vol |
| | baseMin | 100 | 1 bps min |
| **Protocol** | protocolFeeBps | 1000 | 1% of swap fees |
| **Deposit/Withdraw** | depositFeeBps | 0 | No deposit penalty |
| | withdrawalFeeBps | 0 | Haircut is sufficient |

**Note**: Deposit/withdrawal fees default to 0 but can be set to ~20 bps (0.02%) for MEV/arbitrage protection.

---

## Summary

### Key Design Principles

1. **Per-asset coverage**: Uses raw `C = reserves / liabilities` in token units (NOT value-weighted, global pool coverage NOT used)
2. **Coverage timing**: Post-swap for inflows (penalties), pre-swap for outflows (rebates) for ALM incentives
3. **50/50 LP fairness**: `totalFeeBps / 2` per leg for equal LP rewards
4. **Geometric mean**: Path fee from `sqrt(m_in * m_out)` for balanced incentives
5. **No vol clamping**: Use raw oracle volatility (total fee has caps, but volatility itself is not clamped)
6. **Virtual depth**: Achieves path independence for triangulated swaps (A→base→B same slippage as direct A↔B)

### Fee Calculation Flow

```
Direct Swap (A ↔ base):
  1. Decode oracles → volBaseline, volFast, volSlow, TWAPs
  2. m_in = m_cov(in, post-swap) * m_vol(in) * m_pd(in)
  3. m_out = m_cov(out, pre-swap) * m_vol(out) * m_pd(out)
  4. m_path = sqrt(m_in * m_out)
  5. totalFeeBps = baseFee * m_path / 1e18
  6. leg1FeeBps = leg2FeeBps = totalFeeBps / 2
  7. Apply feeIn = amountIn * leg1FeeBps, feeOut = amountOut * leg2FeeBps

Triangulated Swap (A → base → B):
  1. Same as direct, but using virtual depth for base
  2. Base reserves unchanged, earns no LP fees
  3. Only A and B LPs rewarded (50/50 split)
```

### Coverage Timing Summary

| Flow Direction | Coverage Used | Reason |
|----------------|---------------|---------|
| Selling into pool (inflow) | Post-swap `(reserves + amount) / liabilities` | Penalty for oversupply |
| Buying from pool (outflow) | Pre-swap `reserves / liabilities` | Rebate for restocking |
