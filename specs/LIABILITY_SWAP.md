# Liability Swap Specification

## Overview

**Liability swaps** enable LPs to migrate their liability claims (ERC1155 LP tokens) from one asset to another, effectively executing a swap using their LP position as the underlying. This critical feature allows LPs to **rebalance exposure without suffering haircut penalties** when withdrawing from underwater assets.

**Key Benefit**: When an asset has negative coverage ratio (C < 1.0), normal withdraw → swap → deposit flows suffer haircut on withdrawal. Liability swaps bypass this by transferring liabilities directly, applying haircut **only** if the swap worsens net pool coverage.

---

## Problem Statement

### The Haircut Rebalancing Problem

**Current flow** (withdraw → swap → deposit):
```
User wants to rebalance: USDC LP → WETH LP

Asset state:
- USDC: C = 0.7 (70% coverage, underwater)
- WETH: C = 1.2 (120% coverage, over-collateralized)

Step 1: Withdraw USDC
  LP shares: 1000 USDC liability
  Haircut: 1000 × 0.7 = 700 USDC received
  Loss: 300 USDC (30% haircut)

Step 2: Swap 700 USDC → WETH
  Normal swap fees apply (~0.3% base)
  Receive: ~350 WETH

Step 3: Deposit 350 WETH
  Receive: WETH LP tokens for 350 WETH

Net result: 1000 USDC liability → 350 WETH liability (65% value loss due to haircut)
```

**Liability swap flow**:
```
Same initial state:
- USDC: C = 0.7
- WETH: C = 1.2

Liability swap: 1000 USDC liability → WETH liability

Coverage impact:
  USDC: No reserve change, liabilities -1000 → C improves (0.7 → higher)
  WETH: No reserve change, liabilities +quote(1000 USDC) → C worsens (1.2 → lower)

Net coverage delta:
  USDC improvement: ΔC₁ = +improvement from reducing liabilities
  WETH worsening: ΔC₂ = -worsening from adding liabilities
  Net: ΔC_net = ΔC₁ + ΔC₂

If ΔC_net ≥ 0 (net positive or neutral):
  No haircut applied
  Full swap quote received

If ΔC_net < 0 (net negative):
  Haircut = |ΔC_net| × swapAmount
  Applied to worse coverage ratio asset post-swap

Net result: Minimal or zero haircut if rebalancing toward equilibrium
```

**Use Case**: **Constant-mix rebalancing strategies** (e.g., 60/40 USDC/WETH) become viable for LPs even when assets are underwater.

---

## Design Principles

1. **Coverage-neutral swaps incur no haircut**: If the value-weighted net coverage delta is ≥ 0 (system neutral or improving), no penalty
2. **Same fees as normal swaps**: Tri-factor fee model applies (coverage × volatility × divergence)
3. **Hub-and-spoke routing**: Follows existing triangulated swap model (A → base → B or A ↔ base)
4. **Virtual base reserves**: Base token reserves/liabilities unchanged in triangulated swaps (numéraire only)
5. **Haircut on worse asset**: If net coverage worsens, haircut applied to asset with worse post-swap coverage
6. **Decay compatibility**: Allowed during active liability decay (owner should configure linear decay to prevent gaming)

---

## Mathematical Specification

### Coverage Delta Calculation

For liability swap from asset **A** (source) to asset **B** (destination):

**Pre-swap state:**
```
Asset A: reserves = R_A, liabilities = L_A, C_A = R_A / L_A
Asset B: reserves = R_B, liabilities = L_B, C_B = R_B / L_B
```

**Quoted swap amount:**
```
User swaps lpAmount_A of asset A liability

Using normal swap pricing (tri-factor fees applied):
  lpAmount_B = quote(lpAmount_A, A → B)
```

**Post-swap state (liability transfer, reserves unchanged):**
```
Asset A: reserves = R_A (unchanged), liabilities = L_A - lpAmount_A
Asset B: reserves = R_B (unchanged), liabilities = L_B + lpAmount_B

C'_A = R_A / (L_A - lpAmount_A)
C'_B = R_B / (L_B + lpAmount_B)
```

**Coverage deltas (value-weighted in base token):**
```
To prevent arbitrage via reserves value manipulation, coverage deltas are weighted by asset value in base token:

price_A = swap_price(A, base)  // Price of A in base token units
price_B = swap_price(B, base)  // Price of B in base token units

value_A = R_A × price_A  // Asset A value in base token
value_B = R_B × price_B  // Asset B value in base token

ΔC_A = C'_A - C_A  // Unit-based coverage delta for A
ΔC_B = C'_B - C_B  // Unit-based coverage delta for B

ΔC_A_weighted = ΔC_A × value_A  // Value-weighted delta for A
ΔC_B_weighted = ΔC_B × value_B  // Value-weighted delta for B

Net coverage delta (value-weighted):
ΔC_net = ΔC_A_weighted + ΔC_B_weighted

If ΔC_net ≥ 0: System is neutral or improving (no haircut)
If ΔC_net < 0: System is worsening (haircut applied)
```

**Rationale for value weighting**: Without value weighting, users could exploit reserves value differences to minimize haircuts while extracting value. Value weighting ensures coverage deltas reflect true economic impact on the pool.

### Haircut Logic

**Coverage-neutral or positive (pool improves or stays neutral):**
```solidity
if (ΔC_net ≥ 0) {
    haircut = 0
    finalLpAmount_B = lpAmount_B  // Full quote received
}
```

**Coverage worsening (value-weighted net delta negative):**
```solidity
if (ΔC_net < 0) {
    // Haircut proportional to net value-weighted coverage worsening
    // Normalize by total pool value to get haircut ratio
    totalPoolValue = value_A + value_B
    haircutRatio = |ΔC_net| / totalPoolValue

    // Apply haircut to swapped liability amount
    haircut = lpAmount_B × haircutRatio

    // Write off haircut on asset with worse post-swap coverage
    worseAsset = (C'_A < C'_B) ? A : B

    if (worseAsset == A) {
        liabilities_A -= haircut  // Additional reduction beyond swap
        finalLpAmount_B = lpAmount_B  // Destination gets full amount
    } else {
        liabilities_B -= haircut  // Reduce added liability
        finalLpAmount_B = lpAmount_B - haircut  // User receives less
    }
}
```

**Haircut interpretation:**
- If destination worsens coverage more than source improves it, the **user bears the net imbalance**
- Haircut written off on the worse coverage asset (liability decrease with no reserve change)
- Remaining LPs benefit from haircut (improves their coverage ratio)

### Example: Rebalancing from Underwater to Healthy

```
Initial state:
  USDC: R = 700, L = 1000, C = 0.7
  WETH: R = 120, L = 100, C = 1.2

User swaps: 1000 USDC liability → WETH liability

Quote: 1000 USDC → 500 WETH (normal swap pricing, tri-factor fees applied)

Post-swap:
  USDC: R = 700, L = 1000 - 1000 = 0, C' = 700 / 1 = 700 (or ∞ if L=0)
  WETH: R = 120, L = 100 + 500 = 600, C' = 120 / 600 = 0.2

Coverage deltas:
  ΔC_USDC = 700 - 0.7 = +699.3 (massive improvement)
  ΔC_WETH = 0.2 - 1.2 = -1.0 (worsening)

  ΔC_net = 699.3 - 1.0 = +698.3 (net positive)

Result: ΔC_net > 0 → No haircut
  User receives full 500 WETH liability
```

### Example: Worsening Pool Balance

```
Initial state:
  USDC: R = 700, L = 1000, C = 0.7
  DAI: R = 500, L = 1000, C = 0.5 (worse than USDC)

User swaps: 500 USDC liability → DAI liability

Quote: 500 USDC → 500 DAI (assume 1:1 for simplicity)

Post-swap:
  USDC: R = 700, L = 1000 - 500 = 500, C' = 700 / 500 = 1.4
  DAI: R = 500, L = 1000 + 500 = 1500, C' = 500 / 1500 = 0.33

Coverage deltas:
  ΔC_USDC = 1.4 - 0.7 = +0.7
  ΔC_DAI = 0.33 - 0.5 = -0.17

  ΔC_net = 0.7 - 0.17 = +0.53 (net positive)

Result: ΔC_net > 0 → No haircut
  User receives full 500 DAI liability
```

### Example: Net Coverage Worsening

```
Initial state:
  WETH: R = 120, L = 100, C = 1.2 (over-collateralized)
  BONK: R = 10M, L = 40M, C = 0.25 (deeply underwater)

User swaps: 100 WETH liability → BONK liability

Quote: 100 WETH → 200M BONK (assume exchange rate)

Post-swap:
  WETH: R = 120, L = 100 - 100 = 0, C' = 120 / 1 = 120 (or ∞)
  BONK: R = 10M, L = 40M + 200M = 240M, C' = 10M / 240M = 0.042

Coverage deltas:
  ΔC_WETH = 120 - 1.2 = +118.8
  ΔC_BONK = 0.042 - 0.25 = -0.208

  ΔC_net = 118.8 - 0.208 = +118.6 (still net positive!)

Result: ΔC_net > 0 → No haircut
```

**Observation**: It's quite rare for net coverage to worsen, since reducing liabilities on underwater assets creates large positive deltas. Haircut primarily applies when swapping **from healthy to deeply underwater** in large amounts.

---

## Routing Model

### Hub-and-Spoke (Triangulated)

**Triangulated swap** (A → base → B):
```
Example: USDC liability → WETH liability (via base = USDC)

Wait, USDC *is* the base token, so this is a direct swap.

Better example: DAI liability → WETH liability (via USDC base)

Leg 1 (virtual): DAI → USDC (base)
  - No USDC reserve change (virtual numéraire)
  - No USDC liability change (virtual routing)
  - DAI liabilities decrease

Leg 2 (virtual): USDC (base) → WETH
  - No USDC reserve change (virtual numéraire)
  - No USDC liability change (virtual routing)
  - WETH liabilities increase

Net result:
  - Only DAI and WETH liabilities change
  - Base token (USDC) completely unaffected
  - Fees split 50/50 between DAI and WETH LPs (base earns nothing in triangulated)
```

### Direct Swap (A ↔ base)

**Direct swap** (base is tokenIn or tokenOut):
```
Example: USDC liability → WETH liability (USDC is base)

Leg 1: USDC liabilities decrease
Leg 2: WETH liabilities increase

Since USDC is base:
  - This is a direct swap (not triangulated)
  - Coverage delta computed for both USDC and WETH
  - Fees split 50/50 between USDC and WETH LPs
```

**Critical**: In **triangulated** liability swaps, base token reserves and liabilities are **completely unchanged** (virtual routing only). This is consistent with normal triangulated swaps.

**See [SWAP.md](./SWAP.md) for complete hub-and-spoke routing specification**, including virtual depth mechanics and numéraire concepts.

---

## Fee Model

### Tri-Factor Fees Apply

Liability swaps use the **same tri-factor fee model** as normal swaps:

```solidity
// Per-asset multipliers
m_A = m_cov(A, pre-swap) × m_vol(A) × m_pd(A)
m_B = m_cov(B, pre-swap) × m_vol(B) × m_pd(B)

// Geometric mean for path fee
m_path = sqrt(m_A × m_B)

// Total fee
totalFeeBps = baseFee × m_path / 1e18

// Split 50/50 between legs
leg1FeeBps = totalFeeBps / 2
leg2FeeBps = totalFeeBps / 2

// Apply to swap amount
feeAmount = lpAmount_A × totalFeeBps / BPS_PRECISION
netSwapAmount = lpAmount_A - feeAmount
lpAmount_B = quote(netSwapAmount, A → B)
```

**Coverage timing**:
- Use **pre-swap coverage** for fee calculation (not post-swap)
- This is consistent with normal swap pricing
- Coverage delta haircut is computed **after** fees are deducted

**Fee destination**:
- Fees are paid in **liability units** (not reserves)
- Reduces LP's swapped amount before quote computation
- Stays in pool as liability reduction (improves coverage ratio for remaining LPs)

---

## Liability Decay Compatibility

### Problem: Decay Rate Gaming

If assets have **different decay rates** (different `n` exponents), users could game the system:

```
Scenario:
- Asset A: n = 0.5 (fast decay, meme token)
- Asset B: n = 2.0 (slow decay, stablecoin)

At t=0, both at C=0.7:
- Deposit to A (decays quickly → liabilities shrink fast → coverage improves)
- Wait for decay to reduce liabilities
- Liability swap to B (slow decay → keeps value longer)
- Repeat cycle to extract value from decay timing differences
```

### Solution: Owner Configuration of Linear Decay

**Mitigation**: Pool owners should configure **linear decay** (`decayAmplification = 10000`, which equals `n=1.0`) for assets where liability swaps are expected, especially during market stress.

**Per-asset decay configuration** (`IBAMM.LiabilityDecayConfig`):
```solidity
struct LiabilityDecayConfig {
    uint16 decayStartRatioBps;    // Coverage threshold (e.g., 9800 = 98%)
    uint16 decayAmplification;    // n × 10000 (e.g., 10000 = 1.0 linear)
    uint32 decayEnd;              // Time to reach terminal state (seconds)
}
```

**Linear decay settings** to prevent gaming:
```solidity
// For meme tokens (normally n=0.5 fast decay):
decayAmplification = 10000  // Override to n=1.0 (linear)
decayEnd = 60 days          // Extend duration to compensate (was 30 days)

// For stablecoins (normally n=2.0 slow decay):
decayAmplification = 10000  // Override to n=1.0 (linear)
decayEnd = 180 days         // Keep or reduce duration

// Result: All assets decay at same linear rate → no arbitrage opportunity
```

**Owner responsibility**:
- **Set linear decay** (`n=1.0`) when liability swaps are enabled
- **Adjust `decayEnd`** to maintain appropriate recovery timeframes
- **Monitor for gaming**: If users exploit decay differences, update config

**No special liability swap logic needed**: Decay happens continuously over time, not "just during swaps". Liability swaps simply execute within the existing decay state. By configuring all assets with linear decay, the gaming vector is eliminated without complex swap-specific overrides.

**Effect**:
- Removes arbitrage from decay rate differences
- LPs can still rebalance during decay (critical for underwater assets)
- Simpler implementation (no swap-specific decay logic)
- Pool owner controls via per-asset configuration

### Decay State Transition Rules

**Allowed operations**:
```solidity
// Liability swap FROM decaying asset TO healthy asset
✓ Allowed (helps asset recover from underwater state)

// Liability swap FROM healthy asset TO decaying asset
✓ Allowed (user choice, accepts decay exposure)

// Liability swap FROM decaying asset TO decaying asset
✓ Allowed with normalized decay rates
```

**Post-swap decay state**:
```solidity
// If source asset recovers coverage above threshold after swap:
if (C'_A ≥ threshold && improvedFromStart && lockedOutFor24h) {
    stopDecay(assetA)
}

// If destination asset falls below threshold after swap:
if (C'_B < threshold && !isDecaying(assetB)) {
    startDecay(assetB)
}

// If destination asset already decaying and worsens:
if (isDecaying(assetB) && C'_B < C_B) {
    // Continue decay with updated state
    // Decay continues uninterrupted
}
```

**Invariants**:
1. Decay rate normalization applies **only** during liability swap haircut calculation
2. Normal decay progression (with per-asset `n`) continues outside swap context
3. Liability swap cannot skip decay terminal state
4. Net coverage delta always reflects true post-swap state (including ongoing decay)

---

## Implementation Design

### Function Signature

```solidity
/// @notice Swap LP liability from one asset to another
/// @param tokenIn Asset to reduce liability from
/// @param tokenOut Asset to add liability to
/// @param lpAmountIn Amount of tokenIn LP tokens (liability units) to swap
/// @param minLpAmountOut Minimum tokenOut LP tokens to receive (slippage protection)
/// @return lpAmountOut Actual tokenOut LP tokens received
function swapLiability(
    address tokenIn,
    address tokenOut,
    uint256 lpAmountIn,
    uint256 minLpAmountOut
) external returns (uint256 lpAmountOut);
```

### High-Level Flow

```solidity
function swapLiability(...) external returns (uint256) {
    // 1. Validation
    require(!paused, "Pool paused");
    require(tokenIn != tokenOut, "Same asset");
    require(assets[tokenIn].exists && assets[tokenOut].exists, "Asset not found");
    require(lpAmountIn > 0, "Zero amount");

    // 2. Update decay state (if active)
    updateLiabilityDecay(tokenIn);
    updateLiabilityDecay(tokenOut);

    // 3. Check user has sufficient LP tokens (ERC1155 balance)
    uint256 tokenId_in = uint256(uint160(tokenIn));
    require(balanceOf(msg.sender, tokenId_in) >= lpAmountIn, "Insufficient LP tokens");

    // 4. Capture pre-swap state
    uint256 C_in_pre = getCoverageRatio(tokenIn);
    uint256 C_out_pre = getCoverageRatio(tokenOut);
    uint256 L_in_pre = assets[tokenIn].liabilities;
    uint256 L_out_pre = assets[tokenOut].liabilities;

    // 5. Compute swap quote (normal swap pricing with tri-factor fees)
    uint256 lpAmountOut_gross = computeSwapQuote(tokenIn, tokenOut, lpAmountIn);

    // 6. Deduct tri-factor fees from swapped liability
    uint256 feeAmount = (lpAmountIn × totalFeeBps) / BPS_PRECISION;
    uint256 lpAmountIn_net = lpAmountIn - feeAmount;

    // 7. Execute liability transfer (reserves unchanged)
    assets[tokenIn].liabilities -= lpAmountIn;   // Source liability decreases
    assets[tokenOut].liabilities += lpAmountOut_gross;  // Destination liability increases

    // 8. Compute post-swap coverage and value-weighted deltas
    uint256 C_in_post = getCoverageRatio(tokenIn);
    uint256 C_out_post = getCoverageRatio(tokenOut);

    // Get asset values in base token for weighting
    uint256 price_in = getSwapPrice(tokenIn, baseToken);
    uint256 price_out = getSwapPrice(tokenOut, baseToken);
    uint256 value_in = assets[tokenIn].reserves * price_in / 1e18;
    uint256 value_out = assets[tokenOut].reserves * price_out / 1e18;

    // Value-weighted coverage deltas
    int256 delta_in = int256(C_in_post) - int256(C_in_pre);
    int256 delta_out = int256(C_out_post) - int256(C_out_pre);
    int256 delta_in_weighted = delta_in * int256(value_in);
    int256 delta_out_weighted = delta_out * int256(value_out);
    int256 delta_net = delta_in_weighted + delta_out_weighted;

    // 9. Apply haircut if net value-weighted coverage worsens
    uint256 haircut = 0;
    if (delta_net < 0) {
        // Haircut proportional to net value-weighted coverage worsening
        uint256 delta_abs = uint256(-delta_net);
        uint256 totalPoolValue = value_in + value_out;
        uint256 haircutRatio = (delta_abs × 1e18) / totalPoolValue;
        haircut = (lpAmountOut_gross × haircutRatio) / 1e18;

        // Apply haircut to worse coverage asset
        if (C_in_post < C_out_post) {
            // Source is worse → reduce source liabilities further
            assets[tokenIn].liabilities -= haircut;
        } else {
            // Destination is worse → reduce destination liabilities
            assets[tokenOut].liabilities -= haircut;
            lpAmountOut_gross -= haircut;  // User receives less
        }
    }

    // 10. Slippage check
    require(lpAmountOut_gross >= minLpAmountOut, "Slippage exceeded");

    // 11. Burn source LP tokens (ERC1155)
    _burn(msg.sender, tokenId_in, lpAmountIn);

    // 12. Mint destination LP tokens (ERC1155)
    uint256 tokenId_out = uint256(uint160(tokenOut));
    _mint(msg.sender, tokenId_out, lpAmountOut_gross);

    // 13. Update allocations (if needed)
    _updateAllocations();

    // 14. Emit event
    emit LiabilitySwapped(
        msg.sender,
        tokenIn,
        tokenOut,
        lpAmountIn,
        lpAmountOut_gross,
        feeAmount,
        haircut,
        delta_net
    );

    return lpAmountOut_gross;
}
```

### Gas Optimization

**Optimize for common case (no haircut)**:
```solidity
// Fast path: If net coverage improves, skip haircut logic entirely
if (delta_net >= 0) {
    // No haircut calculation needed
    lpAmountOut = lpAmountOut_gross;
} else {
    // Slow path: Compute and apply haircut
    lpAmountOut = _applyHaircut(...);
}
```

**Reuse existing pricing infrastructure**:
```solidity
// Leverage existing swap quote function (already has tri-factor fees)
lpAmountOut_gross = _computeSwapQuote(tokenIn, tokenOut, lpAmountIn_net);
```

**Batch state updates**:
```solidity
// Update both assets' decay states in single call if possible
_batchUpdateDecay([tokenIn, tokenOut]);
```

---

## Events

```solidity
/// @notice Emitted when LP swaps liability from one asset to another
/// @param user LP executing the swap
/// @param tokenIn Asset liability reduced from
/// @param tokenOut Asset liability added to
/// @param lpAmountIn LP tokens burned (source asset)
/// @param lpAmountOut LP tokens minted (destination asset)
/// @param feeAmount Tri-factor fee paid (in source asset liability units)
/// @param haircut Coverage haircut applied (if any)
/// @param netCoverageDelta Net change in pool coverage (WAD precision, can be negative)
event LiabilitySwapped(
    address indexed user,
    address indexed tokenIn,
    address indexed tokenOut,
    uint256 lpAmountIn,
    uint256 lpAmountOut,
    uint256 feeAmount,
    uint256 haircut,
    int256 netCoverageDelta
);

/// @notice Emitted when liability swap triggers decay state change
/// @param asset Asset that started or stopped decay
/// @param decayActive True if decay started, false if stopped
/// @param coverageRatio Coverage ratio after swap (WAD precision)
event LiabilitySwapDecayTransition(
    address indexed asset,
    bool decayActive,
    uint256 coverageRatio
);
```

---

## Security Considerations

### 1. Coverage Manipulation via Flash Swaps

**Attack**: User flash-swaps large amount to manipulate coverage deltas

**Mitigation**:
- Coverage delta computed on **actual liability changes**, not temporary reserve moves
- Flash loans cannot change liabilities (only reserves temporarily)
- Haircut logic based on **post-swap coverage** after all state changes

### 2. Decay Rate Gaming

**Attack**: Arbitrage different decay rates between assets

**Mitigation**:
- **Decay rate normalization** during active decay (linear n=1.0 for all)
- Extended T_max to maintain terminal states
- No advantage to cycling between fast/slow decay assets

### 3. Sandwich Attacks on Liability Swaps

**Attack**: MEV bot frontruns liability swap to worsen coverage delta

**Mitigation**:
- Coverage deltas computed **after** user's swap completes
- Frontrrunning changes pre-swap coverage, but user's delta is isolated
- Slippage protection (`minLpAmountOut`) guards against quote manipulation

### 4. Haircut Amplification via Multiple Swaps

**Attack**: User splits large swap into many small swaps to reduce haircut

**Mitigation**:
- Haircut formula is **linear** in swap amount (no benefit to splitting)
- Each swap recomputes coverage delta independently
- Total haircut for N small swaps ≈ haircut for 1 large swap

### 5. Base Token Reserve Consistency

**Attack**: Triangulated swaps incorrectly modify base reserves/liabilities

**Mitigation**:
- Explicit checks: `assets[baseToken].reserves` unchanged after triangulated liability swap
- Explicit checks: `assets[baseToken].liabilities` unchanged after triangulated liability swap
- Invariant tests verify base token isolation

### 6. LP Token Balance Underflow

**Attack**: User swaps more liability than they own

**Mitigation**:
```solidity
require(balanceOf(msg.sender, tokenId_in) >= lpAmountIn, "Insufficient LP tokens");
```

### 7. Coverage Ratio Division by Zero

**Edge case**: Asset has zero liabilities after swap

**Mitigation**:
```solidity
function getCoverageRatio(address token) internal view returns (uint256) {
    uint256 L = assets[token].liabilities;
    if (L == 0) return type(uint256).max;  // Perfect coverage (no claims)
    return (assets[token].reserves × 1e18) / L;
}
```

---

## Testing Strategy

### Unit Tests

```solidity
// 1. Basic liability swap (no haircut)
testLiabilitySwap_NoHaircut()
  - Setup: Both assets healthy (C ≥ 1.0)
  - Execute: Swap 100 USDC liability → WETH liability
  - Assert: ΔC_net ≥ 0, haircut = 0, full quote received

// 2. Rebalancing from underwater (no haircut expected)
testLiabilitySwap_UnderwaterToHealthy()
  - Setup: USDC C=0.7, WETH C=1.2
  - Execute: Swap USDC liability → WETH liability
  - Assert: ΔC_net > 0, haircut = 0

// 3. Net coverage worsening (haircut applied)
testLiabilitySwap_NetCoverageWorsening()
  - Setup: Construct scenario where ΔC_net < 0
  - Execute: Swap
  - Assert: haircut > 0, applied to worse asset

// 4. Tri-factor fees applied
testLiabilitySwap_TriFactorFees()
  - Setup: High volatility, coverage penalty
  - Execute: Swap
  - Assert: Fee matches tri-factor calculation, reduces swap amount

// 5. Triangulated routing (base unchanged)
testLiabilitySwap_TriangulatedBaseUnchanged()
  - Setup: DAI → WETH (via USDC base)
  - Execute: Swap
  - Assert: USDC reserves unchanged, USDC liabilities unchanged

// 6. Decay rate normalization
testLiabilitySwap_DecayRateNormalization()
  - Setup: Asset A (n=0.5), Asset B (n=2.0), both decaying
  - Execute: Swap A → B
  - Assert: Normalized decay rates used for haircut calculation

// 7. Decay state transitions
testLiabilitySwap_TriggersDecayStart()
  - Setup: Asset B at C=99%, threshold=98%
  - Execute: Large swap into B → coverage falls below threshold
  - Assert: Decay activates for asset B

testLiabilitySwap_TriggersDecayStop()
  - Setup: Asset A decaying at C=97%
  - Execute: Swap out of A → coverage rises above 98%
  - Assert: Decay stops after lockout period

// 8. Edge cases
testLiabilitySwap_ZeroLiabilities()
  - Setup: Swap reduces asset to 0 liabilities
  - Execute: Complete liability drain
  - Assert: Coverage = ∞ (max uint), no division by zero

testLiabilitySwap_InsufficientLPTokens()
  - Execute: Attempt swap with more LP tokens than owned
  - Assert: Reverts with "Insufficient LP tokens"

testLiabilitySwap_SlippageProtection()
  - Setup: Set minLpAmountOut = 200
  - Execute: Swap that quotes 150
  - Assert: Reverts with "Slippage exceeded"
```

### Invariant Tests

```solidity
invariant_totalLiabilitiesConserved()
  // Sum of liabilities across all assets should only decrease by fees/haircuts
  // Σ(liabilities_post) = Σ(liabilities_pre) - fees - haircut

invariant_baseTokenUnchangedTriangulated()
  // For triangulated swaps, base token reserves and liabilities unchanged
  // If swap is A → base → B: base.reserves_post == base.reserves_pre

invariant_coverageDeltaMatchesFormula()
  // ΔC_net should equal mathematical formula
  // ΔC_net = (R_A / L'_A - R_A / L_A) + (R_B / L'_B - R_B / L_B)

invariant_haircutNonNegative()
  // Haircut can never be negative
  // haircut ≥ 0

invariant_lpTokenBalance()
  // User's LP token balance must decrease by lpAmountIn, increase by lpAmountOut
  // balance_post = balance_pre - lpAmountIn + lpAmountOut
```

### Fuzz Tests

```solidity
testFuzz_LiabilitySwap_RandomAmounts(
    uint256 lpAmountIn,
    uint256 coverageA,
    uint256 coverageB
)
  // Bound inputs to realistic ranges
  // Execute swap
  // Assert: No reverts, invariants hold

testFuzz_LiabilitySwap_DecayStates(
    bool decayActiveA,
    bool decayActiveB,
    uint16 n_A,
    uint16 n_B
)
  // Random decay configurations
  // Assert: Normalized decay rates applied correctly
```

### Integration Tests

```solidity
testIntegration_ConstantMixRebalancing()
  // Scenario: LP implements 60/40 USDC/WETH constant-mix strategy
  // Initial: 60% USDC LP, 40% WETH LP (by value)
  // WETH price pumps 50%
  // Portfolio now: 50% USDC, 50% WETH (imbalanced)
  // Rebalance: Liability swap USDC → WETH to restore 60/40
  // Assert: Target allocation achieved, minimal haircut

testIntegration_BankRunPrevention()
  // Scenario: Asset underwater, C=0.6
  // Normal withdraw: suffers 40% haircut → bank run incentive
  // Liability swap: Users swap to healthier assets without haircut
  // Assert: No bank run cascade, coverage stabilizes
```

---

## Parameter Configuration

### Global Parameters

```solidity
struct LiabilitySwapConfig {
    bool enabled;                         // Global kill switch
    uint16 maxHaircutBps;                 // Max haircut allowed (e.g., 5000 = 50%)
    uint32 minSwapAmount;                 // Minimum liability swap amount (dust protection)
}
```

**Recommended values**:
```solidity
enabled = true
maxHaircutBps = 5000  // 50% max haircut (safety cap)
minSwapAmount = 1000  // Minimum 1000 wei equivalent
```

**Note**: Decay normalization is handled via per-asset configuration (set `decayAmplification = 10000` for linear decay), not swap-specific parameters.

### Per-Asset Parameters

**Reuse existing fee parameters**:
- Tri-factor fee model (coverage × volatility × divergence)
- Base fee, min fee, max fee
- Protocol fee split

**No new per-asset parameters needed** (simple, clean design)

---

## Gas Cost Estimation

**Baseline costs**:
```
Coverage state reads:           ~5,000 gas (2 SLOADs per asset)
Decay state update:             ~10,000 gas (if active)
Coverage delta calculation:     ~2,000 gas (arithmetic)
Haircut computation:            ~3,000 gas (conditional)
LP token burn/mint:             ~10,000 gas (ERC1155 operations)
Event emission:                 ~2,000 gas
State writes (liabilities):     ~10,000 gas (2 SSTOREs)

Total estimated:                ~42,000 gas (typical case)
                                ~52,000 gas (with active decay)
```

**Comparable to normal swap** (~40-50k gas), which is acceptable.

**Optimization opportunities**:
- Skip haircut computation if ΔC_net ≥ 0 (saves ~3k gas)
- Batch decay updates for multiple assets (saves ~5k gas)
- Cache coverage ratios if computed multiple times

---

## Comparison to Alternatives

### Alternative 1: Withdraw + Swap + Deposit

```
Gas: ~120,000 (3 transactions)
Haircut: Full coverage haircut on withdrawal (30-70% loss if C<1.0)
UX: Complex (3 steps), high slippage
```

### Alternative 2: LP Token Trading (Not Viable)

```
Problem: LP tokens represent liabilities, not fungible value
Cannot price LP-to-LP swaps without complex accounting
Breaks coverage ratio tracking
```

### Liability Swap (This Proposal)

```
Gas: ~42,000 (single transaction)
Haircut: Zero if rebalancing toward equilibrium, minimal otherwise
UX: Simple (single call), clear slippage protection
```

**Winner**: Liability swap is clearly superior for underwater rebalancing.

---

## UI/UX Considerations

### Quote Preview

**Before executing swap**, show user:
```
Liability Swap Preview:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Swapping: 1,000 USDC LP → WETH LP

Estimated Receive: 0.45 WETH LP

Fees:
  Tri-factor fee: 3.2 USDC LP (0.32%)

Coverage Impact:
  USDC: 0.70 → 0.85 (+21%)
  WETH: 1.20 → 1.10 (-8%)
  Net Pool: +13% (✓ Positive)

Haircut: 0 (no penalty for improving pool balance)

Minimum Receive (1% slippage): 0.445 WETH LP
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Warning for Coverage-Worsening Swaps

```
⚠️ Warning: This swap worsens overall pool coverage

Coverage Impact:
  USDC: 0.70 → 0.60 (-14%)
  WETH: 0.50 → 0.40 (-20%)
  Net Pool: -34% (⚠️ Negative)

Estimated Haircut: 15% (0.067 WETH LP)

Consider swapping in the opposite direction to avoid haircut.

Continue anyway? [Yes] [No]
```

### Constant-Mix Rebalancing Tool

```
Portfolio Rebalancing Tool
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Target Allocation: 60% USDC / 40% WETH

Current State:
  USDC LP: 600 ($420 value, 50% coverage)
  WETH LP: 0.2 ($400 value, 120% coverage)
  Total: $820

Current Allocation: 51% USDC / 49% WETH

Rebalance Action:
  Liability swap: 73.2 USDC LP → 0.036 WETH LP

After Rebalance:
  USDC LP: 526.8 ($368)
  WETH LP: 0.236 ($472)
  Allocation: 44% USDC / 56% WETH

Haircut: 0 (improves pool coverage)
Gas Cost: ~42,000 (~$5)

[Execute Rebalance]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Migration Path

### Phase 1: Core Implementation (Week 1-2)

- [ ] Implement `swapLiability()` function
- [ ] Add coverage delta calculation
- [ ] Integrate with existing tri-factor fee logic
- [ ] Add haircut computation and application
- [ ] Emit events

### Phase 2: Decay Integration (Week 3)

- [ ] Implement decay rate normalization
- [ ] Add decay state transition logic
- [ ] Test decay compatibility thoroughly
- [ ] Document edge cases

### Phase 3: Testing (Week 4)

- [ ] Unit tests (see Testing Strategy above)
- [ ] Invariant tests
- [ ] Fuzz tests
- [ ] Integration tests
- [ ] Gas optimization

### Phase 4: UI/Frontend (Week 5)

- [ ] Add liability swap quote endpoint
- [ ] Build coverage impact preview
- [ ] Implement slippage protection UI
- [ ] Create rebalancing tool
- [ ] Add warnings for coverage-worsening swaps

### Phase 5: Audit & Launch (Week 6+)

- [ ] Internal code review
- [ ] External security audit (focus on coverage delta logic)
- [ ] Testnet deployment
- [ ] Mainnet deployment (behind feature flag initially)
- [ ] Gradual rollout

---

## Open Questions

1. **Should we impose a minimum net coverage delta threshold to allow swaps?**
   - E.g., reject swaps where ΔC_net < -0.05 (worsens coverage by >5%)
   - Pro: Prevents toxic swaps that harm pool
   - Con: Reduces LP flexibility

2. **Should haircut revenue be distributed or burned?**
   - Current: Haircut reduces liabilities (benefits remaining LPs)
   - Alternative: Send haircut to protocol treasury
   - Recommendation: **Keep current** (aligns with coverage model)

3. **Should we allow liability swaps when pool is paused?**
   - Pro: Lets LPs rebalance during emergencies
   - Con: Could be used to game pause mechanics
   - Recommendation: **Block during pause** (conservative approach)

4. **Should there be a daily/hourly limit on liability swap volume per asset?**
   - Pro: Prevents rapid liability shifts that destabilize pool
   - Con: Reduces LP freedom, adds complexity
   - Recommendation: **No limit** (let fees and haircuts self-regulate)

---

## Summary

**Liability swaps enable LPs to rebalance exposure without haircut penalties when underwater**, solving a critical UX problem for constant-mix strategies. Key features:

✅ **Zero haircut** when swaps improve net pool coverage
✅ **Same tri-factor fees** as normal swaps (coverage × vol × divergence)
✅ **Hub-and-spoke routing** (base token virtual in triangulated swaps)
✅ **Decay compatible** (with normalized linear rates during active decay)
✅ **Gas efficient** (~42k gas, comparable to normal swaps)
✅ **Simple implementation** (reuses existing pricing and fee infrastructure)

**Use cases**:
- Rebalancing from underwater to healthy assets (avoid withdraw haircut)
- Implementing constant-mix LP strategies (60/40 portfolios, etc.)
- Escaping bad debt situations without forced liquidation
- Responding to market moves while maintaining LP exposure

**Next steps**: Implement core logic, test thoroughly, integrate with UI, audit, launch.
