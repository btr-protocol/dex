# Swap Routing and Pricing Specification

## Overview

BAMM implements a **hub-and-spoke routing model** where all swaps route through a single **base token** (typically USDC) that acts as a pricing num�raire. This design provides:

- **Capital efficiency**: Single liquidity pool for all assets (no fragmentation)
- **Simple pricing**: All prices denominated in base token
- **Path independence**: Triangulated swaps (A�base�B) have identical slippage to hypothetical direct swaps
- **Minimal complexity**: Two swap types (direct and triangulated), predictable gas costs

**Key Components:**
1. **Base Token**: Central pricing num�raire (usually USDC)
2. **Direct Swaps**: A � base (one token is base)
3. **Triangulated Swaps**: A � base � B (base is virtual num�raire only)
4. **Virtual Depth**: Mechanism ensuring path independence for triangulated swaps

---

## Base Token as Num�raire

### Definition

**Num�raire**: A unit of account used for pricing all other assets. In BAMM, the base token serves as:

1. **Price denominator**: All asset prices quoted in base token units
   ```
   WETH price = 2000 USDC (base)
   DAI price = 1.00 USDC (base)
   ARB price = 0.80 USDC (base)
   ```

2. **Swap intermediary**: All swaps route through base (directly or virtually)
   ```
   DAI � WETH becomes:  DAI � USDC (virtual) � WETH
   ```

3. **Oracle reference**: Internal oracle tracks all prices in base token terms

### Why USDC as Base Token?

**Optimal characteristics**:
- **Stable value**: Minimal price volatility reduces oracle update frequency
- **Deep liquidity**: High trading volume across all pairs
- **Universal pairing**: Every major asset has USDC liquidity
- **Minimal slippage**: Tight spreads for most routes

**Alternative base tokens** (less ideal):
- **WETH**: Volatile price, worse for stable pairs
- **BTC**: Lower DeFi liquidity than WETH
- **DAI**: Less liquid than USDC, potential depeg risk

**Base token properties** (enforced at deployment):
```solidity
// Base token must be:
- ERC20 compliant
- Non-rebasing (constant balances)
- No fee-on-transfer
- Widely liquid (verified off-chain)
- Stable or flagship asset (USDC, USDT, DAI, WETH)
```

---

## Swap Types

### Direct Swap (A � base)

**Definition**: One of the two tokens (tokenIn or tokenOut) **is** the base token.

**Examples**:
```
USDC � WETH  (USDC is base, direct)
WETH � USDC  (USDC is base, direct)
DAI � USDC   (USDC is base, direct)
```

**Routing**:
```
User sends:    100 USDC
Swap route:    USDC � WETH (single leg, base involved)
User receives: 0.05 WETH
```

**Reserve changes**:
```solidity
// Buying WETH with USDC (base)
assets[USDC].reserves += amountIn   // Base reserves increase
assets[WETH].reserves -= amountOut  // WETH reserves decrease
```

**Liability changes** (normal swaps don't change liabilities):
```solidity
// Liabilities unchanged in normal swaps
assets[USDC].liabilities == unchanged
assets[WETH].liabilities == unchanged
```

**Fee split**:
```
Total fee: calculated from tri-factor model (coverage � vol � divergence)
Leg 1 (USDC): 50% of total fee � USDC LPs
Leg 2 (WETH): 50% of total fee � WETH LPs
```

**Key property**: Base token **participates in pricing, fees, and reserve changes**.

### Triangulated Swap (A � base � B)

**Definition**: **Neither** tokenIn nor tokenOut is the base token. Base is used purely as a **virtual num�raire** for pricing.

**Examples**:
```
DAI � WETH  (via USDC base, triangulated)
USDT � ARB  (via USDC base, triangulated)
stETH � WBTC (via USDC base, triangulated)
```

**Routing**:
```
User sends:    100 DAI
Leg 1 (virtual): DAI � USDC (100 DAI worth = ~100 USDC)
Leg 2 (virtual): USDC � WETH (~100 USDC worth = ~0.05 WETH)
User receives: 0.05 WETH

CRITICAL: USDC reserves and liabilities UNCHANGED (virtual routing only)
```

**Reserve changes**:
```solidity
// Triangulated swap: DAI � WETH (via USDC base)
assets[DAI].reserves += amountIn    // DAI reserves increase
assets[WETH].reserves -= amountOut  // WETH reserves decrease
assets[USDC].reserves == unchanged  // Base UNCHANGED (virtual only)
```

**Liability changes**:
```solidity
// Liabilities unchanged in normal swaps (both direct and triangulated)
assets[DAI].liabilities == unchanged
assets[WETH].liabilities == unchanged
assets[USDC].liabilities == unchanged
```

**Fee split**:
```
Total fee: calculated from tri-factor model (only DAI and WETH factors, NOT base)
Leg 1 (DAI): 50% of total fee � DAI LPs
Leg 2 (WETH): 50% of total fee � WETH LPs
Base (USDC): 0% of fee � USDC LPs earn NOTHING (virtual routing)
```

**Key property**: Base token **provides pricing only**, no reserve/liability changes, no LP fees.

---

## Virtual Depth and Path Independence

### Problem: Base Token Depth Affects Slippage

**Without virtual depth**, triangulated swaps would suffer variable slippage based on base token depth:

```
Scenario: DAI � WETH swap via USDC base

Case 1: USDC pool has 10M reserves (deep)
  � Low slippage on both DAI�USDC and USDC�WETH legs
  � Total slippage: ~0.3%

Case 2: USDC pool has 100K reserves (shallow)
  � HIGH slippage on both legs (base is bottleneck)
  � Total slippage: ~5%

Problem: Same DAI�WETH swap has wildly different slippage based on unrelated USDC liquidity
```

**This violates path independence**: The route DAI�USDC�WETH should have the same slippage as a hypothetical direct DAI�WETH pool.

### Solution: Virtual Depth

**Virtual depth** makes base token **appear** as deep (or shallow) as the real economic assets (DAI and WETH), ensuring **path independence**.

**Formula**:
```solidity
// For triangulated swap A � base � B

// Leg 1 (A � base):
virtualBaseDepth_leg1 = effectiveDepth(assetA)

// Leg 2 (base � B):
virtualBaseDepth_leg2 = effectiveDepth(assetB)

where:
effectiveDepth(asset) = asset.reserves  // Simple: use actual reserves
```

**Effective behavior**:
```
DAI reserves: 5M
WETH reserves: 2500 (= $5M worth at $2000/WETH)
USDC reserves: 100K (shallow, but irrelevant)

Leg 1 (DAI � USDC virtual):
  Use virtualDepth = 5M (DAI's depth) for slippage calculation
  � USDC *appears* to have 5M liquidity for this leg

Leg 2 (USDC virtual � WETH):
  Use virtualDepth = 2500 * $2000 = 5M (WETH's depth equivalent)
  � USDC *appears* to have 5M liquidity for this leg

Result: Slippage depends ONLY on DAI and WETH curves, NOT USDC
```

### Implementation

**During pricing calculation** (see `LibPricing.sol:quoteRoute`):

```solidity
function quoteRoute(...) internal view returns (RouteQuote memory rq) {
    rq.isTriangulated = (tokenIn != baseToken && tokenOut != baseToken);

    if (!rq.isTriangulated) {
        // Direct swap: use actual reserves for both legs
        priceIn = _segmentPrice(assetIn, profIn, dataIn, amountIn);
        priceOut = _segmentPrice(assetOut, profOut, dataOut, 0);
    } else {
        // Triangulated swap: use virtual depth for base legs

        // Virtual depth for base (path independence)
        uint256 virtualBaseDepth1 = _effectiveDepth(assetIn);   // Use tokenIn depth
        uint256 virtualBaseDepth2 = _effectiveDepth(assetOut);  // Use tokenOut depth

        // Get spot prices using virtual depth
        priceIn = _segmentPrice(assetIn, profIn, dataIn, amountIn);
        priceBase1 = _segmentPriceWithDepth(assetBase, profBase, dataBase, 0, virtualBaseDepth1);
        priceOut = _segmentPrice(assetOut, profOut, dataOut, 0);
        priceBase2 = _segmentPriceWithDepth(assetBase, profBase, dataBase, amountBase, virtualBaseDepth2);

        // Base reserves UNCHANGED (virtual routing)
        // Slippage computed from virtual depth, NOT actual base reserves
    }
}
```

**Key insight**: Virtual depth affects **slippage calculation only**, not reserve accounting. Base reserves remain unchanged.

### Example: Path Independence Verification

**Setup**:
```
DAI reserves: 1M
WETH reserves: 500 (= $1M at $2000/WETH)
USDC reserves: 10K (shallow base)

User swaps: 10K DAI � WETH
```

**Without virtual depth** (broken):
```
Leg 1: 10K DAI � USDC
  Slippage: Low (DAI pool is deep)
  Receive: ~10K USDC

Leg 2: 10K USDC � WETH
  Slippage: HIGH (USDC pool only has 10K reserves, trade consumes 100%!)
  Receive: ~3 WETH (massive slippage due to shallow USDC)

Total received: 3 WETH (terrible price)
```

**With virtual depth** (correct):
```
virtualBaseDepth_leg1 = 1M (DAI reserves)
virtualBaseDepth_leg2 = 500 * $2000 = 1M (WETH reserves equivalent)

Leg 1: 10K DAI � USDC (virtual)
  Slippage: Computed using virtualDepth = 1M (not actual 10K)
  Virtual receive: ~10K USDC equivalent

Leg 2: USDC (virtual) � WETH
  Slippage: Computed using virtualDepth = 1M (not actual 10K)
  Receive: ~5 WETH (same slippage as direct DAI�WETH would have)

Total received: 5 WETH (path-independent price)

USDC reserves: Still 10K (unchanged, virtual routing)
```

**Verification**: DAI�USDC�WETH (virtual depth) H hypothetical direct DAI�WETH pool slippage.

---

## Pricing Flow

### Direct Swap Pricing

**Example**: 100 USDC � WETH

```solidity
// 1. Decode oracles
OracleData memory dataIn = decodeOracle(oracleUSDC);
OracleData memory dataOut = decodeOracle(oracleWETH);

// 2. Get spot prices from piecewise curves
priceIn = segmentPrice(assetUSDC, profileUSDC, dataIn, 100);  // USDC price in base
priceOut = segmentPrice(assetWETH, profileWETH, dataOut, 0); // WETH price in base

// 3. Calculate tri-factor fee
// Coverage: post-swap for inflows (USDC), pre-swap for outflows (WETH)
coverageUSDC_post = (reservesUSDC + 100) / liabilitiesUSDC
coverageWETH_pre = reservesWETH / liabilitiesWETH

m_USDC = m_cov(coverageUSDC_post) � m_vol(dataIn) � m_pd(priceIn, dataIn)
m_WETH = m_cov(coverageWETH_pre) � m_vol(dataOut) � m_pd(priceOut, dataOut)

m_path = sqrt(m_USDC � m_WETH)  // Geometric mean
totalFeeBps = baseFee � m_path / 1e18

// 4. Apply fee
feeAmount = 100 � totalFeeBps / 1_000_000
amountAfterFee = 100 - feeAmount

// 5. Convert via prices
amountOut = (amountAfterFee � priceIn) / priceOut
amountOut = adjustDecimals(amountOut, 6, 18)  // USDC 6 decimals � WETH 18 decimals

// 6. Fee split 50/50
leg1FeeBps = totalFeeBps / 2  // USDC LPs
leg2FeeBps = totalFeeBps / 2  // WETH LPs

feeIn = amountIn � leg1FeeBps / 1_000_000   // USDC units
feeOut = amountOut � leg2FeeBps / 1_000_000  // WETH units

protocolFeeIn = feeIn � protocolFeeBps / 1_000_000
protocolFeeOut = feeOut � protocolFeeBps / 1_000_000

lpFeeIn = feeIn - protocolFeeIn
lpFeeOut = feeOut - protocolFeeOut
```

**Reserve changes**:
```solidity
assets[USDC].reserves += 100         // Inflow
assets[WETH].reserves -= amountOut   // Outflow
```

**Coverage timing**: FEES.md specifies post-swap coverage for inflows, pre-swap for outflows (ALM incentives).

### Triangulated Swap Pricing

**Example**: 100 DAI � WETH (via USDC base)

```solidity
// 1. Decode oracles
OracleData memory dataDAI = decodeOracle(oracleDAI);
OracleData memory dataUSDC = decodeOracle(oracleUSDC);  // Base
OracleData memory dataWETH = decodeOracle(oracleWETH);

// 2. Calculate virtual depths
virtualBaseDepth1 = effectiveDepth(assetDAI);   // DAI reserves
virtualBaseDepth2 = effectiveDepth(assetWETH);  // WETH reserves

// 3. Get spot prices (using virtual depth for base)
priceDAI = segmentPrice(assetDAI, profileDAI, dataDAI, 100);
priceUSDC_leg1 = segmentPriceWithDepth(assetUSDC, profileUSDC, dataUSDC, 0, virtualBaseDepth1);
priceWETH = segmentPrice(assetWETH, profileWETH, dataWETH, 0);

// 4. Calculate tri-factor fee (only DAI and WETH, NOT base)
m_DAI = m_cov(coverageDAI_post) � m_vol(dataDAI) � m_pd(priceDAI, dataDAI)
m_WETH = m_cov(coverageWETH_pre) � m_vol(dataWETH) � m_pd(priceWETH, dataWETH)

m_path = sqrt(m_DAI � m_WETH)  // Geometric mean (base NOT included)
totalFeeBps = baseFee � m_path / 1e18

// 5. Leg 1: DAI � USDC (virtual)
feeAmount1 = 100 � (totalFeeBps / 2) / 1_000_000
amountAfterFee1 = 100 - feeAmount1

amountBase = (amountAfterFee1 � priceDAI) / priceUSDC_leg1  // Virtual USDC amount
amountBase = adjustDecimals(amountBase, 18, 6)  // DAI 18 � USDC 6 decimals

// 6. Leg 2: USDC (virtual) � WETH
priceUSDC_leg2 = segmentPriceWithDepth(assetUSDC, profileUSDC, dataUSDC, amountBase, virtualBaseDepth2);

rawAmountOut = (amountBase � priceUSDC_leg2) / priceWETH
rawAmountOut = adjustDecimals(rawAmountOut, 6, 18)  // USDC 6 � WETH 18 decimals

feeAmount2 = rawAmountOut � (totalFeeBps / 2) / 1_000_000
amountOut = rawAmountOut - feeAmount2

// 7. Fee split (base earns NOTHING)
leg1FeeBps = totalFeeBps / 2  // DAI LPs
leg2FeeBps = totalFeeBps / 2  // WETH LPs
baseLeg1FeeBps = 0            // USDC LPs earn 0 (virtual routing)
baseLeg2FeeBps = 0            // USDC LPs earn 0 (virtual routing)

protocolFeeIn = feeAmount1 � protocolFeeBps / 1_000_000   // DAI units
protocolFeeOut = feeAmount2 � protocolFeeBps / 1_000_000  // WETH units

lpFeeIn = feeAmount1 - protocolFeeIn
lpFeeOut = feeAmount2 - protocolFeeOut
```

**Reserve changes**:
```solidity
assets[DAI].reserves += 100           // Inflow
assets[WETH].reserves -= amountOut    // Outflow
assets[USDC].reserves == UNCHANGED    // Base virtual (no change)
```

**Key difference**: Base token reserves and liabilities **completely unchanged** in triangulated swaps.

**Coverage timing**: FEES.md specifies post-swap coverage for inflows, pre-swap for outflows (ALM incentives).

---

## Fee Distribution

### Direct Swap (A � base)

**Fee split**: 50/50 between tokenIn and tokenOut LPs

```
Example: 100 USDC � WETH
Total fee: 30 bps (0.3%)
Total fee amount: 0.3 USDC equivalent

Leg 1 (USDC): 15 bps applied to 100 USDC = 0.15 USDC
  � Protocol fee: 0.15 � 1% = 0.0015 USDC
  � LP fee: 0.1485 USDC � USDC LPs

Leg 2 (WETH): 15 bps applied to output (~0.05 WETH)
  � Protocol fee: ~0.00005 WETH
  � LP fee: ~0.00045 WETH � WETH LPs
```

**Both legs earn fees** because both involve real liquidity:
- USDC reserves increase (liquidity provided)
- WETH reserves decrease (liquidity consumed)

### Triangulated Swap (A � base � B)

**Fee split**: 50/50 between tokenIn and tokenOut LPs, **base earns 0%**

```
Example: 100 DAI � WETH (via USDC base)
Total fee: 30 bps (0.3%)
Total fee amount: 0.3 DAI equivalent

Leg 1 (DAI): 15 bps applied to 100 DAI = 0.15 DAI
  � Protocol fee: 0.15 � 1% = 0.0015 DAI
  � LP fee: 0.1485 DAI � DAI LPs

Leg 2 (WETH): 15 bps applied to output (~0.05 WETH)
  � Protocol fee: ~0.00005 WETH
  � LP fee: ~0.00045 WETH � WETH LPs

Base (USDC): 0 bps (virtual routing, no liquidity used)
  � Protocol fee: 0
  � LP fee: 0 � USDC LPs earn NOTHING
```

**Base earns no fees** because it provides no liquidity:
- USDC reserves unchanged (virtual num�raire only)
- No USDC LP capital at risk in this swap
- Only DAI and WETH liquidity actually used

**Fair distribution**: Fees go to LPs who provide real liquidity, not virtual accounting.

---

## Decimal Handling

BAMM supports tokens with arbitrary decimals (e.g., USDC=6, WETH=18, SHIB=18).

### Decimal Adjustment Formula

```solidity
function adjustDecimals(
    uint256 amount,
    uint8 decimalsIn,
    uint8 decimalsOut
) internal pure returns (uint256) {
    if (decimalsIn > decimalsOut) {
        // Scale down
        return amount / (10 ** (decimalsIn - decimalsOut));
    } else if (decimalsOut > decimalsIn) {
        // Scale up
        return amount * (10 ** (decimalsOut - decimalsIn));
    } else {
        // Same decimals
        return amount;
    }
}
```

### Example: USDC (6) � WETH (18)

```solidity
// User swaps 100 USDC (6 decimals)
amountIn = 100_000_000  // 100.0 USDC in 6-decimal units

// Convert to WETH (18 decimals) after pricing
amountOut = 50_000_000_000_000_000  // 0.05 WETH in 18-decimal units

// Adjustment applied:
amountOut = amountOut_raw � 10^(18-6) = amountOut_raw � 10^12
```

### Example: WETH (18) � USDC (6)

```solidity
// User swaps 0.05 WETH (18 decimals)
amountIn = 50_000_000_000_000_000  // 0.05 WETH in 18-decimal units

// Convert to USDC (6 decimals) after pricing
amountOut = 100_000_000  // 100.0 USDC in 6-decimal units

// Adjustment applied:
amountOut = amountOut_raw / 10^(18-6) = amountOut_raw / 10^12
```

**Precision loss**: When scaling down (e.g., 18�6 decimals), dust amounts (<1e-6) are truncated. This is acceptable for normal trade sizes.

---

## Slippage Protection

### Minimum Output Amount

**User specifies** `minAmountOut` when calling `swap()`:

```solidity
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,  // Slippage protection
    address receiver
) external returns (uint256 amountOut);
```

**Enforcement**:
```solidity
amountOut = quoteRoute(...);
require(amountOut >= minAmountOut, "Slippage exceeded");
```

**Frontend calculation**:
```javascript
// Get quote from on-chain view function
const quote = await bamm.getQuote(tokenIn, tokenOut, amountIn);

// Apply slippage tolerance (e.g., 1%)
const slippageBps = 100;  // 1% = 100 bps
const minAmountOut = quote * (1_000_000 - slippageBps) / 1_000_000;

// Execute swap
await bamm.swap(tokenIn, tokenOut, amountIn, minAmountOut, receiver);
```

### Why Slippage Occurs

1. **Oracle lag**: Internal TWAP updates slower than spot price movement
2. **Liquidity depth**: Large trades consume multiple segments of piecewise curve
3. **Coverage imbalance**: High fees when assets over/under-collateralized
4. **Volatility spike**: Tri-factor fee multiplier increases during high vol
5. **Frontrunning**: MEV bot trades before user transaction

**Virtual depth eliminates** base token depth as a slippage source in triangulated swaps.

---

## Gas Costs

### Direct Swap (A � base)

**Typical gas**: ~80,000

```
Oracle updates (2 assets):    ~20,000
Piecewise curve traversal:    ~15,000
Coverage factor calculation:  ~10,000
Fee computation:              ~8,000
Reserve updates:              ~15,000
Event emission:               ~5,000
Transfers (2):                ~10,000
```

### Triangulated Swap (A � base � B)

**Typical gas**: ~110,000

```
Oracle updates (3 assets):    ~30,000
Virtual depth calculation:    ~5,000
Piecewise curve traversal:    ~20,000
Coverage factor calculation:  ~12,000
Fee computation:              ~10,000
Reserve updates (2 non-base): ~15,000
Event emission:               ~8,000
Transfers (2):                ~10,000
```

**Gas delta**: Triangulated swaps cost ~30k more gas due to:
- Extra oracle decode (base token)
- Virtual depth computation
- Additional pricing leg

**Still competitive** with multi-hop routers (Uniswap V3 multi-hop: ~150k-200k gas).

---

## Security Considerations

### 1. Base Token Reserve Consistency

**Invariant**: In triangulated swaps, base token reserves and liabilities must remain unchanged.

**Enforcement**:
```solidity
// Before swap
uint256 baseReservesBefore = assets[baseToken].reserves;
uint256 baseLiabilitiesBefore = assets[baseToken].liabilities;

// Execute triangulated swap
_executeTriangulatedSwap(...);

// After swap
assert(assets[baseToken].reserves == baseReservesBefore);
assert(assets[baseToken].liabilities == baseLiabilitiesBefore);
```

**Tests**: Fuzz test with random triangulated swaps, verify base unchanged.

### 2. Virtual Depth Manipulation

**Attack**: User attempts to manipulate virtual depth calculation to reduce slippage.

**Mitigation**:
- Virtual depth uses **actual reserves** (not user-controllable)
- No user input affects depth calculation
- Depth computed at swap execution time (no stale state)

### 3. Decimal Overflow/Underflow

**Attack**: Extreme decimal differences cause overflow in adjustment.

**Mitigation**:
```solidity
// Max decimal difference: 18 (e.g., 0 decimals � 18 decimals)
// Max multiplier: 10^18 (fits in uint256)

// Overflow check (automatic in Solidity 0.8+)
require(amount <= type(uint256).max / (10 ** decimalDiff), "Overflow");
```

### 4. Price Manipulation via Flash Swaps

**Attack**: Flash swap to move oracle, profit on next trade.

**Mitigation**:
- **TWAP windows**: Fast TWAP (5min) and slow TWAP (30min) resist manipulation
- **Circuit breakers**: Deviation freeze triggers if fast/slow diverge >threshold
- **Tri-factor fees**: High fees during manipulation attempts (volatility spike)

See [CIRCUIT_BREAKERS.md](./CIRCUIT_BREAKERS.md) for details.

### 5. Path Independence Failure

**Attack**: Exploit difference between direct and triangulated routes for same pair.

**Mitigation**:
- **Virtual depth** ensures path independence (tested)
- **Fee model identical** for both routes
- **Invariant tests**: `directSwap(A,B) H triangulatedSwap(A,base,B)` within rounding

---

## Testing Strategy

### Unit Tests

```solidity
testDirectSwap()
  - Swap USDC � WETH
  - Verify amountOut matches quote
  - Verify reserves updated correctly
  - Verify fees distributed 50/50

testTriangulatedSwap()
  - Swap DAI � WETH (via USDC)
  - Verify base reserves unchanged
  - Verify base liabilities unchanged
  - Verify fees exclude base (only DAI + WETH LPs earn)

testVirtualDepth()
  - Compare slippage with/without virtual depth
  - Verify path independence: direct H triangulated

testDecimalAdjustment()
  - Test all combinations: 6�18, 18�6, 18�18, 0�18, etc.
  - Verify no overflow/underflow

testCoverageTiming()
  - Verify inflows use post-swap coverage
  - Verify outflows use pre-swap coverage
  - Verify rebalancing incentives work
```

### Integration Tests

```solidity
testMultipleTriangulatedSwaps()
  - Execute 100 random DAI�WETH swaps
  - Verify base reserves unchanged after all swaps
  - Verify base earns no fees

testRebalancingIncentives()
  - Setup underwater asset (coverage <1.0)
  - Execute swap to rebalance
  - Verify fee discount applied
  - Verify coverage improves

testGasCosts()
  - Measure direct swap gas
  - Measure triangulated swap gas
  - Verify within expected ranges
```

### Invariant Tests

```solidity
invariant_baseUnchangedTriangulated()
  // For all triangulated swaps:
  // base.reserves_post == base.reserves_pre
  // base.liabilities_post == base.liabilities_pre

invariant_pathIndependence()
  // For swaps where direct route exists:
  // directSwap(A,B) H triangulatedSwap(A,base,B) within 0.1%

invariant_feeDistribution()
  // Total fees collected == sum(LP fees) + sum(protocol fees)
  // Base earns 0 fees in triangulated swaps
```

---

## Related Documentation

- **[FEES.md](./FEES.md)**: Complete tri-factor fee specification, **including coverage timing for ALM incentives**
- **[ALM_AND_COVERAGE.md](./ALM_AND_COVERAGE.md)**: Coverage ratio dynamics and ALM incentives
- **[LIQUIDITY_SHAPING.md](./LIQUIDITY_SHAPING.md)**: Piecewise bonding curves (Makima splines) and pricing
- **[ORACLE.md](./ORACLE.md)**: Internal oracle system, TWAP calculation, volatility tracking
- **[CIRCUIT_BREAKERS.md](./CIRCUIT_BREAKERS.md)**: Price deviation freeze and reserve price floors
- **[LIABILITY_SWAP.md](./LIABILITY_SWAP.md)**: LP liability swapping (rebalancing without haircut)

---

## Summary

**Hub-and-spoke routing** with base token as num�raire provides:

 **Capital efficiency**: Single liquidity pool, no fragmentation
 **Simple pricing**: All prices in base token units
 **Path independence**: Virtual depth ensures A�base�B H direct A�B slippage
 **Fair fee distribution**: Only real liquidity providers earn fees
 **Predictable gas**: ~80k direct, ~110k triangulated
 **ALM incentives**: Coverage timing rewards rebalancing, penalizes imbalance

**Two swap types**:
1. **Direct (A � base)**: Base participates in reserves, fees, coverage
2. **Triangulated (A � base � B)**: Base is virtual num�raire only (reserves/liabilities unchanged, no fees)

**Virtual depth** is the key mechanism ensuring triangulated swaps have the same slippage as hypothetical direct pairs, making the hub-and-spoke model equivalent to a fully-connected pool in terms of user experience.
