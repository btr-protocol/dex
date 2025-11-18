# BAMM Tokenomics - BTR Token Model

## Overview

This document specifies the tokenomics design for the BTR governance token, designed for the BAMM DEX protocol featuring:

- **One-sided liquidity** (single-token LP deposits)
- **Coverage ratio-based ALM** (Wombat/Platypus inspired)
- **Composable staked positions** (transferable sLP and sBTR tokens)
- **Simple staking mechanics** (instant stake, cooldown-based unstake)
- **Unified governance & earning model** (same BTR-coverage formula for both)
- **Per-asset emission routing** (coverage × utilization weighted, linear TVL)
- **Sustainable emissions** (exponential decay, Velodrome-style, ~3-year half-life)
- **Pure buyback-and-burn** (70% of revenue, deflationary long-term)

---

## Table of Contents

1. [Core Principles](#core-principles)
2. [Token Supply & Allocation](#token-supply--allocation)
3. [Staking Mechanics](#staking-mechanics)
4. [Unified Governance & Earning Model](#unified-governance--earning-model)
5. [Emissions Schedule](#emissions-schedule)
6. [Per-Asset Emission Routing](#per-asset-emission-routing)
7. [Utilization Measurement](#utilization-measurement)
8. [Value Accrual Mechanism](#value-accrual-mechanism)
9. [Reward Distribution](#reward-distribution)
10. [Parameters & Tuning](#parameters--tuning)
11. [Implementation Considerations](#implementation-considerations)
12. [Security & Attack Vectors](#security--attack-vectors)

---

## Core Principles

### Design Goals

1. **Simplicity** - Linear formulas, no ve-locks or gauge voting, unified earning/voting model
2. **Composability** - Fungible, transferable sLP and sBTR (ERC20/4626), Pendle/lending compatible
3. **Fair alignment** - Community-first allocation (65% emissions, no VCs), strict team vesting (5yr)
4. **Sustainability** - Exponential decay emissions (Velodrome-style, 3yr half-life), buyback-burn from real revenue
5. **Anti-inflationary** - Hard 100M cap, 70% buyback-burn, tail emissions governance-controlled
6. **Incentive efficiency** - Per-asset routing (coverage × utilization), not just TVL or idle capital

### Philosophy

**"Emissions should reward productive liquidity where it's needed, not just deposits; governance and earning power should use the same alignment mechanism."**

Unlike traditional liquidity mining that pays purely for TVL, or ve-models that force 4-year locks, BTR:
- Routes emissions **per-asset** based on coverage need and utilization (volume/TVL)
- Uses **linear TVL weighting** (no sqrt bias against smaller pools)
- Applies a **unified BTR-coverage formula** for both voting power and earning multipliers
- Employs **soft locks** (cooldown) instead of hard time-locks for better UX and composability
- Accrues value via **buyback-burn** instead of dividends (simpler, more tax-efficient, price-supportive)

---

## Token Supply & Allocation

### Supply Cap

```
Total Supply: 100,000,000 BTR (100 million)
```

**Hard cap** - Immutable, cannot be increased without 67% supermajority governance vote (highly contentious).

### Allocation Breakdown

| Category | Allocation | Tokens | Vesting | Notes |
|----------|-----------|---------|---------|-------|
| **Emissions** | 65% | 65,000,000 BTR | ~10yr exponential decay | 90% to sLP, 5% to sBTR, 5% emissions-treasury |
| **Treasury** | 20% | 20,000,000 BTR | Unlocked (DAO) | Grants, POL, operations, emergency reserves |
| **Team & Advisors** | 12% | 12,000,000 BTR | 5yr linear, 6mo cliff | 15% unlock at cliff, 85% over 54mo |
| **LBP (Public Sale)** | 3% | 3,000,000 BTR | Immediate | Fair-launch price discovery |

**Key points:**
- **No VCs**: 0% investor allocation (bootstrapped, community-first)
- **65% to users**: Largest allocation to emissions (vs 40-60% industry average)
- **12% team**: Conservative (vs 15-20% industry), with **5-year vest** (vs 3-4yr standard)
- **3% LBP**: Minimal public sale, majority distributed via emissions over 10 years

**Detailed allocation & vesting**: See [ALLOCATION_AND_VESTING.md](./ALLOCATION_AND_VESTING.md)

### Emission Timeline (65M BTR)

Emission split:
- **90%** → sLP holders (58.5M BTR)
- **5%** → sBTR stakers (3.25M BTR)
- **5%** → Emissions treasury (3.25M BTR, for airdrops/campaigns)

**Exponential decay schedule** (Velodrome-inspired):

```
E_{t+1} = E_t × r
```

Where:
- $E_t$: emissions for epoch $t$ (weekly epochs)
- $r$: decay rate per epoch (governance parameter, stored as `decayRateBps`)

**Default calibration** (3-year half-life):
```
Target half-life: T_1/2 = 3 years = 156 weeks
Decay rate: r = 2^(-1/156) ≈ 0.9956
As BPS: decayRateBps = 9956 (0.44% weekly decay)
```

**Illustrative emission trajectory** (with $E_0 = 150,000$ BTR/week, calibrated for ~65M over 10 years):

```
Year 1:    ~7.8M BTR  → 150,000 BTR/week declining to ~128,000
Year 2:    ~6.7M BTR  → ~128,000 declining to ~109,000
Year 3:    ~5.7M BTR  → ~109,000 declining to ~93,000
Year 4-5:  ~8.9M BTR  → ~93,000 declining to ~67,000
Year 6-10: ~36M BTR   → ~67,000 declining to ~18,000
Year 10+:  Tail emissions (governed)
```

**Hard cap enforcement**:
```solidity
cumulativeEmitted += currentEmission
require(cumulativeEmitted <= 65_000_000e18, "Emission cap exceeded")
```

Once cumulative emissions approach 65M, the final epoch is truncated.

**Governance control**:
- Single parameter: `decayRateBps` (default 9956 = 0.44% weekly decay)
- Allowed range: 9900-9990 (0.1%-1.0% weekly decay)
  - Lower bound (9900): ~0.7 year half-life (rapid decay)
  - Upper bound (9990): ~13 year half-life (slower decay)
- Hard cap (65M) is immutable; governance adjusts decay rate only

**Rationale**:
- **Simpler on-chain**: One multiply per epoch vs stepped halving logic
- **Governance flexibility**: Single knob (`r`) tunes front-loading without changing total allocation
- **Proven model**: Velodrome's 1% weekly decay, adapted to 0.44% for 3-year half-life
- **Smooth curve**: No discontinuous jumps (halving boundaries)
- **Safety**: Cumulative cap prevents over-emission regardless of decay parameter

---

## Staking Mechanics

### Design: Liquid Staking Standard with Parametric Unlock

**Pattern**: Industry-standard liquid staking following Ethena (sUSDe, sENA) and Aave (stkAAVE) models - fungible, transferable receipt tokens with **parametric unlock periods** (no hard time-locks, no redemption windows).

**Critical Implementation Requirements:**

| Token State | Transferable? | Earns Emissions? | Voting Rights? | Notes |
|-------------|--------------|------------------|----------------|-------|
| **Active sLP/sBTR** | ✅ YES | ✅ YES | ✅ YES | Normal staked tokens |
| **Pending redemption (locked)** | ❌ NO | ❌ NO | ❌ NO | Awaiting unlock timestamp |
| **Pending redemption (unlocked)** | ❌ NO | ❌ NO | ❌ NO | Ready to claim, no expiry |

Once `requestUnstake()` is called, tokens immediately lose ALL benefits (emissions, voting, transferability) regardless of whether they are still locked or already unlocked. This differs from Aave which has a redemption window expiry—we do NOT expire unlocked redemptions.

**Why this model:**
- **No ve-tokenomics**: No 4-year locks, no decay mechanics, no NFT positions
- **Liquid staking receipts**: ERC20/4626 tokens that accrue value while staked
- **Parametric unlock**: Governance-adjustable cooldown period (1 day to 1 year, default 21 days)
- **No redemption windows**: Unlike Aave's 48-hour claim window, unlocked tokens remain claimable indefinitely
- **Composable**: Fungible receipts integrate with Pendle, lending markets, aggregators
- **Still aligned**: Cooldown creates friction against instant arbitrage while preserving transferability
- **Future-proof**: Transferability enables secondary markets and protocol integrations

**Key implementation standards:**
- **Active staked tokens (sLP/sBTR)**: Transferable, earn emissions, grant voting rights
- **Tokens pending redemption**: NOT transferable, DO NOT earn emissions, DO NOT grant voting rights
  - This applies to both locked (awaiting unlock) and unlocked (ready to claim) pending tokens
  - Once `requestUnstake()` is called, tokens enter redemption queue and lose all benefits
  - No redemption window expiry: unlocked tokens can be claimed anytime (no re-locking)

### LP Staking (LP → sLP)

**Instant staking:**
```solidity
function stakeLP(uint256 poolId, uint256 assetId, uint256 amount)
    external returns (uint256 sLPAmount)
```

- **1:1 conversion** at stake time: `1 LP = 1 sLP`
- **Rebasing** via liquidity index (same as underlying LP tokens)
- **Per-asset sLP**: Each pool/asset combination has separate sLP token (ERC20 or ERC4626)
- **Transferable**: Full composability with DeFi ecosystem
- **Earnings**: BTR emissions based on per-asset weight (coverage × utilization × TVL)

**Unstaking with parametric unlock:**
```solidity
function requestUnstake(uint256 sLPAmount) external returns (uint256 requestId)
function claimUnstake(uint256 requestId) external returns (uint256 lpAmount)
function cancelUnstake(uint256 requestId) external  // Optional: cancel and restore to active stake
```

**Unlock parameters** (governance-adjustable):
- **Default unlock period**: 21 days (3 weeks)
- **Allowed range**: 1 day to 1 year (365 days)
- **Initial conservative setting**: 21 days balances security vs UX

**Redemption lifecycle**:
1. **Active stake**: sLP is transferable, earns emissions, grants voting rights
2. **Request unstake**: User calls `requestUnstake(amount)`, receives `requestId`
   - sLP amount is burned immediately
   - Redemption request enters queue with unlock timestamp = `block.timestamp + unlockPeriod`
3. **Pending redemption (locked)**: `block.timestamp < unlockTimestamp`
   - **NOT transferable** (request is user-specific)
   - **NO emissions eligibility** (no longer staked)
   - **NO voting rights** (inactive)
4. **Pending redemption (unlocked)**: `block.timestamp >= unlockTimestamp`
   - Same restrictions as locked: **NOT transferable, NO emissions, NO voting**
   - **No expiry**: Can claim anytime (unlike Aave's 48-hour redemption window)
   - **No re-locking**: Unlocked requests stay unlocked until claimed
5. **Claim**: User calls `claimUnstake(requestId)`, receives underlying LP tokens

**Security benefits**:
- Prevents flash-loan governance attacks (21-day minimum lock)
- Reduces same-block stake → vote → unstake arbitrage
- Longer default than typical 7-day protocols for added security
- **Soft lock**: Not a hard time-lock; users can initiate unstake anytime, just wait cooldown to claim

**Why transferable sLP (active stakes only):**
- Pendle integration (yield tokenization, PT/YT splitting)
- Lending collateral (borrow against sLP positions)
- Secondary market liquidity (exit via DEX if unwilling to wait 21-day unlock)
- **Risk mitigation**: Utilization-weighted emissions mean idle sLP earns less; 21-day unlock creates significant friction
- **Note**: Only active sLP is transferable; pending redemptions are NOT transferable

### BTR Staking (BTR → sBTR)

**Instant staking:**
```solidity
function stakeBTR(uint256 amount) external returns (uint256 sBTRAmount)
```

- **1:1 conversion** at stake time
- **Rebasing** via staking index (accumulates BTR emissions from 5% sBTR slice)
- **Composable** - sBTR is ERC20 and transferable
- **Dual purpose**:
  1. Direct earning: 5% of total emissions distributed pro-rata to sBTR
  2. Boost mechanism: sBTR up to 1/M (default 1/5) of sLP value boosts LP earning power

**Unstaking with parametric unlock:**
```solidity
function requestUnstake(uint256 sBTRAmount) external returns (uint256 requestId)
function claimUnstake(uint256 requestId) external returns (uint256 btrAmount)
function cancelUnstake(uint256 requestId) external  // Optional: cancel and restore to active stake
```

**Unlock parameters** (same as sLP):
- **Default unlock period**: 21 days (3 weeks)
- **Allowed range**: 1 day to 1 year (365 days)
- **Shared governance parameter**: Both sLP and sBTR use same `unlockPeriod` for consistency

**Redemption lifecycle** (identical to sLP):
1. **Active stake**: sBTR is transferable, earns emissions, grants voting rights, provides LP boost
2. **Request unstake**: User calls `requestUnstake(amount)`, receives `requestId`
   - sBTR amount is burned immediately
   - Redemption request enters queue with unlock timestamp
3. **Pending redemption (locked)**: `block.timestamp < unlockTimestamp`
   - **NOT transferable**
   - **NO sBTR emissions**
   - **NO voting rights**
   - **NO LP boost** (sBTR value no longer counts for coverage multiplier)
4. **Pending redemption (unlocked)**: `block.timestamp >= unlockTimestamp`
   - Same restrictions: **NOT transferable, NO emissions, NO voting, NO boost**
   - **No expiry**: Can claim anytime (no redemption window)
   - **No re-locking**: Unlocked requests stay unlocked until claimed
5. **Claim**: User calls `claimUnstake(requestId)`, receives underlying BTR tokens

**Why transferable sBTR (active stakes only):**
- Fungibility (easier to track, integrate, trade than veNFTs)
- Liquidity for long-term holders (secondary market exit option)
- Simpler mental model than ve-decay or position-specific NFTs
- **Risk mitigation**: Coverage-based earning boost caps at 1:1 LP value (no unbounded multipliers)
- **Note**: Only active sBTR is transferable; pending redemptions are NOT transferable

---

## Unified Governance & Earning Model

### Design: Same Formula for Voting Power and Earning Multiplier

**Key innovation**: Instead of separate logic for governance power and emission multipliers, BTR uses a **single BTR-coverage formula** that drives both:
1. How much of a wallet's LP "counts" for voting
2. How much of a wallet's LP "counts" for emissions

This dramatically simplifies the mental model and eliminates edge cases.

### BTR Coverage Formula

For wallet $j$:

Let:
- $V^{LP}_j$: total dollar value of all sLP positions
- $V^{BTR}_j$: dollar value of sBTR holdings

Define **BTR coverage fraction** with multiplier $M$ (default 5):

$$
f_j =
\begin{cases}
  0, & V^{LP}_j = 0 \\
  \min\left(1,\ \frac{M \cdot V^{BTR}_j}{V^{LP}_j}\right), & V^{LP}_j > 0
\end{cases}
$$

**Interpretation**: $1 of sBTR can "cover" up to $M (default $5) of LP value.

Define **LP multiplier** using base and max weights:
- $w_{\min}$: uncovered LP multiplier (default 0.5 or 0.75)
- $w_{\max}$: fully covered LP multiplier (fixed at 1.0)

$$
m^{LP}_j = w_{\min} + (w_{\max} - w_{\min}) \cdot f_j
$$

**Properties**:
- No sBTR: $f_j = 0$ → $m^{LP}_j = w_{\min}$ (e.g., 0.5)
- Sufficient sBTR ($V^{BTR}_j \geq V^{LP}_j / M$): $f_j = 1$ → $m^{LP}_j = 1$
- Partial coverage: linear interpolation

**Example** (with $M = 5$, $w_{\min} = 0.5$):
```
Alice:
  - $50,000 sLP
  - $10,000 sBTR

Coverage check: M × V^BTR = 5 × $10,000 = $50,000 ≥ V^LP ($50,000)
  → f_Alice = 1 (fully covered)
  → m^LP_Alice = 0.5 + 0.5 × 1 = 1.0

Bob:
  - $50,000 sLP
  - $0 sBTR

  → f_Bob = 0
  → m^LP_Bob = 0.5

Alice's LP earns 2× per dollar compared to Bob's LP (1.0 vs 0.5).
```

### Voting Power with Unified Formula

Wallet $j$'s total voting power:

$$
PV_j = V^{BTR}_j + m^{LP}_j \cdot V^{LP}_j
$$

**Components**:
1. **sBTR direct vote**: $V^{BTR}_j$ (1:1 dollar voting power)
2. **sLP boosted vote**: $m^{LP}_j \cdot V^{LP}_j$ (LP value multiplied by coverage factor)

**Example** (continuing from above):
```
Alice: PV_Alice = $10,000 + 1.0 × $50,000 = $60,000 voting power
Bob:   PV_Bob = $0 + 0.5 × $50,000 = $25,000 voting power

Alice has 2.4× Bob's voting power despite same LP value.
```

**Extremes**:
- **LP-only governance**: Wallet with only sLP gets discounted vote ($w_{\min} \times V^{LP}$), but non-zero
- **BTR-only governance**: Wallet with only sBTR gets full 1:1 vote, no LP needed
- **Combined**: LP + sufficient BTR maximizes voting power

**Why this is clean**:
- Linear formula (no max/min nesting complexity)
- Single "coverage" concept unifies voting and earning
- Easy to reason about: "stake BTR = 1/M of my LP to maximize both voting and earnings"
- Governed parameters: $M$, $w_{\min}$, $w_{\max}$ (all simple scalars)

### Earning Power with Same Formula

For each asset $(i,k)$ where wallet $j$ holds sLP of value $V_{j,i,k}$:

**Effective reward stake**:
$$
R_{j,i,k} = V_{j,i,k} \cdot m^{LP}_j
$$

**Per-asset emission share**:
$$
\text{reward}_{j,i,k} = E^{asset}_{t,i,k} \cdot \frac{R_{j,i,k}}{\sum_{\ell} R_{\ell,i,k}}
$$

Where $E^{asset}_{t,i,k}$ is the total BTR emission allocated to asset $(i,k)$ in epoch $t$ (see next section).

**Intuition**:
- Same $m^{LP}_j$ that boosts voting also boosts earnings
- Wallet with no sBTR earns $w_{\min}$ per dollar of LP (e.g., 0.5× baseline)
- Wallet with sBTR ≥ LP/M earns 1.0× per dollar of LP (2× compared to uncovered)
- Extra sBTR beyond full coverage only increases sBTR's own 5% emission share and direct voting power, not LP boost (prevents N× exploits)

### Governance Scope

**All token holders (sLP + sBTR) vote on**:
- Asset listings (add/remove pools)
- Fee parameter adjustments (tri-factor model coefficients)
- Oracle configuration (window lengths, staleness thresholds)
- Protocol upgrades (implementation contracts, emergency actions)
- Treasury spending (budgets, grants, POL deployment)
- Emission routing parameters (coverage/utilization factors)
- Revenue routing (buyback % vs treasury %)

**sBTR-weighted votes** (require higher sBTR participation):
- BTR tokenomics changes (supply cap, emission curve parameters)
- Coverage multiplier $M$ adjustments
- LP multiplier bounds ($w_{\min}$, $w_{\max}$)
- Staking cooldown period changes

**Governance thresholds**:
- **Simple majority** (>50% of votes): Parameter tuning, treasury budgets, routine adjustments
- **Supermajority** (≥67%): Supply cap, protocol upgrades, emergency powers

**Rationale**:
- Unified model prevents governance/earning power misalignment
- LPs still have meaningful governance even without BTR (via $w_{\min} > 0$)
- BTR holders control tokenomics (supply, emissions, their own incentives)
- Combined alignment: protocol success benefits both LPs (fees) and BTR holders (buyback appreciation)

---

## Emissions Schedule

### Already Covered Above

See "Token Supply & Allocation" section for:
- Total emissions: 65M BTR over ~10 years
- Emission split: 90% sLP / 5% sBTR / 5% emissions-treasury
- Halving formula: $E_t = E_0 \cdot h^{\lfloor t/H \rfloor}$
- Example schedule with $E_0 \approx 62,500$ BTR/week

This section focuses on **how** those emissions are distributed **per-asset** (for sLP) and **per-user** (for sBTR).

---

## Per-Asset Emission Routing

### Design: Per-Asset Coverage × Utilization, Linear TVL

**Key change from initial spec**: Emissions are routed **per-asset** (not per-pool), using **linear TVL weighting** (not sqrt), to avoid systematic bias against smaller but equally healthy assets.

### Per-Asset Metrics

Index pools by $i$ and assets within pools by $k$.

For each asset $(i,k)$:

**Coverage ratio** (from ALM):
$$
r_{i,k} = \frac{A_{i,k}}{L_{i,k}}
$$

Where:
- $A_{i,k}$: asset value (reserves) in pool $i$
- $L_{i,k}$: liabilities (sum of LP claims) in pool $i$

**Coverage factor** (incentivize underwater assets):
$$
C_{i,k} =
\begin{cases}
  1 + \kappa (1 - r_{i,k}), & r_{i,k} < 1 \\
  1, & r_{i,k} \geq 1
\end{cases}
$$

With $\kappa$ capped so $C_{i,k} \leq C_{\max}$ (e.g., 2.0) to avoid perverse incentives around deeply insolvent assets.

**Typical values**:
```
C = 1.05:  coverage_factor = 1.0 (healthy)
C = 0.95:  coverage_factor ≈ 1.05 (slight boost)
C = 0.80:  coverage_factor ≈ 1.2 (moderate boost)
C = 0.70:  coverage_factor ≈ 1.3 (capped at C_max if needed)
C = 0.50:  coverage_factor = 2.0 (max, severely underwater)
```

**Per-asset utilization** (simplest version):
$$
u_{i,k} = \frac{\text{volume involving asset } k \text{ in pool } i}{\text{TVL}_{i,k}}
$$

Over a rolling window (e.g., 24-168 hours).

**Utilization factor** (saturating to cap impact):
$$
U_{i,k} = 1 + \lambda \cdot \frac{u_{i,k}}{u_{i,k} + u_0}
$$

Where $\lambda$ and $u_0$ are chosen so high utilization yields 1.5-2× uplift but cannot dominate coverage.

**Typical parameters**: $\lambda = 1$, $u_0 = 0.5$ (50% utilization → 1.67× factor, 100% → 1.83×, asymptote at 2×).

### Per-Asset Weight

Final per-asset weight:
$$
w_{i,k} = C_{i,k} \cdot U_{i,k}
$$

This is a **pure multiplier** applied to TVL (no sqrt or other non-linearity).

### Per-Asset Emission Allocation

Let $E_t$ = total epoch emissions, and $E^{LP}_t = \alpha_{LP} E_t$ (e.g., 90% of $E_t$).

Per-asset share:
$$
s_{i,k} = \frac{w_{i,k} \cdot \text{TVL}_{i,k}}{\sum_{j,m} w_{j,m} \cdot \text{TVL}_{j,m}}
$$

Per-asset emission:
$$
E^{asset}_{t,i,k} = E^{LP}_t \cdot s_{i,k}
$$

**Properties**:
- **Linear TVL**: Emissions scale exactly with "urgency-adjusted TVL"
- **Fair to small assets**: A \$100K asset with 2× urgency ($w = 2$) gets exactly 2× emissions per dollar vs a \$100K asset with 1× urgency, regardless of pool size
- **No sqrt bias**: Eliminates the structural under-payment of smaller pools present in sqrt models

**Example**:
```
Asset A: C = 1.0, U = 1.5, TVL = $1M
  → w_A = 1.0 × 1.5 = 1.5
  → weighted_TVL_A = 1.5 × $1M = $1.5M

Asset B: C = 1.3, U = 1.2, TVL = $500K
  → w_B = 1.3 × 1.2 = 1.56
  → weighted_TVL_B = 1.56 × $500K = $780K

Total weighted TVL = $1.5M + $780K = $2.28M

If E^LP_t = 50,000 BTR:
  E^asset_A = 50,000 × ($1.5M / $2.28M) ≈ 32,895 BTR
  E^asset_B = 50,000 × ($780K / $2.28M) ≈ 17,105 BTR

Asset B gets higher emissions per dollar ($17,105 / $500K = 0.0342) than Asset A ($32,895 / $1M = 0.0329) because it has higher urgency (coverage × utilization), despite being half the size.
```

### Why Per-Asset (Not Per-Pool)

**Per-pool utilization** is too coarse:
- An under-used asset in a very active pool could ride on other assets' activity
- Doesn't align with per-asset ALM (coverage is tracked per-asset)

**Per-asset utilization** is more precise:
- Directly measures "how busy is this specific asset"
- Consistent with coverage ratio (also per-asset)
- One extra counter per asset (volume), which is manageable

**Hybrid** (pool-level $U_i$ × per-asset volume share) adds complexity without major benefit; reserved for future refinement if needed.

### Minimum Emission Floor (Optional)

**Problem**: New or very low-utilization assets get near-zero emissions (cold-start problem).

**Solution**: Governance can set a minimum emission floor per asset (e.g., 0.1-0.5% of total daily emissions).

```
E^asset_{t,i,k} = max(E^LP_t · s_{i,k}, MIN_FLOOR)
```

**Trade-off**: Helps bootstrap new assets but dilutes efficiency-based routing; use sparingly or only for strategic assets.

---

## Utilization Measurement

### Design: Timestamp-Weighted EMA (Not TWAP Accumulator)

**Decision**: Use an **exponential moving average (EMA)** for utilization instead of a TWAP-style accumulator (like the price oracle).

**Rationale**:
- **Price oracles** (InternalOracle.sol) use TWAP accumulators because price manipulation can cause insolvency in lending/derivatives—strong time-weighting and manipulation resistance are critical
- **Utilization oracles** control *where to send emissions*, not solvency thresholds—worst case is over-farming a given asset by generating fake volume and paying fees
- Economics (fees) and caps (max utilization factor $U_{\max}$) provide primary protection against wash-trading, not oracle design
- EMA is simpler (one value + timestamp vs accumulator + snapshots) and sufficient for this use case

### Timestamp-Dependent EMA

For each asset $(i,k)$, maintain:
- `emaUtil`: current EMA value (fixed-point, e.g., 1e18)
- `lastUpdate`: timestamp of last update

On every swap affecting asset $k$ (or periodic poke):

1. Compute $\Delta t = $ `block.timestamp - lastUpdate`
2. Compute decay factor: $\text{decay} = e^{-\Delta t / \tau}$ (approximate in fixed-point or use lookup table)
3. Compute current raw utilization $u_{i,k}(t)$ for this step (e.g., volume in last $\Delta t$ / TVL)
4. Update:
   $$
   \text{emaUtil}_{\text{new}} = \text{emaUtil}_{\text{old}} \cdot \text{decay} + u_{i,k}(t) \cdot (1 - \text{decay})
   $$
5. Set `lastUpdate = block.timestamp`

**Time constant** $\tau$ (governance parameter):
- **Short** (e.g., 1 day): Responsive to recent activity, but more manipulable
- **Medium** (e.g., 3-7 days): Good balance between responsiveness and smoothing
- **Long** (e.g., 14+ days): Very stable, but slow to react to real demand shifts

**Default**: $\tau = 7$ days (1 week)

### Why Not Use Accumulators for Utilization?

**TWAP accumulators** (like Uniswap v3 price oracle):
- Provide exact time-weighting over fixed windows
- Robust to update frequency bias
- Best practice for **price oracles** where manipulation = insolvency

**For utilization**:
- No "ground truth" external price; utilization is inherently internal (volume / TVL)
- Attackers can generate high utilization via wash-trading regardless of oracle design (paying fees each time)
- Main defenses: economic cost (fees), caps ($U_{\max}$), and emissions bounded by coverage too
- TWAP adds complexity (snapshots, window management) with little extra security vs EMA

**Conclusion**: EMA is appropriate for utilization; save accumulators for critical price feeds.

### Implementation Notes

**Gas cost**: One `SLOAD` (emaUtil + lastUpdate), compute decay (can be approximated or cached for common $\Delta t$ ranges), one `SSTORE`. Very cheap on L2.

**Volume tracking**: Simplest approach is to track cumulative volume per asset and compute $u_{i,k}(t) = \Delta \text{volume} / \Delta t / \text{TVL}$ at each update, or use a secondary EMA for volume rate.

**Staleness**: If no swaps for a long time, utilization EMA should decay toward zero. Can be implemented by "poking" the EMA with $u = 0$ before using it in emission calculations.

---

## Value Accrual Mechanism

### Decision: Pure Buyback-and-Burn (No Fee Sharing)

**Model**: 70% of net protocol revenue → buyback BTR and burn; 30% → treasury (non-BTR assets).

**Why buyback-burn over dividends:**

| Aspect | Buyback-Burn | Fee Sharing (Dividends) |
|--------|-------------|------------------------|
| **Tax treatment** | Capital gains (more efficient) | Income (immediate tax) |
| **Sell pressure** | Creates buy pressure | Creates sell pressure (claim + sell) |
| **Implementation** | Simple (swap + burn) | Complex (per-user accounting, distribution) |
| **Benefit distribution** | All holders equally | Large holders disproportionately |
| **Narrative** | Deflationary, scarcity | Real yield, income |
| **Empirical success** | PancakeSwap, Hyperliquid | Curve (diluted by inflation), Yield Basis |

**Conclusion**: Buyback-burn aligns with best-in-class 2024-2025 tokenomics (PancakeSwap v3, Hyperliquid), is simpler to implement, and more tax-efficient for most users.

### Revenue Routing

**Protocol fee sources** (see [FEES.md](./FEES.md)):
- **Swap fees**: 10% of swap fees go to protocol (rest to LPs)
- **Withdrawal fees**: 50% of withdrawal haircut (coverage-based) goes to protocol
- **Flash loan fees**: 100% to protocol (0 bps at launch, target 0.5 bps = 0.005%, 10x cheaper than Aave)

**Revenue allocation** (governance-adjustable within bounds):
```
70% → Buyback-and-burn
30% → Treasury (held as USDC, ETH, or other non-BTR assets)
```

**Rationale**:
- **70% buyback**: Aggressive deflationary stance, supports BTR price
- **30% treasury**: Maintains operational flexibility, diversified reserves, emergency backstop
- **No "buyback to treasury"**: Avoids circular BTR accumulation; protocol's own BTR comes from 5% emissions-treasury slice

### Buyback Execution

**Cadence**: Weekly (or bi-weekly) TWAP execution

**Mechanism**:
```solidity
// Pseudo-code
function executeBuyback(uint256 stableAmount) external onlyTreasury {
    // Use TWAP or DEX aggregator to minimize slippage
    uint256 btrReceived = swapStableToBTR(stableAmount, twapParams);

    // Burn immediately (transparent, provable)
    _burn(address(this), btrReceived);

    emit BuybackExecuted(stableAmount, btrReceived, block.timestamp);
}
```

**TWAP parameters**:
- Split large buybacks across multiple blocks or hours to avoid single-block manipulation
- Use on-chain DEX aggregators (e.g., 1inch, Paraswap) for best price execution
- Transparent: all buyback txs visible on-chain, BTR burn provably reduces `totalSupply`

**Dynamic adjustment (optional, governance-controlled)**:
```
if (BTR price < 30-day MA):
    buyback_allocation = 80%  (aggressive support)
else if (BTR price > 50-day MA * 1.5):
    buyback_allocation = 60%  (preserve treasury during euphoria)
else:
    buyback_allocation = 70%  (baseline)
```

**Rationale**: Countercyclical buybacks maximize BTR burned per dollar (buy low, preserve cash high).

### Protocol Revenue Projections (Illustrative)

**Assumptions**:
- $100M daily swap volume
- 0.3% average swap fee → $300K daily swap fees
- 10% protocol take → $30K/day = ~$11M/year from swaps
- Plus withdrawal fees and flash loans (conservative: +20-30%) → ~$14M/year total

**Buyback math** (70% of $14M = ~$9.8M/year):
```
At $0.10/BTR: 98M BTR burned/year (nearly 1× supply, unrealistic at scale)
At $0.50/BTR: 19.6M BTR burned/year (~20% of supply)
At $1.00/BTR: 9.8M BTR burned/year (~10% of supply)
At $2.00/BTR: 4.9M BTR burned/year (~5% of supply)
```

**Long-term deflationary dynamics**:
- **Years 1-3**: Emissions dominate (high inflation), buyback provides price support
- **Years 4-7**: Emissions slow (exponential decay), buyback becomes more significant
- **Years 8-10**: Emissions tail off, buyback may exceed emissions (net deflation begins)
- **Years 10+**: Pure deflation if buyback continues and emissions end or become negligible

### Fee Structure Summary

See [FEES.md](./FEES.md) for complete details. Quick summary:

**Swap fees** (tri-factor model):
- Dynamic: 0.01% - 5% based on volatility, coverage, depth
- Protocol share: 10%
- Example: 0.3% swap → 0.03% protocol, 0.27% LP

**Withdrawal fees** (coverage-based):
- $r \geq 1$: 0% withdrawal fee (no haircut)
- $r < 1$: Coverage haircut, 50% to protocol, 50% to remaining LPs
- Example: $r = 0.9$, withdraw 100 units → receive 90 units, 5 to protocol, 5 to LPs

**Flash loan fees**:
- Launch: 0% (free flash loans to bootstrap ecosystem)
- Target: 0.005% (0.5 bps, 10x cheaper than Aave's 9 bps)
- 100% to protocol (LPs unaffected by flash loans)

**Expected blended protocol take**: ~10-15% of total fees collected, growing as protocol matures and volumes increase.

---

## Reward Distribution

### Design: Epoch-Based Emissions + Aave-Style Index Distribution

**Pattern**: Combine epoch-based emission amounts (exponential decay schedule) with lazy index updates for gas efficiency.

### Per-Asset Reward Indices

For each asset $(i,k)$ with sLP staking:

Maintain:
- `assetIndex`: cumulative reward per dollar of effective stake (grows over time)
- `lastUpdate`: timestamp of last index update
- `emissionRate`: current BTR/second for this asset (based on latest epoch allocation)

**Index update** (on any sLP stake/unstake/claim for asset $(i,k)$):
```solidity
timeDelta = block.timestamp - lastUpdate
totalEffectiveStake = Σ(V_j,i,k * m^LP_j)  // sum of all users' boosted stakes

if (totalEffectiveStake > 0) {
    assetIndex += (emissionRate * timeDelta) / totalEffectiveStake
}
lastUpdate = block.timestamp
```

**Per-user claimable** (for wallet $j$ in asset $(i,k)$):
```solidity
userEffectiveStake = V_j,i,k * m^LP_j
claimable_j,i,k = userEffectiveStake * (assetIndex - userIndexSnapshot_j,i,k)
```

On claim:
- Transfer `claimable_j,i,k` BTR to user
- Set `userIndexSnapshot_j,i,k = assetIndex`

**Benefits**:
- **Gas-efficient**: No per-block loops; index updated only on interactions
- **Exact**: No average-entry-time approximations needed
- **Battle-tested**: Used by Aave, Compound, Morpho, etc.

### sBTR Reward Distribution

For sBTR (simpler, single global pool):

Maintain:
- `sBTRIndex`: cumulative reward per sBTR (grows over time)
- `sBTREmissionRate`: BTR/second for sBTR (5% of total emissions)
- `totalSBTR`: total sBTR staked

**Index update**:
```solidity
timeDelta = block.timestamp - lastUpdate
if (totalSBTR > 0) {
    sBTRIndex += (sBTREmissionRate * timeDelta) / totalSBTR
}
```

**Per-user claimable**:
```solidity
claimable_j = sBTR_j * (sBTRIndex - userIndexSnapshot_j)
```

Same claim mechanics as sLP.

### Epoch Transitions

At each epoch boundary (e.g., weekly):
1. Compute new total emission $E_t$ from exponential decay formula: $E_t = E_{t-1} \times \text{decayRateBps} / 10000$
2. Split: 90% → $E^{LP}_t$, 5% → $E^{sBTR}_t$, 5% → emissions-treasury
3. For each asset $(i,k)$:
   - Compute $E^{asset}_{t,i,k}$ using per-asset routing (coverage × utilization × TVL)
   - Update `emissionRate_{i,k} = E^{asset}_{t,i,k} / epochDuration` (e.g., BTR/second)
4. Update `sBTREmissionRate = E^{sBTR}_t / epochDuration`

**No user action needed**: Emission rates update automatically; users claim whenever convenient.

### Claim Mechanics

**Manual claim**:
```solidity
function claimRewards(uint256[] calldata assetIds) external {
    for each asset in assetIds {
        update assetIndex
        compute claimable = userStake * (assetIndex - userSnapshot)
        transfer claimable BTR to msg.sender
        set userSnapshot = assetIndex
    }
}
```

**Auto-claim on interaction** (optional piggybacking):
- On stake: auto-claim existing rewards before updating stake
- On unstake: auto-claim before reducing stake
- Trade-off: slightly higher gas, but better UX (rewards never "forgotten")

**Recommendation**: Support both manual claim (gas-efficient for passive users) and auto-claim option (convenience for active users).

---

## Economic Incentives & Alignment

### Trader Incentives

**Traders benefit from:**
- Low slippage (deep liquidity from LPs)
- Competitive fees (tri-factor model reduces fees in balanced conditions)
- Privacy (optional DarkPool routing)

**Traders do NOT receive emissions** - This is intentional:
- Prevents wash trading to farm tokens
- Keeps emissions focused on liquidity provision
- Trading is a one-time action; LP is ongoing commitment

### LP Incentives

**LPs earn:**
1. **Swap fees** (0.27% average to LPs, 0.03% to protocol)
2. **BTR emissions** (sLP rewards based on utilization + coverage)
3. **Governance power** (sLP votes on asset listings, parameters)

**LP risk:**
- Coverage ratio < 1 → Withdraw less than deposited (pro-rata loss)
- Mitigated by:
  - High emissions in underwater pools (attract deposits → recovery)
  - Dynamic fees (high fees when imbalanced → discourages withdrawals)
  - Liability decay (gradual bad debt elimination over time)

**Example LP APR breakdown:**
```
Pool: USDC (healthy, high utilization)
  - Swap fee APR: 8% (from trading volume)
  - BTR emissions APR: 12% (utilization-weighted)
  - Total APR: 20%

Pool: WBTC (underwater, low utilization)
  - Swap fee APR: 3% (lower volume)
  - BTR emissions APR: 25% (coverage multiplier 3.0x)
  - Total APR: 28%

Despite lower fees, underwater pool has higher total APR to attract deposits.
```

### BTR Holder Incentives

**sBTR holders earn:**
1. **Base staking APR** (5%-20%, increasing over time)
2. **Governance power boost** (2.5x voting multiplier)
3. **Value accrual** (buyback reduces supply, increases price)

**Why hold BTR?**
- Long-term value appreciation (buyback + emissions decrease)
- Amplify LP voting power (1 sBTR = 2.5x voting)
- Participate in protocol growth (governance, treasury decisions)

### Protocol Incentives

**Protocol benefits from:**
- TVL growth (more fees, more volume)
- Balanced pools (higher capital efficiency)
- Long-term LPs (stable liquidity, less volatility)
- Governance participation (better decision-making)

**Incentive alignment:**
```
Traders → Volume → Fees → LPs earn more → More deposits → Better prices → More traders
                                        ↓
                                   Protocol fees → Buyback → BTR price ↑ → More staking
                                        ↓
                                   Emissions → Underwater pools → Coverage recovery
```

---

## Parameters & Tuning

### Governance-Adjustable Parameters

**Emission curve & supply**:

| Parameter | Initial Value | Range | Threshold |
|-----------|--------------|-------|-----------|
| $E_0$ (initial weekly emission) | 150,000 BTR | 100,000 - 200,000 | Simple majority |
| `decayRateBps` (weekly decay rate) | 9956 (0.44% decay) | 9900 - 9990 | Simple majority |
| **Supply cap** | 100M BTR | Immutable | Supermajority (67%)† |
| **Emission cap** | 65M BTR | Immutable | Supermajority (67%)† |

Notes:
- `decayRateBps = 9956` corresponds to 3-year half-life
- Range 9900-9990 = 0.7 to 13 year half-life
- † Supply/emission caps extremely rare to change, would require extraordinary circumstances

**Emission splits**:

| Parameter | Initial Value | Range | Threshold |
|-----------|--------------|-------|-----------|
| $\alpha_{LP}$ (sLP share) | 0.90 (90%) | 0.80 - 0.95 | Simple majority |
| $\alpha_{BTR}$ (sBTR share) | 0.05 (5%) | 0.02 - 0.10 | Simple majority |
| $\alpha_T$ (emissions-treasury) | 0.05 (5%) | 0.03 - 0.10 | Simple majority |

Constraint: $\alpha_{LP} + \alpha_{BTR} + \alpha_T = 1$.

**Coverage & utilization logic**:

| Parameter | Initial Value | Range | Threshold |
|-----------|--------------|-------|-----------|
| $\kappa$ (coverage slope) | 1.0 | 0.5 - 2.0 | Simple majority |
| $C_{\max}$ (max coverage factor) | 2.0 | 1.5 - 3.0 | Simple majority |
| $\lambda$ (utilization amplitude) | 1.0 | 0.5 - 2.0 | Simple majority |
| $u_0$ (utilization inflection) | 0.5 (50%) | 0.1 - 1.0 | Simple majority |
| $\tau$ (utilization EMA time constant) | 7 days | 1 - 30 days | Simple majority |

**BTR coverage and LP multipliers** (unified model):

| Parameter | Initial Value | Range | Threshold |
|-----------|--------------|-------|-----------|
| $M$ (BTR:LP coverage multiplier) | 5 | 1 - 10 | Simple majority |
| $w_{\min}$ (uncovered LP multiplier) | 0.5 - 0.75 | 0.25 - 0.9 | Simple majority |
| $w_{\max}$ (covered LP multiplier) | 1.0 | Fixed | — |

**Buyback & revenue routing**:

| Parameter | Initial Value | Range | Threshold |
|-----------|--------------|-------|-----------|
| Buyback % (of revenue) | 70% | 50% - 90% | Simple majority |
| Treasury % (of revenue) | 30% | 10% - 50% | Simple majority |

**Staking & distribution** (liquid staking standard, parametric unlock):

| Parameter | Initial Value | Range | Threshold |
|-----------|--------------|-------|-----------|
| Unlock period (sLP & sBTR) | 21 days (3 weeks) | 1 day - 1 year (365 days) | Simple majority |
| Epoch length | 1 week | 1 day - 1 month | Simple majority |

Notes:
- Unlock period is a **parametric soft lock** (unstake request → wait unlock period → claim anytime), not a hard time-lock like ve-models
- No redemption window expiry (unlike Aave's 48-hour window)
- Pending redemptions (locked or unlocked) are NOT transferable, DO NOT earn emissions, DO NOT grant voting rights
- Same unlock period applies to both sLP and sBTR for consistency

**Protocol fees** (see [FEES.md](./FEES.md)):

| Parameter | Initial Value | Threshold |
|-----------|--------------|-----------|
| Swap fee protocol % | 10% | Supermajority (67%) |
| Withdrawal fee protocol % | 50% | Supermajority (67%) |
| Flash loan fee | 0% at launch, target 0.005% (0.5 bps) | Simple majority |

### Recommended Review Schedule

**Quarterly reviews** (governance proposals):
- Emissions allocation efficiency (TVL growth per BTR emitted, coverage ratio trends)
- Buyback execution (BTR burned, treasury balance, market impact)
- Utilization EMA effectiveness (is $\tau$ appropriate? Are weights fair?)

**Annual reviews**:
- Tokenomics fundamentals (emission split, coverage/utilization parameters, $M$, $w_{\min}$)
- Supply & burn dynamics (projected year to net deflation, tail emission needs post-year 10)
- Governance participation (voter turnout, proposal quality, sBTR vs sLP engagement)

---

## Implementation Considerations

### Smart Contract Architecture

**Staking contracts** (liquid staking standard):
```
LPStaking.sol         (~500 lines)
  - stakeLP(), requestUnstake(), claimUnstake(), cancelUnstake()
  - ERC20/ERC4626 sLP tokens (per-asset, transferable when active)
  - Rebasing via liquidity index (Aave-style)
  - Parametric unlock (default 21 days, range 1 day - 1 year)
  - Redemption queue (no expiry, no redemption window)
  - Transfer restrictions: pending redemptions NOT transferable
  - Emissions accounting: pending redemptions excluded from effective stake
  - Voting power: pending redemptions excluded

BTRStaking.sol        (~400 lines)
  - stakeBTR(), requestUnstake(), claimUnstake(), cancelUnstake()
  - ERC20 sBTR tokens (transferable when active)
  - Rebasing via staking index (Aave-style)
  - Parametric unlock (same as sLP: 21 days default)
  - Redemption queue (no expiry, no redemption window)
  - Transfer restrictions: pending redemptions NOT transferable
  - Emissions accounting: pending redemptions excluded from effective stake
  - Voting power: pending redemptions excluded
  - LP boost: pending redemptions excluded from coverage calculation

EmissionsController.sol  (~500 lines)
  - calculateEmissions() (Velodrome-style: E_t = E_{t-1} * decayRateBps / 10000)
  - distributeEmissions() (weekly epoch transitions)
  - updateWeights() (per-asset coverage × utilization)
  - enforceEmissionCap() (cumulative 65M hard cap)

TreasuryBuyback.sol   (~200 lines)
  - executeBuyback() (TWAP, weekly)
  - burnTokens() (provable burn)
  - adjustAllocation() (governance)

GovernanceVoting.sol  (~400 lines)
  - propose(), vote(), execute()
  - calculateVotingPower() (sLP + sBTR boost)
  - threshold checks (simple vs supermajority)
```

### Oracle Requirements

**For emissions calculation:**
- 30-day rolling volume (per pool)
- 30-day time-weighted TVL (per pool)
- Current coverage ratio (per pool)

**For buyback:**
- BTR/USDC price feed (TWAP, manipulation resistant)
- Treasury balance
- Market conditions (30-day MA, 50-day MA)

### Gas Optimization

**Emission calculation simplicity** (Velodrome pattern):
```solidity
// Single multiply per epoch (extremely gas-efficient)
currentEmission = currentEmission * decayRateBps / 10_000;
cumulativeEmitted += currentEmission;
require(cumulativeEmitted <= EMISSION_CAP, "Cap exceeded");
```

**Batch operations:**
- Emissions calculated weekly (not per-block)
- Buyback executed weekly (not daily)
- Voting power cached (not recalculated every vote)

**Efficient storage:**
- Pack staking data (scaled balances + indices)
- Use uint128 for balances (sufficient for most cases)
- Cache utilization + coverage (update weekly)

**Estimated gas costs:**
```
stakeLP():      ~80,000 gas
unstakeLP():    ~60,000 gas
claimLP():      ~50,000 gas
stakeBTR():     ~60,000 gas
unstakeBTR():   ~50,000 gas
vote():         ~80,000 gas
executeBuyback(): ~150,000 gas
distributeEmissions(): ~200,000 gas (weekly, amortized)
```

---

## Security & Attack Vectors

### Flash Loan Attacks

**Attack:** Borrow large amount → deposit → vote → withdraw same block.

**Mitigation:**
- **21-day unlock period** (can't instant exit, must wait 3 weeks)
- Voting power snapshot at proposal creation (can't flash-loan vote)
- **No voting rights for pending redemptions** (locked or unlocked)
- Significantly longer than industry standard 7 days for extra security

### Governance Attacks

**Attack:** Acquire majority voting power → pass malicious proposal.

**Mitigation:**
- Dual governance (need both sLP + sBTR or large sBTR position)
- Timelock on sensitive changes (2-7 days)
- Supermajority required for critical parameters (67%)
- Veto power for multisig (first 6 months, then removed)

### Mercenary Capital

**Attack:** Stake → farm emissions → dump → leave.

**Mitigation:**
- Utilization-weighted emissions (idle capital earns less)
- **21-day unlock period** (creates significant friction, 3× longer than typical protocols)
- **No emissions during pending redemption** (opportunity cost of unlocking)
- sBTR APR increases over time (rewards long-term holders)
- Buyback creates price support (limits dump impact)

### Wash Trading

**Attack:** Fake volume to inflate utilization → earn more emissions.

**Mitigation:**
- Net volume after fees (wash trading burns money)
- 30-day rolling average (single-day spikes don't help)
- Fee structure discourages zero-profit trades

### Coverage Ratio Gaming

**Attack:** Deposit in underwater pool → earn high emissions → withdraw when coverage recovers.

**Mitigation:**
- This is actually desired behavior! (helps pool recover)
- Withdrawal haircut applies (pro-rata loss sharing)
- **21-day unlock period** prevents instant arbitrage (must commit capital for 3 weeks)
- **No emissions during unlock** (opportunity cost discourages quick flip strategies)

### Sybil Attacks on Voting

**Attack:** Split holdings across many wallets to appear decentralized.

**Mitigation:**
- Doesn't matter - voting power is voting power
- Delegation system allows consolidation for efficiency
- Identity not required (permissionless)

---

## Summary

### Core Design Principles

**100M hard-capped BTR** with logarithmic halving emissions over ~10 years, 70% buyback-burn from protocol revenue, and unified BTR-coverage formula for both voting and earning power.

### Allocation (65/20/12/3)

- **65% emissions** (90% to sLP, 5% to sBTR, 5% emissions-treasury)
- **20% treasury** (unlocked, DAO-controlled, for grants/POL/operations)
- **12% team** (5-year vest, 6-month cliff, 15% unlock—stricter than 90% of industry)
- **3% LBP** (fair launch, minimal upfront sale)

See [ALLOCATION_AND_VESTING.md](./ALLOCATION_AND_VESTING.md) for complete details.

### Staking: Liquid Staking Standard with Parametric Unlock

- **sLP**: Per-asset ERC20/4626 receipts, instant stake, parametric unlock (default 21 days)
- **sBTR**: Global ERC20 receipt, instant stake, parametric unlock (default 21 days)
- **Active stakes transferable**: Full composability (Pendle, lending, secondary markets)
- **Pending redemptions NOT transferable**: No emissions, no voting, no boost
- **No redemption windows**: Unlike Aave, unlocked tokens never expire (claim anytime)
- **No ve-locks**: Simpler UX, better DeFi integration than 4-year NFT locks
- **Industry standard**: Follows Ethena (sUSDe, sENA) and Aave (stkAAVE) liquid staking models

### Unified Governance & Earning Formula

**Single BTR-coverage mechanism** drives both voting power and emission multipliers:

- Coverage fraction: $f_j = \min(1, M \cdot V^{BTR}_j / V^{LP}_j)$ (default $M = 5$)
- LP multiplier: $m^{LP}_j = w_{\min} + (1 - w_{\min}) \cdot f_j$ (default $w_{\min} = 0.5$)
- Voting power: $PV_j = V^{BTR}_j + m^{LP}_j \cdot V^{LP}_j$
- Earning power: $R_{j,i,k} = V_{j,i,k} \cdot m^{LP}_j$

Result: $1 of sBTR covers up to $5 of LP, doubling both voting and earnings (2× vs uncovered).

### Per-Asset Emission Routing (Linear TVL)

**No gauge voting, no sqrt bias**—emissions auto-route based on:

- Coverage factor: $C_{i,k} = 1 + \kappa(1 - r_{i,k})$ (capped at $C_{\max} \approx 2$)
- Utilization factor: $U_{i,k} = 1 + \lambda u_{i,k}/(u_{i,k} + u_0)$ (saturating at ~2×)
- Per-asset weight: $w_{i,k} = C_{i,k} \cdot U_{i,k}$
- Emission share: $s_{i,k} = (w_{i,k} \cdot \text{TVL}_{i,k}) / \sum (w \cdot \text{TVL})$

**Linear TVL**: Emissions scale exactly with urgency-adjusted capital, fair to small and large assets alike.

### Utilization Measurement: EMA (Not TWAP Accumulator)

**Timestamp-weighted EMA** with time constant $\tau \approx 7$ days:
- Simpler than accumulator (one value + timestamp vs snapshots)
- Sufficient for emission routing (vs price oracles which need TWAP for solvency)
- Economics (fees) and caps ($U_{\max}$) protect against wash-trading

### Value Accrual: Pure Buyback-and-Burn

**70% of protocol revenue** → buyback BTR and burn; **30%** → treasury (non-BTR assets)

- Simpler than dividends (no per-user accounting, no immediate tax)
- Proven model: PancakeSwap v3, Hyperliquid
- Deflationary long-term: emissions tail off years 8-10, buyback may dominate (net deflation)

### Reward Distribution: Aave-Style Indices

**Epoch-based emissions** (matching halving schedule) with **lazy index updates**:
- Per-asset `assetIndex` grows with `emissionRate * timeDelta / totalEffectiveStake`
- Per-user claimable: `userStake * (assetIndex - userSnapshot)`
- Gas-efficient, no per-block loops, battle-tested (Aave, Compound, Morpho)

### Comparison to ve-Models

| Feature | BTR Tokenomics | veCRV / Velodrome |
|---------|---------------|-------------------|
| **Staking UX** | Instant stake, 21-day parametric unlock | 4-year locks, decay mechanics |
| **Transferability** | Fungible ERC20 receipts (active stakes) | Non-fungible veNFTs |
| **Pending redemptions** | NOT transferable, no emissions/voting | N/A (locked positions) |
| **Redemption windows** | None (claim anytime after unlock) | N/A (time-locked) |
| **Emission routing** | Auto (coverage × utilization) | Weekly gauge votes + bribes |
| **Earning & voting** | Unified formula | Separate boost logic |
| **Value accrual** | Buyback-burn | Fee sharing (often diluted) |
| **Composability** | High (Pendle, lending, DEXs) | Low (veNFTs hard to integrate) |
| **Reference models** | Ethena sUSDe/sENA, Aave stkAAVE | Curve veCRV, Velodrome veNFT |

**Conclusion**: BTR is simpler, more composable, and better aligned with 2025 DeFi UX expectations while maintaining strong incentive alignment.

---

## Related Documentation

- **[ALLOCATION_AND_VESTING.md](./ALLOCATION_AND_VESTING.md)** - Complete allocation breakdown, vesting schedules, transparency requirements
- **[ALM_AND_COVERAGE.md](./ALM_AND_COVERAGE.md)** - Coverage ratio model and liability tracking (informs emission routing)
- **[FEES.md](./FEES.md)** - Fee structure and tri-factor model (protocol revenue sources for buyback)
- **[ARCHITECTURE.md](./ARCHITECTURE.md)** - Protocol architecture and design decisions
- **[ERC1155_LP_TOKENS.md](./ERC1155_LP_TOKENS.md)** - LP token specification (underlying for sLP)

---

## References

**Protocols studied:**
- **Aave** - stkAAVE safety module (liquid staking with cooldown, redemption windows), fee switch, governance
- **Ethena** - sUSDe/sENA liquid staking (transferable receipts, rebasing), fee switch, ENA tokenomics
- **Curve** - veCRV, gauge voting, liquidity incentives
- **Velodrome** - veNFT, bribe marketplace, ve(3,3) model
- **PancakeSwap** - CAKE v3 buyback model, hard cap, deflationary
- **Wombat/Platypus** - Coverage ratio ALM, asset-liability model
- **Bitcoin** - Halving schedule, predictable supply, scarcity

**Key insights:**
1. **Liquid staking > ve-locks** for composability (Ethena sUSDe, Aave stkAAVE)
2. **Parametric unlock without expiry** > redemption windows (improves on Aave's 48-hour window)
3. **Transferable active stakes** + non-transferable pending redemptions (balance composability + security)
4. Buyback > dividends for long-term value (PancakeSwap, Hyperliquid)
5. Utilization > TVL for emissions efficiency (Gauntlet research)
6. Coverage multipliers attract liquidity to underwater pools
7. Simple mechanics > complex lockups for adoption
