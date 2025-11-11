# ERC1155 Rebasing LP Tokens

## Overview

BAMM uses ERC1155 for multi-asset LP tokens with rebasing mechanics to auto-compound fees.

**Key features:**
- One ERC1155 contract for all LP tokens
- Token ID = asset address
- Rebasing via liquidity index
- Auto-compounding fees
- Standard ERC1155 compatibility

---

## Token ID Scheme

```solidity
tokenId = uint256(uint160(assetAddress))
```

**Example:**
```
WETH: 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619
LP Token ID: 701332046859776641134542099953513155635840574233

USDC: 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174
LP Token ID: 226552318844750743941710897158473426892348547444
```

**Benefits:**
- No need for token ID registry
- Direct asset → LP token mapping
- Gas efficient (no lookups)

---

## Rebasing Mechanism

### Scaled Balances

**Problem:** Standard ERC1155 can't auto-compound fees

**Solution:** Store scaled balances, apply index on read

```solidity
struct LPState {
    uint128 totalScaledSupply;   // Sum of all scaled balances
    uint128 liquidityIndex;       // Rebasing multiplier
}

mapping(address => mapping(address => uint256)) scaledBalances;
```

### Balance Calculation

```solidity
function balanceOf(address owner, uint256 id) public view returns (uint256) {
    address token = address(uint160(id));
    LPState storage lpState = lpStates[token];

    if (lpState.liquidityIndex == 0) return 0;

    uint256 scaledBalance = scaledBalances[owner][token];
    return (scaledBalance * lpState.liquidityIndex) / PRECISION;
}
```

**PRECISION = 1e18**

### Index Updates

Fees accrue by increasing the liquidity index:

```solidity
function _accrueFeesToLPs(address token, uint256 feeAmount) internal {
    asset.reserves += feeAmount;

    uint256 oldReserves = asset.reserves - feeAmount;
    if (oldReserves > 0) {
        uint256 newIndex = (lpState.liquidityIndex * asset.reserves) / oldReserves;
        lpState.liquidityIndex = newIndex;
    }
}
```

**Effect:** All LP balances automatically increase

---

## Deposit Flow

```solidity
function deposit(address token, uint256 amount, uint256 minLpTokens)
    external returns (uint256 lpTokens)
```

### First Deposit

```solidity
if (lpState.totalScaledSupply == 0) {
    lpTokens = amount;
    scaledAmount = amount;  // Index = 1.0
}
```

### Subsequent Deposits

```solidity
lpTokens = (amount * totalScaledSupply * PRECISION) /
           (reserves * liquidityIndex);

scaledAmount = (lpTokens * PRECISION) / liquidityIndex;
```

### Update State

```solidity
lpState.totalScaledSupply += scaledAmount;
asset.reserves += amount;
scaledBalances[msg.sender][token] += scaledAmount;

_mint(msg.sender, tokenId, lpTokens, "");
```

### Example

```
Initial state:
reserves = 1000 USDC
totalScaledSupply = 1000
liquidityIndex = 1.0

User deposits 100 USDC:
lpTokens = (100 * 1000 * 1e18) / (1000 * 1e18) = 100
scaledAmount = (100 * 1e18) / 1e18 = 100

New state:
reserves = 1100 USDC
totalScaledSupply = 1100
liquidityIndex = 1.0 (unchanged)
```

---

## Fee Accrual Example

```
Initial:
reserves = 1000 USDC
totalScaledSupply = 1000
liquidityIndex = 1.0
Alice balance = 100 LP tokens (scaled: 100)

Swap fee of 10 USDC accrues:
newReserves = 1010 USDC
newIndex = (1.0 * 1010) / 1000 = 1.01

Alice balance now:
scaledBalance = 100 (unchanged)
actualBalance = 100 * 1.01 / 1.0 = 101 LP tokens

Alice automatically earned 1 LP token (1% fee share)
```

---

## Withdraw Flow

```solidity
function withdraw(address token, uint256 lpTokens, uint256 minAmountOut)
    external returns (uint256 amountOut)
```

### Calculate Output

```solidity
scaledAmount = (lpTokens * PRECISION) / liquidityIndex;

amountOut = (scaledAmount * liquidityIndex * reserves) /
            (totalScaledSupply * PRECISION);
```

### Apply Withdrawal Fee

```solidity
withdrawalFee = _calculateWithdrawalFee(token);
if (withdrawalFee > 0) {
    feeAmount = (amountOut * withdrawalFee) / BPS_PRECISION;
    amountOut -= feeAmount;
    _accrueFeesToLPs(token, feeAmount);  // Remaining LPs benefit
}
```

### Update State

```solidity
lpState.totalScaledSupply -= scaledAmount;
asset.reserves -= amountOut;
scaledBalances[msg.sender][token] -= scaledAmount;

_burn(msg.sender, tokenId, lpTokens);
```

### Example

```
Current state:
reserves = 1010 USDC
totalScaledSupply = 1000
liquidityIndex = 1.01
Alice balance = 101 LP tokens (scaled: 100)

Alice withdraws 101 LP tokens:
scaledAmount = (101 * 1e18) / 1.01e18 = 100
amountOut = (100 * 1.01e18 * 1010) / (1000 * 1e18) = 102.01 USDC

Alice receives 102.01 USDC (her deposit + fee share)
```

---

## Transfer Mechanics

### ERC1155 Transfer

```solidity
function safeTransferFrom(
    address from,
    address to,
    uint256 id,
    uint256 amount,
    bytes calldata data
) public override
```

### Scaled Balance Updates

Transfers update scaled balances:

```solidity
function _afterTokenTransfer(...) internal {
    address token = address(uint160(id));
    uint256 scaledAmount = (amount * PRECISION) / liquidityIndex;

    if (from != address(0)) {
        scaledBalances[from][token] -= scaledAmount;
    }
    if (to != address(0)) {
        scaledBalances[to][token] += scaledAmount;
    }
}
```

**Effect:** Transferring LP tokens transfers proportional scaled balance

---

## ERC1155 Metadata

### URI

```solidity
function uri(uint256 id) public view returns (string memory) {
    address token = address(uint160(id));
    return string(abi.encodePacked(
        "https://btr.supply/pool/",
        _toHexString(address(this)),  // Pool address
        "/",
        _toHexString(token)            // Asset address
    ));
}
```

**Rationale:**
- Multiple pools can exist for the same base asset
- URI must uniquely identify both pool AND asset
- Format: `/pool/{pool}/{asset}` allows proper metadata routing

**Example:**
```
Pool: 0x1234567890abcdef1234567890abcdef12345678
Token ID: 701332046859776641134542099953513155635840574233 (WETH)
URI: https://btr.supply/pool/1234567890abcdef1234567890abcdef12345678/7ceb23fd6bc0add59e62ac25578270cff1b9f619
```

**Metadata server returns:**
```json
{
  "name": "BTR WETH LP",
  "symbol": "BTR-WETH-LP",
  "decimals": 18,
  "image": "https://btr.supply/pool/weth/image.png",
  "properties": {
    "pool": "0x1234567890abcdef1234567890abcdef12345678",
    "asset": "0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619",
    "reserves": "100.5",
    "liquidityIndex": "1.05",
    "apy": "12.5%"
  }
}
```

---

## LP Value Calculation

### Get Underlying Value

```solidity
function getLPValue(address token, uint256 lpTokens)
    external view returns (uint256 underlyingAmount)
{
    LPState storage lpState = lpStates[token];
    if (lpState.liquidityIndex == 0) return 0;

    uint256 scaledAmount = (lpTokens * PRECISION) / lpState.liquidityIndex;
    underlyingAmount = (scaledAmount * lpState.liquidityIndex * asset.reserves) /
                       (lpState.totalScaledSupply * PRECISION);
}
```

### Example

```
reserves = 1000 USDC
totalScaledSupply = 1000
liquidityIndex = 1.1 (10% fees accrued)

100 LP tokens worth:
scaledAmount = (100 * 1e18) / 1.1e18 = 90.91
underlyingAmount = (90.91 * 1.1e18 * 1000) / (1000 * 1e18) = 100 USDC
```

---

## Invariants

### 1. Scaled Supply Consistency

```solidity
sum(scaledBalances[user][token]) == lpState.totalScaledSupply
```

### 2. Balance Consistency

```solidity
balanceOf(user, tokenId) == (scaledBalances[user][token] * liquidityIndex) / PRECISION
```

### 3. Total Supply Matches Reserves

```solidity
totalSupply[tokenId] * pricePerLP ≈ asset.reserves
```

### 4. Index Monotonicity

```solidity
liquidityIndex(t+1) >= liquidityIndex(t)
```

Index only increases (fees always positive).

---

## Edge Cases

### Zero Index Protection

```solidity
if (lpState.liquidityIndex == 0) {
    lpState.liquidityIndex = PRECISION;  // Initialize to 1.0
}
```

### Transfer Before Initialized

```solidity
if (lpState.liquidityIndex == 0) {
    if (amount > 0) revert NotInitialized();
    continue;  // Allow zero-amount transfers
}
```

### Minimum Liquidity

```solidity
if (asset.reserves == 0 && amount < MIN_LIQUIDITY) {
    revert BelowMinimumLiquidity();
}
```

**Prevents:**
- First depositor manipulation
- Dust deposits
- Rounding exploits

---

## Gas Optimization

1. **Single storage read:** `lpState` cached
2. **Batch updates:** Index updated once per fee event
3. **Minimal math:** Division only on view functions
4. **Packed structs:** `LPState` fits in 1 slot

---

## Comparison to Alternatives

### vs. Standard ERC20 LP Tokens

| Feature | ERC20 | ERC1155 (BAMM) |
|---------|-------|----------------|
| Multi-asset | Need N contracts | Single contract |
| Fee compounding | Manual claim | Automatic |
| Transfer gas | ~50k | ~50k (similar) |
| Mint gas | ~50k | ~50k (similar) |
| Metadata | Static | Dynamic URI |

### vs. ERC4626 Vault

| Feature | ERC4626 | ERC1155 (BAMM) |
|---------|---------|----------------|
| Standard | Vault standard | LP standard |
| Multi-asset | Need N vaults | Single contract |
| Share price | `assets/shares` | `liquidityIndex` |
| Rebasing | Via share price | Via index |

---

## Future Enhancements

- **Batch minting:** Deposit multiple assets at once
- **LP token staking:** Additional yield on staked LPs
- **LP derivatives:** Wrapped versions for DeFi composability
- **Permit support:** Gasless approvals
- **Multi-send:** Batch transfers to multiple recipients
