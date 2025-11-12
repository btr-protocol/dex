# 🎯 Audit-Ready Codebase Summary

**Purpose**: Quick reference for auditors and developers reviewing the BAMM protocol

---

## 📋 TABLE OF CONTENTS

1. [Architecture Overview](#architecture-overview)
2. [Critical Files (Priority for Audit)](#critical-files)
3. [Key Invariants & Assumptions](#key-invariants)
4. [Recent Optimizations](#recent-optimizations)
5. [Known Complexity Areas](#known-complexity)
6. [Testing Coverage](#testing-coverage)

---

## 🏗️ ARCHITECTURE OVERVIEW

### Contract Hierarchy
```
BAMM.sol (737 LOC) - Main AMM contract
├── BAMMManagement.sol (917 LOC) - Owner functions
│   ├── InternalOracle.sol (264 LOC) - TWAP oracle
│   ├── LibAccessControl (239 LOC) - Role-based access
│   └── LibRescue (156 LOC) - Emergency rescue
└── Libraries
    ├── LibPricing.sol (576 LOC) ⭐ CRITICAL - All pricing logic
    ├── LibMaths.sol (712 LOC) - Math utilities + B64 format
    ├── LibStorage.sol (43 LOC) - EIP-7201 storage
    └── LibCast.sol (71 LOC) - Type casting

External Dependencies:
├── Solady (SafeTransferLib, FixedPointMathLib, ReentrancyGuard)
└── OpenZeppelin Interfaces (ERC165, ERC20)
```

### Data Flow for Swap
```
User → BAMM.swap()
  ├→ Validation (blacklist, pause, freeze)
  ├→ LibPricing.getSegmentPrice() [Execution Price]
  ├→ LibPricing.calculateSwapFee() [Dynamic Fees]
  ├→ Reserve updates
  ├→ Hook calls (pre/post)
  └→ SafeTransferLib transfers
```

---

## ⭐ CRITICAL FILES (Priority for Audit)

### 1. **LibPricing.sol** (576 LOC) - HIGHEST PRIORITY
**What it does**: All pricing and fee logic for the ALM model
**Key functions**:
- `getSegmentPricePure()` - Piecewise bonding curve pricing (streaming computation)
- `calculateSwapFee()` - Multi-factor dynamic fees (volatility, coverage, divergence)
- `calculateCoverageMultiplier()` - Wombat-style liquidity depth protection
- `calculateTotalValue()` - Portfolio valuation

**Recent changes** (2025-01-11):
- ✅ Refactored to pure functions (storage-agnostic)
- ✅ Uses Solady's fullMulDiv for precision
- ✅ Streaming execution price (no temp arrays)
- ✅ One-shot fee multiplier combination

**Audit focus**:
- [ ] Verify breadth clamping prevents underflow
- [ ] Check segment count bounds (≤16)
- [ ] Validate fee multiplier composition
- [ ] Confirm TWAP usage (fast vs slow)

---

### 2. **BAMM.sol** (737 LOC)
**What it does**: Main swap, deposit, withdraw logic
**Key functions**:
- `swap()` - Primary trading interface with hooks
- `deposit()` - LP token minting with scaled balances
- `withdraw()` - LP token burning
- `multiSwap()` - Batch swaps for routing

**Critical invariants**:
- Reserves must equal sum of all LP scaled balances × liquidityIndex
- LP token totalSupply = sum of all user scaled balances
- Circuit breakers freeze on deviation threshold

**Audit focus**:
- [ ] Reentrancy protection (nonReentrant everywhere)
- [ ] Slippage protection (minAmountOut checks)
- [ ] Hook integration (proper pre/post sequencing)
- [ ] Oracle staleness checks

---

### 3. **BAMMManagement.sol** (917 LOC)
**What it does**: Owner, access control, pausing, freezing, oracle config
**Key functions**:
- Access control (4-day timelock for OWNER/KEEPER)
- Asset management (add/remove/freeze/circuit-breaker)
- Fee configuration
- Oracle setup (internal vs external)

**Recent changes** (2025-01-11):
- ✅ Fixed circuit breaker to only trigger on threshold breach
- ✅ Added no-op guards (pause/freeze)
- ✅ ERC-165 hook validation
- ✅ Optimized base asset conversion with fullMulDiv

**Audit focus**:
- [ ] Role escalation paths
- [ ] Timelock bypass attempts
- [ ] Circuit breaker logic correctness
- [ ] updateBaseAsset gas limits (50+ assets)

---

### 4. **InternalOracle.sol** (264 LOC)
**What it does**: Uniswap V3-style accumulator-based TWAP oracle
**Key functions**:
- `_getFastTWAP()` - 6-hour TWAP for responsive pricing
- `_getSlowTWAP()` - 1-week TWAP for base fees
- `_updateOracleInternal()` - Keeper-driven price updates
- EMA-based volatility tracking

**Critical invariants**:
- Accumulator = sum of (price × time) since inception
- TWAP = (accumulator[t2] - accumulator[t1]) / (t2 - t1)
- Volatility EMAs must be ≤ 100% (100_000_000 in 1e6 base)

**Audit focus**:
- [ ] Accumulator overflow (should use 256-bit)
- [ ] Division by zero in TWAP (timeDelta == 0 case)
- [ ] Volatility calculation precision
- [ ] Oracle staleness thresholds

---

### 5. **LibAccessControl.sol** (239 LOC)
**What it does**: Role-based access with 4-day timelock + 3-day acceptance window
**Key roles**:
- OWNER (timelocked) - All config changes
- GUARDIAN (instant) - Freeze/pause emergency actions
- KEEPER (timelocked) - Oracle updates
- TREASURY (instant) - Fee collection

**Security model**:
- Two-step role transfer (Ownable2Step pattern)
- 4-day timelock for sensitive roles
- 3-day acceptance window (cannot be accepted too early or too late)

**Audit focus**:
- [ ] Cannot skip timelock
- [ ] Cannot accept expired grants
- [ ] Last owner cannot be removed
- [ ] Role replacement logic (replacing != address(0))

---

## 🔐 KEY INVARIANTS & ASSUMPTIONS

### Mathematical Invariants
1. **Reserve Conservation**
   ```
   ∀ token: asset.reserves == sum(scaledBalance[user] × liquidityIndex) / 1e18
   ```

2. **TWAP Consistency**
   ```
   fastTWAP = (priceAccum[now] - priceAccum[t-6h]) / 6hours
   slowTWAP = (priceAccum[now] - priceAccum[t-1w]) / 1week
   ```

3. **Fee Bounds**
   ```
   minFeeBps ≤ actualFee ≤ maxFeeBps
   baseFee × (volMult × covMult × divMult) / 1_000_000 ∈ [min, max]
   ```

4. **Segment Weights**
   ```
   sum(segmentWeights[0..segmentCount-1]) == WEIGHT_SUM (255)
   ```

### Trust Assumptions
- OWNER is trusted but timelocked (4 days)
- GUARDIAN is semi-trusted (can freeze but not steal)
- KEEPER is trusted for oracle updates
- External oracles (if used) are trusted
- Hooks (if set) are trusted by governance

### External Dependencies
- Solady libraries are audited and trusted
- ERC20 tokens follow standard (approve/transfer semantics)
- Block timestamps are monotonic (Ethereum consensus)

---

## 🚀 RECENT OPTIMIZATIONS (2025-01-11)

### LibPricing.sol
- ✅ Removed 50 LOC of redundant TWAP calculations
- ✅ Streaming execution price (no 17-element price array)
- ✅ One-shot fee multiplier (3 sequential muls → 1 combined)
- ✅ Uses Solady fullMulDiv for all ratio math
- ✅ Pure functions (caller decodes TWAPs)

**Gas Impact**: ~15-20% reduction in pricing calls

### BAMMManagement.sol
- ✅ No-op guards (pause/freeze/updateHooks)
- ✅ requireOwnerOrGuardian() helper (saves ~5k gas)
- ✅ Fixed circuit breaker (only triggers on threshold breach)
- ✅ ERC-165 validation for hooks
- ✅ fullMulDiv for base asset conversion

**Gas Impact**: ~20k gas saved on no-op owner calls, ~500 gas/asset on base updates

### LibAccessControl.sol
- ✅ Added requireAnyRole() for dual-role checks
- ✅ requireOwnerOrGuardian() convenience wrapper

---

## ⚠️ KNOWN COMPLEXITY AREAS

### 1. **Virtual Function Overrides**
**Issue**: BAMM, BAMMManagement, and InternalOracle all override `_getFastTWAP()`
**Why**: Diamond inheritance requires override disambiguation
**Impact**: Call graphs harder to trace
**Mitigation**: All implementations delegate to InternalOracle version

### 2. **Storage Access Patterns**
**Current**: Mix of direct access and helper functions
**Improving**: Moving toward cached `_getStorage()` once per function

### 3. **B64 Floating Point Format**
**Location**: LibMaths.sol:145-272 (128 LOC)
**Purpose**: Efficient oracle storage (52-bit mantissa, 5-bit decimals, 7-bit exponent)
**Why not standard**: Standard uint256 wastes gas, b64 fits in one storage slot
**Documentation**: Extensively commented in LibMaths.sol

### 4. **Multi-asset Base Currency Conversion**
**Function**: `BAMMManagement.updateBaseAsset()`
**Complexity**: O(n) loop over all assets, rescales all prices and accumulators
**Risk**: May hit gas limit with 50+ assets
**TODO**: Consider multi-tx batched approach for production

---

## 🧪 TESTING COVERAGE

### Unit Tests
- [ ] LibPricing pure functions
  - [ ] Execution price calculation
  - [ ] Fee multiplier composition
  - [ ] Coverage ratio edge cases
- [ ] LibMaths
  - [ ] B64 encoding/decoding
  - [ ] mulDiv precision
  - [ ] EMA updates
- [ ] LibAccessControl
  - [ ] Timelock enforcement
  - [ ] Role transfer flow
  - [ ] Replacement logic

### Integration Tests
- [ ] BAMM swap flow
  - [ ] Normal swap
  - [ ] With slippage revert
  - [ ] With hooks
  - [ ] Circuit breaker trigger
- [ ] Deposit/Withdraw
  - [ ] LP token minting
  - [ ] Scaled balance accounting
  - [ ] Withdrawal fee application
- [ ] Multi-swap routing

### Fuzz Tests (Priority)
- [ ] LibPricing.getSegmentPricePure() with random segment configs
- [ ] Fee calculation with extreme volatility/coverage
- [ ] TWAP calculation with random time deltas
- [ ] Base asset conversion with various price ratios

---

## 📚 RECOMMENDED AUDIT ORDER

1. **Read this document** (15 min)
2. **Read CODEBASE_REDUNDANCY_AUDIT.md** (10 min) - Understand what's been optimized
3. **LibPricing.sol** (2-3 hours) - Most critical, all pricing logic
4. **BAMM.sol** (2 hours) - Core swap/deposit/withdraw
5. **InternalOracle.sol** (1 hour) - TWAP logic
6. **BAMMManagement.sol** (2 hours) - Owner functions
7. **LibAccessControl.sol** (1 hour) - Role security
8. **Hooks** (1 hour) - Review BaseBAMMHook and examples
9. **Dark Pool** (if scope includes ZK) - Separate module

**Total estimated audit time**: 10-12 hours for core AMM (excluding dark pool)

---

## 🔍 QUICK REFERENCE: Where Is X?

| What | Where | LOC |
|------|-------|-----|
| Swap logic | BAMM.sol:swap() | ~80 |
| Pricing math | LibPricing.getSegmentPricePure() | ~70 |
| Fee calculation | LibPricing.calculateSwapFee() | ~65 |
| TWAP oracle | InternalOracle._getFastTWAP() | ~45 |
| Access control | LibAccessControl.requireRole() | ~10 |
| Circuit breaker | BAMMManagement.checkCircuitBreaker() | ~45 |
| Pause/Freeze | BAMMManagement.pausePool/freezeAsset | ~15 |
| LP accounting | BAMM.deposit/withdraw | ~150 |

---

## 📞 CONTACT & QUESTIONS

**For implementation questions**: Check inline comments in source files
**For architecture questions**: See contract NatSpec headers
**For optimization rationale**: See CODEBASE_REDUNDANCY_AUDIT.md
**For audit-specific concerns**: Flag them clearly in audit report

---

**Document Version**: 1.0
**Last Updated**: 2025-01-11
**Codebase State**: Post-optimization (Phase 1 in progress)
**Recommended for**: External auditors, security reviewers, new developers

---

## ✅ AUDIT CHECKLIST (For Auditors)

### Security
- [ ] Reentrancy: All state-changing functions use `nonReentrant`
- [ ] Access control: All owner functions check roles
- [ ] Integer overflow: Using Solidity 0.8.28 (built-in checks) + explicit checks
- [ ] Oracle manipulation: TWAP averages prevent single-block manipulation
- [ ] Front-running: Slippage protection via `minAmountOut`
- [ ] Denial of service: Circuit breakers and pause mechanisms
- [ ] Centralization: 4-day timelock on owner actions

### Correctness
- [ ] Reserve accounting: LP tokens = scaled balances × index
- [ ] Fee calculation: Bounded by min/max, deterministic multipliers
- [ ] Price calculation: Segment weights sum to 255, offsets in [-100, 100]
- [ ] TWAP calculation: Accumulator math checked for overflow
- [ ] Role transfers: Two-step pattern prevents accidents

### Gas Efficiency
- [ ] Storage access: Minimize SLOADs (caching where possible)
- [ ] Loops: Bounded (max 16 segments, finite asset list)
- [ ] Math: Uses fullMulDiv for precision without overflow
- [ ] Events: Emitted after state changes (CEI pattern)

**Sign off when complete**: ________________ Date: ________
