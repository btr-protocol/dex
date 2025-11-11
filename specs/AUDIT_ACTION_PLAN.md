# BAMM Audit Action Plan

## Executive Summary

Based on three comprehensive audits, we've identified critical security issues, significant gas optimization opportunities (30-50% savings potential), and auditability improvements. This plan prioritizes fixes by impact and risk.

## Priority 1: CRITICAL - Security & Compatibility Issues

### 1.1 Factory Initialize Signature Mismatch ⚠️ DEPLOYMENT BLOCKER
**Impact:** CRITICAL - Will brick all pool deployments via beacon proxy
**Location:** `BAMMFactory.sol:90-104` vs `BAMMManagement.sol:564-623`

**Problem:**
- Factory encodes: `(address,address,address,uint128,address,address,address,uint16,uint16,uint16,uint16,uint16)`
- BAMM expects: `(LiquidityConfig, OracleConfig, FeeConfig, address, address, address)`

**Solution:** Add compatibility initialize overload that unpacks flat parameters to structs

**Estimated Effort:** 2-3 hours
**Gas Impact:** None
**Risk if not fixed:** Deployment will always revert

---

### 1.2 Fee-on-Transfer Token Support ⚠️ VALUE EXTRACTION VULNERABILITY
**Impact:** HIGH - Accounting desync enables value extraction
**Location:** `BAMM.sol:259,374,662` (transfers), `BAMM.sol:338,593` (reserve updates)

**Problem:**
- Deposit/swap assume `amountIn` received = `amountIn` requested
- Withdraw assumes `amountOut` sent = `amountOut` calculated
- Enables arbitrage on tokens with transfer taxes (USDT, PAXG, etc.)

**Solution:** Measure actual balance deltas via pre/post snapshots:
```solidity
uint256 balanceBefore = token.balanceOf(address(this));
token.safeTransferFrom(msg.sender, address(this), amountIn);
uint256 actualReceived = token.balanceOf(address(this)) - balanceBefore;
```

**Estimated Effort:** 4-6 hours
**Gas Impact:** +3k per operation (2 SLOAD + arithmetic)
**Risk if not fixed:** Value leakage, LP unfairness

---

### 1.3 Blacklist Gaps in Deposit/Withdraw ⚠️ POLICY INCONSISTENCY
**Impact:** MEDIUM - Allows blacklisted users to add/remove liquidity
**Location:** `BAMM.sol:612-666` (deposit), `BAMM.sol:668-728` (withdraw)

**Problem:**
- `swap()` checks blacklist for msg.sender and receiver (L104-105)
- `deposit()` and `withdraw()` omit blacklist checks
- Policy inconsistency: blacklisted can LP but not trade

**Solution:** Add blacklist checks at function entry:
```solidity
function deposit(...) external nonReentrant notPaused notFrozen(token) {
    if ($.blacklisted[msg.sender]) revert E.Blacklisted();
    // ... rest of function
}
```

**Estimated Effort:** 1 hour
**Gas Impact:** +100 gas per call (1 SLOAD)
**Risk if not fixed:** Regulatory/compliance issues

---

## Priority 2: HIGH IMPACT - Gas Optimizations

### 2.1 Storage Packing in Asset Struct
**Impact:** 6-12k gas per swap
**Location:** `IBAMM.sol` (Asset struct definition)

**Problem:** Poor field ordering wastes 2-4 storage slots per asset
- Current: ~12-13 slots
- Optimized: 8-9 slots via grouping uint128s, uint64s, uint32s, uint16s, uint8s

**Solution:** Reorder struct fields to pack smaller types together

**Estimated Effort:** 3-4 hours (+ extensive testing)
**Gas Savings:** 2,000-4,000 gas per SLOAD (multiple reads per swap)

---

### 2.2 Storage Packing in PoolInfo Struct
**Impact:** 1-2k gas per factory query
**Location:** `BAMMFactory.sol:32-39`

**Current Packing:**
```solidity
struct PoolInfo {
    address baseToken;     // 20 bytes
    address poolAdmin;     // 20 bytes
    address keeper;        // 20 bytes
    uint256 deployedAt;    // 32 bytes
    bool exists;          // 1 byte
    bool hasDarkPool;     // 1 byte
} // Total: 6 slots
```

**Optimized Packing:**
```solidity
struct PoolInfo {
    address baseToken;     // 20 bytes
    address poolAdmin;     // 20 bytes (slot 1: 40 bytes)
    address keeper;        // 20 bytes
    bool exists;          // 1 byte
    bool hasDarkPool;     // 1 byte (slot 2: 22 bytes)
    uint256 deployedAt;    // 32 bytes (slot 3)
} // Total: 3 slots (50% reduction)
```

**Estimated Effort:** 30 minutes
**Gas Savings:** 4,000 gas per pool info access

---

### 2.3 Refactor calculateSwapFeeTwoLegPure Parameters
**Impact:** Reduces bytecode, eliminates stack-too-deep risk
**Location:** `LibPricing.sol:278-300` (24+ parameters)

**Problem:**
- 24 individual parameters create massive function signature
- Stack depth pressure forces memory shuffling
- Error-prone call sites (parameter ordering mistakes)

**Solution:** Consolidate into structs:
```solidity
struct LegData {
    uint256 fastTWAP1e8;
    uint256 slowTWAP1e8;
    uint32 fastVol;
    uint32 slowVol;
    uint128 reserves;
    uint16 minFeeBps;
    uint16 maxFeeBps;
}

function calculateSwapFeeTwoLegPure(
    LegData calldata leg1,
    LegData calldata base,
    LegData calldata leg2,
    uint256 leg1Notional,
    uint256 leg2Notional,
    uint256 totalValue
) internal pure returns (FeeComponents memory)
```

**Estimated Effort:** 4-5 hours (signature change affects multiple call sites)
**Gas Savings:** 5-10k bytecode reduction, better inlining
**Auditability:** Dramatically improves readability

---

### 2.4 Extract Duplicate Fee Distribution Code
**Impact:** 15-20k bytecode reduction, maintenance improvement
**Location:** `BAMM.sol:152-189, 294-320, 514-538` (3 copies of ~150 lines)

**Problem:**
- Fee distribution logic duplicated in:
  1. Two-leg leg1 (L152-189)
  2. Two-leg leg2 (L177-189)
  3. Single-leg (L294-320)
  4. batchSwap (L514-538)
- Creates audit burden and update risk

**Solution:** Extract to helper functions:
```solidity
function _distributeFees(
    Asset storage assetIn,
    Asset storage assetOut,
    uint256 totalFee,
    uint256 protocolFeeBps,
    uint64 fastTWAPIn,
    uint64 fastTWAPOut
) internal returns (
    uint256 lpFeesForIn,
    uint256 feeInTokenOut
) {
    // Centralized logic
}
```

**Estimated Effort:** 6-8 hours
**Gas Savings:** Negligible runtime, 15k bytecode
**Auditability:** Single source of truth for fee logic

---

## Priority 3: MEDIUM - Auditability & Safety

### 3.1 Add Invariant Assertions
**Impact:** Prevents silent accounting bugs
**Location:** `BAMM.sol` (swap functions)

**Solution:** Add post-swap assertions:
```solidity
// After two-leg swap calculations:
assert(totalIn == totalOut + protocolFee1 + protocolFee2 + lpFees);
assert(finalReservesIn >= oldReservesIn); // Inflow check
assert(finalReservesOut <= oldReservesOut); // Outflow check
```

**Estimated Effort:** 2-3 hours
**Gas Impact:** ~100-200 gas in dev builds (removed in production)

---

### 3.2 Document Magic Numbers
**Impact:** Improves audit transparency
**Location:** `LibPricing.sol` (inventory divergence multipliers)

**Problem:** Undocumented constants like 80, 125, 150, 200, 300 in fee calculations

**Solution:**
```solidity
// Inventory divergence penalty curve parameters
// Economic rationale: Progressive penalty prevents single-asset depletion
uint256 private constant DIVERGENCE_THRESHOLD_1 = 80;   // Mild penalty starts
uint256 private constant DIVERGENCE_THRESHOLD_2 = 125;  // Medium penalty
uint256 private constant DIVERGENCE_THRESHOLD_3 = 150;  // Strong penalty
uint256 private constant DIVERGENCE_PENALTY_1 = 200;    // 2x multiplier
uint256 private constant DIVERGENCE_PENALTY_2 = 300;    // 3x multiplier
```

**Estimated Effort:** 2 hours
**Gas Impact:** None

---

### 3.3 Circuit Breaker Reference Staleness Check
**Impact:** Prevents griefing via stale oracle data
**Location:** `BAMMManagement.sol:484-524`

**Problem:** Circuit breaker uses reference asset without recency check
- Attacker could freeze pool using stale reference price
- Guardian-only function but still exploitable

**Solution:**
```solidity
function checkCircuitBreaker(address token) external override onlyGuardian returns (bool triggered) {
    // ... existing code ...

    // Validate reference asset freshness (e.g., updated within last hour)
    if (block.timestamp - refAsset.lastOracleUpdate > 1 hours) {
        revert E.StaleOracle();
    }

    // ... rest of function
}
```

**Estimated Effort:** 1 hour
**Gas Impact:** +200 gas

---

### 3.4 updateBaseAsset Gas Limit Protection
**Impact:** Prevents partial state updates
**Location:** `BAMMManagement.sol:357-435`

**Problem:**
- Loops over ALL assets to convert prices
- Can run out of gas with 50+ assets
- Partial update leaves inconsistent prices

**Solution:** Implement paginated migration:
```solidity
struct BaseAssetMigration {
    address newBase;
    uint256 nextIndex;
    bool inProgress;
}

function startBaseAssetUpdate(address newBaseToken) external onlyAdmin {
    // Initialize migration
}

function updateAssetBatch(uint256 batchSize) external onlyAdmin {
    // Process next batchSize assets
}

function finishBaseAssetUpdate() external onlyAdmin {
    // Finalize migration
}
```

**Estimated Effort:** 6-8 hours
**Gas Impact:** Spreads cost across multiple transactions

---

## Priority 4: LOW - Nice-to-Have Optimizations

### 4.1 Remove Empty _updateAlloc Calls
**Impact:** 100-200 gas per operation
**Location:** `BAMM.sol:85-88` (called at L256, L372, L599, L660, L723)

**Solution:** Gate with feature flag or remove until implemented

### 4.2 Assembly Optimization for _getDecimals
**Impact:** 50-100 gas
**Location:** `BAMM.sol:62-67`

**Solution:** Use assembly for staticcall to avoid ABI encoding

### 4.3 Consolidate Division by BPS_PRECISION
**Impact:** Minor bytecode reduction
**Location:** Fee calculations throughout

---

## Implementation Order

### Phase 1: Critical Fixes (Week 1)
1. Factory initialize signature (Day 1)
2. Blacklist gaps (Day 1)
3. Fee-on-transfer support (Days 2-3)

### Phase 2: High-Impact Gas (Week 2)
4. Storage packing Asset struct (Days 1-2)
5. Storage packing PoolInfo (Day 3)
6. calculateSwapFeeTwoLegPure refactor (Days 4-5)

### Phase 3: Code Quality (Week 3)
7. Extract fee distribution (Days 1-2)
8. Add invariant assertions (Day 3)
9. Document magic numbers (Day 4)
10. Circuit breaker staleness (Day 5)

### Phase 4: Long-term (Week 4)
11. updateBaseAsset pagination (Days 1-3)
12. Minor optimizations (Days 4-5)

---

## Testing Requirements

### Critical Path Testing
- [ ] Factory deploy-initialize round-trip
- [ ] Fee-on-transfer token integration tests (mock token with 1% tax)
- [ ] Blacklist enforcement on all entry points

### Gas Benchmarking
- [ ] Before/after gas profiles for swap, batchSwap, deposit, withdraw
- [ ] Compare single-leg vs two-leg routing gas costs
- [ ] Measure factory deployment costs

### Invariant Testing
- [ ] Fee conservation: totalIn = totalOut + allFees
- [ ] Reserve accounting: sum(deltas) = 0
- [ ] LP index monotonicity: never decreases

---

## Risk Mitigation

1. **Storage Layout Changes:** Use storage gap pattern to maintain upgradeability
2. **Signature Changes:** Deploy new implementation, test extensively on testnet
3. **Fee Logic Changes:** Implement feature flags for gradual rollout
4. **Gas Optimizations:** Benchmark before/after, ensure no logic changes

---

## Success Metrics

- [ ] 0 deployment-blocking bugs
- [ ] 30-50% gas reduction on swap operations
- [ ] 100% test coverage on modified code
- [ ] Clean audit from external firm
- [ ] Documentation completeness score >95%
