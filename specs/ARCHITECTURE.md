# BAMM Protocol Architecture

## Overview

BAMM (Balanced Automated Market Maker) is a multi-asset AMM with dynamic fee mechanisms, internal oracle pricing, and rebasing LP tokens.

**Core Design:**
- Hub-and-spoke swap model (all routes via base token)
- Dynamic multi-factor fee system
- Internal oracle with dual EMA tracking
- ERC1155 rebasing LP tokens
- Upgradeable via beacon proxy pattern (see [UPGRADEABILITY.md](./UPGRADEABILITY.md))

---

## System Architecture

### Contract Structure

```
BAMM.sol              ~900 lines  (core pool logic + management + flash loans)
├─ BAMMManagement     ~350 lines  (ownership, roles, oracles, rescue)
├─ BAMMFlashLender    ~150 lines  (ERC-3156 flash loans)
└─ Pricing (library)  ~400 lines  (fee calculations + ALM)

BeaconFactory.sol     ~80 lines   (abstract base for all factories)
BAMMFactory.sol       ~180 lines  (extends BeaconFactory)
DarkPoolFactory.sol   ~80 lines   (extends BeaconFactory)
OracleFactory.sol     ~110 lines  (extends BeaconFactory)
```

**Factory System:**
- All factories extend `BeaconFactory` (shared beacon management)
- Each factory controls beacon upgrades for its deployments
- Independent ownership (BAMM/DarkPool/Oracle factories separate)

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

**Storage Pattern:**
- Using EIP-7201 namespaced storage via LibStorage
- Upgradeable via beacon proxy pattern
- Each proxy maintains isolated storage
- See [UPGRADEABILITY.md](./UPGRADEABILITY.md) for details

---

## Swap Mechanism

### Hub-and-Spoke Model

All swaps route through the base token (typically USDC) as a pricing numéraire. The system supports two swap types:

1. **Direct swaps** (A ↔ base): One token is the base token
2. **Triangulated swaps** (A → base → B): Base token is virtual numéraire only

**Key properties**:
- Base token reserves/liabilities unchanged in triangulated swaps
- Virtual depth ensures path independence (A→base→B has same slippage as direct A↔B)
- Fee split 50/50 between real liquidity providers (base earns nothing in triangulated swaps)

**For complete swap routing specification**, including pricing flow, virtual depth mechanics, and numéraire concepts, see **[SWAP.md](./SWAP.md)**.

---

## Asset Management

### Adding Assets

```solidity
function addAsset(
    address token,
    address oracle,
    uint16 targetAllocBps,
    uint8 segmentCount,
    uint8[32] calldata weights,
    int8[33] calldata offsets,
    uint32 minPriceStep,
    uint32 maxBreadth
) external onlyOwner
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

**LP receives their proportional share of available reserves.** No explicit haircut penalties are applied; the coverage ratio is naturally reflected in reserve availability. This ensures fair pro-rata loss sharing without additional penalties for withdrawing during pool imbalances.

**Withdrawal fee:** 0% to 5% based on inventory imbalance

---

## Emergency Controls

### Pause/Unpause

```solidity
function pausePool() external onlyOwner
function unpausePool() external onlyOwner
```

Blocks all swaps and deposits. Withdrawals remain enabled.

### Asset Freeze

```solidity
function freezeAsset(address token, string calldata reason) external onlyOwner
function unfreezeAsset(address token) external onlyOwner
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

The protocol uses **EIP-1967 beacon proxies** for all major components (BAMM pools, DarkPools, Oracles).

```
BeaconFactory (base)
  ├─ UpgradeableBeacon (Solady)
  │    └─ Implementation (shared logic)
  │
  └─ Beacon Proxies (multiple instances)
       ├─ Proxy 1 (isolated storage)
       ├─ Proxy 2 (isolated storage)
       └─ Proxy N (isolated storage)
```

**Upgrade flow:**
1. Deploy new implementation
2. Factory owner calls `upgradeBeacon(newImpl)`
3. **ALL proxies instantly use new logic** (live lookup on every call)
4. Each proxy's storage preserved

**Key Features:**
- Single atomic upgrade for all instances
- Instant activation (no migration)
- Rollback capability (upgrade to previous impl)
- Gas-efficient Solady implementation
- Safe ownership transfer (EOA → multisig)

**See [UPGRADEABILITY.md](./UPGRADEABILITY.md) for:**
- Detailed upgrade procedures
- Storage compatibility rules
- Security considerations
- Testing strategies
- Component-specific details

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
7. **Coverage Ratio Tracking:** `C = reserves / liabilities` (withdrawal maintains constant C)
8. **Fair Withdrawal:** LPs receive proportional share of reserves without explicit haircut penalties

---

## Gas Optimization

- **Struct packing:** Minimize storage slots
- **Cached calculations:** Store total value with TTL
- **Batch operations:** Update allocations once per tx
- **Minimal inheritance:** Single contract + libraries
- **Custom errors:** Save gas vs strings
- **Ternary operators:** Reduce bytecode

---

## Design Decisions & Rationale

### Why No External Price Oracles (Chainlink, etc.)?

**Decision:** BAMM uses **internal oracle pricing only** (EMA-based TWAPs), with no dependency on external oracles like Chainlink.

**Rationale:**

1. **Hub-and-spoke pricing model:**
   - All swaps route through base token (USDC)
   - Prices calculated via: `amountOut = (amountIn * priceIn) / priceOut`
   - Internal oracle provides `priceIn` and `priceOut`
   - **No price oracle manipulation risk** since swaps don't use prices in invariant calculations

2. **Internal EMA provides sufficient accuracy:**
   - Dual EMA tracking (fast + slow) for each asset
   - Updated on every swap with actual trade prices
   - Self-correcting: arbitrageurs keep prices in line with external markets
   - Cheaper and more gas-efficient than external oracle calls

3. **Attack vector elimination:**
   - Chainlink integration adds dependency on external system
   - Oracle manipulation attacks don't apply to this model
   - Does not use price-weighted inventory calculations vulnerable to oracle gaming
   - LP tokens are **non-transferable liabilities**, not tradeable assets

4. **Reduced complexity & gas costs:**
   - No external contract calls per swap
   - No multi-source price aggregation needed
   - No TWAP observation storage beyond internal EMA
   - Simpler upgrade path (fewer dependencies)

**When we might need external oracles:**
- Cross-chain price synchronization (future)
- Initial asset listing (bootstrapping prices)
- Circuit breaker triggers based on off-chain events (NOT for core pricing)

**Related:** See [ORACLE.md](./ORACLE.md) for internal oracle specification.

---

### Why LP Tokens Can't Be Swapped

**Decision:** LP tokens represent **one-sided liability claims** and cannot be swapped or transferred.

**Rationale:**

1. **Accounting model** (see [ALM_AND_COVERAGE.md](./ALM_AND_COVERAGE.md)):
   - LP tokens track liabilities: `C = reserves / liabilities`
   - Each asset has its own LP token (ERC1155 token IDs)
   - Swapping LP tokens would break liability tracking

2. **No deposit→swap LP→withdraw arbitrage:**
   - Attack path doesn't exist in this protocol
   - LPs can only withdraw the specific asset they deposited (or a portion)

3. **Simplified economics:**
   - No need for LP-LP pricing mechanisms
   - No cross-pool LP arbitrage concerns
   - Simpler invariant design (reserves/liabilities per asset)

4. **User experience:**
   - LPs understand: "deposit USDC → get USDC LP tokens → withdraw USDC"
   - No confusing "LP token markets" or "impermanent loss from LP swaps"

**Related:** See [ERC1155_LP_TOKENS.md](./ERC1155_LP_TOKENS.md) for LP token specification.

---

### Why No Circuit Breakers for Withdrawals

**Decision:** No automatic withdrawal pausing based on coverage ratio thresholds.

**Rationale:**

1. **Fairness to LPs:**
   - LPs deposit in good faith, should always be able to exit
   - "Pausing withdrawals" when coverage < threshold is a rugpull
   - Better to let LPs leave fairly than trap them

2. **Bank run prevention paradox:**
   - Knowing withdrawals CAN be paused → incentivizes rushing to exit first
   - Creates the bank run you're trying to prevent
   - Better to allow orderly exits at fair (reduced) rates

3. **Natural protection through fees:**
   - Withdrawal fees increase when assets imbalanced (0-5% dynamic)
   - High fees slow withdrawals naturally without pausing
   - Tri-factor fee model makes large withdrawals expensive when coverage low

4. **Proper invariant design:**
   - If protocol needs circuit breakers to survive, the economic model is broken
   - Better to design fees/invariant such that C cannot drop below critical levels
   - Current model: reserves depleted → fees increase → withdrawals slow → rebalancing

**Emergency controls we DO have:**
- `freezeAsset()`: Owner can freeze specific asset swaps (not withdrawals)
- `pausePool()`: Owner can pause swaps and deposits (withdrawals still enabled)
- `rescueERC20()`: Owner can recover stuck tokens (with timelock)

**Related:** See [ALM_AND_COVERAGE.md](./ALM_AND_COVERAGE.md) for coverage ratio behavior.

---

## Related Documentation

- [UPGRADEABILITY.md](./UPGRADEABILITY.md) - Complete upgrade system documentation
- [FEES.md](./FEES.md) - Fee structure and calculations
- [ORACLE.md](./ORACLE.md) - Oracle system and price feeds
- [DARK_POOL.md](./DARK_POOL.md) - Privacy layer specification
- [BAMM_HOOKS.md](./BAMM_HOOKS.md) - Hook system details
- [ERC1155_LP_TOKENS.md](./ERC1155_LP_TOKENS.md) - ERC1155 rebasing LP tokens
- [ALM_AND_COVERAGE.md](./ALM_AND_COVERAGE.md) - Coverage ratio ALM model

---

## Future Considerations

- Governance token integration: stake governance token to vote for proposals and asset incentives
- Pendle SY wrapper for composability
- Aave hypothecation of reserves for idle liquidity yield (but high swap gas cost)
- Cross-chain inventory management
