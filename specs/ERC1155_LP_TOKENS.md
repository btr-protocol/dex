# ERC1155 Rebasing LP Tokens

## Overview

BTR uses **ERC1155 (Multi-Token Standard)** with **rebasing mechanics** (Aave-style scaled balances) for LP tokens to enable:
1. **Multi-asset efficiency**: Single contract for all pool assets
2. **Auto-compounding fees**: O(1) fee distribution without manual claims
3. **Value stability**: LP token count grows, not value per token
4. **DeFi composability**: Wrappable into ERC20/ERC4626 when needed

---

## Design Decision: Token Standard

### Options Considered

| Standard | Structure | Pros | Cons |
|----------|-----------|------|------|
| **ERC20 per asset** | N contracts | Universal support, simple | O(N) deployment, O(holders) fee distribution |
| **ERC4626 per asset** | N vaults | Standard vault interface | O(N) deployment, share price can decrease |
| **ERC1155 multi-asset** | 1 contract | O(1) deployment, batch ops | Requires modern wallets, custom DEX integration |

### Decision: ERC1155

**Rationale:**
- BTR pools have **3-10 assets** → massive gas savings at scale
- **O(1) fee distribution** via rebasing eliminates per-holder minting costs
- **Batch operations** enable atomic multi-asset deposits/withdrawals
- Modern wallet support (MetaMask, Rabby, Rainbow) is excellent
- **Wrappable** into ERC20/ERC4626 for legacy DeFi protocols

**Key Trade-off:** Accept custom DEX integration work in exchange for 75-98% gas savings on operations.

---

## Design Decision: No LP-LP Swaps

### Decision

**LP tokens represent one-sided liability claims** and cannot be swapped for other LP token types.

- ✅ **User-to-user transfers**: Allowed (standard ERC1155 transfers)
- ❌ **LP-LP swaps**: NOT allowed (e.g., cannot swap USDC LP tokens for WETH LP tokens)
- ✅ **Withdraw**: Only the specific asset type that the LP token represents

### Example

```solidity
// ✅ ALLOWED: Deposit USDC, get USDC LP tokens
bamm.deposit(USDC, 1000e6, minLpTokens);
uint256 usdcLPBalance = bamm.balanceOf(alice, tokenId(USDC));

// ✅ ALLOWED: Transfer USDC LP tokens to Bob
bamm.safeTransferFrom(alice, bob, tokenId(USDC), usdcLPBalance, "");

// ❌ NOT ALLOWED: Swap USDC LP for WETH LP (no such function exists)
// bamm.swapLP(tokenId(USDC), tokenId(WETH), amount);  // DOES NOT EXIST

// ✅ ALLOWED: Withdraw USDC using USDC LP tokens
bamm.withdraw(USDC, usdcLPBalance, minAmountOut);
```

### Rationale

**1. Liability Tracking Model** (see [ALM_COVERAGE_RATIO.md](./ALM_COVERAGE_RATIO.md)):

Each asset tracks its own reserves and liabilities separately:

```solidity
struct Asset {
    uint128 reserves;      // Physical tokens in pool
    uint128 liabilities;   // Total deposited (LP claims)
}

Coverage Ratio (C) = reserves / liabilities
```

If LP tokens could be swapped:
- USDC LP holder swaps for WETH LP
- USDC liabilities decrease, WETH liabilities increase
- But reserves didn't change → coverage ratios break
- Liability tracking becomes meaningless

**2. No Deposit→Swap LP→Withdraw Arbitrage:**

The coverage ratio feedback document proposes fees to prevent this attack:
1. Deposit USDC when coverage > 1 (get favorable LP rate)
2. Swap USDC LP for WETH LP
3. Withdraw WETH when coverage < 1 (extract value)

**This attack path doesn't exist** in BAMM because:
- Step 2 is impossible (no LP-LP swaps)
- LPs can only withdraw the specific asset they deposited

**3. Simplified Economics:**

Without LP-LP swaps:
- No need for LP-LP pricing mechanisms (complex!)
- No cross-asset LP arbitrage concerns
- Simpler invariant design (reserves/liabilities per asset)
- Clearer user mental model

**4. User Experience:**

LPs understand the simple flow:
- Deposit USDC → get USDC LP tokens → withdraw USDC
- Your LP tokens represent claims on USDC reserves only
- No confusing "which LP token is more valuable?" questions

### What LPs CAN Do

| Action | Allowed? | Description |
|--------|----------|-------------|
| **Deposit** | ✅ | Deposit asset X, receive asset X LP tokens |
| **Withdraw** | ✅ | Burn asset X LP tokens, withdraw asset X |
| **Transfer LP** | ✅ | Send LP tokens to another address (standard ERC1155) |
| **Swap assets** | ✅ | Swap asset X for asset Y via pool (NOT LP tokens) |
| **Swap LP tokens** | ❌ | Cannot swap asset X LP for asset Y LP |

### Comparison to Other Protocols

| Protocol | LP Token Model | LP-LP Swaps? |
|----------|----------------|--------------|
| **Uniswap V2** | One ERC20 per pair | ❌ No (separate pools) |
| **Balancer V2** | One ERC20 per pool | ❌ No (single LP represents all assets) |
| **Curve** | One ERC20 per pool | ❌ No (single LP represents all assets) |
| **BAMM** | One ERC1155 ID per asset | ❌ No (one-sided liabilities) |

**Key difference:** Other AMMs use single LP token for entire pool (e.g., 1 token represents 50% ETH + 50% USDC). BAMM uses **separate LP tokens per asset** but disallows swapping between them.

### Related Design Decisions

- **See [ARCHITECTURE.md](./ARCHITECTURE.md#why-lp-tokens-cant-be-swapped)** - High-level protocol design
- **See [ALM_COVERAGE_RATIO.md](./ALM_COVERAGE_RATIO.md)** - Liability tracking and coverage ratios
- **See [FEES.md](./FEES.md)** - Why deposit/withdrawal arbitrage fees are unnecessary

---

## Design Decision: Rebasing vs Non-Rebasing

### Three Approaches to Fee Distribution

| Approach | Token Count | Token Value | UX | Gas Cost | Value Peg |
|----------|-------------|-------------|----|---------|-----------|
| **1. Manual Claims** | Fixed | Fixed | ❌ Requires claiming | O(1) | ✅ Stable |
| **2. Auto-Compounding Value** | Fixed | Grows | ✅ Automatic | O(1) | ❌ Breaks (like aTokens) |
| **3. Rebasing (BTR)** | Grows | Stable | ✅ Automatic | O(1) | ✅ Stable |

### Approach 1: Manual Claims (e.g., Uniswap V2)

```solidity
// Users must manually claim accumulated fees
function claimFees(address token) external returns (uint256 feeAmount);
```

**Pros:**
- Simple accounting
- LP token value stays constant
- Gas-efficient fee accrual (no per-user updates)

**Cons:**
- ❌ Poor UX: Users must remember to claim
- ❌ Gas cost to claim
- ❌ Unclaimed fees don't compound
- ❌ Fee tracking complexity

### Approach 2: Auto-Compounding Value (e.g., Aave aTokens)

```solidity
// LP token value increases, count stays fixed
lpTokenValue = reserves / totalSupply;  // Grows over time
```

**Pros:**
- Auto-compounding (no claims)
- Simple implementation
- Gas-efficient

**Cons:**
- ❌ **Breaks value peg**: 1 LP ≠ 1 underlying token
- ❌ Complicates accounting for integrators
- ❌ Harder to reason about positions
- ⚠️ Can be wrapped into ERC4626 for composability

**Example:** If you deposit 100 USDC and get 100 LP tokens, after 10% fees accrue:
- Your 100 LP tokens are worth 110 USDC
- LP token value: 1.1 USDC per token
- **Problem:** Integrators must constantly track value, not count

### Approach 3: Rebasing (BTR - Aave-style)

```solidity
// LP token count increases, value stays stable
balanceOf(user) = scaledBalance * liquidityIndex / 1e18;
```

**Pros:**
- ✅ Auto-compounding (no claims)
- ✅ **Maintains value peg**: 1 LP ≈ 1 underlying token
- ✅ Token count reflects value intuitively
- ✅ Gas-efficient: O(1) per fee event
- ✅ Wrappable into ERC20/ERC4626

**Cons:**
- ⚠️ `balanceOf()` changes without transfers (rebasing behavior)
- ⚠️ Requires explanation to users unfamiliar with rebasing

**Example:** If you deposit 100 USDC and get 100 LP tokens, after 10% fees accrue:
- Your LP token count: 110 tokens
- LP token value: ~1.0 USDC per token
- **Benefit:** Token count directly shows value

### Decision: Rebasing (Approach 3)

**Rationale:**
1. **Better UX than claims**: Automatic fee accrual
2. **Better accounting than value growth**: Maintains 1:1 peg intuition
3. **Proven pattern**: Aave's scaled balance model (battle-tested)
4. **Composability**: Can wrap into non-rebasing ERC20/ERC4626 for DeFi integration

**Critical insight:** Rebasing preserves the intuition that "LP token count = value" while enabling auto-compounding.

---

## Rebasing Mechanism: Scaled Balances + Liquidity Index

### Data Structures

```solidity
struct LPState {
    uint128 totalScaledSupply;   // Sum of all scaled balances (constant except mint/burn)
    uint128 liquidityIndex;       // Rebasing multiplier (grows with fees, starts at 1e18)
}

// Internal accounting: scaled balances
mapping(address => mapping(address => uint256)) scaledBalances;
```

### Balance Calculation

```solidity
function balanceOf(address owner, uint256 id) public view returns (uint256) {
    address token = address(uint160(id));
    uint256 scaledBalance = scaledBalances[owner][token];
    uint128 index = lpStates[token].liquidityIndex;

    return (scaledBalance * index) / 1e18;  // Scales up with fees
}
```

**Key property:** `scaledBalance` is constant (except deposits/withdrawals/transfers), but `balanceOf()` grows as fees accrue.

### Fee Accrual: O(1) Regardless of LP Count

```solidity
function _accrueFeesToLPs(Asset storage asset, LPState storage lpState, uint256 feeAmount) {
    // Add fees to reserves
    uint256 oldReserves = asset.reserves;
    asset.reserves = oldReserves + feeAmount;

    // Update index: newIndex = oldIndex × newReserves / oldReserves
    lpState.liquidityIndex = uint128(
        (uint256(lpState.liquidityIndex) * asset.reserves) / oldReserves
    );
}
```

**Gas cost:** ~40k (2 SSTORE) regardless of LP holder count

**Comparison:**

| Approach | 10 LPs | 100 LPs | 1000 LPs |
|----------|--------|---------|----------|
| **ERC20 minting** | ~200k | ~2M | ~20M |
| **Rebasing (BTR)** | ~40k | ~40k | ~40k |

**Savings:** 98% for 100 LPs, 99.8% for 1000 LPs

### Example: Fee Accrual

```
Initial State:
├─ reserves: 1000 USDC
├─ totalScaledSupply: 1000
├─ liquidityIndex: 1.0e18
└─ Alice scaledBalance: 100

Alice LP balance: (100 × 1.0e18) / 1e18 = 100 tokens

Swap generates 50 USDC fee:
├─ newReserves: 1050 USDC
├─ newIndex: (1.0e18 × 1050) / 1000 = 1.05e18
└─ Alice scaledBalance: 100 (unchanged)

Alice LP balance: (100 × 1.05e18) / 1e18 = 105 tokens (+5%)

Result: All LPs automatically earn 5% more tokens
```

---

## Token ID Scheme: Direct Address Casting

### Design

```solidity
// Zero-cost bijection
uint256 tokenId = uint256(uint160(assetAddress));
address asset = address(uint160(tokenId));
```

**Properties:**
- **Bijective**: Every asset ↔ exactly one token ID
- **Zero-cost**: Pure assembly cast, no storage lookups
- **Predictable**: Off-chain tools can calculate IDs
- **No registry**: Eliminates 2 storage slots (~40k gas) per asset

**Example:**
```
WETH: 0x7ceB23fD6bC0adD59E62ac25578270cFf1b9f619
→ Token ID: 701332046859776641134542099953513155635840574233
```

### Alternative Rejected: Sequential IDs

Would require storage mappings and contract queries. No benefits over direct casting.

---

## Deposit & Withdraw Mechanics

### Deposit

```solidity
function deposit(address token, uint256 amount) external returns (uint256 lpTokens) {
    // Calculate LP tokens proportional to reserves
    if (totalScaledSupply == 0) {
        lpTokens = amount;  // First deposit: 1:1
    } else {
        lpTokens = (amount × totalScaledSupply × 1e18) / (reserves × liquidityIndex);
    }

    // Store scaled amount (not absolute)
    uint256 scaledAmount = (lpTokens × 1e18) / liquidityIndex;

    // Update state
    totalScaledSupply += scaledAmount;
    reserves += amount;
    scaledBalances[msg.sender][token] += scaledAmount;
}
```

**Key:** Scaled balance stored, future fees automatically increase user's `balanceOf()`.

### Withdraw

```solidity
function withdraw(address token, uint256 lpTokens) external returns (uint256 amountOut) {
    // Calculate underlying amount
    uint256 scaledAmount = (lpTokens × 1e18) / liquidityIndex;
    amountOut = (scaledAmount × liquidityIndex × reserves) / (totalScaledSupply × 1e18);

    // Apply withdrawal fee (if any) - benefits remaining LPs
    if (withdrawalFee > 0) {
        uint256 fee = (amountOut × withdrawalFee) / 10000;
        amountOut -= fee;
        _accrueFeesToLPs(asset, lpState, fee);
    }

    // Update state
    totalScaledSupply -= scaledAmount;
    reserves -= amountOut;
    scaledBalances[msg.sender][token] -= scaledAmount;
}
```

**Key:** Withdrawal fees benefit remaining LPs (discourages mercenary capital).

---

## Transfer Mechanics

### Standard Compliance

BTR implements full ERC1155 with hooks to update scaled balances:

```solidity
function safeTransferFrom(address from, address to, uint256 id, uint256 amount, bytes data) {
    // Standard ERC1155 auth check
    require(msg.sender == from || isApprovedForAll(from, msg.sender));

    // Update scaled balances (not absolute)
    uint256 scaledAmount = (amount × 1e18) / liquidityIndex;
    scaledBalances[from][token] -= scaledAmount;
    scaledBalances[to][token] += scaledAmount;

    // Standard receiver check
    if (to.code.length != 0) {
        require(IERC1155Receiver(to).onERC1155Received(...));
    }
}
```

**Key:** Both sender and receiver maintain proportional fee earnings after transfer.

### Batch Transfers

```solidity
// Transfer multiple LP tokens in one tx
uint256[] memory ids = [uint256(uint160(WETH)), uint256(uint160(USDC))];
uint256[] memory amounts = [10e18, 100e6];
bamm.safeBatchTransferFrom(alice, bob, ids, amounts, "");
```

**Gas savings:** ~53% vs separate transactions.

---

## Metadata: Dynamic URI

### URI Format

```solidity
function uri(uint256 id) public view returns (string memory) {
    address token = address(uint160(id));
    return string(abi.encodePacked(
        "https://btr.supply/pool/",
        toHexString(address(this)),  // Pool address (multiple pools can exist)
        "/",
        toHexString(token)            // Asset address
    ));
}
```

**Why include pool address?** Multiple BTR pools can exist with overlapping assets. Including pool address ensures unique URIs and distinct metadata (APY, reserves, etc.).

**Metadata Schema:**
```json
{
  "name": "BTR WETH LP",
  "symbol": "BTR-WETH-LP",
  "decimals": 18,
  "properties": {
    "pool": "0x...",
    "asset": "0x...",
    "reserves": "125.3",
    "liquidityIndex": "1.0523",
    "apy": "12.5%",
    "volume24h": "$2.5M"
  }
}
```

**Choice: Dynamic URLs** (not embedded JSON) because reserves, APY, volume change continuously. Server queries blockchain for real-time values.

---

## Security Considerations

### 1. First Depositor Attack Prevention

```solidity
if (reserves == 0 && amount < minLiquidity) {
    revert BelowMinimumLiquidity();
}
```

**Attack:** Deposit 1 wei, directly transfer 1000 tokens to contract → next depositor gets unfavorable rate.

**Mitigation:** Require minimum first deposit (e.g., 1e6 for USDC).

### 2. Reentrancy Protection

All state-changing functions use `nonReentrant` modifier to prevent callback attacks during external token transfers.

### 3. Scaled Balance Consistency

```solidity
if (fromBalance < scaledAmount) revert InsufficientBalance();
```

Prevents transferring more than owned and balance inflation attacks.

### 4. Integer Overflow Protection

Solidity 0.8+ built-in checks + explicit bounds:
```solidity
totalScaledSupply = Cast.toUint128(totalScaledSupply + scaledAmount);
```

### 5. Division by Zero Protection

```solidity
if (liquidityIndex == 0) {
    liquidityIndex = 1e18;  // Initialize to 1.0
}
```

---

## Composability: Wrapping for DeFi Integration

### Problem: DeFi Protocols Expect ERC20

Most DeFi protocols (Uniswap, Aave, Compound) expect ERC20 tokens. ERC1155 requires custom integration.

### Solution: ERC20 Wrapper Contracts

```solidity
contract WrappedBTRLP is ERC20 {
    IBAMM public immutable bamm;
    address public immutable underlyingAsset;
    uint256 public immutable tokenId;

    function wrap(uint256 amount) external {
        // Transfer ERC1155 LP tokens to wrapper
        bamm.safeTransferFrom(msg.sender, address(this), tokenId, amount, "");

        // Mint ERC20 wrapper tokens 1:1
        _mint(msg.sender, amount);
    }

    function unwrap(uint256 amount) external {
        // Burn ERC20 wrapper tokens
        _burn(msg.sender, amount);

        // Return ERC1155 LP tokens
        bamm.safeTransferFrom(address(this), msg.sender, tokenId, amount, "");
    }
}
```

**Properties:**
- 1:1 backing (1 wrapped token = 1 LP token)
- Wrapping/unwrapping ~100k gas
- Wrapper inherits rebasing (balance grows over time)
- Can be used in any ERC20-compatible protocol

### ERC4626 Vault Wrapper

```solidity
contract BTRLP4626Vault is ERC4626 {
    IBAMM public immutable bamm;
    address public immutable underlyingAsset;

    function deposit(uint256 assets, address receiver) public override returns (uint256 shares) {
        // User deposits underlying asset (e.g., USDC)
        asset.transferFrom(msg.sender, address(this), assets);

        // Vault deposits into BAMM
        asset.approve(address(bamm), assets);
        uint256 lpTokens = bamm.deposit(underlyingAsset, assets, 0);

        // Mint ERC4626 shares 1:1
        shares = lpTokens;
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256 assets) {
        // Burn ERC4626 shares
        _burn(owner, shares);

        // Withdraw from BAMM
        assets = bamm.withdraw(underlyingAsset, shares, 0);

        // Transfer underlying to receiver
        asset.transfer(receiver, assets);
    }

    function totalAssets() public view override returns (uint256) {
        uint256 lpTokens = bamm.balanceOf(address(this), tokenId);
        return bamm.getLPValue(underlyingAsset, lpTokens);
    }
}
```

**Properties:**
- Standard ERC4626 interface
- Compatible with all vault-aware protocols
- Inherits auto-compounding from rebasing
- ~200k gas per deposit/redeem

**Trade-off:** Adds ~100-200k gas overhead for wrapping, but enables universal DeFi composability.

---

## Gas Analysis

### Fee Distribution

| Approach | 10 LPs | 100 LPs | 1000 LPs | Scales with LP count? |
|----------|--------|---------|----------|----------------------|
| **ERC20 minting** | ~200k | ~2M | ~20M | ❌ Yes (O(N)) |
| **Manual claims** | ~40k accrual + O(N) claims | Same | Same | ⚠️ Deferred to users |
| **Rebasing (BTR)** | ~40k | ~40k | ~40k | ✅ No (O(1)) |

**Savings:** 98% for 100 LPs, 99.8% for 1000 LPs

### Per-Operation Costs

| Operation | ERC20 | ERC1155 (BTR) | Difference |
|-----------|-------|---------------|------------|
| **Single transfer** | ~50k | ~52k | +4% |
| **Batch transfer (3)** | ~150k | ~70k | **-53%** |
| **Balance query** | 2.5k | 3k | +20% |
| **Deposit** | ~50k | ~50k | ~0% |
| **Withdraw** | ~50k | ~50k | ~0% |

**Takeaway:** Comparable costs for individual operations, massive savings on fee distribution and batch operations.

---

## Comparison to Alternatives

### vs. ERC20 per Asset

| Aspect | ERC20 (N contracts) | ERC1155 (BTR) |
|--------|---------------------|---------------|
| Deployment cost | O(N) × ~1.5M gas | O(1) × ~2.5M gas |
| Fee distribution | O(holders) per asset | O(1) for all assets |
| Batch operations | No | Yes |
| Wallet support | Universal | Modern wallets |
| DEX integration | Native | Requires wrapper |
| Rebasing support | Custom (like stETH) | Native |

**Winner:** ERC1155 for pools with 3+ assets due to deployment savings and O(1) fee distribution.

### vs. ERC4626 per Asset

| Aspect | ERC4626 (N vaults) | ERC1155 (BTR) |
|--------|---------------------|---------------|
| Multi-asset | Need N vaults | Single contract |
| Share accounting | `assets/shares` ratio | `liquidityIndex` |
| Fee distribution | Via share price increase | Via token count increase |
| Value peg | Breaks (share value grows) | Maintains (token count grows) |
| Standard adoption | Growing | Custom |
| Composability | Native | Via wrapper |

**Winner:** ERC1155 for multi-asset efficiency, but ERC4626 for standard compatibility (mitigated by wrapper).

### Rebasing vs Non-Rebasing

| Approach | Auto-Compound | Value Peg | UX | Gas per Distribution |
|----------|---------------|-----------|----|--------------------|
| **Manual claims** | ❌ No | ✅ Stable | ❌ Poor | O(1) + O(N) claims |
| **Value growth** | ✅ Yes | ❌ Breaks | ⚠️ Confusing | O(1) |
| **Rebasing (BTR)** | ✅ Yes | ✅ Stable | ✅ Intuitive | O(1) |

**Winner:** Rebasing for best combination of UX, gas efficiency, and accounting clarity.

---

## Invariants

### 1. Scaled Supply Consistency
```solidity
sum(scaledBalances[user][token]) == lpState.totalScaledSupply
```

### 2. Balance Consistency
```solidity
balanceOf(user, tokenId) == (scaledBalances[user][token] × liquidityIndex) / 1e18
```

### 3. Index Monotonicity
```solidity
liquidityIndex(t+1) >= liquidityIndex(t)  // Fees always positive
```

### 4. Total Value Conservation
```solidity
sum(balanceOf(user, tokenId) for all users) ≈ asset.reserves
```

---

## Conclusion

### ✅ Why ERC1155 Rebasing for BTR

1. **O(1) Fee Distribution**: 98-99% gas savings vs ERC20 minting
2. **Multi-Asset Efficiency**: Single contract for 3-10 assets
3. **Auto-Compounding UX**: No manual claims required
4. **Value Peg**: Token count grows, not value (maintains 1:~1 peg)
5. **Batch Operations**: Atomic multi-asset transfers
6. **Composability**: Wrappable into ERC20/ERC4626 for DeFi integration

### ⚠️ Trade-offs Accepted

1. **Rebasing behavior**: `balanceOf()` changes without transfers (industry standard for yield-bearing tokens)
2. **Wallet UX**: Some wallets show in "Collectibles" (mitigated by metadata)
3. **DEX integration**: Requires wrappers for ERC20-only protocols (~100-200k gas overhead)
4. **Balance query cost**: +500 gas vs ERC20 (negligible)

### 🎯 Best Practice

- **Primary interface**: ERC1155 for gas efficiency and auto-compounding
- **Optional wrappers**: Deploy ERC20/ERC4626 wrappers for DeFi integration
- **Metadata server**: Dynamic URIs with real-time pool metrics

**Overall:** ERC1155 with rebasing is optimal for multi-asset LP tokens. The gas savings (98%+ on fee distribution), improved UX (auto-compounding), and accounting clarity (value peg) far outweigh the need for optional wrappers for legacy protocols.
