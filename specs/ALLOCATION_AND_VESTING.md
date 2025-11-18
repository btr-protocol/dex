# BTR Token Allocation and Vesting Schedule

## Overview

This document specifies the **complete allocation structure** and **vesting schedules** for the BTR governance token, designed for a research-heavy, no-VC DeFi protocol with strong community alignment and long-term commitment signals.

**Key characteristics:**
- **Hard cap**: 100,000,000 BTR (100M tokens)
- **No VC dilution**: Community-first distribution
- **Long-term vesting**: 5-year team vest (stricter than industry standard)
- **Heavy emissions**: 65% to users over ~10 years
- **Fair launch**: Small 3% LBP, majority via emissions

---

## Table of Contents

1. [Supply Cap & Philosophy](#supply-cap--philosophy)
2. [Allocation Breakdown](#allocation-breakdown)
3. [Emissions (65%)](#emissions-65)
4. [Treasury (20%)](#treasury-20)
5. [Team & Advisors (12%)](#team--advisors-12)
6. [Liquidity Bootstrapping Pool (3%)](#liquidity-bootstrapping-pool-3)
7. [Vesting Implementation](#vesting-implementation)
8. [Governance & Adjustments](#governance--adjustments)
9. [Comparison to Industry Standards](#comparison-to-industry-standards)
10. [Transparency & Auditability](#transparency--auditability)

---

## Supply Cap & Philosophy

### Hard Cap

```
Total Supply: 100,000,000 BTR
```

**Immutability**: This cap is **hard-coded** and cannot be increased without a 67% supermajority governance vote, which would be highly contentious and require extraordinary circumstances.

### Design Philosophy

**"Emissions should reward productive liquidity, not just deposits; vesting should ensure long-term commitment, not extraction."**

This allocation reflects:
- **Community-first**: 65% flows directly to users via emissions
- **Long-term alignment**: 5-year team vest (vs 3-4 year industry standard)
- **Operational flexibility**: 20% treasury for sustainable operations
- **Fair launch**: Tiny 3% public sale, majority earned through participation

Unlike VC-heavy projects that allocate 15-30% to investors on top of 15-20% team allocations, this structure keeps **77%** in the hands of the community (65% emissions + 12% team with strict vesting).

---

## Allocation Breakdown

| Category | Allocation | % of Supply | Tokens | Vesting Type |
|----------|-----------|-------------|---------|--------------|
| **Emissions** | 65% | 65.0% | 65,000,000 BTR | Halving curve, 10 years |
| **Treasury** | 20% | 20.0% | 20,000,000 BTR | Unlocked (DAO-controlled) |
| **Team & Advisors** | 12% | 12.0% | 12,000,000 BTR | 5yr linear, 6mo cliff, 15% unlock |
| **Liquidity Bootstrapping Pool** | 3% | 3.0% | 3,000,000 BTR | Immediate (LBP) |
| **TOTAL** | 100% | 100.0% | 100,000,000 BTR | — |

### Rationale

**65% emissions**: Prioritizes user acquisition and liquidity provision over 10 years, aligning with long-term protocol growth rather than quick token dumping.

**20% treasury**: Provides operational runway for:
- Grants and ecosystem development (5-8%)
- Protocol-owned liquidity (POL) deployment (5-10%)
- Emergency reserves and partnerships (3-5%)
- Events, marketing, and selective incentives (2-5%)

**12% team**: Conservative for a no-VC, bootstrapped project (industry average is 15-20%). Sufficient to compensate core contributors over 5 years while maintaining strong community alignment.

**3% LBP**: Minimal public sale emphasizes fair distribution via emissions rather than upfront capital extraction. Typical projects do 5-10% public sale, but those often have shorter emission windows.

---

## Emissions (65%)

### Total Emissions: 65,000,000 BTR

**Distribution period**: ~10 years with logarithmic decay (halving every 2 years)

### Emission Split

| Recipient | % of Emissions | BTR Amount | Purpose |
|-----------|---------------|------------|---------|
| **sLP holders** | 90% | 58,500,000 BTR | Per-asset incentives (coverage × utilization weighted) |
| **sBTR stakers** | 5% | 3,250,000 BTR | Pure governance incentives (pro-rata to sBTR) |
| **Emissions Treasury** | 5% | 3,250,000 BTR | Airdrops, grants, special campaigns (in BTR) |

**Note**: See [TOKENOMICS.md](./TOKENOMICS.md) for complete emission schedule, halving curve parameters, and per-asset routing formula.

### Halving Schedule (Illustrative)

Assuming $E_0 \approx 62,500$ BTR/week (calibrated to reach 65M over ~10 years with halvings every 104 weeks):

```
Year 1-2:   ~50% of emissions (≈32.5M BTR)  → 62,500 BTR/week
Year 3-4:   ~25% of emissions (≈16.25M BTR) → 31,250 BTR/week
Year 5-6:   ~12.5% of emissions (≈8.125M BTR) → 15,625 BTR/week
Year 7-8:   ~6.25% of emissions (≈4.06M BTR) → 7,813 BTR/week
Year 9-10:  ~3.125% of emissions (≈2.03M BTR) → 3,906 BTR/week
Year 10+:   Tail emissions (governance-adjustable) → ~1,953 BTR/week or less
```

**Curvature parameters** ($E_0$, halving interval $H$, halving factor $h$) are governed within tight bounds to prevent supply breach while allowing empirical tuning.

### Why 90/5/5 (not 90/2/8 or 88/2/10)

**5% to sBTR** gives pure governance holders a meaningful but not dominant yield source:
- Prevents under-incentivizing a dedicated governor class
- Still small enough that LP coverage remains the primary farming route
- Typical staking: ~50% of BTR mcap (≈10% of TVL) → sBTR emissions are 5% of 65M = 3.25M over 10 years, spread across ~5M staked, yielding moderate APR
- Avoids meta-game where users hoard BTR purely to farm emissions

**5% to emissions treasury** (not 8-10%) because:
- 20% of total supply (20M BTR) is already allocated to the **main treasury** unlocked
- Emissions-treasury is for targeted BTR-denominated incentives (airdrops, special campaigns), not operational expenses
- Too large a slice here dilutes the user-first narrative

**90% to sLP** remains the dominant sink, ensuring liquidity is the protocol's core focus.

---

## Treasury (20%)

### Total Treasury: 20,000,000 BTR

**Unlock**: Immediate, but controlled by DAO governance (multisig → DAO transition)

### Recommended Allocation (DAO-adjustable)

| Purpose | Initial Target % | BTR Amount | Notes |
|---------|-----------------|------------|-------|
| **Grants & Ecosystem** | 25-40% | 5-8M BTR | Developer grants, partnerships, integrations |
| **Protocol-Owned Liquidity (POL)** | 25-50% | 5-10M BTR | Deploy BTR into key DEX pairs, maintain liquid markets |
| **Emergency Reserves** | 15-25% | 3-5M BTR | Coverage backstop, black swan events, exploit response |
| **Operations & Marketing** | 10-25% | 2-5M BTR | Events, audits, salaries (non-core team), selective campaigns |

**Governance**: All treasury expenditures above a threshold (e.g., 1% of treasury = 200k BTR) require on-chain proposals with 7-day timelock.

**No vesting**: Treasury is unlocked but rate-limited via governance; DAO can impose spending caps or multi-year budgets.

**Separation from team**: Unlike some protocols that lump "team + treasury," this design keeps them separate to maintain transparency and prevent accusations of self-dealing.

---

## Team & Advisors (12%)

### Total Team Allocation: 12,000,000 BTR

**Recipients**: Founders, core developers, early contributors, advisors

**Vesting**: 5-year linear vest with 6-month cliff and 15% unlock at cliff

### Vesting Schedule

```
Total duration:   60 months
Cliff:            6 months
Unlock at cliff:  15% (1,800,000 BTR total across all team allocations)
Remaining vest:   85% (10,200,000 BTR) over 54 months
Monthly rate:     85% / 54 ≈ 1.574% per month (≈188,889 BTR/month in aggregate)
```

**Timeline**:
- **Month 0-6**: No tokens claimable (cliff period)
- **Month 6**: 15% unlocks (1.8M BTR total for all team members)
- **Month 7-60**: Linear vesting of remaining 85% (≈188,889 BTR/month total)

**Example**: For a contributor allocated 100,000 BTR:
- Month 6: 15,000 BTR claimable
- Months 7-60: 1,574 BTR/month claimable
- Month 12: Total claimable = 15,000 + (6 × 1,574) = 24,444 BTR (≈24.4%)
- Month 60: Full 100,000 BTR claimable

### Rationale

**5-year vest (vs 3-4 year industry standard)**:
- Signals **exceptional long-term commitment**
- Appropriate for infrastructure protocols requiring multi-year development
- Only ~10% of crypto projects use 5+ year vesting, making this a strong differentiation point

**6-month cliff (vs 12-month standard)**:
- More humane given **minimal or no salary** during development
- Provides early liquidity for bootstrapped team
- Still sufficient to deter short-term mercenaries

**15% unlock at cliff**:
- Matches effective unlocks of standard schedules (see comparison below)
- Necessary liquidity for team with no VC runway or substantial salaries
- Remaining 85% over 54 months ensures majority of value locked long-term

**12% allocation (vs 15-20% industry average)**:
- Conservative for a **no-VC project** (no investor dilution eating 15-30%)
- Sufficient to reward ~10-15 core contributors over 5 years
- Strong optics: only 12% team + 3% LBP = **15% total extractive allocation**, vs **65% to users**

### Comparison to Industry Standard

**Industry norm**: 4-year vest, 1-year cliff, 25% at cliff, then 1/36 monthly

| Metric | Industry Standard | BTR Protocol | Notes |
|--------|------------------|--------------|-------|
| **Total duration** | 48 months | 60 months | BTR is 25% longer |
| **Cliff** | 12 months | 6 months | BTR is 50% shorter (more humane) |
| **% at cliff** | 25% | 15% | Appears less, but... |
| **% at 12 months** | 25% | ≈24.4% | Effectively identical! |
| **Monthly rate (post-cliff)** | 2.08% | 1.57% | BTR is slower (more back-loaded) |
| **Total % in Year 1** | 25% | 24.4% | Nearly identical |
| **Total % in Year 2** | 50% | 43.3% | BTR is stricter |
| **Total % in Year 3** | 75% | 62.2% | BTR is much stricter |
| **Total % in Year 4** | 100% | 81.1% | BTR still vesting |
| **Total % in Year 5** | — | 100% | Extra year of commitment |

**Conclusion**: BTR's schedule is **more aligned and stricter** than industry standard because:
- Year 1 unlock is effectively the same (~24-25%)
- Years 2-4 unlock significantly slower
- Year 5 adds an entire additional year of lock
- Total commitment period is 25% longer

### Differentiated Schedules (Optional)

**Founders**: Strict 5-year schedule as above

**Early contributors (non-founders)**: Optionally use 4-year schedule with same 6-month cliff and 15% unlock, then linear over 42 months:
- Month 6: 15% unlock
- Months 7-48: 85% / 42 ≈ 2.02% per month
- Total duration: 48 months (still on par with or stricter than industry)

**Advisors**: 3-year schedule with 6-month cliff, 10% unlock:
- Month 6: 10% unlock
- Months 7-36: 90% / 30 = 3% per month
- Typical for part-time advisors providing strategic input vs full-time builders

**Rationale**: Keeps founder alignment strongest (5yr), provides flexibility for hiring (4yr), and standard advisor terms (3yr), while all schedules remain transparent and on-chain.

---

## Liquidity Bootstrapping Pool (3%)

### Total LBP Allocation: 3,000,000 BTR

**Unlock**: Immediate, deployed to LBP contract at launch

**Purpose**: Fair-launch price discovery and initial liquidity

### LBP Configuration (Illustrative)

Using a **Balancer v2 LBP** or **Fjord Foundry**-style auction:

- **Duration**: 48-72 hours
- **Starting weights**: 95% BTR / 5% USDC (high BTR weight → high initial price)
- **Ending weights**: 50% BTR / 50% USDC (balanced → lower final price)
- **Initial liquidity**: 3M BTR + ~$50k-$100k USDC (from treasury or team)
- **Price trajectory**: Descending auction discourages FOMO buying, rewards patient participants

**Target raise**: $300k - $1M (at effective prices $0.10 - $0.50 per BTR)

**Post-LBP**: Remaining BTR (if any unsold) returns to treasury; paired assets (USDC) go to treasury or initial LP seeding.

### Why Only 3%?

**Heavy emission model**: 65% of supply flows to users over 10 years via farming, making the LBP a "bootstrap" rather than a primary distribution event.

**Fair launch ethos**: Small upfront sale prevents whales from acquiring large positions before community can participate via staking/providing liquidity.

**Comparison**: Typical projects allocate 5-10% to public sales, but those often have **shorter emission windows** or no emissions. Examples:
- **Ethena**: 2% public sale, but only 15% to liquidity mining
- **PancakeSwap v3**: 5% IFO, 60% emissions over 3 years
- **Curve**: ~3% liquidity mining initially, majority locked in veCRV by founders/VCs (different model)

BTR's 3% LBP + 65% emissions over 10 years is aligned with **fair-launch, community-first** precedents.

---

## Vesting Implementation

### On-Chain Vesting Contracts

**Standard**: Use audited, battle-tested contracts such as:
- **Sablier v2** (streaming vesting with cliffs)
- **OpenZeppelin VestingWallet** (simple linear vesting)
- **Custom vesting module** integrated with sBTR staking (allows vested tokens to be auto-staked)

**Features**:
- Monthly or continuous vesting (continuous is more capital-efficient for claimants)
- Revocable vs non-revocable (recommend **non-revocable** for founders, **revocable** for advisors/employees if needed)
- Direct withdrawal or auto-stake (allows team to earn governance power + sBTR rewards while vesting)

### Cliff Implementation

**6-month cliff**: No tokens claimable until `startTime + 6 months`

At cliff timestamp:
```solidity
claimable = allocation * 0.15
```

After cliff (months 7-60):
```solidity
claimable = allocation * 0.15 + (allocation * 0.85 * (currentTime - cliffTime) / (54 months))
```

### Auto-Staking Option

**Problem**: Vested tokens sit idle, team has no governance power or sBTR rewards until they manually stake.

**Solution**: Implement a **VestingStaker** contract that:
1. Holds vested BTR allocations
2. Automatically stakes all claimable tokens into sBTR
3. Team members earn sBTR rewards and voting power during vesting
4. On claim, team receives sBTR (which they can unstake with cooldown if desired)

**Benefits**:
- Aligns team incentives with stakers (earn same rewards)
- Increases governance participation
- Simple UX: claim sBTR directly, no intermediate BTR → sBTR step

**Trade-off**: Adds complexity; optional feature, not required for launch.

---

## Governance & Adjustments

### What Is Governed?

**Immutable (cannot be changed)**:
- Total supply cap (100M BTR)
- Team vesting schedules (once deployed, contracts are non-upgradable)

**Governed (adjustable via DAO)**:
- Emission curve parameters (within bounds: $E_0$, halving interval $H$, halving factor $h$)
- Emission split (sLP vs sBTR vs emissions-treasury, within ranges like 80-95% / 2-10% / 3-10%)
- Treasury spending (any spend > threshold requires proposal + vote)
- Revenue routing (buyback % vs treasury %, within bounds)

**Governance thresholds**:
- **Simple majority (>50%)**: Emission split adjustments, treasury budgets, parameter tuning
- **Supermajority (≥67%)**: Supply cap changes (extremely rare), protocol upgrades, emergency actions

### Review Schedule

**Quarterly reviews** (governance proposals):
- Treasury spending reports and upcoming budgets
- Emission effectiveness (TVL growth, coverage ratio trends)
- Buyback execution (BTR burned, treasury health)

**Annual reviews**:
- Vesting transparency reports (how much team BTR unlocked, how much staked/sold)
- Tokenomics fundamentals (emission split, coverage/utilization parameters)
- Long-term supply projections (when will emissions end, tail emission needs)

---

## Comparison to Industry Standards

### Allocation Benchmarks

| Category | BTR Protocol | Industry Average | Assessment |
|----------|-------------|------------------|------------|
| **Community (emissions)** | 65% | 40-60% | **Above average** (strong) |
| **Treasury** | 20% | 15-25% | **Median** (appropriate) |
| **Team** | 12% | 15-20% | **Below average** (conservative) |
| **Public sale** | 3% | 5-15% | **Well below average** (fair launch) |
| **VCs/Investors** | 0% | 15-30% | **None** (bootstrapped) |

**BTR total extractive allocation** (team + public sale): **15%**
**Industry typical extractive allocation** (team + investors + public): **35-50%**

BTR is **significantly more community-aligned** than typical VC-backed projects.

### Vesting Benchmarks

| Metric | BTR Team | Industry Standard |
|--------|---------|-------------------|
| **Vest duration** | 5 years | 3-4 years |
| **Cliff duration** | 6 months | 6-12 months |
| **% at cliff** | 15% | 10-25% |
| **% at 12 months** | ≈24.4% | 25% |
| **Total commitment** | 60 months | 36-48 months |

**Assessment**: BTR vesting is **stricter and longer** than 90% of crypto projects, signaling exceptional alignment.

### Notable Comparables

**Curve (CRV)**:
- Allocation: ~62% to liquidity mining, ~30% to founders/early investors (3-4 year vest), ~5% employees, ~3% community
- Vesting: Standard 3-4 year with 1-year cliff
- Note: Heavy early founder control (large unvested holdings), less "fair launch" than BTR

**Uniswap (UNI)**:
- Allocation: 60% community (43% governance treasury + 17% airdrops), 21% team (4yr vest), 18% investors (4yr), 1% advisors
- Vesting: Standard 4-year with 1-year cliff
- Note: BTR is similar to UNI's community-first model but with longer team vest and no VC dilution

**Ethena (ENA)**:
- Allocation: 15% liquidity incentives, 25% foundation, 30% investors (2-3yr), 15% core contributors (3yr), 15% ecosystem development
- Vesting: 3-year standard for team, 2-year for investors (!), much shorter than BTR
- Note: BTR is **far stricter** (5yr vs 3yr team, no investors)

**PancakeSwap (CAKE v3)**:
- Allocation: 60% emissions over 3 years, 20% marketing/treasury, 15% team, 5% IFO
- Vesting: 3-year team vest with 1-year cliff
- Note: Similar emission-heavy model, but BTR extends to 10 years and has 5-year team vest (stricter)

**Conclusion**: BTR sits in the **top quartile** for community alignment and team commitment length.

---

## Transparency & Auditability

### Public Vesting Dashboard

**Minimum transparency requirements**:
- On-chain vesting contracts with source code verified on Etherscan/Arbiscan
- Public dashboard showing:
  - Total team allocation and vested/unvested breakdown
  - Individual allocations per address (with role labels: founder, contributor, advisor)
  - Real-time claimable amounts and claim history
  - Treasury balance and spending log

**Tools**: Existing platforms like **Token Vesting** dashboards, **Hedgey**, or **Sablier UI** provide turnkey solutions.

### Disclosure Standards

**At launch**:
- Publish full allocation table (this document) and vesting contract addresses
- Disclose all team member allocations by role (anonymized if needed, but amounts public)
- Publish LBP parameters and post-LBP report (funds raised, BTR sold, treasury deployment)

**Ongoing**:
- Quarterly on-chain transparency reports (how much team BTR claimed, how much staked vs sold)
- Annual state-of-tokenomics posts (emissions effectiveness, treasury health, governance participation)

**Accountability**: Community can verify all claims on-chain; any discrepancy is immediately visible and challengeable via governance.

---

## Summary

**Allocation**: 65/20/12/3 (emissions/treasury/team/LBP) is **best-in-class** for a bootstrapped, community-first protocol.

**Vesting**: 5-year team vest with 6-month cliff and 15% unlock is **stricter than 90% of industry** while remaining humane given no VC funding and minimal salaries.

**Philosophy**: Maximize long-term alignment, minimize extractive behavior, and provide transparent, auditable on-chain enforcement.

**Result**: A tokenomics structure that should receive **strong community support** and **credible commitment signals** from the team, positioning BTR as a serious, long-term DeFi infrastructure protocol.

---

## Related Documentation

- **[TOKENOMICS.md](./TOKENOMICS.md)**: Full tokenomics model (emissions, staking, governance, buyback)
- **[ALM_AND_COVERAGE.md](./ALM_AND_COVERAGE.md)**: Coverage ratio model (informs emission routing)
- **[FEES.md](./FEES.md)**: Fee structure (protocol revenue model)
- **[ARCHITECTURE.md](./ARCHITECTURE.md)**: Protocol architecture and design decisions

---

## References

**Industry data**:
- Bitbond: [Token Vesting Comprehensive Guide](https://www.bitbond.com/resources/token-vesting-comprehensive-guide-for-crypto-projects/)
- TokenMinds: [Crypto Vesting Best Practices](https://tokenminds.co/blog/token-sales/crypto-vesting)
- Liquifi: [Token Vesting and Allocation Benchmarks](https://www.liquifi.finance/post/token-vesting-and-allocation-benchmarks)
- Blockchain App Factory: [Token Distribution Strategies](https://www.blockchainappfactory.com/token-distribution)

**Example protocols studied**:
- Curve, Uniswap, PancakeSwap, Ethena, Balancer, Aave, Compound

**Vesting tools**:
- Sablier v2, OpenZeppelin VestingWallet, Hedgey, custom implementations
