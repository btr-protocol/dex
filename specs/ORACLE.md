# Oracle System

## Overview

The BAMM protocol uses a **hybrid oracle architecture** that combines:
- **Price TWAPs:** Uniswap V3-style accumulators for time-weighted price averaging
- **Volatility:** Exponential Moving Averages (EMA/EWMA) for variance smoothing

This design ensures **true time-weighting for prices** (resistant to bursty updates) while using **exponential decay for volatility** (appropriate for variance clustering and mean reversion).

Each asset can operate in one of three oracle modes, and all prices use the custom **b64 float format** (56-bit mantissa, 8-bit signed exponent) for efficient storage and precision.

### Why Accumulator for Price, EMA for Volatility?

**Price TWAPs (Accumulator):**
- Each second gets equal weight (time-weighted by design)
- Resistant to manipulation via burst updates
- Mathematically exact, no approximation errors
- Battle-tested in Uniswap V3 ($1.7T+ volume)

**Volatility (EMA/EWMA):**
- Variance exhibits clustering and mean-reversion
- Exponential decay matches market behavior
- Standard in risk management (RiskMetrics uses λ=0.94)
- Guardian calculates from time-windows off-chain, submits periodically

**Rationale:** Accumulator-based TWAPs provide true time-weighting (each second gets equal weight), making them resistant to manipulation via burst updates. This is mathematically exact with no approximation errors, unlike update-weighted EMAs which would give disproportionate influence to periods with frequent updates.

---

## Oracle ID System

### Critical Design: Base/Quote Pair Identification

The oracle system uses **oracle IDs** to uniquely identify price pairs, preventing dangerous quote currency mismatches:

```solidity
oracleId = keccak256(abi.encodePacked(baseAsset, quoteAsset))
```

Where:
- **baseAsset** = Token being priced (e.g., WETH, USDC, WBTC)
- **quoteAsset** = Pricing currency (pool's accounting base, e.g., USDC)

### Why Oracle IDs?

**Problem:** Using only the asset address as a lookup key is dangerous during accounting base changes. An oracle might return a price in the wrong quote currency (e.g., WETH/USDC when you need WETH/DAI).

**Solution:** Oracle IDs track **both** the base and quote assets, ensuring:
- Correct base/quote pairing
- Automatic invalidation when accounting base changes
- Explicit reinitialization required for new base
- No silent quote currency mismatches

### Automatic Oracle ID Management

**Asset Addition:**
```solidity
// Oracle ID computed automatically during asset registration
bytes32 oracleId = LibStorage.computeOracleId(token, pool.baseToken);
asset.oracleId = oracleId;  // Stored in asset config
```

**Base Asset Migration:**
When the pool owner changes the accounting base currency:

1. **Step 1: Start Migration**
   ```solidity
   // Provide oracle reinitialization data for internal oracles
   bytes memory oracleReinitData = abi.encode(
       [token1, token2, ...],           // Assets to reinitialize
       [newPrice1, newPrice2, ...],     // New prices in new base
       [fastVol1, fastVol2, ...],       // Fast volatilities
       [slowVol1, slowVol2, ...]        // Slow volatilities
   );
   pool.startBaseAssetUpdate(newBaseToken, oracleReinitData);
   ```

2. **Step 2: Batch Migrate (Call Repeatedly)**
   ```solidity
   // For each asset in batch:
   // - Compute new oracle ID = keccak256(token, newBaseToken)
   // - Internal oracles: Reset with new price data (MUST provide data)
   // - External oracles: Migrate accumulator data with price conversion
   // - Update asset.oracleId to new ID
   pool.batchMigrateAssetPrices(50);  // Process 50 assets per batch
   ```

3. **Step 3: Finalize**
   ```solidity
   pool.finishBaseAssetUpdate();  // Updates pool.baseToken
   ```

**Safety:**
- Internal oracles **REVERT** if reinit data is missing during migration
- Pool should be **PAUSED** before starting base asset migration
- Swaps **REVERT** if oracle ID is missing or zero
- All oracle IDs automatically recomputed with new base

### Oracle ID in Operation

**Reading Oracle Data:**
```solidity
// Asset stores its oracle ID
bytes32 oracleId = asset.oracleId;
if (oracleId == bytes32(0)) revert InvalidParameter();

// Use oracle ID for lookups (not asset address)
IOracle.OracleData memory data = IOracle(mainOracle).getOracleData(oracleId);
```

**Updating Internal Oracle:**
```solidity
// Guardian updates using oracle ID
bytes32 oracleId = asset.oracleId;
pool.updateOracle(token, newPrice, newVolatility);
// ^ Internally uses oracleId for storage lookup
```

---

## Three Oracle Modes

Each asset can operate in one of three oracle modes:

### 1. Internal-Only Oracle

```solidity
mainOracle = address(this)
fallbackOracle = address(0) or address(this)
```

**Characteristics:**
- Pool maintains its own price accumulator (Uniswap V3 style)
- Updated by guardian via `updateOracle()`
- TWAPs calculated on-demand from accumulator
- No external dependencies

**Best for:**
- New tokens without reliable external oracles
- Long-tail assets
- Highly liquid pools with accurate internal price discovery

**Initialization:**
```solidity
AddAssetParams memory params = AddAssetParams({
    mainOracle: address(pool),  // Internal oracle
    fallbackOracle: address(0),
    oracleData: abi.encode(
        uint64(currentPrice),  // Initial spot price in b64 format
        uint32(fastVol),       // Initial fast volatility (1e6 base)
        uint32(slowVol)        // Initial slow volatility (1e6 base)
    )
});
```

**Note:** Only `currentPrice` is needed for initialization. TWAPs are built over time from the accumulator.

### 2. External-Only Oracle

```solidity
mainOracle = <external IOracle contract>
fallbackOracle = address(0) or <another external oracle>
```

**Characteristics:**
- Reads from external oracle implementing `IOracle` interface
- Oracle reading MUST succeed at asset addition (reverts if fails)
- Fallback oracle tried if main oracle fails
- Lower gas (no internal EMA updates)

**Best for:**
- Major assets (WETH, WBTC) with established oracles
- CEX-listed tokens with Chainlink feeds
- Correlated assets (wstETH, rETH) with specialized oracles

**Interface:**
```solidity
/// @notice Shared interface for all oracle types (internal and external)
interface IOracle {
    struct OracleData {
        uint64 fastTWAP;          // Fast price (b64 format)
        uint64 slowTWAP;          // Slow price (b64 format)
        uint32 fastVolatility;    // Fast volatility (1e6 base: 1_000_000 = 1%)
        uint32 slowVolatility;    // Slow volatility (1e6 base)
        uint32 lastUpdate;        // Timestamp of last update
    }

    /// @notice Get oracle data for a specific oracle ID (base/quote pair)
    /// @dev Oracle ID = keccak256(abi.encodePacked(baseAsset, quoteAsset))
    function getOracleData(bytes32 oracleId) external view returns (OracleData memory data);

    /// @notice Check if oracle data is fresh
    function isFresh(bytes32 oracleId, uint32 maxAge) external view returns (bool isFresh);

    /// @notice Get just the fast TWAP (most gas efficient)
    function getFastPrice(bytes32 oracleId) external view returns (uint64 fastTWAP);
}
```

**Extended Interfaces:**
```solidity
/// @notice Internal oracle with update/reset capabilities
interface IInternalOracle is IOracle {
    function updateOracle(bytes32 oracleId, uint64 newPrice, uint32 newVolatility) external;
    function resetOracle(bytes32 oracleId, uint64 initialPrice, uint32 initialFastVol, uint32 initialSlowVol) external;
}

/// @notice External multi-asset oracle
interface IExternalOracle is IOracle {
    function addOraclePair(address baseAsset, address quoteAsset, bytes memory initData) external;
    function updateOracle(bytes32 oracleId, bytes memory updateData) external;
    function batchUpdateOracles(bytes32[] calldata oracleIds, bytes[] memory updateData) external;
}
```

**Safety:**
```solidity
// Oracle reading with fallback (in BAMMManagement)
OracleData memory data = _readOracleWithFallback(
    asset.oracleId,  // Uses oracle ID, not asset address
    mainOracle,
    fallbackOracle,
    24 hours  // Max staleness
);
// Reverts if both main and fallback fail
```

### 3. Hybrid (External with Internal Fallback)

```solidity
mainOracle = <external IOracle contract>
fallbackOracle = address(this)
```

**Characteristics:**
- Primary: External oracle when available
- Fallback: Internal oracle when external stale/fails
- Best of both worlds: decentralized reference + internal continuity

**Best for:**
- Critical assets in production
- Risk-averse configurations
- Assets with intermittent oracle updates

---

## Oracle Architecture

### Interface Hierarchy

The oracle system uses a clean interface hierarchy:

```
IOracle (shared base interface)
├── IInternalOracle (adds update/reset methods)
│   └── InternalOracle (accumulator implementation)
└── IExternalOracle (adds multi-asset management)
    └── ExternalOracle (external price feed implementation)
```

**IOracle (Base Interface):**
- Shared by both internal and external oracles
- Provides uniform reading interface using oracle IDs:
  - `getOracleData(bytes32 oracleId)` - Full oracle data
  - `isFresh(bytes32 oracleId, uint32 maxAge)` - Freshness check
  - `getFastPrice(bytes32 oracleId)` - Gas-efficient single value read

**IInternalOracle (Extends IOracle):**
- Adds methods for managing internal accumulator:
  - `updateOracle(bytes32 oracleId, ...)` - Update price and volatility
  - `resetOracle(bytes32 oracleId, ...)` - Reset accumulator (e.g., quote currency change)

**IExternalOracle (Extends IOracle):**
- Adds methods for multi-asset oracle management:
  - `addOraclePair(address base, address quote, ...)` - Register new oracle pair
  - `updateOracle(bytes32 oracleId, ...)` / `batchUpdateOracles(...)` - Update prices
  - `grantOracleRole()` / `revokeOracleRole()` - Access control
  - Oracle pair management views

### Separation of Concerns

**InternalOracle (Abstract Contract):**
- ONLY manages accumulator (Uniswap V3 TWAP pattern)
- NEVER reads from external oracles
- Implements IInternalOracle interface
- Provides `getOracleData()` reading from internal accumulator

**BAMMManagement (Abstract Contract):**
- Handles oracle reading with fallback logic
- Uses IOracle interface to read from ANY oracle type (internal or external)
- Validates and routes `updateOracle()` calls
- Manages oracle configuration changes

**BAMM (Concrete Contract):**
- Extends both InternalOracle and BAMMManagement
- Resolves method collisions with final overrides
- Combines validation (from BAMMManagement) with accumulator updates (from InternalOracle)

**Why This Design?**
- **No circular dependencies:** InternalOracle doesn't know about external oracles
- **Unified reading:** Both oracle types use IOracle interface
- **Clean fallback logic:** BAMMManagement handles main→fallback without InternalOracle involvement
- **Interface-based:** Code works with IOracle, doesn't care about implementation

---

## Hybrid Oracle System: Accumulator + EMA

### Data Structure

```solidity
struct Asset {
    // Price TWAP Accumulator (Uniswap V3 style)
    uint256 priceAccumulator;      // Σ(price × timeElapsed) - cumulative price-seconds
    uint64 currentPrice;            // Latest spot price in b64 format
    uint256 fastAccumSnapshot;      // Accumulator value ~6 hours ago
    uint32 fastSnapshotTime;        // When fast snapshot was taken
    uint256 slowAccumSnapshot;      // Accumulator value ~1 week ago
    uint32 slowSnapshotTime;        // When slow snapshot was taken

    // Volatility EMA (EWMA for variance)
    uint32 fastVolatility;         // Fast volatility EMA (1e6 base, ~6 hour smoothing)
    uint32 slowVolatility;         // Slow volatility EMA (1e6 base, ~1 week smoothing)

    uint32 lastOracleUpdate;        // Timestamp of last update
    address mainOracle;             // Main oracle (address(this)=internal, else=external)
    address fallbackOracle;         // Fallback oracle (address(0)=disabled, address(this)=internal)
    // ... other fields
}
```

### Price TWAP: Accumulator Pattern

**Update formula (Uniswap V3 style):**
```solidity
// On each guardian update
timeElapsed = block.timestamp - asset.lastOracleUpdate
asset.priceAccumulator += asset.currentPrice × timeElapsed
asset.currentPrice = newPrice

// Refresh snapshots periodically
if (block.timestamp - asset.fastSnapshotTime >= 6 hours) {
    asset.fastAccumSnapshot = asset.priceAccumulator
    asset.fastSnapshotTime = uint32(block.timestamp)
}

if (block.timestamp - asset.slowSnapshotTime >= 7 days) {
    asset.slowAccumSnapshot = asset.priceAccumulator
    asset.slowSnapshotTime = uint32(block.timestamp)
}
```

**Reading TWAPs:**
```solidity
function getFastTWAP(Asset storage asset) internal view returns (uint64) {
    // Include current interval
    uint256 timeElapsed = block.timestamp - asset.lastOracleUpdate
    uint256 currentAccum = asset.priceAccumulator + (asset.currentPrice × timeElapsed)

    // Calculate TWAP over window
    uint256 timeDelta = block.timestamp - asset.fastSnapshotTime
    if (timeDelta == 0) return asset.currentPrice

    return uint64((currentAccum - asset.fastAccumSnapshot) / timeDelta)
}
```

**Key properties:**
- **Time-weighted by construction**: Each second gets exactly equal weight
- **Constant gas**: ~615 gas per update regardless of time gap
- **No approximation errors**: Mathematically exact
- **Battle-tested**: Uniswap V3's $1.7T+ volume model

### Volatility: EMA/EWMA Pattern

**Update formula:**
```solidity
// Fast volatility: 90% old, 10% new (~6.6 update half-life)
asset.fastVolatility = (asset.fastVolatility × 90 + newVolatility × 10) / 100

// Slow volatility: 95% old, 5% new (~13.5 update half-life)
asset.slowVolatility = (asset.slowVolatility × 95 + newVolatility × 5) / 100
```

**Implementation:**
```solidity
asset.fastVolatility = updateVolatilityEMA(asset.fastVolatility, newVolatility, $.fastTWAPWeight);
asset.slowVolatility = updateVolatilityEMA(asset.slowVolatility, newVolatility, $.slowTWAPWeight);
```

### Configurable Volatility EMA Weights

**Default values:**
- `fastTWAPWeight = 90` (90% old, 10% new) - Variable name kept for storage compatibility
- `slowTWAPWeight = 95` (95% old, 5% new)

**Note:** These weights **only affect volatility smoothing**. Price TWAPs use the accumulator pattern (no weights needed).

**Owner can update weights:**
```solidity
// Update volatility EMA weights (owner only)
function updateVolatilityWeights(uint8 _fastWeight, uint8 _slowWeight) external onlyOwner;

// Get current weights
function getVolatilityWeights() external view returns (uint8 fastWeight, uint8 slowWeight);
```

**Weight to Half-Life Conversion:**

For volatility EMA, the half-life (h) represents update count to 50% decay:

```
weight = 100 × 0.5^(1/halfLife)
halfLife = log(0.5) / log(weight/100)
```

**Examples:**
```
Half-life 7 updates  → weight ≈ 90
Half-life 10 updates → weight ≈ 93
Half-life 14 updates → weight ≈ 95
Half-life 20 updates → weight ≈ 97
```

**Why EMA for Volatility?**
- Volatility exhibits **clustering and mean-reversion**
- Exponential decay matches market behavior (RiskMetrics uses λ=0.94)
- Guardian submits realized volatility from time-windows off-chain
- Update-weighting is acceptable since guardian pre-calculates from time-periods

### When to Use Each EMA

**Fast EMA (~6 hour window)**:
- **Breadth calculation** - Liquidity distribution width (responsive to recent volatility)
- **Immediate fee adjustments** - Volatility multiplier in fee calculation
- **Short-term momentum** - Quick reaction to market regime changes
- **TVL/accounting** - Current valuation

**Slow EMA (~1 week window)**:
- **Base fee determination** - Long-term volatility defines fee tier
- **Reference price** - Piecewise curve center (stable baseline)
- **Circuit breaker validation** - Avoid false triggers from noise
- **Trend detection** - Macro price direction

**Divergence Detection**:
```solidity
// Price momentum
if (fastTWAP > slowTWAP) {
    // Uptrend - recent prices above long-term average
} else if (fastTWAP < slowTWAP) {
    // Downtrend - recent prices below long-term average
}

// Volatility regime
if (fastVolatility > slowVolatility) {
    // Increasing volatility - market heating up
} else {
    // Calming market - volatility normalizing
}
```

---

## Price and Volatility Precision

### Price (b64 Float Format)

**Type:** `uint64` (b64 custom format)
**Structure:**
- 56-bit mantissa
- 8-bit signed exponent (offset by 128)
- Base-10 floating point

**Encoding:**
```solidity
uint64 = (mantissa << 8) | uint8(exponent + 128)
```

**Range:** ~1e-18 to ~1e+18 with ~16-17 decimal digits of precision

**Examples:**
```
USDC price (1.0):  100000000 mantissa, exp=-8  → 0x00000000_05F5E100_80
WETH ($2000):      200000000000 mantissa, exp=-8 → 0x002E90ED_D000_80
```

See [B64_FLOAT.md](./B64_FLOAT.md) for complete specification.

### Volatility (1e6 Base)

**Type:** `uint32`
**Base:** 1e6 (6 decimals)
**Range:** 0% to 100% (0 to 100,000,000)

**Examples:**
```
1% volatility (stables):     1_000_000
10% volatility (low):        10_000_000
50% volatility (moderate):   50_000_000
100% volatility (extreme):   100_000_000
```

---

## Oracle Update Process

### Internal Oracle Update (Owner)

Only for assets with `mainOracle == address(this)`:

```solidity
function updateOracle(
    address token,
    uint64 newPrice,     // b64 format
    uint32 newVolatility // 1e6 base
) external onlyOwner {
    Asset storage asset = assets[token];

    // Validation
    require(asset.mainOracle == address(this), "Not internal oracle");
    require(newPrice > 0, "Zero price");
    require(newVolatility <= 100_000_000, "Invalid volatility");

    // Price change validation (max 10% per update)
    uint256 oldPrice1e18 = LibMaths.decodePriceTo1e18(asset.currentPrice);
    uint256 newPrice1e18 = LibMaths.decodePriceTo1e18(newPrice);
    uint256 priceDelta = newPrice1e18 > oldPrice1e18
        ? newPrice1e18 - oldPrice1e18
        : oldPrice1e18 - newPrice1e18;
    uint256 maxChange = (oldPrice1e18 * asset.maxTWAPChange) / 10000;
    require(priceDelta <= maxChange, "Price change too large");

    // Update accumulator (Uniswap V3 style)
    uint256 timeElapsed = block.timestamp - asset.lastOracleUpdate;
    asset.priceAccumulator += uint256(asset.currentPrice) * timeElapsed;
    asset.currentPrice = newPrice;

    // Update snapshots if windows elapsed
    if (block.timestamp - asset.fastSnapshotTime >= asset.fastWindow) {
        asset.fastAccumSnapshot = asset.priceAccumulator;
        asset.fastSnapshotTime = uint32(block.timestamp);
    }
    if (block.timestamp - asset.slowSnapshotTime >= asset.slowWindow) {
        asset.slowAccumSnapshot = asset.priceAccumulator;
        asset.slowSnapshotTime = uint32(block.timestamp);
    }

    // Update volatility EMAs (NOT prices - prices use accumulator)
    asset.fastVolatility = LibMaths.updateVolatilityEMA(
        asset.fastVolatility, newVolatility, $.fastTWAPWeight
    );
    asset.slowVolatility = LibMaths.updateVolatilityEMA(
        asset.slowVolatility, newVolatility, $.slowTWAPWeight
    );

    asset.lastOracleUpdate = uint32(block.timestamp);

    // Compute TWAPs for event emission
    uint64 fastTWAP = _calculateTWAPFromAccumulator(asset, asset.fastSnapshotTime, asset.fastAccumSnapshot);
    uint64 slowTWAP = _calculateTWAPFromAccumulator(asset, asset.slowSnapshotTime, asset.slowAccumSnapshot);

    emit OracleUpdate(token, fastTWAP, slowTWAP,
                      asset.fastVolatility, asset.slowVolatility, msg.sender);
}
```

**Key difference from EMA:** Prices use **Uniswap V3 accumulator pattern** (true time-weighting), while volatility uses **EMA** (exponential decay).

### Price Change Validation

**Max change per update:** 10% (configurable via `maxTWAPChange`)

This prevents single-update manipulation and requires gradual adjustment:

**Example:**
```
Real price moves: $100 → $150 (+50%)

Update 1: $100.00 → $110.00 (+10.0% max)
Update 2: $110.00 → $121.00 (+10.0% max)
Update 3: $121.00 → $133.10 (+10.0% max)
Update 4: $133.10 → $146.41 (+10.0% max)
Update 5: $146.41 → $150.00 (+2.45%)

Total: 5 updates needed to reach target
```

### External Oracle Reading

External oracles are read via `IOracle.getOracleData(bytes32 oracleId)`:

```solidity
function _readOracleWithFallback(
    bytes32 oracleId,
    address mainOracle,
    address fallbackOracle,
    uint32 maxAge
) internal view returns (IOracle.OracleData memory data) {
    // Try main oracle
    try IOracle(mainOracle).getOracleData(oracleId) returns (IOracle.OracleData memory mainData) {
        // Check freshness
        if (block.timestamp - mainData.lastUpdate <= maxAge) {
            return mainData;
        }
    } catch {}

    // Main oracle failed or stale - try fallback
    if (fallbackOracle != address(0)) {
        try IOracle(fallbackOracle).getOracleData(oracleId) returns (IOracle.OracleData memory fallbackData) {
            // Check freshness
            if (block.timestamp - fallbackData.lastUpdate <= maxAge) {
                return fallbackData;
            }
        } catch {}
    }

    // Both oracles failed - REVERT (no dangerous defaults!)
    revert OracleStale();
}
```

**Architecture Note:** Oracle reading with fallback logic is handled by **BAMMManagement**, NOT by InternalOracle. This separation of concerns ensures:
- **InternalOracle:** Only manages accumulator (no external dependencies)
- **BAMMManagement:** Handles oracle reading and fallback (uses shared IOracle interface)
- **Unified reading:** Both internal and external oracles use the same IOracle interface for reads

**Key Safety Feature:** If both main and fallback oracles fail, the function REVERTS. There are NO fallback to dangerous default values.

---

## Volatility Calculation

Volatility should be calculated off-chain by the guardian using realized volatility:

```python
# Calculate realized volatility from recent price changes
def calculate_volatility(asset, window_hours=6):
    # Get recent prices
    prices = get_recent_prices(asset, window=f"{window_hours}h")

    # Calculate log returns
    log_returns = [math.log(prices[i] / prices[i-1])
                   for i in range(1, len(prices))]

    # Calculate variance and standard deviation
    variance = sum(r**2 for r in log_returns) / len(log_returns)
    volatility_decimal = math.sqrt(variance * 365 * 24 / window_hours)  # Annualized

    # Convert to 1e6 base
    volatility_uint32 = int(volatility_decimal * 100 * 1_000_000)  # Percentage * 1e6

    return min(volatility_uint32, 100_000_000)  # Cap at 100%

# Example usage
fast_vol = calculate_volatility(WETH, window_hours=6)   # Fast volatility
slow_vol = calculate_volatility(WETH, window_hours=168)  # Slow volatility (1 week)
```

---

## Guardian Role & Responsibilities

### Permissions

**Guardian CAN:**
- Trigger circuit breakers (`checkCircuitBreaker()`)

**Guardian CANNOT:**
- Update oracle prices (moved to external guardian bots)
- Add/remove assets
- Pause pool
- Modify parameters
- Change liquidity profiles

**Note:** In the current implementation, guardians only trigger circuit breakers. Oracle updates for internal oracles are handled by dedicated guardian bots calling `updateOracle()`.

### Recommended Update Frequency

For internal oracles:

- **Stablecoins (USDC, DAI):** Every 1-2 hours
- **Major assets (WETH, WBTC):** Every 15-30 minutes
- **Volatile assets:** Every 5-15 minutes
- **During high volatility:** More frequent (respecting 10% limit)

### Multiple Guardians

Guardians can be granted instantly (no timelock):

```solidity
grantRole(GUARDIAN_ROLE, guardian1);  // Instant grant
grantRole(GUARDIAN_ROLE, guardian2);  // Instant grant
grantRole(GUARDIAN_ROLE, guardian3);  // Instant grant
```

**Best practice:** Run redundant guardian instances for reliability.

---

## Usage in BAMM

### Piecewise Curve Centering

The piecewise liquidity curve is centered around the slow TWAP (stable reference):

```solidity
uint256 centerPrice = asset.slowTWAP;  // Long-term stable center
uint256 breadth = calculateBreadth(asset.fastVolatility);  // Width responds to recent volatility
```

### Fee Calculation

```solidity
// Base fee from SLOW volatility (long-term regime)
uint256 avgSlowVol = (assetIn.slowVolatility + assetOut.slowVolatility) / 2;
uint256 baseFee = calculateBaseFee(avgSlowVol);

// Volatility multiplier from FAST volatility (recent spikes)
uint256 avgFastVol = (assetIn.fastVolatility + assetOut.fastVolatility) / 2;
uint256 volMultiplier = calculateVolatilityMultiplier(avgFastVol);

// Apply multipliers
uint256 totalFee = baseFee * volMultiplier * inventoryMult * divergenceMult;
```

### Circuit Breakers

Use slow TWAP for stable reference (avoid false triggers):

```solidity
function checkCircuitBreaker(address token) external onlyGuardian {
    CircuitBreaker storage breaker = circuitBreakers[token];
    if (breaker.referenceAsset == address(0)) return;

    Asset storage asset = assets[token];
    Asset storage refAsset = assets[breaker.referenceAsset];

    // Compare slow TWAPs (stable baseline)
    int256 deviationBps = ((int256(uint256(asset.slowTWAP)) -
                           int256(uint256(refAsset.slowTWAP))) * 10000) /
                          int256(uint256(refAsset.slowTWAP));

    if (abs(deviationBps) > breaker.maxDeviation) {
        asset.isFrozen = true;
        if (token == baseToken) {
            isPoolPaused = true;  // Freeze entire pool if base asset fails
        }
        emit CircuitBreakerTriggered(token, deviationBps, block.timestamp);
    }
}
```

---

## Oracle Security

### Manipulation Resistance

1. **Price change cap:** Maximum 10% change per update (configurable)
2. **EMA smoothing:** Gradual adjustment prevents sudden manipulation
3. **Guardian validation:** Off-chain validation before pushing prices
4. **Dual tracking:** Fast and slow EMAs provide cross-validation
5. **No dangerous defaults:** External oracle failures cause revert (no fallback values)

### Freshness Checks

```solidity
function isOracleFresh(address token, uint256 maxAge) public view returns (bool) {
    Asset storage asset = assets[token];
    if (asset.lastOracleUpdate == 0) return false;
    return (block.timestamp - asset.lastOracleUpdate) <= maxAge;
}
```

**Recommended staleness thresholds:**
- **Volatile assets (WETH, WBTC):** 15 minutes
- **Stablecoins (USDC, DAI):** 1 hour
- **Long-tail assets:** 30 minutes

### Circuit Breaker Configuration

Configure per-asset deviation limits:

```solidity
// Example: wstETH should track WETH closely
updateCircuitBreaker(
    address(wstETH),
    address(WETH),    // Reference asset
    300               // 3% max deviation (basis points)
);

// Example: Stablecoins should track each other
updateCircuitBreaker(
    address(USDC),
    address(DAI),
    100               // 1% max deviation
);
```

---

## Design Rationale

### Why Dual EMAs?

**Single EMA Problems:**
- Too fast → Noise sensitivity, false signals, excessive fee volatility
- Too slow → Lag, missed regime changes, delayed response

**Dual EMA Benefits:**
- **Fast EMA:** Responsive to recent action, protects against short-term spikes
- **Slow EMA:** Stable baseline reference, filters noise
- **Divergence:** Momentum/trend indicator
- **Flexibility:** Use appropriate EMA for each purpose

### Why Accumulator for Prices, EMA for Volatility?

**Price TWAP (Accumulator Pattern - Uniswap V3 Style):**
- True time-weighting (each second gets equal weight)
- Manipulation resistant (burst updates don't affect weight)
- Mathematically exact (no approximation errors)
- Battle-tested in Uniswap V3 ($1.7T+ volume)
- Minimal storage: 1 accumulator + 2 snapshots + timestamps
- Constant gas: ~615 gas per update regardless of time gap

**Volatility (EMA Pattern):**
- Variance exhibits clustering and mean-reversion
- Exponential decay matches market behavior
- Standard in risk management (RiskMetrics uses λ=0.94)
- Guardian calculates from time-windows off-chain, submits periodically
- Update-weighting is acceptable since guardian pre-calculates from time-periods

**Architecture Separation:**
- **IOracle:** Shared interface for reading oracle data (both internal and external)
- **IInternalOracle:** Extends IOracle with update/reset methods for accumulator management
- **IExternalOracle:** Extends IOracle with multi-asset management methods
- **InternalOracle:** ONLY manages accumulator (no external oracle reading)
- **BAMMManagement:** Handles oracle reading with fallback logic using IOracle interface
- **Unified reading:** Both oracle types implement IOracle for consistent reading

### Why Two Volatility Metrics?

**Fast volatility** (~6 hours):
- Protects against recent volatility spikes
- Immediate fee adjustments via volatility multiplier
- Responsive breadth calculation
- Captures intraday regime changes

**Slow volatility** (~1 week):
- Baseline for "normal" volatility
- Determines base fee tier
- Circuit breaker calibration
- Filters out short-term noise and anomalies

### Why b64 Float Format?

**Standard uint256 Problems:**
- Wastes storage for prices (only need ~16 digits)
- Poor packing with other struct members
- Complex decimal handling per asset

**b64 Float Benefits:**
- Compact: 8 bytes vs 32 bytes
- Efficient packing: Multiple prices in one slot
- Universal precision: Same format for all assets
- Wide range: 1e-18 to 1e+18

See [B64_FLOAT.md](./B64_FLOAT.md) for complete specification.

---

## Edge Cases

### Zero Price Protection

```solidity
if (asset.slowTWAP == 0) return PRICE_PRECISION;  // Return 1.0 in b64
```

### Oracle Not Initialized

Swaps require initialized oracles:

```solidity
function swap(...) {
    require(assetIn.fastTWAP > 0, "Oracle not initialized");
    require(assetOut.fastTWAP > 0, "Oracle not initialized");
    ...
}
```

### Switching Oracle Modes

When updating oracle config:

```solidity
// Switching TO internal oracle: Keep existing TWAPs/volatility
if (newMainOracle == address(this)) {
    // Preserve current state, update via updateOracle() later
}

// Switching TO external oracle: MUST successfully read
else {
    (fastTWAP, slowTWAP, fastVol, slowVol) = _readOracleOrRevert(newMainOracle, newFallbackOracle);
    // Reverts if external oracle fails
}
```

---

## Constants

```solidity
MAX_PRICE_CHANGE_BPS  = 1000      // 10% per update (configurable)
MAX_VOLATILITY        = 100_000_000  // 100%
MAX_INITIAL_PRICE     = 1e18      // Max price on initialization
PRICE_PRECISION       = 1e18      // For calculations (high precision for extreme price ratios)
```

---

## Future Enhancements

Potential improvements for future versions:

1. **Multi-timeframe EMAs:** Add very slow EMA (1 month) for macro trends
2. **Cross-asset correlation:** Detect when assets move together, adjust fees
3. **Implied volatility:** Derive from trade size distributions
4. **Oracle aggregation:** Combine multiple external sources with weights
5. **Automated staleness handling:** Auto-widen fees or freeze if oracle stale
6. **On-chain TWAP fallback:** Use DEX pools as emergency price source
7. **Automated weight adjustment:** Adjust EMA weights based on market regime (bull/bear/sideways)

---

## References

- Dual EMA system inspired by traditional finance technical analysis
- Curve v2 CryptoSwap re-pegging mechanism
- Realized volatility calculation from VIX methodology
- Manipulation resistance lessons from Uniswap v3 TWAP security incidents
- b64 float format design for optimal storage and precision

---

## Related Documentation

- [B64_FLOAT.md](./B64_FLOAT.md) - Complete b64 float format specification
- [PIECEWISE_BONDING_CURVE.md](./PIECEWISE_BONDING_CURVE.md) - How oracle prices drive liquidity distribution
- [FEES.md](./FEES.md) - How volatility metrics determine dynamic fees
- [ACCESS_CONTROL.md](./ACCESS_CONTROL.md) - Guardian role permissions and security
