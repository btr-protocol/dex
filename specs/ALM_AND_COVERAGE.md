# Coverage Ratio-Based ALM Model

## Overview

BAMM implements a **Wombat-inspired coverage ratio system** for Active Liquidity Management (ALM). The coverage ratio tracks the health of each asset pool and automatically adjusts fees to incentivize rebalancing.

## Why Single-Pool Architecture at Scale

### The Problem: Isolated Pool Models

Traditional DEX architectures isolate assets into separate pools by risk profile:
- **Curve**: Separate stable pools (3pool), volatile pools (tricrypto), factory pools
- **Balancer**: Isolated metapools per asset class, fragmented liquidity
- **Aave**: Separate lending instances (v2, v3, isolated pools) by risk tier
- **Venus**: Isolated pools (Core, Stablecoins, DeFi, GameFi)
- **Platypus**: Separate pools by asset type (Main, Alt, Factory)

**Consequences**:
- **Liquidity fragmentation**: $100M TVL split across 5 pools = $20M average depth per pool
- **Routing complexity**: Multi-hop swaps (USDT → 3pool → tricrypto → WETH) = 3× gas + slippage
- **Capital inefficiency**: Idle liquidity in low-volume pools, congestion in high-volume pools
- **LP dilution**: Emissions spread thin, APRs inconsistent

### Our Solution: Unified Pool with Multi-Layer Risk Mitigation

**BAMM uses a single pool for all assets** (stables, majors, alts) with **5 complementary protection layers**:

1. **Piecewise bonding curves** (liquidity profiling): Per-asset curves shaped to volatility/momentum profile—tight for stables, wide for alts
2. **Coverage-only tri-factor swap fees** (dynamic penalties): Simple reserves/liabilities coverage × volatility × divergence—no value weighting, direct ALM alignment
3. **Liability time decay** (long-term risk socialization): Gradual reduction of underwater LP claims to absorb permanent losses fairly
4. **Reserve price circuit breakers**: Disable swaps when internal reserve-based price exceeds safe deviation from oracle
5. **Deviation freeze**: Disable asset when fast TWAP deviates >threshold from slow TWAP (depeg/exploit detection)

**Result**:
- **Maximum capital efficiency**: All liquidity in one pool, no fragmentation
- **Minimal slippage**: Deep liquidity for all pairs (single-hop routing)
- **Contagion isolation**: Circuit breakers + liability decay prevent toxic assets from draining entire pool
- **Fair risk/reward**: Higher-risk assets earn higher fees + emissions, justified by decay exposure

### Comparison to Isolated Models

| Aspect | Isolated Pools (Aave/Venus/Balancer) | BAMM Single Pool |
|--------|--------------------------------------|------------------|
| **Liquidity depth** | Fragmented across instances | Unified, maximum depth |
| **Routing** | Multi-hop (high gas, slippage) | Single-hop (efficient) |
| **Contagion risk** | Zero (full isolation) | Mitigated (5-layer protection) |
| **Capital efficiency** | Low (idle liquidity) | High (all capital active) |
| **LP experience** | Inconsistent APRs | Balanced APRs with risk tiers |
| **Scalability** | Linear growth (N pools for N assets) | Sub-linear (1 pool, add assets) |

**Why this works for BAMM**:
- **Platypus failed** because they had only **single-factor fees** (coverage) and **no circuit breakers**—a USP depeg drained the pool
- **Wombat** has partial protection but still uses separate pools for risk tiers
- **BAMM combines** Wombat's ALM + Curve's piecewise curves + comprehensive circuit breakers + liability decay = safe single-pool at scale

### Use Cases Enabled by Single-Pool Design

**Direct pairs without fragmentation**:
```
USDC → WETH    (stable → major, 1 hop instead of USDC → 3pool → tricrypto → WETH)
USDT → ARB     (stable → alt, 1 hop instead of USDT → stable pool → bridge → alt pool)
DAI → WBTC     (stable → major, single swap)
stETH → frxETH (LSDs in same pool, no separate metastable pool)
```

**LP benefits**:
- Deposit USDC, earn fees from ALL pairs (USDC/WETH, USDC/ARB, USDC/WBTC), not just USDC/USDT
- Emissions routed per-asset (coverage × utilization), so high-volume pairs get most incentives
- Circuit breakers protect against toxic assets draining stable positions

**Trader benefits**:
- Best price execution (deepest liquidity)
- Lowest gas (single swap, no hops)
- Competitive fees (dynamic, not fixed 0.3%)

---

## Core Concepts

### Coverage Ratio Definition

**CRITICAL**: Coverage ratio is **unit-based**, NOT value-based.

```solidity
Coverage Ratio (C) = reserves (units) / liabilities (units)

Where:
- reserves  = actual token UNITS in the pool (e.g., 10M BONK tokens)
- liabilities = total deposited UNITS (LP claims in token units, e.g., 10M BONK)
```

**Price changes alone do NOT change coverage ratio.** Only **swap flows** (which add/remove reserves) change coverage.

**Example**:
- BONK: 10M reserves, 10M liabilities → C = 1.0
- BONK price pumps 10× ($0.10 → $1.00)
- Coverage still 1.0 (price irrelevant)
- Traders arbitrage: buy BONK via USDC→BONK swaps → reserves drain to 4M
- Coverage now 4M / 10M = 0.4 (reserves depleted by flows, NOT price change)

### States

| State | Condition | Description |
|-------|-----------|-------------|
| **Healthy** | C ≥ 1.0 | Pool has more assets than liabilities (earned fees) |
| **Under-collateralized** | C < 1.0 | Pool is imbalanced, LPs should be incentivized to stay |

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

When an LP withdraws tokens:

```solidity
// Calculate LP's proportional shares
liabilityShare = lpTokens * totalLiabilities / totalLPTokens
amountOut = lpTokens * totalReserves / totalLPTokens

// No explicit haircut: LP receives proportional share of available reserves
// Coverage ratio naturally reflected in reserve availability

// Update state
asset.reserves -= amountOut
asset.liabilities -= liabilityShare
```

**Result**: Coverage ratio remains constant; fair pro-rata loss sharing without additional penalties

### Swaps

Swaps affect only reserves, not liabilities:

```solidity
assetIn.reserves += amountIn
assetOut.reserves -= amountOut
// liabilities unchanged
```

**Result**: Coverage ratios change based on pool imbalance and fees earned

---

## Coverage Ratio and Fair Loss Sharing

### Mechanism

When an LP withdraws, they receive their **proportional share of available reserves**:

```solidity
amountOut = (lpTokens / totalLPTokens) * reserves
liabilityShare = (lpTokens / totalLPTokens) * liabilities
```

No explicit haircut multiplication is applied. The coverage ratio is naturally reflected in the reserve availability.

### Example

Pool state:
- reserves = 900 USDC
- liabilities = 1000 USDC
- C = 0.9

LP withdrawal:
- LP owns 10% of pool
- LP's liability share = 100 USDC
- LP's reserve share = 90 USDC
- **LP receives: 90 USDC** (their proportional share of reserves)

After withdrawal:
- reserves = 810 USDC
- liabilities = 900 USDC
- **C = 0.9** (unchanged)

### Incentive Structure

The system creates natural **rebalancing incentives** without explicit haircuts:

1. **Low liquidity → Higher fees** (tri-factor model increases fees when imbalanced)
2. **Higher fees → More revenue** for all LPs in the pool
3. **Fair withdrawal** (no additional penalties for leaving during imbalance)
4. **Result**: LPs can exit fairly; high fees attract new deposits; pool rebalances naturally

---

## Tri-Factor Fee Model

The coverage ratio is the **first factor** in the tri-factor fee model. See [`FEES.md`](FEES.md) for full details.

### Coverage Factor (Per-Asset)

**CRITICAL**: Uses **per-asset coverage** (unit-based), NOT global pool coverage (value-based).

```solidity
// Per-asset coverage (in token units, NOT value)
C = reserves (units) / liabilities (units)

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

**Key Points**:
- **Per-asset coverage**: `reserves / liabilities` in token units (NOT value-weighted)
- **Global pool coverage NOT used**: Only for analytics, NOT fee calculation
- **Coverage timing**: Post-swap for inflows (penalties), pre-swap for outflows (rebates)
- Linear rebates when under-collateralized (encourages deposits/inflows)
- Linear penalties when over-collateralized (discourages outflows)
- No hardcoded thresholds - all configurable parameters

---

## Pool-Wide Coverage

### Total Liabilities Calculation

For inventory factor calculation, we need total pool liabilities:

```solidity
uint256 totalLiabilities = 0;
for (address token : registeredAssets) {
    totalLiabilities += assets[token].liabilities * getPrice(token) / PRICE_PRECISION;
}
```

### Total Reserves Calculation

Already implemented via cached total value:

```solidity
uint256 totalReserves = cachedTotalValue;
```

---

## Asset Struct Update

The `Asset` struct now tracks liabilities:

```solidity
struct Asset {
    // SLOT 1: uint128 + uint128 = 32 bytes
    uint128 reserves;       // Physical tokens in pool (assets)
    uint128 liabilities;    // Total deposited amount (LP claims)

    // ... (8 more slots)

    // SLOT 9: uint128 = 16 bytes
    uint128 minLiquidity;   // Minimum liquidity (moved from slot 1)
}
```

**Storage cost**: Added 1 new slot (9th slot) for minLiquidity

---

## Comparison to Weight-Based Coverage

### Old System (Weight-Based)

```solidity
// Coverage based on arbitrary weights
coverage = reserves / (weight * someConstant)
```

**Problems**:
- Weights are arbitrary and must be manually configured
- No direct relationship to LP claims
- Doesn't track actual pool health

### New System (Liability-Based)

```solidity
// Coverage based on actual LP claims
coverage = reserves / liabilities
```

**Benefits**:
- Direct relationship to LP claims
- Automatic tracking of pool health
- No manual weight configuration needed
- True reflection of over/under-collateralization
- Proven model (Wombat, Platypus)

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

// Withdrawals (with haircut)
oldReserves = asset.reserves;
asset.reserves -= amountOut;  // haircutted amount
asset.liabilities -= liabilityShare;  // full share
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
if (amountOut > asset.reserves) revert E.InsufficientReserves();
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

## Parameter Defaults

### Per-Asset Coverage Factor

```solidity
covMinMult = 20           // 0.2x min rebate when under-collateralized
covMaxMult = 10000        // 100x max penalty when over-collateralized
covUnderMax = 0.5e18      // 50% max under-coverage to scale
covOverMax = 0.5e18       // 50% max over-coverage to scale
```

### Global Fee Caps

```solidity
minMult = 20              // 0.2x global min (allows inventory rebates)
maxMult = 10000           // 100x global max
```

---

## Owner Functions

### Update Coverage Parameters

```solidity
function updateCoverageParams(
    uint16 _covMinMult,      // 0.2x = 20, 1.0x = 100
    uint16 _covMaxMult,      // 100x = 10000
    uint256 _covUnderMax,    // 0.5e18 (50% max under-coverage)
    uint256 _covOverMax      // 0.5e18 (50% max over-coverage)
) external onlyOwner
```

---

## Testing Checklist

- [x] Deposit increases liabilities correctly
- [x] Withdraw decreases liabilities by proportional share
- [x] Coverage ratio remains constant after withdrawal
- [x] LP receives fair proportional share of reserves
- [x] No additional haircut penalties applied
- [x] Fee-on-transfer protection updates both reserves and liabilities
- [x] Division by zero protection
- [x] Overflow protection on liability tracking
- [ ] Integration with tri-factor fee calculation (pending)
- [ ] Under-collateralized pool (C < 1) withdrawal works correctly
- [ ] Over-collateralized pool (C > 1) withdrawal works correctly

---

## Why No Circuit Breakers?

### Decision

BAMM **does NOT implement automatic withdrawal pausing** based on coverage ratio thresholds.

### Rationale

**1. Fairness to LPs:**
- LPs deposit in good faith and should always be able to exit
- "Pausing withdrawals when coverage < threshold" is effectively a rugpull
- Better to allow fair (potentially reduced) withdrawals than trap LPs

**2. Bank Run Prevention Paradox:**
- If users know withdrawals CAN be paused → they rush to exit at first sign of trouble
- **This creates the bank run** the circuit breaker was meant to prevent
- Better to allow orderly exits at dynamically adjusted rates

**3. Natural Protection Through Fees:**
- Withdrawal fees increase when assets are imbalanced (0-5% based on inventory)
- Tri-factor fee model makes large withdrawals expensive when coverage is low
- High fees naturally slow withdrawals without explicit pausing
- This is **economically enforced** (not governance-enforced)

**4. Proper Invariant Design Philosophy:**
- If a protocol needs circuit breakers to survive, **the economic model is broken**
- Better to design fees/invariants such that C cannot drop below critical levels naturally
- Current model: reserves depleted → fees spike → withdrawals slow → pool rebalances

**5. Emergency Controls We DO Have:**

| Control | Scope | Blocks Withdrawals? | Purpose |
|---------|-------|---------------------|---------|
| `freezeAsset()` | Per-asset | ❌ No | Freeze swaps only (oracle failure, token issue) |
| `pausePool()` | Entire pool | ❌ No | Pause swaps + deposits (withdrawals still work) |
| `rescueERC20()` | Stuck tokens | ❌ No | Recover tokens sent by mistake (timelock required) |

**Even in emergencies, withdrawals remain enabled** to honor LP claims.

### Comparison to Feedback Document Proposal

The coverage ratio feedback document proposes:

```solidity
// ❌ NOT IMPLEMENTED IN BAMM
enum CircuitState { Normal, Warning, Paused, Recovery }

if (coverage < 0.60) {
    pauseWithdrawals();  // Trap LPs!
}
```

**Why we reject this:**
- Unfair to LPs (they took no additional risk)
- Terrible UX ("why can't I withdraw MY money?")
- Creates regulatory risk ("freeze withdrawals")
- Band-aid on broken economic model

**Our alternative:**
```solidity
if (coverage < threshold) {
    withdrawalFee = calculateDynamicFee(coverage);  // Up to 5%
    triFactorMult = calculateCoverageMultiplier();  // Up to 5.0x on swaps
    // Withdrawals ALWAYS allowed, just more expensive when imbalanced
}
```

**Related:** See [ARCHITECTURE.md](./ARCHITECTURE.md#why-no-circuit-breakers-for-withdrawals) for high-level design philosophy.

---

## Stress Test Requirements

Before mainnet launch, the coverage ratio model must be stress tested under extreme conditions.

### Test 1: Large Withdrawal When C < 1

**Scenario:** Pool is under-collateralized (C = 0.7), LP attempts to withdraw 50% of pool.

**Expected behavior:**
```solidity
// Initial state
reserves = 700 USDC
liabilities = 1000 USDC
C = 0.7

// LP owns 50% → wants to withdraw
LP liability share = 500 USDC
LP reserve share = 350 USDC  // 50% of 700

// LP receives 350 USDC (their proportional share)
// Withdrawal fee applies (let's say 2% = 7 USDC)
// Actual payout = 343 USDC

// After withdrawal
reserves = 357 USDC (700 - 343)
liabilities = 500 USDC (1000 - 500)
C = 0.714  // Slightly improved or constant depending on fees
```

**Tests to write:**
- [ ] Coverage ratio does not worsen significantly after withdrawal
- [ ] LP receives fair proportional share
- [ ] Pool remains functional after large withdrawal
- [ ] Remaining LPs are not disadvantaged

### Test 2: Coverage Ratio Floor

**Scenario:** Determine the minimum coverage ratio the pool can reach under normal operations.

**Method:**
```solidity
function testFuzz_coverageCannotCrashBelowFloor(
    uint256 swapCount,
    uint256 withdrawPercent
) public {
    swapCount = bound(swapCount, 1, 100);
    withdrawPercent = bound(withdrawPercent, 1, 99);

    // Execute random swaps and withdrawals
    for (uint i = 0; i < swapCount; i++) {
        // Random swap
    }

    // Large withdrawal
    withdraw(totalLiquidity * withdrawPercent / 100);

    // Assert coverage ratio floor
    uint256 coverage = getCoverageRatio(USDC);
    assertGe(coverage, MIN_COVERAGE_FLOOR);  // e.g., 0.5 = 50%
}
```

**Tests to write:**
- [ ] Fuzz test: 10,000 random operation sequences
- [ ] Determine empirical coverage floor (e.g., never drops below 50%?)
- [ ] Verify fee model prevents catastrophic under-collateralization
- [ ] Test with malicious actors trying to drain pool

### Test 3: Incentive Alignment

**Scenario:** Verify that high fees when C < 1 attract deposits and discourage withdrawals.

**Method:**
```solidity
function test_incentivesAlignWithCoverage() public {
    // Setup: Pool at C = 0.8
    setupPool(reserves: 800, liabilities: 1000);

    // Measure fee for deposit
    uint256 depositFee = calculateDepositFee(USDC, 100);
    // Measure fee for withdrawal
    uint256 withdrawalFee = calculateWithdrawalFee(USDC, 100);
    // Measure fee for swap OUT of USDC (depleting reserves)
    uint256 swapOutFee = calculateSwapFee(USDC, WETH, 100);

    // Expectations:
    // - Deposit fee should be LOW (encourage deposits)
    // - Withdrawal fee should be HIGH (discourage withdrawals)
    // - Swap fee to deplete USDC should be HIGH

    assertLe(depositFee, BASE_DEPOSIT_FEE);  // No penalty for depositing
    assertGe(withdrawalFee, BASE_WITHDRAWAL_FEE * 2);  // Penalty for withdrawing
    assertGe(swapOutFee, BASE_SWAP_FEE * 2);  // Penalty for depleting
}
```

**Tests to write:**
- [ ] Deposit fees decrease as C decreases (encourage deposits)
- [ ] Withdrawal fees increase as C decreases (discourage withdrawals)
- [ ] Swap fees to deplete asset increase as C decreases
- [ ] Fees correctly incentivize rebalancing behavior

### Test 4: Fee-on-Transfer Token Edge Cases

**Scenario:** Ensure coverage ratio tracking remains accurate with fee-on-transfer tokens.

**Expected behavior:**
```solidity
// Deposit 100 USDT (with 1% transfer fee)
// Actual received: 99 USDT

reserves += 99
liabilities += 99  // MUST match actual received amount
C = reserves / liabilities  // Should remain correct
```

**Tests to write:**
- [ ] Deposit with fee-on-transfer: reserves = liabilities = actual amount
- [ ] Withdraw with fee-on-transfer: coverage ratio remains stable
- [ ] Multiple deposits with varying transfer fees
- [ ] Coverage ratio never diverges due to transfer fees

### Test 5: Recovery from Under-Collateralization

**Scenario:** Pool starts at C = 0.6, verify it can recover to C = 1.0 through natural operations.

**Method:**
1. Setup pool at C = 0.6 (reserves = 600, liabilities = 1000)
2. Execute normal swap activity (generate fees)
3. High fees attract deposits (low/zero deposit fees when C < 1)
4. Monitor coverage ratio over time
5. Verify C → 1.0 within reasonable timeframe

**Tests to write:**
- [ ] Simulation: 1000 swaps from C = 0.6 → track C over time
- [ ] Verify fee model makes recovery profitable for arbitrageurs
- [ ] Time to recovery < reasonable threshold (e.g., 1000 swaps)
- [ ] No external intervention required for recovery

### Coverage Floor Parameter

Based on stress tests, determine and document:

```solidity
/// @notice Minimum expected coverage ratio under normal operations
/// @dev Empirically determined via stress testing
/// @dev If coverage drops below this, it indicates:
///      - Extreme market conditions
///      - Potential economic attack
///      - Need for owner intervention (asset freeze)
uint256 public constant MIN_EXPECTED_COVERAGE = ???;  // TBD via testing

// Suggested values:
// - Conservative: 0.8 (80%)
// - Moderate: 0.6 (60%)
// - Aggressive: 0.4 (40%)
```

**Action items:**
1. Run all stress tests
2. Determine empirical floor
3. Document in this file
4. Add invariant check (development only): `assert(C >= MIN_EXPECTED_COVERAGE * 0.9)`
5. Set up monitoring/alerts for mainnet if C approaches floor

---

## Bad Debt Management: Liability Time Decay

When an asset becomes persistently underwater (coverage ratio below threshold for extended period), the protocol employs **time-based liability decay** to gradually eliminate bad debt without external subsidies.

### Overview

**Problem:** If coverage ratio stays below 1.0 (e.g., asset crashed 50% and doesn't recover), the pool has structural bad debt.

**Solution:** Gradually reduce liabilities $L'_k$ over time until they match available reserves $A_k$.

### Key Properties

1. **Time-based:** Decay progresses based solely on elapsed time (predictable for LPs)
2. **Threshold-triggered:** Only activates when $r_k < r_{\text{threshold}}$ (e.g., 98%)
3. **Auto-shutoff:** Stops automatically when coverage recovers above threshold for 24+ hours
4. **Parametric curve:** Exponent $n$ controls front-loading vs back-loading
5. **LP agency preserved:** LPs can withdraw anytime at current coverage ratio

### Formula

$$L'_k(t) = L_0 \cdot \left[1 - \left(1 - \frac{A_k}{L_0}\right) \cdot \left(\frac{\Delta t}{T_{\text{max}}}\right)^n\right]$$

**Terminal state** (at $t = T_{\text{max}}$): $L'_k = A_k$ (full debt absorption, $r_k = 1.0$)

### LP Economics

**Critical insight:** When reserves are constant, LP withdrawable value stays constant during decay:

$$\text{withdrawableAmount} = \text{shares} \times L'_k(t) \times r_k(t) = \text{shares} \times A_k = \text{constant}$$

**Why?** As liabilities decay ($L'_k \downarrow$), coverage ratio improves ($r_k \uparrow$) at exactly offsetting rates.

**Decay is NOT a penalty** - it's a transparency mechanism that brings nominal accounting in line with economic reality over time.

### Example

```
Scenario: Asset underwater at 90% coverage
  Initial: A=900, L=1000, r=0.90

t=0 (LP deposits):
  - Nominal claim: 100 tokens
  - Coverage haircut: 90%
  - Withdrawable: 100 × 0.90 = 90 tokens

t=30 days (decay reduces L to 950):
  - Nominal claim: 95 tokens (decay ate 5)
  - Coverage: 900/950 = 94.7%
  - Withdrawable: 95 × 0.947 = 90 tokens ✓

t=90 days (terminal state, L=900):
  - Nominal claim: 90 tokens (decay ate 10 total)
  - Coverage: 900/900 = 100%
  - Withdrawable: 90 × 1.00 = 90 tokens ✓
```

**Withdrawable amount stays 90 throughout.** The loss was realized at t=0 (reserves < liabilities), decay just spreads the accounting adjustment over time.

### Flash Loan Protection

Decay mechanism includes robust flash loan resistance:

1. **Time-weighted coverage check:** Must stay above threshold for 24 hours
2. **Improvement requirement:** Coverage must exceed start coverage
3. **Continued decay during lockout:** Can't skip terminal state

See [`LIABILITY_TIME_DECAY.md`](LIABILITY_TIME_DECAY.md) for full specification.

---

## Related Documentation

- [FEES.md](FEES.md) - Complete fee model spec
- [ORACLE.md](ORACLE.md) - Oracle system and price feeds
- [LIABILITY_TIME_DECAY.md](LIABILITY_TIME_DECAY.md) - Time-based bad debt elimination mechanism

---

## Key Takeaways

1. **Coverage ratio = reserves / liabilities** (inspired by Wombat model)
2. **Fair pro-rata loss sharing** without explicit haircut penalties
3. **Natural rebalancing incentives** via tri-factor fee model (higher fees when imbalanced)
4. **Sustainable bad debt elimination** via time-based liability decay (no protocol subsidies)
5. **O(1) complexity** with delta-based caching
6. **Zero breaking changes** to external interfaces
7. **Negligible gas cost** (~5k additional per deposit/withdraw)
8. **LP-friendly design**: No penalties for withdrawing during imbalances; coverage ratio naturally reflected in available reserves

**The system promotes fairness, transparency, and long-term sustainability while maintaining proper coverage ratio tracking.**
