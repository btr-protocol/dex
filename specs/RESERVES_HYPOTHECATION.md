# Reserves Hypothecation via Yield Protocol Integration

## Overview

BAMM supports **reserves hypothecation** through yield-generating lending protocols. Reserves can be deployed into external protocols (Aave V3, Morpho Vaults, Euler V2) to generate yield while maintaining coverage ratio integrity.

**Supported Protocols:**
- **Aave V3** - Rebasing aToken model (`Pool.supply`/`Pool.withdraw`)
- **Morpho Vaults** - ERC-4626 vaults with growing share price (`deposit`/`redeem`)
- **Euler V2** - ERC-4626 credit vaults with growing exchange rate (`deposit`/`redeem`)

## Core Concept

**Hypothecation** = Pledging reserves in external protocols while maintaining user claims.

**BAMM Accounting:**
- `asset.reserves` tracks user claims (what users can withdraw at C=1)
- Actual tokens held as yield-bearing assets (aTokens, vault shares, eTokens)
- Yield accrual increases value beyond tracked reserves
- Coverage ratio remains valid: `yield token value ≥ reserves`

### Key Invariants

**Aave V3 (Rebasing):**
```
aToken.balanceOf(BAMM) ≥ asset.reserves
```
Balance grows automatically via rebasing.

**Morpho/Euler (ERC-4626):**
```
vault.convertToAssets(vault.balanceOf(BAMM)) ≥ asset.reserves
```
Share count constant, share price grows.

**Why inequality?**
1. Yield accrues continuously (balance OR share price increases)
2. BAMM reserves only update on deposits/withdrawals/swaps
3. Delta = accrued yield available for distribution

## Protocol Comparison

| Protocol | Token Type | Interest Accrual | Deposit | Withdraw | Balance Tracking |
|----------|-----------|------------------|---------|----------|------------------|
| **Aave V3** | aToken (rebasing) | Balance increases | `Pool.supply()` | `Pool.withdraw()` | `aToken.balanceOf()` grows |
| **Morpho** | Shares (non-rebasing) | Share price increases | `vault.deposit()` | `vault.redeem()` | Share count constant, `convertToAssets()` grows |
| **Euler V2** | eTokens (non-rebasing) | Exchange rate increases | `vault.deposit()` | `vault.redeem()` | Share count constant, exchange rate formula |

### Contract Addresses (Ethereum Mainnet)

**Aave V3:**
- Pool: `0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2`
- aUSDC: `0x98C23E9d8f34FEfb1B7BD6a91B7FF122F4e16F5c`

**Morpho Vaults:**
- Gauntlet USDC Core: `0x8eB67A509616cd6A7c1B3c8C21D48FF57df3d458`
- Steakhouse USDC: `0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB`

**Euler V2:**
- USDC Vault 2: `0x797DD80692c3b2dAdabCe8e30C07fDE5307D48a9`

## Implementation Patterns

### Hook Flow

All hooks follow the same pattern:

1. **postDeposit:** Deposit reserves into protocol after BAMM updates state
2. **preWithdraw:** Withdraw from protocol before BAMM transfers to user
3. **preBuy:** Withdraw if BAMM needs liquidity for swap output
4. **postSell:** Deposit newly received tokens after swap

### Aave V3 Hook

See: `contracts/src/hooks/AaveYieldHook.sol`

**Key Methods:**
```solidity
// Deposit
Pool.supply(token, amount, bamm, 0);  // Receive aTokens

// Withdraw
Pool.withdraw(token, amount, bamm);   // Burn aTokens

// Check value
aToken.balanceOf(bamm);               // Rebasing balance
```

### Morpho Hook

See: `contracts/src/hooks/MorphoYieldHook.sol`

**Key Methods:**
```solidity
// Deposit
vault.deposit(amount, bamm);                    // Receive shares

// Withdraw
uint256 shares = vault.previewWithdraw(amount); // Calculate shares needed
vault.redeem(shares, bamm, bamm);               // Burn shares

// Check value
vault.convertToAssets(vault.balanceOf(bamm));   // Shares → assets
```

**Differences from Aave:**
- Share count stays constant, price per share increases
- Use `previewWithdraw()` to convert assets → shares
- Use `convertToAssets()` to convert shares → assets
- MetaMorpho vaults auto-allocate across multiple Morpho Blue markets

### Euler V2 Hook

See: `contracts/src/hooks/EulerYieldHook.sol`

**Key Methods:**
Same as Morpho (both are ERC-4626):
```solidity
// Deposit
eulerVault.deposit(amount, bamm);

// Withdraw
uint256 shares = eulerVault.previewWithdraw(amount);
eulerVault.redeem(shares, bamm, bamm);

// Check value
eulerVault.convertToAssets(eulerVault.balanceOf(bamm));
```

**Euler-Specific:**
- "Credit vaults" that allow borrowing
- Exchange rate = `(cash + totalBorrows + VIRTUAL_DEPOSIT) / (totalShares + VIRTUAL_DEPOSIT)`
- Permissionless vault creation with custom risk parameters

## Yield Distribution

### How Users Benefit

**Key Insight:** Users automatically receive yield through LP share mechanism.

**Example Timeline:**

**T=0:**
```
BAMM reserves:     1,000 USDC (tracked)
Vault shares:      1,000 shares (convertToAssets = 1,000)
User A LP share:   50%
Coverage ratio:    100%
```

**T=1 (After 5% Yield):**
```
BAMM reserves:     1,000 USDC (unchanged)
Vault shares:      1,000 shares (convertToAssets = 1,050)
Accrued yield:     50 USDC
```

**User A Withdraws (50% LP):**
1. Hook calculates: `userShare = 50% * 1,000 = 500 USDC`
2. Hook redeems shares worth 500 USDC from vault
3. BAMM applies coverage haircut: `amountOut = 500 * C`
4. User receives 500 USDC (if C=100%)

**Yield Capture:**
To realize accrued yield, protocol can periodically harvest:
```solidity
uint256 vaultValue = vault.convertToAssets(vault.balanceOf(bamm));
uint256 yield = vaultValue - reserves;
// Option 1: Add to reserves (benefits all LPs)
// Option 2: Extract to treasury
// Option 3: Distribute as fee rebates
```

## Coverage Ratio Interaction

Coverage ratio haircut applies **independently** of hypothecation:

```solidity
coverageRatio = min(1.0, reserves / liabilities);
amountOut = userShareOfReserves * coverageRatio;
```

**Why it works:**
1. `asset.reserves` tracks user claims (matched to liabilities)
2. Yield token value tracks actual backing
3. Hook ensures: `yield token value ≥ reserves`
4. Coverage ratio = `reserves / liabilities` (independent of yield token balance)

**Undercollateralized Example:**
```
Reserves:    800 USDC
Liabilities: 1,000 USDC
Vault value: 850 USDC (800 + 50 yield)
Coverage:    80% (800/1000)

User withdraws 100 USDC claim:
→ Hook calculates: 100 USDC share
→ Hook redeems from vault
→ BAMM applies haircut: 100 * 0.80 = 80 USDC
→ User receives 80 USDC (correct)
```

## Security Considerations

### 1. Protocol Depeg Risk
If yield token depegs (exploit, depeg event):
- Users still have claims against `asset.reserves`
- Coverage ratio protects: `C = (compromised value) / liabilities`
- Haircut automatically applies losses proportionally

### 2. Liquidity Crunches
If protocol has insufficient liquidity:
- Hook withdrawal fails → user tx reverts
- **Mitigation:** Maintain buffer balance in BAMM
- **Mitigation:** Multi-protocol diversification

### 3. ERC-4626 Inflation Attacks
Morpho/Euler vaults susceptible to first-deposit inflation attack:
- **Risk:** Attacker manipulates share price before first deposit
- **Mitigation:** Verify vaults have "dead shares" (initial deposit)
- **Gauntlet/Steakhouse vaults:** Already mitigated
- **Custom vaults:** Check existing deposits before integration

### 4. Hook Failure Modes
If protocol withdrawal reverts:
- User withdrawal fails
- Pool frozen until liquidity returns
- **Mitigation:** Emergency direct withdrawal by governance

## Monitoring

### Key Metrics

**Hypothecation Ratio:**
```
Aave:   H = aToken.balanceOf(BAMM) / reserves
Morpho: H = vault.convertToAssets(shares) / reserves
Euler:  H = eulerVault.convertToAssets(shares) / reserves
```
Should be ≥ 1.0; if < 1.0 → Critical alert

**Yield APY:**
```
vaultValue = vault.convertToAssets(vault.balanceOf(BAMM))
APY = (vaultValue - reserves) / reserves * (365/days)
```

**Liquidity Buffer:**
```
Buffer = IERC20(token).balanceOf(BAMM)
```
Should cover typical swap/withdrawal volume.

### View Functions

All hooks expose:
```solidity
getAccruedYield() → uint256        // vaultValue - reserves
getTotalAssetValue() → uint256     // Total value including yield
getVaultShares() → uint256         // Share/token balance
getVaultMetrics() → (totalAssets, totalSupply)
```

### Events

```solidity
event YieldHarvested(address indexed token, uint256 amount, address recipient);
event ProtocolDeposit(address indexed protocol, address indexed token, uint256 amount);
event ProtocolWithdrawal(address indexed protocol, address indexed token, uint256 amount);
event HypothecationRatioAlert(address indexed token, uint256 ratio);
```

## Multi-Protocol Strategy

Diversify across protocols for risk management:

```solidity
// Example: 50% Aave, 30% Morpho, 20% Euler
function postDeposit(..., uint256 amount, ...) {
    uint256 toAave = (amount * 50) / 100;
    uint256 toMorpho = (amount * 30) / 100;
    uint256 toEuler = amount - toAave - toMorpho;

    aavePool.supply(token, toAave, bamm, 0);
    morphoVault.deposit(toMorpho, bamm);
    eulerVault.deposit(toEuler, bamm);
}
```

**Benefits:**
- Reduces single-protocol risk
- Diversifies yield sources
- Maintains liquidity across venues

## Gas Optimization

### Batched Operations
Instead of withdraw→deposit on each swap, accumulate deltas:

```solidity
int256 netFlow;  // Track cumulative flow

// After N operations:
if (netFlow > 0) {
    vault.deposit(uint256(netFlow), bamm);
} else if (netFlow < 0) {
    vault.redeem(shares, bamm, bamm);
}
```

### ERC-4626 Efficiency
ERC-4626 vaults generally more gas-efficient than proprietary interfaces due to:
- Standardized accounting
- Fewer state transitions
- Optimized implementations by curators (Gauntlet, Steakhouse)

## Implementation Files

- **Aave V3:** `contracts/src/hooks/AaveYieldHook.sol`
- **Morpho:** `contracts/src/hooks/MorphoYieldHook.sol`
- **Euler V2:** `contracts/src/hooks/EulerYieldHook.sol`
- **Base Hook:** `contracts/src/hooks/BaseBAMMHook.sol`

## References

- [Aave V3 Pool](https://aave.com/docs/developers/smart-contracts/pool)
- [Morpho Vaults](https://docs.morpho.org/build/earn/tutorials/assets-flow/)
- [Euler V2 EVK](https://docs.euler.finance/developers/evk/)
- [ERC-4626 Standard](https://eips.ethereum.org/EIPS/eip-4626)
- [BAMM Architecture](./ARCHITECTURE.md)
- [Coverage Ratio ALM](./ALM_COVERAGE_RATIO.md)
