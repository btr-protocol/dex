# Value Calculation Verification

## Formula Consistency Check

### Full Calculation (O(n))

```solidity
totalValue = sum(reserves[i] * price[i] / PRICE_PRECISION) for all i
```

Where:
- `reserves[i]` = token reserves in native decimals
- `price[i]` = fastTWAP decoded to 1e18 format (`b64ToPrice()`)
- `PRICE_PRECISION` = 1e18
- Result: total value in base token terms

### Delta Calculation (O(1))

```solidity
valueDelta = reservesDelta * price / PRICE_PRECISION
newTotal = oldTotal + valueDelta
```

### Proof of Equivalence

Given:
- Initial: `total_0 = sum(reserves_i * price_i / 1e18)`
- Token j changes: `reserves_j' = reserves_j + delta_j`
- New total: `total_1 = sum(reserves_i * price_i / 1e18)` where i ≠ j, plus `reserves_j' * price_j / 1e18`

Expanding:
```
total_1 = sum(reserves_i * price_i / 1e18) for i ≠ j
        + reserves_j' * price_j / 1e18

total_1 = sum(reserves_i * price_i / 1e18) for i ≠ j
        + (reserves_j + delta_j) * price_j / 1e18

total_1 = sum(reserves_i * price_i / 1e18) for i ≠ j
        + reserves_j * price_j / 1e18
        + delta_j * price_j / 1e18

total_1 = sum(reserves_i * price_i / 1e18) for all i
        + delta_j * price_j / 1e18

total_1 = total_0 + (delta_j * price_j / 1e18)
```

Therefore: **newTotal = oldTotal + valueDelta** ✓

### Implementation Verification

**From LibPricing.sol:475**:
```solidity
uint256 valueDelta = M.mulDiv(uint256(reservesDelta), price1e18, M.PRICE_PRECISION);
newTotal = cachedTotal + valueDelta;
```

**From LibPricing.sol:434** (full calculation):
```solidity
uint256 value = M.mulDiv(uint256(asset.reserves), price1e18, M.PRICE_PRECISION);
total += value;
```

✓ **Both use same formula**: `reserves * price1e18 / PRICE_PRECISION`

## Price Semantics

### TWAP Price Representation

- **Format**: 1e18 (PRICE_PRECISION)
- **Meaning**: Price of this token denominated in base token
- **Example**: If USDC is base, WBTC/USDC = 60,000 means 60,000 USDC per 1 WBTC
- **Storage**: b64 float format (56-bit mantissa, 8-bit exponent)
- **Usage**: Decoded via `M.b64ToPrice()` to 1e18 format

### Value Calculation Units

Given:
- Base token: USDC (6 decimals)
- Asset: WBTC (8 decimals)
- WBTC reserves: 1.0 BTC = 100,000,000 (native decimals)
- WBTC/USDC price: $60,000

Price in 1e18:
```
price1e18 = 60000 * 1e18 / (10^baseDecimals / 10^assetDecimals)
price1e18 = 60000 * 1e18 * 10^assetDecimals / 10^baseDecimals
price1e18 = 60000 * 1e18 * 10^8 / 10^6
price1e18 = 60000 * 1e18 * 100
price1e18 = 6,000,000,000,000 (in 1e18 format)
```

Value calculation:
```
value = reserves * price1e18 / PRICE_PRECISION
value = 100,000,000 * 6,000,000,000,000 / 1e18
value = 600,000,000,000,000,000,000 / 1e18
value = 6,000,000,000,000 (in base token units)
```

With USDC at 6 decimals:
```
value_usdc = 6,000,000,000,000 / 1e6 = 6,000,000 USDC
```

**ERROR DETECTED**: Should be 60,000 USDC, not 6,000,000!

## Issue Analysis

The problem is that `price1e18` needs to be **normalized** to account for decimal differences between tokens.

### Correct Approach

Price should represent: "How many base token units (in base decimals) per 1 token unit (in token decimals)"

If WBTC is $60,000 and:
- WBTC: 1.0 BTC = 1e18 units
- USDC: 1.0 USDC = 1e6 units
- Price: 60,000 USDC per 1 BTC

Then for reserves calculation:
```
value_in_base = reserves_asset * (price * base_decimals / asset_decimals)
```

Or more precisely, price1e18 should be:
```
price1e18 = (units_of_base_per_unit_of_asset) * 1e18
```

Where units are in respective native decimals.

**TODO**: Verify this is how oracle prices are actually stored/calculated.

## Workaround Hypothesis

Perhaps the value calculation is intentionally in an abstract "value space" where all tokens are normalized to same decimals, and allocations are calculated as ratios (which are dimensionless).

Since currentAllocBps = (value * 10000) / totalValue, the absolute units cancel out as long as all values use the same calculation.

**This would still be correct for:**
- Weight calculation (ratio of values)
- Imbalance calculation (deviation from target %)
- Fee calculation (based on imbalance %)

**Needs verification**: External getValue() function and actual USD equivalence.
