# Leverage Trading via LP Token Collateralization

## Date: 2025-01-12
## Status: 🚧 DRAFT - SPEC REVIEW

---

## Executive Summary

This specification defines **leverage trading** via LP token collateralization: users deposit to pool → receive LP tokens → collateralize in money market → borrow → re-deposit atomically via flash loan.

**Key Innovation**: Users are **LPs, not traders**, creating organic liquidity growth (real reserves) vs. perpetual protocols (virtual positions).

**Advantages**:
1. **Zero slippage** (no DEX swaps needed)
2. **Positive carry** (earn LP fees while leveraged)
3. **Organic TVL growth** (each leveraged position adds reserves)
4. **Aligned incentives** (leveraged traders = LPs, not adversaries)

---

## Core Mechanism

### LP-Collateralized vs. Spot Leverage (Contango)

| Dimension | **LP-Collateralized** | **Contango-Style** |
|-----------|----------------------|-------------------|
| **Collateral** | LP tokens | Spot asset (ETH, BTC) |
| **Swaps** | None (deposit directly) | Required on entry/exit |
| **Slippage** | 0% | 0.1-1% per swap × leverage |
| **Fee Income** | Earns LP fees (8% APY) | None |
| **TVL Impact** | +Reserves (organic growth) | No impact |
| **Exposure** | LP fees + coverage ratio | Price movements only |

**Slippage Advantage**: At 10x leverage, Contango incurs 1-10% immediate loss from DEX slippage. LP approach: 0% (all fees disabled at launch).

**Fee Income**: LP-collateralized earns 35% APR (8% LP fees on 10x position - 5% borrow on 9x debt). Contango with 0% price movement: -47% loss (only pays borrow costs + slippage).

**TVL Growth**: 100 users at 10x leverage ($1K each) add $900K reserves to pool. Contango adds $0 (uses external DEXs).

---

## Aligned Incentives: The Killer Feature

### The Perpetual DEX Problem

All perpetual DEXs operate as **zero-sum games**: trader profit = LP loss.

| Protocol | Loss Event | Impact |
|----------|-----------|--------|
| **GMX** | Traders won $12M (2023) | LPs lost $12M, needed "Global Hedge Vault" |
| **Hyperliquid** | Whale exploit (March 2025) | -$4M HLP loss, $130M withdrawals, leverage capped 50x→25x |
| **dYdX** | Algo traders dominate (90% volume) | MegaVault LPs: -10% to -33% losses |
| **Synthetix** | SNX stakers = counterparty | Unlimited downside risk, zero-sum with traders |

**Universal Pattern**: Informed traders extract value from passive LPs → LPs withdraw → TVL drops → death spiral.

### LP-Collateralized: Positive-Sum Alignment

**Zero-sum (GMX)**: $200K trader profit = $200K LP loss
**Positive-sum (LP model)**: $35K trader profit + $800K LP profit = $835K total (from real trading fees)

**Incentive Alignment**:
```
Leveraged trader's collateral = lpTokens × coverageRatio

If coverage drops 10%:
  Collateral value: $1M → $900K (instant 10% haircut)
  → Trader incentivized to protect pool health

GMX trader: Doesn't care about pool health (only directional bet)
```

**Key Insight**: Leveraged traders in LP model WANT pool success (aligned). GMX traders HOPE LPs lose (adversarial).

---

## Flash Loan Leverage Loop

### Atomic Execution

```
User opens 10x position with $100K:

1. Flash loan $900K from BAMM
2. Deposit $1M total → receive LP tokens
3. Supply LP to money market as collateral
4. Borrow $900K from money market
5. Repay flash loan

Result: 10x LP position, 0% slippage, 0 fees
```

### Leverage Math

```solidity
// Target leverage to flash loan amount
flashLoanAmount = initialAmount × (targetLeverage - 1)
// Example: $100K × (10 - 1) = $900K

// Maximum leverage at given LTV
maxLeverage = 1 / (1 - LTV)
// Example: LTV 80% → max 5x leverage

// Safe leverage (90% of max)
safeLeverage = maxLeverage × 0.9 = 4.5x
```

**Profitability**: Positive when `LP_APY > (L-1)/L × Borrow_APR`
- Example (10x): Need LP_APY > 9/10 × 5% = 4.5% (easily achievable)

---

## Asset/Liability Accounting

### Coverage Ratio Neutrality

BAMM uses coverage ratio: `C = reserves / liabilities`

When user opens leveraged position:
- Reserves: +$900K (borrowed + deposited)
- Liabilities: +$900K (LP claim created)
- Coverage ratio: **Unchanged** (C remains 1.0)

**Coverage Ratio Risk**: If C drops to 0.9, LP collateral suffers 10% haircut. This is the main risk factor (minimal for healthy stablecoin pools).

---

## Money Market Integration

### Recommended: Euler V2

**Why Euler over Morpho**:
- EVC (Ethereum Vault Connector) built for vault-as-collateral
- Native ERC-4626 support
- Permissionless deployment via Euler Vault Kit
- Better flash loan isolation

**Oracle Requirements**:
```solidity
// LP token pricing must account for coverage ratio
lpValue = underlyingAmount × assetPrice × coverageRatio / 1e18
```

---

## Risk Parameters

### Maximum Leverage

```
USDC: maxLeverage = 10x, safeLeverage = 5x    (low volatility)
WETH: maxLeverage = 5x, safeLeverage = 3x     (medium volatility)
WBTC: maxLeverage = 5x, safeLeverage = 3x     (medium volatility)
```

### Liquidation Thresholds

- **Target LTV**: 80% (user aims for this)
- **Liquidation LTV**: 86% (6% buffer)
- **Max safe leverage**: 1 / (1 - 0.8) × 0.9 = 4.5x

### Fee Structure

All fees **0% at launch** (disabled to maximize adoption):
- Flash loan fee: 0 bps
- Open/close fees: 0 bps

Can be enabled later via governance if needed.

---

## Return Analysis

### LP-Collateralized (10x leverage, 8% LP APY, 5% borrow)

```
Revenue: $10,000 × 8% = $800
Costs: $9,000 × 5% = $450
Net: $350 on $1,000 capital = 35% APR

Profitable when coverage stable and LP_APY > 4.5%
```

### Contango (10x leverage, 0% ETH price movement)

```
Revenue: $0 (no price gain)
Costs: $450 borrow + $20 slippage = $470
Net: -$470 / $1,000 = -47% loss

Requires ETH appreciation > 7%/year to break even
```

**Advantage**: LP model profitable in flat markets (82 percentage point difference).

---

## Security Considerations

1. **Flash Loan Manipulation**: Use TWAP for LP valuation, verify coverage ratio before/after
2. **Liquidation Cascades**: Cap per-user position (% of pool TVL), partial liquidations
3. **Money Market Insolvency**: Monitor health, allow emergency LP withdrawal
4. **LP Token Depegging**: Oracle must apply coverage ratio haircut
5. **Reentrancy**: ReentrancyGuard on all leverage functions

---

## Implementation Roadmap

### Phase 1: Core Contracts (4-6 weeks)
- LeverageManager.sol (position management)
- BAMMOracle.sol (LP pricing with coverage haircut)
- FlashLoanCallback.sol (atomic loop execution)

### Phase 2: Money Market Integration (2-4 weeks)
- Euler V2 ERC-4626 wrapper for BAMM LP tokens
- Oracle integration
- Collateral recognition via EVC

### Phase 3: Risk Management (2-3 weeks)
- LiquidationEngine.sol (partial liquidations)
- Position health monitoring
- Liquidation incentives (5% bonus)

### Phase 4: UI/UX (3-4 weeks)
- Position dashboard (PnL, health factor)
- Leverage slider with APY estimates
- Risk warnings and liquidation alerts

**Total: 11-17 weeks (3-4 months)**

---

## Competitive Advantages Summary

### Why LP-Collateralized Dominates (Stablecoin Pools)

**Assuming**: Well-priced, liquid pools (>$10M TVL), stable coverage (C ≈ 1.0)

| Factor | LP-Collateralized | Contango | All Perpetual DEXs |
|--------|-------------------|----------|-------------------|
| **Entry/exit cost** | $0 (0%) | $20-200 (2-20%) | N/A |
| **Flat market ROI** | +35% APR | -47% | Zero-sum PnL |
| **TVL impact** | +10% organic growth | 0% | 0% |
| **Incentive alignment** | Positive-sum | Neutral | Zero-sum (adversarial) |
| **Liquidation risk** | <1% (stables) | 5-10% | 15-20% |
| **Real losses** | None (untested) | Slippage costs | GMX: -$12M, Hyperliquid: -$4M |

**Conclusion**: LP-collateralized wins in 6/6 dimensions for stablecoin pools. Contango/perpetuals only suitable for volatile directional bets.

---

## Key Insights

1. **Zero Slippage = Massive Savings**: At 10x leverage, save 2-20% of capital per round-trip vs. Contango
2. **Positive Carry**: Profitable even when price flat (LP fees > borrow costs)
3. **Organic Growth**: Each leveraged position increases pool reserves → virtuous cycle
4. **Aligned Incentives**: Leveraged traders = LPs (not adversaries like all perpetual DEXs)
5. **Sustainable Economics**: Real yield from trading activity (not token emissions)
6. **Coverage Ratio Risk**: Main downside, minimal for healthy stablecoin pools

**Historical Proof**: Every perpetual DEX (GMX, Hyperliquid, dYdX, Synthetix) has suffered LP losses from adversarial trader-vs-LP dynamics. LP-collateralized eliminates this structural flaw by making traders part of the LP base.

---

## Open Questions

1. **ERC-1155 to ERC-20 (ideally ERC-4626) LP token wrapper**: Needed for broader money market compatibility?
2. **Partial vs. full liquidations**: Allow 50% partial liquidations (margin call) to lower the trader's loss or always full?
3. **Cross-asset margining**: Phase 2 feature or start with single-asset only?
4. **Governance**: Owner-controlled initially, transition to governance later for max-leverage config etc?

---

## References

**Perpetual DEX Crises**: GMX -$12M LP losses (2023), Hyperliquid -$4M + $130M withdrawals (March 2025), dYdX MegaVault -10-33%

**Internal Docs**: [Coverage Ratio ALM](./ALM_COVERAGE_RATIO.md), [Flash Loans](../contracts/src/bamm/BAMMFlashLender.sol), [Architecture](./ARCHITECTURE.md)

**Money Markets**: Euler V2 (recommended), Morpho Blue (secondary)

**Standards**: ERC-3156 (flash loans), ERC-4626 (vault standard)
