# BAMM Protocol Architecture

## Overview

BAMM (Balanced Automated Market Maker) is a multi-asset AMM with dynamic fee mechanisms, internal oracle pricing, and rebasing LP tokens.

**Core Design:**
- Hub-and-spoke swap model (all routes via base token)
- Dynamic multi-factor fee system
- Internal oracle with dual EMA tracking
- ERC1155 rebasing LP tokens
- Upgradeable via beacon proxy pattern

---

## System Architecture

### Contract Structure

```
BAMM.sol              ~600 lines  (core pool logic)
├─ AccessControl      ~100 lines  (role management)
├─ Rescue             ~70 lines   (emergency recovery)
└─ Pricing (library)  ~170 lines  (fee calculations)

BAMMFactory.sol       ~100 lines  (minimal, permissionless)
BAMMEvents.sol        ~70 lines   (errors + events)
```

**Total: ~1,010 lines**

### Storage Model

**Non-upgradeable storage** (simpler, gas efficient):
```solidity
contract BAMM {
    address public baseToken;
    bool public paused;

    mapping(address => Asset) public assets;
    mapping(address => LiquidityProfile) public profiles;
    mapping(address => LPState) public lpStates;
    mapping(address => mapping(address => uint256)) public scaledBalances;

    address[] public registeredAssets;
}
```

**Key structs:**
```solidity
struct Asset {
    uint128 reserves;
    uint64 fastTWAP;
    uint64 slowTWAP;
    uint32 fastVolatility;
    uint32 slowVolatility;
    uint16 targetAllocBps;
    uint16 currentAllocBps;
    uint8 segmentCount;
    uint8 decimals;
    bool isFrozen;
    uint32 lastOracleUpdate;
    address oracle;
}

struct LPState {
    uint128 totalScaledSupply;
    uint128 liquidityIndex;
}
```

**Why non-upgradeable storage?**
- Simpler implementation
- Lower gas costs (no EIP-7201 overhead)
- Pool upgrades via new beacon implementation
- Factory handles versioning

---

## Swap Mechanism

### Hub-and-Spoke Model

All swaps route through the base token (USDC):

```
TokenA → USDC → TokenB
```

**Price calculation:**
```solidity
amountOut = (amountIn * priceIn) / priceOut
```

**With decimals:**
```solidity
if (decimalsIn > decimalsOut) {
    amountOut /= 10 ** (decimalsIn - decimalsOut)
} else {
    amountOut *= 10 ** (decimalsOut - decimalsIn)
}
```

**Flow:**
1. Calculate fee (multi-factor)
2. Deduct fee from input
3. Calculate output via prices
4. Adjust for decimals
5. Check reserves & slippage
6. Execute transfers
7. Update allocations

---

## Asset Management

### Adding Assets

```solidity
function addAsset(
    address token,
    address oracle,
    uint16 targetAllocBps,
    uint8 segmentCount,
    uint8[16] calldata weights,
    int8[17] calldata offsets,
    uint64 minBreadth,
    uint64 maxBreadth
) external onlyAdmin
```

**Requirements:**
- Unique token address
- Valid oracle address
- Target allocation ≤ 100%
- Segment count: 2-16
- Weights normalize to 255
- Offsets: -100 to +100

### Liquidity Profiles

Define price curve shape via segment weights:

```
Price
  ↑
  |     ┌─────┐
  |   ┌─┘     └─┐
  |  ┌┘         └┐
  | ┌┘           └┐
  |─┴─────────────┴─→ Liquidity
   EMA-100%    EMA+100%
```

**Segments:** Up to 16 per asset
**Weights:** Relative liquidity depth
**Offsets:** Position relative to EMA price

---

## Liquidity Provision

### Deposit

```solidity
function deposit(address token, uint256 amount, uint256 minLpTokens)
    external returns (uint256 lpTokens)
```

**LP token calculation:**
```solidity
if (firstDeposit) {
    lpTokens = amount
} else {
    lpTokens = (amount * totalScaledSupply * PRECISION) /
               (reserves * liquidityIndex)
}
```

### Withdraw

```solidity
function withdraw(address token, uint256 lpTokens, uint256 minAmountOut)
    external returns (uint256 amountOut)
```

**Output calculation:**
```solidity
amountOut = (scaledAmount * liquidityIndex * reserves) /
            (totalScaledSupply * PRECISION)
```

**Withdrawal fee:** 0% to 5% based on inventory imbalance

---

## Emergency Controls

### Pause/Unpause

```solidity
function pausePool() external onlyAdmin
function unpausePool() external onlyAdmin
```

Blocks all swaps and deposits. Withdrawals remain enabled.

### Asset Freeze

```solidity
function freezeAsset(address token, string calldata reason) external onlyAdmin
function unfreezeAsset(address token) external onlyAdmin
```

Blocks swaps for specific asset.

### Circuit Breaker

```solidity
function checkCircuitBreaker(address token) external onlyKeeper returns (bool)
```

Auto-freezes asset if price deviates too far from reference.

---

## Upgrade Mechanism

### Beacon Proxy Pattern

```
Factory
  └─ UpgradeableBeacon
       ├─ Implementation (logic)
       └─ Multiple BeaconProxies (pools)
            ├─ Pool 1 (data)
            ├─ Pool 2 (data)
            └─ Pool N (data)
```

**Upgrade flow:**
1. Deploy new implementation
2. Factory admin calls `upgradeBeacon(newImpl)`
3. All pools automatically use new logic
4. Data preserved in each proxy

**Benefits:**
- Single upgrade for all pools
- Atomic across ecosystem
- Individual pool data isolated

---

## Constants

```solidity
PRECISION           = 1e18
PRICE_PRECISION     = 1e18  // High precision for extreme price ratios
BPS_PRECISION       = 10_000
MIN_LIQUIDITY       = 1000
MAX_SEGMENTS        = 16
MIN_SEGMENTS        = 2
WEIGHT_SUM          = 255

BASE_FEE_BPS        = 30      // 0.30%
MAX_FEE_BPS         = 1000    // 10%
WITHDRAWAL_FEE_BPS  = 0-500   // 0-5%

MAX_PRICE_CHANGE    = 10%     // Per oracle update
```

---

## Security Invariants

1. **Total Allocation:** `Σ(asset.currentAllocBps) = 10000`
2. **Minimum Reserves:** `reserves ≥ MIN_LIQUIDITY` (when supply > 0)
3. **LP Index Monotonic:** `liquidityIndex ≥ PRECISION` (always increases)
4. **LP Balance Consistency:** `scaledSupply * index / PRECISION = totalSupply`
5. **Fee Bounds:** `0 ≤ totalFee ≤ MAX_FEE_BPS`
6. **Oracle Change Limit:** `|newPrice - oldPrice| / oldPrice ≤ 10%`

---

## Gas Optimization

- **Struct packing:** Minimize storage slots
- **Cached calculations:** Store total value with TTL
- **Batch operations:** Update allocations once per tx
- **Minimal inheritance:** Single contract + libraries
- **Custom errors:** Save gas vs strings
- **Ternary operators:** Reduce bytecode

---

## Future Considerations

- Governance token integration: stake governance token to vote for proposals and asset incentives.
- Pendle SY wrapper for composability
- Aave hypothecation of reserves for idle liquidity yield (but high swap gas cost)
- Cross-chain inventory management
