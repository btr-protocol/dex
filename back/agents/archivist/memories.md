# Archivist Persistent Memories

These memories are **never compacted** and always included in context.

## Project Structure

- **Smart Contracts**: `./contracts/src` (Solidity 0.8.33, Foundry)
- **SDK**: `./sdk/src` (TypeScript)
- **Frontend**: `./front/src` (React/Preact)
- **Documentation**: `./docs` (Markdown)

---

## Deterministic Deployment Addresses

**IMPORTANT**: These addresses are reserved via CREATE3 and will be the same across all chains (Ethereum, BNB, Base, Arbitrum, Anvil local).

**Even if contracts are not yet deployed, these addresses are already mined and reserved.**

| Contract | Address | Notes |
|----------|---------|-------|
| **POOL_ZERO** | `0xb7127AE785907441BFBC6C7bDAcC339CD7e2b712` | Multi-asset pool (volatile assets) |
| **POOL_STABLE** | `0xb712dCA09c4327daC7789EA34574783dC554b712` | Stablecoin pool |
| **TREASURY** | `0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3` | Protocol treasury |
| **BRIDGE** | `0xb71269762A37C3bAaE98Bc1C9d95aec3885Fb712` | Cross-chain bridge |
| **BTR** | `0xb7122066D05B248FB3F09025EFe1db9d1761b712` | Governance token (to be deployed) |

### Deployment Infrastructure

| Component | Address | Description |
|-----------|---------|-------------|
| **DEPLOYER** | `0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3` | CREATE3 deployer address (used for all deployments) |
| **CreateX** | `0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed` | CREATE3 factory contract (universal, available on all chains) |

**Deployment Method**: CREATE3 deterministic deployment via CreateX factory.
- Addresses derived from: `keccak256(abi.encodePacked(deployer, salt))`
- Same address across all EVM chains
- Contracts can be "redeployed" to same address if self-destructed

---

## Smart Contract Architecture

### Diamond-like Proxy Pattern

**PoolProxyV1** is a lightweight dispatcher (EIP-2535 diamond inspired) that routes calls to modules (facets) via selector registry.

**Key Features**:
- Module trust system with bytecode hash validation (CRITICAL-10 fix)
- Timelock module updates (high security operations)
- ERC-7201 storage namespacing
- Flow guard for JIT protection (deposit→withdraw cooldowns)

### Module Structure

| Module | Purpose |
|--------|---------|
| **BaseV1** | Shared storage, reentrancy guard (transient), flow guard, helpers |
| **ExchangeV1** | Trading: `swap()`, `batchSwap()`, `getSwapQuote()` |
| **LiquidityV1** | Liquidity: `deposit()`, `withdraw()`, `withdrawTo()`, `swapLiability()`, `donate()` |
| **InternalOracleV1** | TWAP oracles with fast/slow offsets |
| **AdminV1** | Owner operations, timelock governance |
| **FlashV1** | Flash loans |
| **LendV1** | AAVE v3 integration |
| **StakingV1** | LP and gov token staking |
| **DistributorV1** | Reward distribution |
| **RescueV1** | Emergency fund recovery |

### Interface Hierarchy

```
IPoolV1
├── IExchangeV1 (trading)
├── ILiquidityV1 (liquidity)
├── IAdminV1
├── IFlashV1
├── ILendV1
├── IStakingV1
├── IDistributorV1
├── IOracleV1
├── IRescueV1
└── IErrors

ICoreV1 = IExchangeV1 + ILiquidityV1 (combined)
```

---

## User-Facing Contract Interfaces

### ExchangeV1 - Trading Operations

```solidity
// Single swap with anchor path pricing
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address recipient
) external payable returns (uint256 amountOut);

// Multi-input/multi-output batch swap
function batchSwap(
    bytes calldata inputs,   // packed: [address(160)][uint64(amtB64)]
    bytes calldata outputs,  // packed: [address(160)][uint16(w)][uint64(minB64)]
    address recipient
) external payable returns (uint256[] memory amountsOut);

// Get quote without execution
function getSwapQuote(
    address tokenIn,
    address tokenOut,
    uint256 amountIn
) external returns (SwapQuote memory);
```

**View Functions**:
- `getAsset(address) → Asset`
- `getRiskConfig(address) → RiskConfig`
- `getLiquidityProfile(address) → LiquidityProfile`
- `getCoverageRatio(address) → uint256` (reserves/liabilities * 1e18)
- `getMidPrice(address) → uint256`

### LiquidityV1 - Liquidity Operations

```solidity
// Deposit tokens, receive LP tokens (same token count on withdrawal)
function deposit(
    address token,
    uint256 amount
) external payable returns (DepositResult memory);

// Withdraw LP tokens for same asset
function withdraw(
    address token,
    uint256 lpAmount,
    uint256 minAmountOut
) external returns (WithdrawResult memory);

// Withdraw LP tokens for different asset (with swap)
function withdrawTo(
    address tokenFrom,
    address tokenTo,
    uint256 lpAmount,
    uint256 minAmountOut
) external returns (WithdrawResult memory);

// Swap LP tokens between assets (changes liability exposure)
function swapLiability(
    address tokenIn,
    address tokenOut,
    uint256 lpAmountIn,
    uint256 minLpAmountOut
) external returns (uint256 lpAmountOut);

// Donate reserves without receiving LP (increases liquidity index)
function donate(address token, uint256 amount) external payable;
```

---

## Key Data Structures

### Asset (4 storage slots)

```solidity
struct Asset {
    uint128 reserves;           // Slot 1: Current reserves
    uint128 liabilities;        // Slot 1: LP liabilities

    uint128 minLiquidity;       // Slot 2: Minimum liquidity threshold
    uint64 liquidityIndex;      // Slot 2: Compounded donation index
    uint32 lastUpdate;          // Slot 2: Last decay update
    uint32 minDispersion;       // Slot 2: Min liquidity dispersion

    address anchor;             // Slot 3: Parent in anchor tree
    uint16 minFeeBps;           // Slot 3: Min fee (0.0001% units)
    uint16 maxFeeBps;           // Slot 3: Max fee
    uint32 maxDispersion;       // Slot 3: Max dispersion
    uint8 anchorDepth;          // Slot 3: Tree depth
    uint8 decimals;             // Slot 3: Token decimals

    uint16 gamma;               // Slot 4: Inventory sensitivity
    uint16 vega;                // Slot 4: Volatility sensitivity
    uint16 lambda;              // Slot 4: Deviation sensitivity
    uint16 haircutSuppressor;   // Slot 4: Haircut curve gentleness
    uint64 reservationPrice;    // Slot 4: Price floor (B64)
}
```

### SwapQuote

```solidity
struct SwapQuote {
    uint256 amountOut;
    uint256 amountIn;
    uint16 spreadBps;           // Bid-ask spread
    uint256 protoFee;           // Protocol fee
    uint256 lpFee;              // LP fee
    int8 skewIn;                // Input inventory skew (-100 to +100)
    int8 skewOut;               // Output inventory skew
    address[] routeHops;        // Anchor tree path
    uint256[] hopAmounts;
    uint64[] hopPrices;         // B64 encoded
}
```

---

## Protocol Mathematics

### Coverage Ratio

$$coverage = reserves / liabilities$$

- At 100% (1e18): equilibrium, no skew
- Below 100%: positive skew (pool buying, premium)
- Above 100%: negative skew (pool selling, discount)

### Inventory Skew (Avellaneda-Stoikov)

$$skew = { (100, coverage <= 50%), (gamma * 100 * progress, 50% < coverage < 100%), (-gamma * 100 * progress, coverage >= 100%) :}$$

Where $progress$ is normalized distance from target coverage. Gamma is a multiplier (basis 10000): 10000 = 1x, 5000 = 0.5x.

### Haircut (Withdrawal Protection)

$$haircutRatio = (1 - coverage)^p$$

Where $p = 1 + suppression/10000$ (linear to convex). Applied when coverage < 100%.

### Dispersion (Liquidity Breadth)

$$dispersion = clamp(1000 + sigma * vega / 1000, minDispersion, maxDispersion)$$

- $sigma$: volatility EMA (1e6 = 1%)
- $vega$: volatility sensitivity (10000 = 1x)

### Effective Depth (Concave Curve)

$$D = R + k * (L - R) * progress^(1/(1+2k))$$

Where $progress = (coverage - 0.5) / 0.5$ for coverage in [50%, 100%]. Higher k = faster rise (more concave).

### B64 Encoding (52/5/7 floating point)

- **Mantissa**: 52 bits
- **Exponent**: 5 bits (biased by 64)
- **Decimals**: 7 bits (0-31)

$$value = mantissa * 10^(exponent - 64 - decimals)$$

---

## Anchor Tree Pricing

Multi-asset swaps use **Lowest Common Ancestor (LCA)** algorithm on tree topology.

### Tree Structure

```
USDC (root, depth=0)
├── USDT (depth=1)
├── USDe (depth=1) → sUSDe (depth=2)
├── WETH (depth=1)
│   ├── wstETH (depth=2)
│   ├── rETH (depth=2)
│   └── weETH (depth=2)
└── WBTC (depth=1)
    ├── tBTC (depth=2)
    └── cbBTC (depth=2)
```

**Constraints**:
- Max depth: 4 (root at 0, leaves at ≤4)
- Each asset has exactly one anchor (parent)
- Single root guarantees acyclicity

### Hop Semantics

Each hop has distinct behavior:

| Hop Type | Reserves | Pricing | Purpose |
|----------|----------|---------|---------|
| **Edge** (1st/last) | ✓ Change | Full impact | Consume liquidity |
| **Intermediate** (middle) | ✗ Fixed | Mid-price only | Numeraire transform |

**Example** (USDT→wstETH via USDC→WETH):
1. USDT→USDC (edge): Price impact on both, reserve changes
2. USDC→WETH (intermediate): Mid-price only, no reserve change
3. WETH→wstETH (edge): Price impact on both, reserve changes

### Risk Aggregation

Per-hop signals aggregated conservatively:

$$sigma_pair = max_i(sigma_i)$$
$$delta_pair = max_i(delta_i)$$

**Rationale**: Path risk dominated by noisiest hop.

---

## Catmull-Rom Spline (Liquidity Profiling)

Per-asset liquidity profile using **Monotone Cubic Hermite Spline** for smooth, monotonic price-depth curves.

### Spline Structure

```solidity
struct Point {
    uint256 x;  // Cumulative depth (0 to 10000)
    int256 y;   // Price offset from TWAP (in bps)
}
```

### Profile Construction

1. **Weights**: Define segment depths (must sum to 200)
2. **Knots**: Define price offsets at segment boundaries (0-100% of dispersion)
3. **Scaling**: `x = (cumulativeWeight * 10000) / WEIGHT_SUM`
4. **Y-value**: `offset = knot * dispersion / 100`

### Spline Evaluation

Hermite cubic interpolation between control points:

$$H(t) = h_0(t)y_0 + h_1(t)y_1 + H_0(t)m_0 + H_1(t)m_1$$

Where tangents $m$ computed from neighboring secants (Fritsch-Butland monotonicity).

### Volume Traversal

For trade execution, integrate area under curve:

$$avgOffset = area(startDepth, endDepth) / (endDepth - startDepth)$$

Returns VWAP execution price over traded volume.

---

## Bi-Factor Fee Model

Fees determined by **volatility** (vega) and **deviation** (lambda) sensitivities with asymmetric spread.

### Volatility Band (Symmetric)

$$S_vol = 100 + sigma_pair * vega_spread / 100$$

Always applied, symmetric for both directions.

### Deviation Surcharge (Asymmetric)

$$U = delta_pair * lambda_spread / 100$$

Only applied if trade **worsens** coverage (toxic flow penalty).

### Net Coverage Impact Calculation

Determines if trade improves or worsens portfolio balance:

$$imbalance = sum(price_j * |reserves_j - liabilities_j|)$$

$$netImpact = imbalance_after - imbalance_before$$

- **Negative**: Improves coverage → volatility band only (arb-friendly)
- **Positive**: Worsens coverage → volatility + deviation (toxic penalty)

### Final Spread

$$spreadBps = improvesCoverage ? S_vol : S_vol + U$$

Clamped to `[minFee, maxFee]` per asset.

### Fee Split

$$totalFee = spreadBps * amount / 1_000_000$$
$$protoFee = totalFee * protoShare / 100$$
$$lpFee = totalFee - protoFee$$

---

## Mid-Price Calculation

Mid-price derived from spline based on inventory skew:

1. Map skew (-100 to +100) to depth position: $depth = 5000 + skew * 50$
2. Interpolate offset via spline: $offset = eval(depth, points)$
3. Convert to absolute price: $price = TWAP * (1e6 + offset) / 1e6$

If no profile configured, fallback to linear:
$$price = TWAP * (1e6 + skew * dispersion / 100) / 1e6$$

---

## Cooperative Arbitrage

Whitelisted arbitrage program aligning CEX-DEX stat arb with LP protection.

### Mechanism

**Reputation-based rebate system**:
- Arbitrageurs apply to DAO for Cooperator status
- Donate arbitrage proceeds to pool → earn reputation
- Higher reputation → larger rebates on future trades

**Reputation formula**:
$$reputation = donations / rebates$$

**Profit comparison**:
- Standard arb: $profit = CEX_price - pool_price - fees$
- Cooperative: $profit = CEX_price - pool_price - fees + rebate$

### Parameters (Pool-Level)

| Parameter | Default | Range | Governance |
|-----------|---------|-------|------------|
| Max cooperators | 50 | 10-100 | Yes |
| Rebate rate | 50% | 10-90% | Yes |
| Min reputation | 0.9 | 0.5-0.99 | Yes |

### Economic Effect

Rebates lower cooperators' profit threshold → faster arbitrage → smaller LVR window.

If DAO operates bot donating 100% of proceeds: effectively front-runs adversarial arbitrageurs, returning all LVR to LPs.

### Key Insight

Targets **cross-exchange (CEX-DEX) statistical arbitrage**, not MEV (block ordering manipulation).

---

## Tokenomics

### BTR Token Supply

| Category | Amount | Percentage |
|----------|--------|------------|
| Emissions | 65M | 65% |
| Treasury | 20M | 20% |
| Team/Vest | 10M | 10% |
| Advisors | 5M | 5% |
| **Total** | **100M** | **100%** |

### Emission Distribution (of 65M)

| Destination | Amount | Percentage |
|-------------|--------|------------|
| sLP stakers | 58.5M | 90% |
| sBTR stakers | 3.25M | 5% |
| Emissions treasury | 3.25M | 5% |

### Emission Schedule

**Geometric halving progression**:
$$E(t) = E_0 * h^(floor(t / T))$$

- $E_0$: Initial emission rate
- $h$: Halving factor (0.5)
- $T$: Halving interval
- Duration: ~10 years to emit 65M

### Staking Mechanics

**BTR Staking (sBTR)**:
- 1:1 exchange rate
- 5% of emissions to stakers
- Voting power from sBTR balance
- No unstake cooldown

**LP Staking (sLP)**:
- Receipt token for staked LP
- 90% of emissions to LP stakers
- 14-day unstake cooldown
- sLP + sBTR = maximum reward boost

### Governance

- **Snapshot-based voting** (off-chain, on-chain verification)
- **Quorum**: ≥10% participation
- **Voting power**: $sBTR + min(sLP, sBTR) * multiplier$
- **Timelocks**: 7 days for most actions

---

## Key Constants

| Constant | Value | Description |
|----------|-------|-------------|
| WAD | 1e18 | Price/coverage precision |
| PBPS | 1_000_000 | Fee/spread precision (0.0001%) |
| WEIGHT_SUM | 200 | Liquidity profile weight sum |
| INIT_LIQUIDITY_INDEX | 1e12 | Starting liquidity index |

---

## Oracle System

**Internal Oracle** (InternalOracleV1):
- TWAP accumulator with fast/slow snapshots
- Fast offset: short-term price deviation
- Slow offset: long-term trend
- Volatility EMAs for fee calculation

**External Oracle** (IOracleV1):
- Supports Chainlink, Pyth via adapter
- Fallback to internal on stale data

---

## Risk Management

### Liability Decay

Linear % per year when coverage < threshold:
$$decay = liabilities * decaySlope * dt / 1e18$$

Capped at $liabilities - reserves$ (never below 100% coverage).

### Flow Guard (JIT Protection)

Cooldown between deposit→withdraw and stake→unstake:
- Default: 15 seconds
- Prevents same-block arbitrage attacks

### Reservation Price

Swaps revert if oracle price drops below floor:
$$if (price < reservationPrice) revert$$
