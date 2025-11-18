# Oracle Architecture

## Overview

The BAMM protocol uses a **three-struct oracle system** designed for minimal gas cost and maximum flexibility. Each struct serves a distinct purpose in the oracle data flow.

---

## Three Oracle Structs (Purpose-Driven Design)

### **1. `IOracle.OracleData` - External Interface**

**Purpose:** Standardized interface for reading oracle data (internal or external oracles)

**Location:** `contracts/src/interfaces/IOracle.sol`

**Structure:**
```solidity
struct OracleData {
    uint64 fastTWAP;          // Fast price (e.g., 6h window) in B64 format
    uint64 slowTWAP;          // Slow price (e.g., 7d window) in B64 format
    uint32 fastVolatility;    // Fast vol (1e6 base: 1M = 1%)
    uint32 slowVolatility;    // Slow vol (1e6 base)
    uint32 lastUpdate;        // Timestamp of last update
}
```

**Use Cases:**
- ✅ Return value from `IOracle.getOracleData()`
- ✅ Read from external oracles (Chainlink, Uniswap V3, etc.)
- ✅ Fallback oracle validation

**Design:**
- **Compact:** 5 fields, 28 bytes (fits in calldata efficiently)
- **No decoded prices:** Keeps interface minimal (caller decodes when needed)
- **Timestamp included:** Enables staleness checks

---

### **2. `LibStorage.OracleEntry` - Storage Layout**

**Purpose:** Optimized on-chain storage for internal oracle state

**Location:** `contracts/src/libraries/LibStorage.sol`

**Structure:**
```solidity
struct OracleEntry {
    // SLOT 0: uint256 = 32 bytes
    uint256 priceAccumulator;      // Σ(price × timeElapsed) - cumulative price-seconds

    // SLOT 1: uint256 = 32 bytes
    uint256 fastAccumSnapshot;      // Accumulator value at last fast snapshot

    // SLOT 2: uint256 = 32 bytes
    uint256 slowAccumSnapshot;      // Accumulator value at last slow snapshot

    // SLOT 3: all small scalars packed = 32 bytes
    uint64 currentPrice;            // Current spot price in B64 format (8 bytes)
    uint32 fastSnapshotTime;        // When fast snapshot was taken (4 bytes)
    uint32 slowSnapshotTime;        // When slow snapshot was taken (4 bytes)
    uint32 lastOracleUpdate;        // Timestamp of last update (4 bytes)
    uint32 fastWindow;              // Fast TWAP window in seconds (4 bytes)
    uint32 slowWindow;              // Slow TWAP window in seconds (4 bytes)
    uint32 fastVolatility;          // Fast vol EMA (1e6 base) (4 bytes)
    uint32 slowVolatility;          // Slow vol EMA (1e6 base) (4 bytes)
    uint16 maxTWAPChange;           // Max price change per update in bps (2 bytes)
    uint8 flags;                    // bit0=exists, bit1=external (1 byte)
    uint8 _pad;                     // Padding (1 byte)
}
```

**Use Cases:**
- ✅ Storage for internal oracle state (Uniswap V3-style accumulator)
- ✅ TWAP calculation (fast and slow windows)
- ✅ Volatility tracking (EMA-based)

**Design:**
- **Storage-optimized:** 4 slots (128 bytes), tightly packed
- **Accumulator-based:** Enables constant-cost TWAP updates
- **Inline TWAPs:** TWAPs computed on-the-fly from accumulators (no storage of TWAPs)

**Why accumulators instead of storing TWAPs?**
- TWAPs are **always fresh** (computed on-demand from accumulator + current price)
- **No stale data:** TWAPs update automatically with every read
- **Gas efficient:** Single SSTORE on price update (accumulator += price × elapsed)

---

### **3. `LibPricing.OracleData` - Memory Helper**

**Purpose:** Stack depth workaround for complex fee calculations

**Location:** `contracts/src/libraries/LibPricing.sol`

**Structure:**
```solidity
struct OracleData {
    uint64 fastTWAP;         // Fast TWAP in B64 format
    uint64 slowTWAP;         // Slow TWAP in B64 format
    uint256 priceFast1e18;   // Fast TWAP decoded to 1e18 (avoids repeated decode)
    uint256 priceSlow1e18;   // Slow TWAP decoded to 1e18 (avoids repeated decode)
    uint32 fastVol;          // Fast vol
    uint32 slowVol;          // Slow vol
}
```

**Use Cases:**
- ✅ **Only used in `calculateSwapFee()`** to avoid "stack too deep" errors
- ✅ Pre-decodes B64 prices to 1e18 (avoids redundant `b64ToPrice()` calls)
- ✅ Aggregates oracle data for tri-factor fee model

**Design:**
- **Memory-only:** Never stored, exists only during function execution
- **Pre-decoded:** Includes both B64 and 1e18 formats (optimization)
- **Temporary:** Created by `_decodeOracleData()`, used in one function, discarded

**Why not reuse `IOracle.OracleData`?**
- Needs **decoded prices** (`priceFast1e18`, `priceSlow1e18`) for fee calculations
- Fee model calls `b64ToPrice()` multiple times → pre-decode saves gas
- Stack depth: Having all data in one struct reduces local variables

---

## Data Flow

```
┌─────────────────────┐
│   External Oracle   │  (Chainlink, Uniswap V3, etc.)
│  IOracle.OracleData │
└─────────┬───────────┘
          │
          │ getOracleData()
          ▼
┌─────────────────────┐
│   BAMMManagement    │  (reads external, updates internal)
│        ↓            │
│  LibStorage.        │  (internal oracle state)
│  OracleEntry        │  - Accumulator: Σ(price × time)
│  (4 slots)          │  - Snapshots: fast/slow
│                     │  - Volatility: EMA tracking
└─────────┬───────────┘
          │
          │ _decodeOracleData()
          ▼
┌─────────────────────┐
│  LibPricing.        │  (memory struct for fee calc)
│  OracleData         │  - TWAPs: computed from accumulator
│  (stack workaround) │  - Decoded: B64 → 1e18
│                     │  - Volatility: copied from storage
└─────────┬───────────┘
          │
          │ calculateSwapFee()
          ▼
┌─────────────────────┐
│   Tri-Factor Fee    │
│   Model             │
└─────────────────────┘
```

---

## Why Three Structs?

### **Performance Optimization**

| Struct | Storage | Calldata | Gas Cost | Use Case |
|--------|---------|----------|----------|----------|
| `IOracle.OracleData` | ❌ No | ✅ 28 bytes | Low (interface) | External oracle reads |
| `LibStorage.OracleEntry` | ✅ 4 slots | ❌ N/A | High (SSTORE) | Internal oracle state |
| `LibPricing.OracleData` | ❌ No | ❌ N/A | Low (memory) | Fee calculation helper |

### **Why Not One Universal Struct?**

**Option 1: Use `IOracle.OracleData` everywhere**
- ❌ Missing accumulator fields (can't implement Uniswap V3-style TWAPs)
- ❌ Missing configuration (windows, max change, flags)
- ❌ Includes timestamp (redundant in storage - we track 3 timestamps separately)

**Option 2: Use `LibStorage.OracleEntry` everywhere**
- ❌ Too large for calldata/interface (128 bytes)
- ❌ Exposes internal implementation details
- ❌ Accumulator fields meaningless for external oracles

**Option 3: Use `LibPricing.OracleData` everywhere**
- ❌ Missing accumulator fields (can't track state)
- ❌ Decoded prices waste calldata space
- ❌ No configuration fields

### **Conclusion:**
- **Each struct is purpose-built** for its specific use case
- **No redundancy:** Each adds unique fields for its role
- **Gas-optimal:** Minimizes storage, calldata, and computation costs

---

## Common Confusion: "Why Not Merge?"

### **Q: Can we merge `LibPricing.OracleData` and `IOracle.OracleData`?**

**A:** No, they serve different purposes:

| Feature | `IOracle.OracleData` | `LibPricing.OracleData` |
|---------|---------------------|------------------------|
| Decoded prices (1e18) | ❌ No | ✅ Yes |
| Timestamp | ✅ Yes (staleness check) | ❌ No (not needed in fee calc) |
| Use case | Interface for external oracles | Stack depth workaround |
| Lifetime | Returned from external call | Created & destroyed in one function |

**`IOracle.OracleData`** is the **public API** - any oracle (internal or external) must return this format.

**`LibPricing.OracleData`** is an **internal optimization** - pre-decodes prices to avoid redundant `b64ToPrice()` calls in fee calculations.

### **Q: Why not store TWAPs in `LibStorage.OracleEntry`?**

**A:** TWAPs are **computed on-demand** from the accumulator:
```solidity
uint256 timeElapsed = block.timestamp - lastOracleUpdate;
uint256 currentAccum = priceAccumulator + (currentPrice * timeElapsed);
uint256 timeDelta = block.timestamp - fastSnapshotTime;
uint64 fastTWAP = timeDelta == 0 ? currentPrice : (currentAccum - fastAccumSnapshot) / timeDelta;
```

**Benefits:**
- ✅ **Always fresh:** TWAPs auto-update on every read
- ✅ **Gas efficient:** Only 1 SSTORE on price update (accumulator)
- ✅ **No staleness:** Impossible to have stale TWAP (always computed from latest state)

**Drawback:**
- Slightly more computation per read (~200 gas), but saves SSTORE (~5000 gas) on updates

**Trade-off:** More reads than writes → compute-on-read is better.

---

## Oracle Initialization

### **Internal Oracle Init Data:**

Uses `IOracle.OracleConfig.extension` field:
```solidity
struct OracleConfig {
    address mainOracle;         // address(this) = internal oracle
    address fallbackOracle;     // address(0) = disabled
    uint16 maxTWAPChange;       // Max price change per update (bps)
    uint32 fastWindow;          // Fast TWAP window (seconds)
    uint32 slowWindow;          // Slow TWAP window (seconds)
    bytes extension;            // Internal: abi.encode(currentPrice, fastVol, slowVol)
}
```

**Why `bytes extension`?**
- ✅ **Flexible:** Internal oracles need init prices, external oracles don't
- ✅ **Compact:** Only 1 field in interface (vs 3+ fields for internal-specific data)
- ✅ **Forward-compatible:** Can add more init params without breaking interface

**Decoding:**
```solidity
(uint64 initPrice, uint32 initFastVol, uint32 initSlowVol) =
    abi.decode(oracleConfig.extension, (uint64, uint32, uint32));
```

---

## Summary

| Struct | Purpose | Storage | Fields | Use Case |
|--------|---------|---------|--------|----------|
| **`IOracle.OracleData`** | External API | ❌ No | 5 (compact) | Oracle interface, external reads |
| **`LibStorage.OracleEntry`** | Internal state | ✅ 4 slots | 15 (optimized) | Accumulator-based TWAP tracking |
| **`LibPricing.OracleData`** | Stack workaround | ❌ Memory | 6 (pre-decoded) | Fee calculation helper |

**Key Insight:** This is **not redundancy** - it's **separation of concerns**:
- **Interface** (IOracle): Public API for external oracles
- **Storage** (LibStorage): Internal state for accumulator-based TWAPs
- **Helper** (LibPricing): Temporary struct to avoid stack depth errors

**Gas Savings:**
- Internal oracle: 75% cheaper than Uniswap V3 (1 SSTORE vs 4 SSTOREs)
- External oracle: Minimal calldata (28 bytes)
- Fee calculation: Pre-decoded prices save ~400 gas per swap

**Maintainability:**
- Clear boundaries between oracle types (internal vs external)
- Each struct optimized for its specific use case
- No forced compromises (e.g., exposing accumulators in public API)

---

## Future Enhancements

### **Potential Consolidation:**
If we decide stack depth is no longer an issue (e.g., after EIP-3074 or Solidity improvements), we could:
1. Remove `LibPricing.OracleData`
2. Decode prices inline in `calculateSwapFee()`
3. Accept minor gas increase (~400 gas/swap) for cleaner code

**Current decision:** Keep all three structs for **maximum performance**.
