# Liability Time Decay for ALM Pools

## Overview

Time-based liability decay is a mechanism for eliminating bad debt in Asset-Liability Management (ALM) pools without external subsidies, forced liquidations, or unfair LP penalties. When an asset becomes persistently underwater (coverage ratio below threshold), the protocol gradually reduces its accounting liabilities over time until they match available reserves.

**Key principle:** Decay converts impermanent loss into a **time-released realized loss**, giving markets time to organically rebalance while maintaining LP agency and predictability.

## Why Liability Decay Enables Single-Pool Architecture

### The Long-Tail Risk Problem in Unified Pools

**Isolated-pool protocols** (Aave v3, Venus Isolated, Balancer metapools) handle directional flow imbalances via **separation**:
- Alt token pumps 10× → Arbitrageurs drain it from DeFi pool → Core pool (USDC/WETH) unaffected
- Stablecoin depegs → Isolated in stable pool → No spillover to volatile assets

**Single-pool protocols** without loss absorption face **catastrophic accumulation**:
- Alt token pumps → Arbitrageurs buy it out → Reserves drain (units) → Coverage ratio <1.0 forever
- Coverage <1.0 persists if opposite flows never come (no one swaps the token back)
- LPs withdraw → Get proportional share of depleted reserves (unit-based loss)
- First withdrawers get best coverage ratio → "Bank run" as later withdrawers get worse ratio
- Result: **Entire pool becomes toxic**, even healthy assets suffer contagion fear

**BAMM's solution**: **Liability time decay** = **gradual unit-based liability reduction** over weeks/months, preventing bank run dynamics.

### How Liability Decay Absorbs Permanent Losses

**CRITICAL**: Coverage ratio = reserves (units) / liabilities (units), **NOT value-based**. Price changes alone do NOT change coverage—only swap flows change reserves relative to liabilities.

**Scenario**: BONK (meme token) in BAMM pool **pumps 10×** and traders arbitrage

**Initial state**:
```
BONK reserves: 10M tokens ($1M at $0.10/token)
BONK liabilities: 10M tokens
Coverage ratio: 1.0 (healthy)
```

**Price pumps 10× → Arbitrage flows**:
```
1. BONK price: $0.10 → $1.00 (10× pump)
2. Pool still prices BONK slightly below $1.00 (oracle lag + tri-factor fees)
3. Traders swap USDC/WETH → BONK at discount (arbitrage)
4. BONK reserves drain: 10M → 4M tokens (traders buying BONK out)
5. Liabilities unchanged: 10M tokens (LP claims in BONK units)
6. Coverage ratio: 4M / 10M = 0.4 (40% backed)
```

**Result**: LPs have **unit-based loss** (only 4M BONK left for 10M claims = 40¢ per $1 claim **in BONK terms**), but **$ value may be OK or even up** (4M BONK × $1.00 = $4M vs original $1M).

**The problem**: Coverage <1.0 means **impermanent loss realized as permanent unit loss** if opposite flows never come (traders never swap BONK back to pool).

**Without liability decay**:
```
1. Coverage ratio: 0.4 (40% backed in BONK units)
2. LPs withdraw → get 0.4 BONK per 1 BONK claim
3. At $1.00/BONK: LP gets $0.40 value per $1.00 claim (60% unit loss, but original deposit was at $0.10 so still 4× gain in $)
4. First withdrawers get best ratio → bank run as coverage worsens
5. Panic spreads → traders assume pool broken → contagion fear
```

**With BAMM liability decay**:
```
1. Coverage ratio: 0.4 → triggers decay (threshold = 0.9)
2. Decay parameters: T_max = 30 days, n = 0.5 (front-loaded, high-risk asset)
3. Day 1: Liabilities reduced ~3% → 10M → 9.7M tokens, coverage = 4M / 9.7M ≈ 0.41
4. Day 7: Liabilities reduced ~15% → 8.5M tokens, coverage = 4M / 8.5M ≈ 0.47
5. Day 30: Liabilities reduced 60% → 4M tokens, coverage = 4M / 4M = 1.0 (full recovery)
6. Result: BONK LPs bear **gradual unit loss** (10M → 4M claims over 30 days)
7. $ value: LP claim now 4M BONK × $1.00 = $4M (4× original $ deposit if they bought at $0.10)
8. USDC/WETH coverage ratios UNAFFECTED → no contagion
```

**Outcome**:
- **Unit-based**: LP loses 60% of BONK tokens (impermanent loss realized)
- **Dollar-based**: LP may still profit if price pump > unit loss (4× price gain > 60% unit loss)
- **Contagion**: Isolated to BONK, other assets healthy
- **Fairness**: Gradual vs instant, predictable formula, time to exit

**Why this happens**:
- BONK pumps → arbitrageurs buy BONK from pool → reserves drain
- Opposite flow (traders selling BONK back) may never come if pump sustains
- Decay mimics impermanent loss mechanics (units lost, but $ may recover)
- Without decay, first withdrawers get best ratio → bank run → pool death

### Liability Decay as Layer 3 of 5-Layer Defense

Decay is the **long-term cleanup mechanism** after short-term protections:

1. **Piecewise bonding curves** (layer 1): Shape slippage per asset risk profile
2. **Tri-factor swap fees** (layer 2): Economic penalties pressure reserves toward equilibrium
3. **Liability time decay** (layer 3): **Gradual absorption of permanent losses** (weeks/months)
4. **Reserve price circuit breakers** (layer 4): Instant swap disable at hard price floor
5. **Deviation freeze** (layer 5): Detect regime breaks, freeze asset

**Timeline of protection**:
- **Seconds**: Deviation freeze catches exploit/depeg → disable swaps
- **Minutes**: Reserve price CB trips if oracle/spot <floor → block toxic routes
- **Hours-Days**: Tri-factor fees ramp up (coverage × volatility × divergence) → economic disincentive
- **Weeks-Months**: Liability decay gradually reduces claims → clean up bad debt

**Why all 5 layers needed for single-pool**:
- Layers 4-5 **prevent contagion** (real-time isolation)
- Layers 1-2 **discourage toxic swaps** (economic pressure)
- Layer 3 **absorbs residual losses** (long-term cleanup)

### Risk/Reward Fairness for LPs

**LP choice matrix** in BAMM single pool:

| Asset Type | Risk (Decay Exposure) | Reward (Fees + Emissions) | Fair? |
|------------|----------------------|--------------------------|-------|
| **Stablecoins** | Low (n=2.0, slow decay, rare directional flows) | Low (tight curves, low fees) | ✓ |
| **Majors (ETH/BTC)** | Medium (n=1.5, moderate decay on strong trends) | Medium (moderate fees, high volume) | ✓ |
| **Alts/Meme** | High (n=0.5, fast decay on pumps/dumps) | High (wide curves, high fees, high emissions) | ✓ |

**Economic reality**: BONK LPs earn 5-10× fees of USDC LPs (due to tri-factor volatility/divergence multipliers) and 2-3× emissions (due to coverage factor in routing). In exchange, they accept liability decay risk if BONK pumps and reserves drain via arbitrage.

**This is fair** because:
- LPs **chose** the asset tier (high risk = high reward explicitly signaled)
- Decay is **predictable** (formula known, time-based, no surprises)
- LPs retain **agency** (can exit anytime at current coverage ratio, no lock)
- **Unit loss ≠ $ loss**: Even with 60% unit decay, LP may still profit in $ if price pumped enough (impermanent loss mechanics)

### Comparison to Isolated Pools

| Aspect | Isolated Pools | BAMM Liability Decay |
|--------|---------------|---------------------|
| **Permanent loss handling** | Isolate pool, LPs take instant loss | Gradual decay (weeks), time to exit |
| **Contagion protection** | 100% (full separation) | 95% (decay + circuit breakers) |
| **Capital efficiency** | Low (fragmented) | High (unified) |
| **LP income** | Narrow (single pool) | Broad (all pairs) |
| **Predictability** | Instant loss on crash | Time-released loss (formula-based) |
| **Exit fairness** | First-out LPs get best price | Pro-rata at all times |

**Why decay > isolation for single-pool**:
- Decay trades **immediate perfect isolation** for **10× capital efficiency** + **predictable gradual loss**
- Combined with circuit breakers (real-time) and tri-factor fees (economic), contagion is <5%
- LPs get **better risk-adjusted returns** (higher fees + emissions) in exchange for decay exposure

### Real-World Analogy: Bank Deposit Insurance vs Bail-In

**Isolated pools** = **Deposit insurance**:
- Each pool fully protected (FDIC-style)
- But: Requires protocol/treasury backing (unsustainable at scale)

**Liability decay** = **Bail-in** (Cyprus 2013):
- Depositors (LPs) in failing bank (underwater asset) take haircut
- Gradual vs instant (decay over weeks vs overnight)
- Healthy banks (other assets) unaffected

**Key difference**: BAMM decay is **predictable and opt-in** (LPs chose high-risk asset tier), unlike Cyprus surprise bail-in.

---

## Motivation

### The Bad Debt Problem

In ALM pools, each asset tracks:
- **Reserves** ($A_k$): Physical tokens held by the protocol
- **Liabilities** ($L_k$): Total LP claims (nominal value owed to LPs)
- **Coverage ratio** ($r_k = A_k / L_k$): Solvency measure

When asset prices move directionally (e.g., token crashes 50%), the pool becomes underwater:
$$r_k < 1.0 \implies \text{Liabilities exceed reserves}$$

Traditional solutions:
1. **Protocol subsidies** (inflationary, unsustainable)
2. **Withdrawal penalties** (punishes LPs, causes bank runs)
3. **Forced liquidations** (unpredictable, MEV-prone)

All create negative externalities or require ongoing protocol intervention.

### The Decay Solution

**Instead:** Gradually reduce liabilities $L_k$ over time when persistently underwater.

**Benefits:**
- ✅ **Predictable:** Time-based formula, no surprises
- ✅ **Self-healing:** Auto-stops when coverage recovers
- ✅ **Fair:** All LPs affected proportionally
- ✅ **Sustainable:** No protocol subsidies needed
- ✅ **Preserves agency:** LPs can exit anytime at current value

**Economic reality:** If an asset is 90% collateralized and stays there, LPs have *already* lost 10%. Decay just brings accounting in line with reality over time.

---

## Mathematical Specification

### Core Formula

$$L'_k(t) = L_0 \cdot \left[1 - \left(1 - \frac{A_k}{L_0}\right) \cdot \left(\frac{\Delta t}{T_{\text{max}}}\right)^n\right]$$

**Where:**
- $L'_k(t)$ = Decayed liability at time $t$
- $L_0$ = Initial liability when decay started
- $A_k$ = Current reserves (constant in formula)
- $\Delta t$ = Elapsed time since decay started
- $T_{\text{max}}$ = Time to reach terminal state (configurable per asset)
- $n$ = Decay exponent/amplification (controls curve shape)

**Terminal state** (at $t = T_{\text{max}}$):
$$L'_k(T_{\text{max}}) = A_k$$
$$r_k = \frac{A_k}{A_k} = 1.0 \ \text{(full debt absorption)}$$

### Decay Curve Shapes

The exponent $n$ controls front-loading vs back-loading:

| Exponent | Curve | First Week Decay | Use Case |
|----------|-------|------------------|----------|
| $n = 0.5$ | Convex (front-loaded) | High (rapid initial loss) | Meme tokens, high-risk assets |
| $n = 1.0$ | Linear | Constant | Medium-risk altcoins |
| $n = 1.5$ | Concave (back-loaded) | Low (gradual start) | ETH/BTC, major assets |
| $n = 2.0$ | Strongly concave | Very low (long grace period) | Stablecoins |

**Intuition:**
- **High risk assets** ($n < 1$): Front-load decay to realize losses quickly
- **Stable assets** ($n > 1$): Back-load decay to give more time for organic recovery

---

## LP Economics

### Withdrawable Value Invariant

**Key property:** When reserves are constant, LP withdrawable value **stays constant** during decay.

$$\text{withdrawableAmount} = \text{sharesPercent} \times L'_k(t) \times r_k(t)$$

Since:
$$r_k(t) = \frac{A_k}{L'_k(t)}$$

We have:
$$\text{withdrawableAmount} = \text{sharesPercent} \times L'_k(t) \times \frac{A_k}{L'_k(t)} = \text{sharesPercent} \times A_k = \text{constant}$$

**Example:**
```
t=0: A=900, L=1000, r=0.90
  LP with 10% shares:
    - Nominal claim: 0.10 × 1000 = 100
    - Coverage haircut: 90%
    - Withdrawable: 100 × 0.90 = 90 ✓

t=30d: Decay reduced L to 950
  LP with 10% shares:
    - Nominal claim: 0.10 × 950 = 95 (decay ate 5)
    - Coverage: 900/950 = 94.7%
    - Withdrawable: 95 × 0.947 = 90 ✓ (unchanged!)

t=T_max: Full decay, L=900
  LP with 10% shares:
    - Nominal claim: 0.10 × 900 = 90 (decay ate 10 total)
    - Coverage: 900/900 = 100%
    - Withdrawable: 90 × 1.00 = 90 ✓ (still unchanged!)
```

### What Decay Really Means

**Decay is NOT a new loss mechanism** - it's a **transparency mechanism**:

- **Without decay:** LP thinks they have 100 tokens, withdraws 90 (instant shock)
- **With decay:** LP sees nominal claim shrink from 100 → 90 over time, withdraws 90 (gradual realization)

**Same economic outcome, better UX.**

The loss was *already realized* when reserves fell below liabilities. Decay just brings accounting in line with reality over a predictable timeframe.

---

## Activation & Recovery

### Activation Conditions

Decay starts when:
1. Coverage ratio $r_k < r_{\text{threshold}}$ (e.g., 98%)
2. State snapshots:
   - $t_0 = \text{block.timestamp}$
   - $L_0 = L_k$ (current liabilities)
   - $r_0 = r_k$ (current coverage)

### Recovery Conditions

Decay stops when coverage recovers **sustainably**:

1. **Threshold crossing:** $r_k \geq r_{\text{threshold}}$
2. **Improvement requirement:** $r_k > r_0$ (must exceed start coverage)
3. **Time lockout:** Stays above threshold for $T_{\text{lockout}}$ (e.g., 24 hours)

**Flash loan protection:**
- Flash loans can't hold coverage elevated for 24 hours
- Improvement check prevents deposit without organic recovery
- Decay continues during lockout period

### State Machine

```
┌─────────┐  r < threshold   ┌──────────┐
│ NORMAL  ├─────────────────>│ DECAYING │
│ (r≥98%) │                  │ (r<98%)  │
└────▲────┘                  └────┬─────┘
     │                            │
     │  r≥threshold               │
     │  + improved                │
     │  + 24h lockout             │
     └────────────────────────────┘
```

---

## Implementation

### Configuration (Per-Asset)

```solidity
struct LiabilityDecayConfig {
    uint16 decayStartRatioBps;    // e.g., 9800 = 98%
    uint16 decayAmplification;    // n × 10000 (e.g., 15000 = 1.5)
    uint32 decayTMaxSeconds;      // e.g., 7776000 = 90 days
    uint32 recoveryLockout;       // e.g., 86400 = 24 hours
}
```

**Recommended settings:**

| Asset Class | Threshold | Amplification (n) | T_max | Lockout |
|-------------|-----------|-------------------|-------|---------|
| Stablecoins | 98% | 2.0 | 365 days | 24h |
| ETH/BTC | 98% | 1.5 | 180 days | 24h |
| Major alts | 95% | 1.0 | 90 days | 12h |
| Meme tokens | 90% | 0.5 | 30 days | 6h |

### State Tracking (Per-Asset)

```solidity
struct LiabilityDecayState {
    uint64 decayStartTime;        // 0 = inactive
    uint64 aboveThresholdSince;   // Recovery timer
    uint128 liabilityAtStart;     // L_0 snapshot
    uint64 coverageAtStart;       // r_0 snapshot (bps)
}
```

### Integration Points

Decay update must be called **before** any operation that modifies reserves or liabilities:

1. **Swaps:** Both `tokenIn` and `tokenOut` (base token only for direct swaps, not triangulated)
2. **Deposits:** Asset being deposited
3. **Withdrawals:** Asset being withdrawn

**Note**: In triangulated swaps (A → base → B), base reserves are virtual and unchanged, so base decay is not updated.
4. **Flash loans:** Borrowed asset

```solidity
// Example: At start of swap()
LiabilityDecay.update(tokenIn);
LiabilityDecay.update(tokenOut);
if (twoLegRoute) {
    LiabilityDecay.update(baseToken);
}
```

---

## Interaction with Other Mechanisms

### Coverage Ratio Haircut

Withdrawal payout formula (unchanged):
$$\text{payout} = \text{liabilityShare} \times \min(r_k, 1.0)$$

Since decay reduces liabilities:
- $L'_k \downarrow$ (liabilities decrease)
- $r_k = A_k / L'_k \uparrow$ (coverage improves)
- **Haircut decreases over time** (natural recovery)

**Key insight:** Haircut and decay are complementary, not additive:
- Haircut: Instant loss at withdrawal time
- Decay: Gradual nominal claim reduction

Net result: Same withdrawable amount (when reserves constant).

### Fee Accumulation

Swap fees accrue to reserves, partially offsetting decay:

$$\frac{dA_k}{dt} = \text{feeRate} \times \text{swapVolume}$$
$$\frac{dL'_k}{dt} = -\text{decayRate}(t)$$

**Net coverage change:**
$$\frac{dr_k}{dt} = \frac{1}{L'_k}\frac{dA_k}{dt} - \frac{A_k}{(L'_k)^2}\frac{dL'_k}{dt}$$

In a healthy pool:
- Fee accumulation ≥ Decay losses
- Coverage naturally recovers above threshold
- Decay auto-stops after lockout

### Arbitrage Incentives

As decay progresses:
1. Coverage ratio $r_k$ improves (liabilities shrink)
2. Asset becomes "cheaper" relative to others (lower liability burden)
3. Arbitrageurs profit from rebalancing trades
4. Reserves increase, accelerating recovery

**Positive feedback loop:** Decay creates natural rebalancing pressure.

---

## Security Considerations

### Flash Loan Resistance

**Attack Vector 1:** Deposit large amount to stop decay

**Mitigation:**
- Improvement check: $r_{\text{current}} > r_{\text{start}}$
- Time lockout: 24 hours above threshold
- **Result:** Flash loan physically cannot satisfy both conditions

**Attack Vector 2:** Repeated start/stop cycling

**Mitigation:**
- Recovery timer resets if coverage falls back down
- Attacker must sustain capital for 24+ hours
- **Result:** Economically unviable (opportunity cost > profit)

**Attack Vector 3:** Frontrun terminal state

**Mitigation:**
- Decay continues during lockout period
- Terminal state still reached if $t \geq T_{\text{max}}$
- **Result:** Attacker can't skip final decay phase

See [`FLASH_LOAN_ATTACK_ANALYSIS.md`](../FLASH_LOAN_ATTACK_ANALYSIS.md) for detailed analysis.

### Invariants

**Must hold at all times:**

1. **Monotonicity:** $L'_k(t_2) \leq L'_k(t_1)$ for $t_2 > t_1$
2. **Terminal floor:** $L'_k(t) \geq A_k$ always
3. **Coverage bounds:** $0 \leq r_k \leq \max(r_{\text{threshold}}, 1.0)$
4. **Lockout integrity:** State changes only after lockout expires
5. **Withdrawal payout:** LP receives $\text{shares} \times L'_k \times r_k$

---

## Events

```solidity
event LiabilityDecayStarted(
    address indexed token,
    uint256 liabilityAtStart,
    uint256 coverageAtStart,  // WAD precision
    uint256 timestamp
);

event LiabilityDecayStopped(
    address indexed token,
    uint256 finalLiability,
    uint256 finalCoverage,
    uint256 timestamp
);

event LiabilityDecayApplied(
    address indexed token,
    uint256 oldLiability,
    uint256 newLiability,
    uint256 coverage,
    uint256 elapsed
);
```

---

## View Functions

### getEffectiveCoverage(token)

Returns current coverage ratio **after** applying decay (without modifying state).

```solidity
function getEffectiveCoverage(address token)
    external view returns (uint256 coverageBps);
```

### predictLPValue(token, shares, futureTimestamp)

Predicts LP withdrawable value at a future timestamp, accounting for decay.

```solidity
function predictLPValue(
    address token,
    uint256 lpShares,
    uint256 futureTimestamp
) external view returns (uint256 value);
```

**Use case:** UI can show LPs their projected value if they wait vs withdraw now.

### getDecayInfo(token)

Returns full decay status for monitoring/UI.

```solidity
function getDecayInfo(address token) external view returns (
    bool active,              // Is decay currently active?
    uint256 progress,         // 0 to 1e18 (0% to 100%)
    uint256 remainingTime,    // Seconds until terminal state
    uint256 elapsedTime,      // Seconds since decay started
    uint256 initialCoverage,  // Coverage when decay started (bps)
    uint256 currentCoverage   // Current coverage (bps)
);
```

---

## Example Scenarios

### Scenario 1: Stablecoin Depeg (Temporary)

**Setup:**
- USDC depegs to $0.92 (8% loss)
- Pool: 920K USDC reserves, 1M USDC liabilities
- Config: threshold 98%, n=2.0, T_max=365d, lockout=24h

**Timeline:**
```
Day 0: Depeg occurs
  - Coverage: 92% (< 98% threshold)
  - Decay starts
  - L_0 = 1M, r_0 = 92%

Day 1-3: Slow decay (n=2.0 is back-loaded)
  - L' ≈ 999K (minimal decay)
  - Coverage ≈ 92.1%

Day 7: USDC repegs to $1.00
  - Arbitrageurs trade in USDC
  - Reserves climb to 980K via fees
  - Coverage: 980K / 999K = 98.1% (> threshold)
  - Improvement: 98.1% > 92% ✓
  - Recovery timer starts

Day 8: Sustained above threshold for 24h
  - Decay stops
  - Final state: L'=999K, r=98.1%
  - LPs recovered 98.1% of original value
```

**Outcome:** Minimal decay occurred, organic recovery succeeded.

### Scenario 2: Altcoin Crash (Permanent)

**Setup:**
- MATIC crashes from $1 to $0.40 (60% loss)
- Pool: 400K MATIC reserves, 1M MATIC liabilities
- Config: threshold 95%, n=1.0, T_max=90d, lockout=12h

**Timeline:**
```
Day 0: Crash occurs
  - Coverage: 40% (< 95% threshold)
  - Decay starts
  - L_0 = 1M, r_0 = 40%

Day 30: Linear decay (n=1.0)
  - Progress: 30/90 = 33.3%
  - Decay amount: (1M - 400K) × 0.333 = 200K
  - L' = 1M - 200K = 800K
  - Coverage: 400K / 800K = 50%

Day 60:
  - Progress: 66.7%
  - L' = 600K
  - Coverage: 400K / 600K = 66.7%

Day 90: Terminal state
  - L' = 400K (full decay)
  - Coverage: 400K / 400K = 100%
  - LPs realize 60% loss (absorbed via decay)
```

**Outcome:** LPs bear the full loss over 90 days (predictable, gradual).

---

## Governance Considerations

### Parameter Updates

**Can be updated:**
- $T_{\text{max}}$ (time to terminal state)
- $n$ (amplification/curve shape)
- $T_{\text{lockout}}$ (recovery lockout period)

**Cannot be updated mid-decay** (to prevent manipulation):
- $r_{\text{threshold}}$ (decay start ratio)
- Once decay active, config frozen until it stops

**Emergency actions:**
- Freeze asset (stops all trading, including decay updates)
- Manual decay override (governance multisig only, for critical bugs)

### Monitoring Requirements

**Must monitor:**
1. Active decay assets (alerts when decay starts)
2. Progress towards terminal state (dashboard)
3. Recovery lockout status (transparency for LPs)
4. Fee accumulation vs decay rate (pool health)

---

## References

1. [Wombat Exchange Whitepaper](https://www.wombat.exchange/Wombat_Whitepaper_VolatilePoolAMM.pdf) - Coverage ratio ALM model
2. [Gyroscope Thesis](https://www.placeholder.vc/blog/2022/10/27/gyroscope-thesis) - Sustainable stablecoin design without subsidies
3. [Dynamic AMM Fee Research](https://www.opengradient.ai/blog/dynamic-amm-fee-research) - Fee-driven pool rebalancing
4. [Flash Loan Attack Analysis](../FLASH_LOAN_ATTACK_ANALYSIS.md) - Detailed security analysis

---

## Appendix: Solidity Implementation

See:
- [`LibLiabilityLiabilityDecay.sol`](../contracts/src/libraries/LibLiabilityLiabilityDecay.sol) - Core decay logic
- [`BAMM.sol`](../contracts/src/bamm/BAMM.sol) - Integration into swap/deposit/withdraw
- [`IBAMM.sol`](../contracts/src/interfaces/IBAMM.sol) - Config and state structs

**Key functions:**
- `update(token)` - State machine & decay application
- `calculateDecayedLiability()` - Pure function for decay formula
- `getEffectiveCoverage()`, `predictLPValue()`, `getDecayInfo()` - View functions
