# BTR DEX Test Suite

## Overview

Comprehensive test infrastructure for the BTR DEX (Anchor Path Pricing AIMM).

### Test Statistics

- **Unit Tests**: 57 passing tests
  - LibMaths: 27 tests (B64 encoding/decoding, arithmetic, comparisons)
  - LibOracle: 30 tests (sigma/delta computation, EMA decoding, offset encoding)
- **Integration Tests**: Framework established (16 tests for pool operations)
- **Total Coverage**: 12 library test coverage plan with ~165 test cases to implement

## Test Structure

```
tests/
├── unit/
│   ├── LibMaths.t.sol          (27 passing) - B64 codec testing
│   ├── LibOracle.t.sol         (30 passing) - Risk signal computation
│   ├── LibPricing.t.sol        (TODO - 32 cases)
│   ├── LibSpline.t.sol         (TODO - 18 cases)
│   ├── LibAnchorPathPricing.t.sol (TODO - 20 cases)
│   ├── LibAnchorTree.t.sol     (TODO - 16 cases)
│   └── [other lib tests]       (TODO)
├── integration/
│   └── PoolDeployment.t.sol    (16 tests - pool/token/swap operations)
└── fixtures/
    ├── BaseTestSetup.sol       (Abstract base with utilities)
    └── BTRToken.sol            (Mock ERC20 for testing)
```

## Completed Work

### 1. Unit Tests - LibMaths (27/27 ✅)

Tests B64 floating-point encoding/decoding:
- Encoding with various mantissas, decimals, exponents
- Roundtrip encode/decode verification
- Mantissa normalization
- Arithmetic operations (add64, sub64, mul64, div64)
- Comparisons (gt64, lt64)
- B64 ↔ 1e18 conversions
- Edge cases and boundary conditions

**Key Test Coverage**:
```solidity
✅ test_encodeB64_single_digits
✅ test_encodeB64_with_decimals
✅ test_decodeB64_roundtrip
✅ test_decodeB64_different_decimal_precision
✅ test_add64_same_decimal / test_sub64_same_decimal
✅ test_mul64_mantissa_normalization_after_multiply
✅ test_div64_precision_preservation
✅ test_b64To1e18_basic / test_b64To1e18_large_value
✅ test_b64_symmetry_of_operations
```

### 2. Unit Tests - LibOracle (30/30 ✅)

Tests oracle feed decoding and risk signal (σ, Δ) computation:

**EMA Decoding** (8 tests):
- Fast/slow EMA with various offsets (zero, positive, negative)
- Overflow and underflow protection
- Clamping behavior

**Offset Encoding** (7 tests):
- Current/EMA relationships
- Roundtrip verification
- Range clamping

**Sigma (Volatility) Computation** (6 tests):
- Mean of fast and slow EMAs
- Blending different timeframes
- Edge cases (zero, max volatility)

**Delta (Deviation) Computation** (6 tests):
- Multi-timeframe price divergence
- Conservative MAX aggregation
- Offset sign handling
- Uint32 overflow protection

**Integration Tests** (3 tests):
- Sigma and delta independence
- Realistic oracle feed scenarios

**Key Test Coverage**:
```solidity
✅ test_decodeFastEMA_zero_offset
✅ test_decodeFastEMA_positive_offset
✅ test_decodeFastEMA_negative_offset
✅ test_encodeOffset_ema_equals_current
✅ test_encodeOffset_ema_higher_than_current
✅ test_roundtrip_offset_with_fastEMA
✅ test_getSigma_equal_vols / test_getSigma_different_vols
✅ test_getSigma_blends_timeframes
✅ test_getDelta_zero_offsets
✅ test_getDelta_fast_above_slow
✅ test_getDelta_conservative_aggregation
✅ test_realistic_oracle_feed
```

### 3. Base Test Infrastructure

**BaseTestSetup.sol** - Abstract base contract with utilities:
- B64 testing utilities (makeB64, toB64, fromB64, assertB64Approx)
- Oracle testing helpers (makeFeedData, getSigma, getDelta)
- Assertion helpers (assertUint32Approx, assertInt32Approx)
- Predefined constants for testing (VOL_*, OFFSET_*, etc.)

**BTRToken.sol** - Mock ERC20 contract:
- Standard ERC20 interface (transfer, approve, transferFrom)
- Mint/burn functions for testing flexibility
- Configurable decimals
- Direct balance/allowance tracking (no inheritance)

### 4. Integration Test Framework

**PoolDeployment.t.sol** - Pool operations testing (16 tests):

**Deployment Tests** (3 passing):
- Pool deployment
- Pool initialization with owner/baseToken
- Token deployment and initial supplies

**Pool Operations Tests** (13 tests - pending module registration):
- Token deposits to pool
- Swap quote generation and execution
- Coverage ratio tracking
- Reserve/liability dynamics
- LP withdrawal

## Library Test Coverage Plan

Based on comprehensive analysis of all 12 libraries:

### CRITICAL (P0) - 76 tests
- **LibMaths.sol**: 28 tests ✅ (27 completed, 1 placeholder)
- **LibOracle.sol**: 16 tests ✅ (30 completed)
- **LibPricing.sol**: 32 tests (TODO)

### IMPORTANT (P1) - 54 tests
- **LibSpline.sol**: 18 tests
- **LibAnchorPathPricing.sol**: 20 tests
- **LibAnchorTree.sol**: 16 tests

### INFRASTRUCTURE (P2) - 30 tests
- **LibTransientCache.sol**: 8 tests
- **LibTimelock.sol**: 6 tests
- **LibTransientOracle.sol**: 4 tests

### CONSTANTS (P3) - 5 tests
- **LibPoseidon.sol**: 3 tests
- **LibConstants.sol**: 2 tests

**Total Planned**: 165+ test cases

## How to Run Tests

```bash
# Run all tests
forge test -v

# Run specific test file
forge test --match-contract LibOracleTest -v

# Run specific test
forge test --match-contract LibMathsTest --match-path "*LibMaths*" -v

# Run integration tests only
forge test test/integration/ -v

# Run unit tests only
forge test test/unit/ -v
```

## Test Results Summary

| Suite | Status | Passing | Total | Notes |
|-------|--------|---------|-------|-------|
| LibMaths | ✅ | 27 | 27 | B64 codec fully tested |
| LibOracle | ✅ | 30 | 30 | Sigma/Delta complete |
| PoolDeployment | 🟡 | 3 | 16 | Framework ready, modules pending |
| **Total** | ✅ | **57** | **73** | |

## Next Steps

### Phase 1 (Immediate)
- [ ] Register module implementations for full integration testing
- [ ] Complete LibPricing unit tests (32 cases)
- [ ] Add more swap scenarios (3+ tokens, different decimals)

### Phase 2 (Short Term)
- [ ] LibSpline interpolation tests (18 cases)
- [ ] LibAnchorPathPricing tests (20 cases)
- [ ] LibAnchorTree tests (16 cases)

### Phase 3 (Medium Term)
- [ ] Infrastructure library tests (cache, timelock, poseidon)
- [ ] E2E scenarios (multi-swap paths, flash loans, coverage dynamics)
- [ ] Stress tests and gas optimization verification

### Phase 4 (Long Term)
- [ ] Fuzz testing with foundry-rs/fuzzing
- [ ] Property-based invariant testing
- [ ] Gas benchmarking suite
- [ ] Coverage report generation

## Architecture Notes

### Modular Design
Tests use:
- **Inheritance**: BaseTestSetup provides common utilities
- **Fixtures**: BTRToken for reusable token deployment
- **Helpers**: _depositLiquidity, _swapTokens functions

### Test Philosophy
- **Unit tests focus on**: Math correctness, edge cases, boundary conditions
- **Integration tests verify**: Component interactions, state transitions
- **Each test is atomic**: Fully independent setUp/execution

### Constants & Precision
- Volatility (σ): 1e6 base (1,000,000 = 1%)
- Deviation (Δ): offset units (0.0001% = 1 unit)
- Spreads: 1e6 base (1,000,000 = 0.01%)
- Balances: 1e18 base (WAD format)

## Troubleshooting

### Module Registration Failures
The pool tests currently fail with "InvalidInput()" because modules haven't been registered. To fix:
1. Deploy Core module and register at pool.modules[selector]
2. Deploy admin module and register
3. Register all required module selectors

### Test Compilation Issues
- Ensure dependencies are in `lib/` (solady, poseidon2-evm, etc.)
- Check Solidity version matches (0.8.28+)
- Run `forge clean && forge build` if cache issues

## Contributing

When adding new tests:
1. Create file in appropriate directory (test/unit/ or test/integration/)
2. Inherit from BaseTestSetup for common utilities
3. Follow naming: test_[feature]_[scenario]
4. Add comments explaining non-obvious assertions
5. Keep tests atomic and independent
