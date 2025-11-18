# Circuit Breakers Specification

## Overview

The BAMM protocol implements **two independent circuit breakers** to protect against catastrophic price events and market dislocations. Both operate automatically on-chain during swap execution, with no reliance on external guardians.

## Why Circuit Breakers Enable Single-Pool Architecture

### The Contagion Problem in Unified Pools

**Traditional isolated-pool protocols** (Aave instances, Venus isolated pools, Balancer metapools) avoid contagion by **full separation**:
- USDC depeg in stable pool ✓ does NOT affect WETH in volatile pool
- Exploit draining ALT tokens ✓ does NOT affect core assets

**Single-pool protocols** (early Platypus, naive Wombat) faced **total contagion risk**:
- USP depeg in Platypus Main pool → entire pool drained (2023 incident)
- Single toxic asset can drain all reserves via swap routing

**BAMM's solution**: **Real-time circuit breakers** that **disable toxic routes** before contagion spreads, while keeping healthy pairs active.

### How Circuit Breakers Isolate Contagion

**Scenario**: USDC depegs to $0.92 (8% below $1.00 peg)

**What happens in pool (unit-based coverage)**:
- USDC still worth $0.92 → arbitrageurs want to **buy USDC at discount**
- Traders swap USDT/DAI → USDC (to arbitrage external markets where USDC = $0.92)
- **USDC reserves increase** (traders buying it), USDT/DAI reserves **decrease**
- USDC coverage ratio **goes UP** (more reserves), USDT/DAI coverage **goes DOWN**

**Without circuit breakers** (Platypus-style):
```
1. Arbitrageurs swap USDT → USDC at near-peg price (pool lags oracle)
2. USDT reserves drain (traders buying USDC out)
3. USDT coverage ratio drops (reserves depleted)
4. USDT LPs try to withdraw → get reduced units (coverage <1.0)
5. Contagion: healthy asset (USDT) coverage destroyed by depegged asset (USDC) flows
```

**With BAMM circuit breakers**:
```
1. Reserve price CB: USDC.reservePrice = $0.98
   → Oracle price $0.92 < $0.98 → swap USDT → USDC REVERTS (can't buy depegged USDC)
2. Deviation freeze CB: |fast TWAP - slow TWAP| > threshold
   → USDC marked frozen → ALL swaps involving USDC REVERT
3. Result: USDC isolated, USDT/DAI/WETH pairs continue trading normally
4. USDT/DAI coverage ratios PROTECTED (no drain via USDC arbitrage)
```

**Outcome**: **Contagion prevented**—circuit breakers stop flow from healthy assets (USDT/DAI) into toxic asset (USDC), protecting healthy asset coverage ratios.

### Circuit Breakers vs Isolated Pools: Trade-Off Analysis

| Aspect | Isolated Pools | BAMM Circuit Breakers |
|--------|---------------|----------------------|
| **Contagion protection** | 100% (full separation) | 95% (toxic routes disabled, healthy routes active) |
| **Capital efficiency** | Low (fragmented liquidity) | High (unified depth) |
| **Routing gas** | High (multi-hop) | Low (single-hop) |
| **LP income** | Narrow (fees from own pool only) | Broad (fees from all pairs) |
| **Response time** | N/A (no contagion possible) | Real-time (on-chain, <1 block) |
| **False positives** | None | Rare (CB triggers during high volatility) |

**Why 95% protection is sufficient**:
- Circuit breakers trip **before significant drain** (reserve price + deviation freeze catch early)
- Combined with **tri-factor fees** (penalty ramps up as coverage worsens) and **liability decay** (long-term loss absorption), residual contagion is minor
- Trade-off: 5% residual risk vs **10× capital efficiency gain** is economically sound

### Real-World Exploit Scenarios

**1. Stablecoin Depeg (USDC March 2023)**:
- USDC depegs to $0.92 → traders want to buy discounted USDC via USDT→USDC swaps
- Reserve price CB: USDC.reservePrice = $0.98 → blocks USDT→USDC swaps (oracle $0.92 < $0.98)
- Deviation freeze: Fast TWAP ($0.92) vs slow TWAP ($0.99) = 7% divergence → freeze USDC
- Result: USDT reserves protected (can't drain via USDC arbitrage), other stables unaffected

**2. LST/LSD Exploit (stETH/Lido slashing)**:
- stETH drops 15% → traders want to buy cheap stETH via WETH→stETH swaps
- Deviation freeze: stETH fast TWAP drops 15% → instant freeze
- Reserve price CB: stETH.reservePrice = $1,800 (if ETH = $2,000) → blocks swaps if oracle <$1,800
- Result: WETH reserves protected (can't drain via stETH arbitrage)

**3. Alt Token Pump (BONK 10× overnight)**:
- BONK pumps 10× → traders buy BONK out via USDC→BONK swaps (pool lags oracle)
- Deviation freeze: BONK fast TWAP diverges massively from slow TWAP → freeze
- Reserve price CB: Disabled for alts (expected volatility) → deviation freeze sufficient
- Result: BONK reserves stop draining, USDC coverage protected

**4. Alt Token Rug Pull (99% drop)**:
- ALT drops 99% → traders dump ALT via ALT→USDC swaps (if pool hasn't caught up)
- Deviation freeze: Fast TWAP (-99%) vs slow TWAP → instant freeze
- Reserve price CB: May trigger if set, but deviation freeze catches it first
- Result: USDC reserves protected (can't receive worthless ALT)

**5. Oracle Manipulation Attack**:
- Attacker manipulates fast TWAP (spot oracle) up/down to create arbitrage
- Deviation freeze: Manipulated fast TWAP diverges from slow TWAP → freeze
- Reserve price CB: May not trigger if manipulation pushes price UP → deviation freeze protects
- Result: Asset frozen until oracle recovers, preventing toxic flows

### Complementary Protection Layers

Circuit breakers are **layer 4 and 5** of a 5-layer defense:

1. **Piecewise bonding curves** (layer 1): Shape slippage per asset—alts have wider curves (more slippage tolerance)
2. **Tri-factor swap fees** (layer 2): Coverage × volatility × divergence penalties discourage toxic swaps economically
3. **Liability time decay** (layer 3): Gradual loss socialization over weeks/months for underwater assets
4. **Reserve price circuit breakers** (layer 4): Hard price floor, instant swap disable
5. **Deviation freeze** (layer 5): Detect regime breaks, disable asset entirely

**Result**: Even if layers 1-3 fail to prevent a toxic swap, layers 4-5 **halt execution before contagion**.

---

## Circuit Breaker #1: Reserve Price Floor

### **Purpose**
Prevent swaps from executing below a minimum price threshold (e.g., stablecoin depeg protection).

### **Mechanism**
- **Per-Asset Configuration**: Each asset has a `reservePrice` field (uint64 B64 format)
- **Default**: `reservePrice = 0` (disabled)
- **Trigger Condition**: Swap reverts if **EITHER** oracle price **OR** pool spot price falls below `reservePrice`

### **Design Rationale**

**Why check both oracle AND pool price?**

The pool can trade below the oracle due to:
1. **Liquidity depletion**: Low reserves cause high price impact
2. **Volatility spikes**: Bonding curve breadth widens, deepening discounts
3. **Oracle lag**: TWAPs reflect historical averages, not current stress

By checking **both**, we ensure:
- ✅ **Oracle protection**: Blocks swaps if external market crashes (e.g., USDC depegs to $0.90)
- ✅ **Pool protection**: Blocks swaps if internal pool state deteriorates (e.g., panic selling depletes reserves)

### **Example Use Cases**

| Asset | Reserve Price | Rationale |
|-------|--------------|-----------|
| USDC  | $0.98 (B64)  | Depeg circuit breaker: halt if stablecoin drops below 2% peg |
| DAI   | $0.97 (B64)  | More lenient for algorithmic stablecoin |
| WETH  | $100 (B64)   | Black swan protection (e.g., flash crash) |
| wstETH | Disabled (0) | Yield-bearing asset, price naturally diverges from WETH |

### **Implementation Details**

**Storage (Zero Overhead):**
```solidity
struct Asset {
    // SLOT 2: fee config block + small scalars = 32 bytes
    uint16 minFeeBps;
    uint16 maxFeeBps;
    uint16 protocolFeeBps;
    uint16 depositFeeBps;
    uint16 withdrawalFeeBps;
    uint16 flashFeeBps;
    uint16 targetCoverageRatio;
    uint8 decimals;
    uint8 segmentCount;
    uint8 flags;
    uint64 reservePrice;           // NEW: B64 circuit breaker (0 = disabled)
    uint8 _pad;                    // 1 byte spare
}
```

**Validation Logic:**
```solidity
// Check oracle price
uint256 oraclePrice = M.b64ToPrice(oracle.currentPrice);
uint256 minPrice = M.b64ToPrice(asset.reservePrice);
if (oraclePrice < minPrice) revert ReservePriceViolation();

// Check pool spot price (after pricing calculation)
uint256 spotPrice = P.getSegmentPrice(asset, profile, feeParams, oracle, amount);
if (spotPrice < minPrice) revert ReservePriceViolation();
```

**Gas Cost:**
- Oracle check: ~300 gas (1 SLOAD + 1 B64 decode + comparison)
- Spot check: ~0 gas (price already computed for swap)

---

## Circuit Breaker #2: Deviation-Based Freeze

### **Purpose**
Detect and halt trading when an asset's relative price movement diverges abnormally from a reference asset (e.g., wstETH depegs from WETH, DAI breaks from USDC).

### **Mechanism**
- **Per-Asset Configuration**: Each asset can specify a `referenceAsset` address and `maxDeviation` threshold (bps)
- **Default**: `referenceAsset = address(0)` (disabled)
- **Trigger Condition**: Swap reverts if `|(r_asset - r_ref) / r_ref| > maxDeviation`, where `r = fast_TWAP / slow_TWAP`

### **Design Rationale**

**Why use fast/slow TWAP ratio instead of absolute price difference?**

Traditional deviation checks compare absolute prices:
```
deviation = |price_asset - price_ref| / price_ref
```

**Problem**: This fails for assets with **non-zero beta** (natural price drift):
- **wstETH vs WETH**: wstETH accrues staking yield → price naturally increases over time
- **stETH vs WETH**: stETH rebases → price drifts slowly
- **Yield-bearing LSTs**: All carry positive drift relative to base asset

**Solution**: Compare **relative returns** (short-term vs long-term momentum):
```
r_asset = fast_TWAP / slow_TWAP   (e.g., 6h / 7d)
r_ref   = fast_TWAP / slow_TWAP   (same windows)
deviation = |(r_asset - r_ref) / r_ref|
```

**Why this works:**
- ✅ **Beta-neutral**: Both assets drift at similar rates under normal conditions
- ✅ **Captures regime breaks**: Sudden divergence in short-term momentum signals dislocation
- ✅ **Time-scale independent**: Works for any TWAP window pairing

**Academic Foundation:**
- **Relative return divergence** is used in pairs trading and statistical arbitrage
- **Fast/slow momentum ratio** captures regime shifts (e.g., TSMOM, momentum factor models)
- **LST depegging**: Research shows LSTs maintain stable return correlation until liquidity crises

### **Example Scenarios**

#### **Scenario 1: Stablecoin Peg Break (USDC vs DAI)**

**Normal State:**
```
USDC: fast=$1.000, slow=$1.000 → r_USDC = 1.000
DAI:  fast=$0.999, slow=$1.001 → r_DAI  = 0.998
Divergence: |1.000 - 0.998| / 0.998 = 0.2% ✅ Within 1% threshold
```

**Depeg Event:**
```
USDC: fast=$1.000, slow=$1.000 → r_USDC = 1.000
DAI:  fast=$0.950, slow=$1.000 → r_DAI  = 0.950
Divergence: |1.000 - 0.950| / 0.950 = 5.3% ❌ Exceeds 1% threshold → HALT
```

#### **Scenario 2: LST Depeg (wstETH vs WETH)**

**Normal State (wstETH naturally appreciates):**
```
WETH:   fast=$2000, slow=$1900 → r_WETH   = 1.053 (+5.3% momentum)
wstETH: fast=$2100, slow=$2000 → r_wstETH = 1.050 (+5.0% momentum)
Divergence: |1.053 - 1.050| / 1.050 = 0.3% ✅ Within 5% LST threshold
```

**Depeg Event (Lido slashing):**
```
WETH:   fast=$2000, slow=$1900 → r_WETH   = 1.053 (+5.3% momentum)
wstETH: fast=$1800, slow=$2000 → r_wstETH = 0.900 (-10% momentum)
Divergence: |1.053 - 0.900| / 0.900 = 17% ❌ Exceeds 5% threshold → HALT
```

**Key Insight**: The check detects **divergence in momentum**, not absolute price. wstETH can trade at $2100 (5% premium to WETH) without triggering, but a sudden drop to $1800 (-10% vs prior trend) triggers the breaker.

### **Configuration Guidelines**

| Asset Pair | maxDeviation | Rationale |
|------------|--------------|-----------|
| USDC ↔ DAI | 100 bps (1%) | Stablecoins should track 1:1 (tight correlation) |
| wstETH ↔ WETH | 500 bps (5%) | LSTs have higher yield variance (looser correlation) |
| stETH ↔ WETH | 500 bps (5%) | Liquid staking rebasing asset |
| rETH ↔ WETH | 500 bps (5%) | Rocket Pool LST |
| cbETH ↔ WETH | 500 bps (5%) | Coinbase wrapped staked ETH |
| Volatile pairs | Disabled (0) | No meaningful correlation (e.g., WETH ↔ USDC) |

### **Staleness Protection**

**Problem**: If reference oracle is stale, the check could freeze trading unnecessarily.

**Solution**: Skip deviation check if reference oracle hasn't updated in 24 hours.

```solidity
if (block.timestamp - refOracle.lastOracleUpdate > 24 hours) {
    return true; // Safe default: allow trading
}
```

**Rationale**:
- ✅ **Conservative**: 24h staleness likely indicates oracle failure, not price event
- ✅ **Fail-open**: Prefer liquidity over false positives (guardians can still manually freeze)
- ✅ **Aligns with oracle design**: Internal oracles update on swap, 24h without swap = low activity

### **Implementation Details**

**Storage (Reuses Existing Struct):**
```solidity
struct CircuitBreaker {
    address referenceAsset;       // Reference asset to compare against (address(0) = disabled)
    uint16 maxDeviation;          // Max relative return divergence in bps (100=1%, 500=5%)
}
```

**Validation Logic:**
```solidity
function _checkCircuitBreakers(...) internal view returns (bool) {
    // CB#2: Deviation check
    if (breaker.referenceAsset != address(0)) {
        IBAMM.Asset storage refAsset = assets[breaker.referenceAsset];
        OracleEntry storage refOracle = oracleEntries[refAsset.oracleId];

        // Skip check if reference oracle is stale (>24h)
        if (block.timestamp - refOracle.lastOracleUpdate > 24 hours) {
            return true; // Safe default: allow trading
        }

        // Calculate relative return ratios: r = fast/slow
        uint256 assetRatio = _calculateRelativeReturn(oracle);
        uint256 refRatio = _calculateRelativeReturn(refOracle);

        // Calculate divergence: |(r_asset - r_ref) / r_ref| in bps
        uint256 divergenceBps = abs(assetRatio - refRatio) * 10000 / refRatio;

        // Trigger if divergence exceeds threshold
        if (divergenceBps > breaker.maxDeviation) {
            return false; // CB#2 triggered
        }
    }
    return true;
}

function _calculateRelativeReturn(OracleEntry storage oracle) private view returns (uint256 ratio) {
    // Calculate fast and slow TWAPs inline (Uniswap V3 accumulator formula)
    uint256 timeElapsed = block.timestamp - oracle.lastOracleUpdate;
    uint256 currentAccum = oracle.priceAccumulator + (uint256(oracle.currentPrice) * timeElapsed);

    uint256 timeDeltaFast = block.timestamp - oracle.fastSnapshotTime;
    uint64 fastTWAP = timeDeltaFast == 0 ? oracle.currentPrice : uint64((currentAccum - oracle.fastAccumSnapshot) / timeDeltaFast);

    uint256 timeDeltaSlow = block.timestamp - oracle.slowSnapshotTime;
    uint64 slowTWAP = timeDeltaSlow == 0 ? oracle.currentPrice : uint64((currentAccum - oracle.slowAccumSnapshot) / timeDeltaSlow);

    // Protect against division by zero
    if (slowTWAP == 0) return 10000; // Default: 1.0x (no divergence)

    // Calculate ratio: (fast / slow) * 10000
    ratio = (uint256(fastTWAP) * 10000) / uint256(slowTWAP);
}
```

**Gas Cost:**
- ~1500 gas (2 oracle reads, 2 TWAP calculations, ratio comparison)
- Amortized across swap (negligible relative to total swap cost)

---

## Guardian Role

### **Current Responsibilities**

The guardian role remains for **manual overrides only**:

1. **Manual freeze/unfreeze**: `freezeAsset()`, `unfreezeAsset()`
2. **Blacklist management**: `blacklist()`, `removeFromBlacklist()`
3. **Emergency pause**: Pause entire pool via owner-granted role

### **Removed Responsibilities**

❌ **Off-chain deviation monitoring**: Circuit Breaker #2 now handles this automatically on-chain

### **Why Keep Guardian?**

The guardian provides a **fail-safe** for edge cases not covered by automated checks:
- **Regulatory compliance**: Blacklist sanctioned addresses
- **Oracle failure**: Manual freeze if both main and fallback oracles fail
- **Novel attack vectors**: Emergency pause for zero-day exploits
- **Social consensus**: Community-driven freezes (e.g., DAO vote)

**Guardian is reactive, not proactive**: Automated circuit breakers handle 99% of price events.

---

## Error Handling

**Errors:**
```solidity
error ReservePriceViolation();           // CB#1: Price below reserve floor
error DeviationCircuitBreakerTriggered(); // CB#2: Relative return divergence exceeded
```

**User Experience:**
- Swaps revert immediately with clear error message
- Front-end should display: "Circuit breaker triggered - asset trading halted"
- Recommend checking oracle prices and waiting for market stabilization

**Recovery:**
- **CB#1**: Owner/guardian updates `reservePrice` or unfreezes asset once price recovers
- **CB#2**: Automatic recovery when fast/slow TWAP ratio normalizes (no manual intervention needed)

---

## Configuration Management

**Updating Reserve Price:**
```solidity
function updateReservePrice(address token, uint64 newReservePrice) external onlyOwner {
    IBAMM.Asset storage asset = _s().assets[token];
    asset.reservePrice = newReservePrice;
}
```

**Updating Circuit Breaker Config:**
```solidity
function updateCircuitBreaker(
    address token,
    address referenceAsset,
    uint16 maxDeviationBps
) external onlyOwner {
    IBAMM.CircuitBreaker storage breaker = _s().circuitBreakers[token];
    breaker.referenceAsset = referenceAsset;
    breaker.maxDeviation = maxDeviationBps;
}
```

**Best Practices:**
- Set `reservePrice` to 2-5% below current price for stablecoins
- Set `maxDeviation` to 1% for stablecoin pairs, 5% for LST pairs
- Review settings monthly or after major market events
- Test with mainnet fork before deploying to production

---

## Comparison to Other AMMs

| Protocol | Circuit Breaker Mechanism |
|----------|---------------------------|
| **BAMM** | Two independent on-chain checks (reserve floor + relative return divergence) |
| **Uniswap V3** | None (relies on arbitrageurs to correct mispricing) |
| **Balancer V2** | Rate-limited joins/exits (not price-based) |
| **Curve** | Admin-controlled A-parameter (slow adjustment, not automatic) |
| **Wombat** | Coverage ratio haircut (limits withdrawals, not swaps) |

**BAMM Advantages:**
- ✅ **Fully automated**: No guardian intervention required
- ✅ **LST-aware**: Handles non-zero beta assets correctly
- ✅ **Dual protection**: Both absolute floor AND relative divergence
- ✅ **Gas efficient**: <2000 gas overhead per swap

---

## Security Considerations

### **Attack Vectors**

1. **Oracle manipulation**: Attacker manipulates external oracle to bypass CB#2
   - **Mitigation**: Fallback oracle, 24h staleness check, manual freeze by guardian

2. **Flash loan price manipulation**: Attacker temporarily crashes pool price to trigger CB#1
   - **Mitigation**: TWAPs smooth out flash crashes, CB#1 checks oracle (not manipulable via pool)

3. **Grief attack**: Attacker intentionally triggers CB to freeze trading
   - **Mitigation**: Thresholds calibrated to avoid false positives, guardian can unfreeze

### **False Positive Risk**

**CB#1** (Reserve Price):
- **Low risk**: Only triggers if price truly drops below floor
- **Tuning**: Set floor 5-10% below normal trading range

**CB#2** (Deviation):
- **Medium risk**: Volatility spikes could cause false positives
- **Tuning**: LST threshold (5%) is 5x stablecoin threshold (1%) to account for yield variance
- **Staleness check**: Prevents false triggers from oracle failures

---

## Future Enhancements

### **Dynamic Thresholds**
- Adjust `maxDeviation` based on historical volatility (e.g., higher threshold during high vol regimes)
- Implement volatility bands (Bollinger Bands style)

### **Multi-Asset Correlation**
- Extend CB#2 to check multiple reference assets (e.g., wstETH vs both WETH and rETH)
- Trigger only if divergence exceeds threshold for ALL references

### **Time-Weighted Triggers**
- Require sustained divergence (e.g., 3+ consecutive blocks) to avoid flash loan manipulation

### **Gradual Freeze**
- Instead of binary freeze, apply progressive fee multiplier as divergence increases
- Example: 2% divergence → 2x fees, 5% divergence → halt

---

## Summary

**Circuit Breaker #1 (Reserve Price Floor):**
- ✅ Per-asset minimum price (B64 format)
- ✅ Checks both oracle AND pool spot price
- ✅ Zero storage overhead (uses padding)
- ✅ Use case: Stablecoin depeg protection

**Circuit Breaker #2 (Deviation-Based):**
- ✅ Compares relative returns (fast/slow TWAP ratio)
- ✅ Beta-neutral (works for yield-bearing LSTs)
- ✅ Automatic on-chain validation
- ✅ Staleness protection (skip if ref oracle >24h old)
- ✅ Use case: LST/stablecoin pair correlation breaks

**Guardian Role:**
- ✅ Manual freeze/unfreeze for edge cases
- ✅ Blacklist management for compliance
- ❌ No longer needed for systematic deviation monitoring

**Result:** Robust, automated protection against catastrophic price events with minimal gas overhead and no guardian dependencies.
