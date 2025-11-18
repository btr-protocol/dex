# Security Audit Fixes Implementation

**Date**: 2025-01-11
**Status**: Implementation plan created
**Based on**: Expert security reviews (convergent findings)

## Overview

Both expert reviews identified the same core security issues and architectural strengths. This document tracks implementation of critical fixes required before testnet/mainnet deployment.

---

## CRITICAL FIXES

### 1. Nullifier Timing Leak ⚠️ [BLOCKING]

**Severity**: CRITICAL
**Location**: `LibVerifier.verifyProof()` lines 60-74
**Issue**: Nullifier uniqueness is checked *after* Groth16 verification, creating a timing side-channel that allows deanonymization through repeated invalid-proof attacks.

**Current Code Problem**:
```solidity
// Step 1: Verify Groth16 proof (EXPENSIVE, all paths same gas)
bool success = _callVerifier(proof, extData.aspRoot);
if (!success) revert();

// Step 2: Check nullifiers (VARIABLE TIME - TIMING LEAK!)
for (uint256 i = 0; i < proof.nullifiers.length; i++) {
    if (nullifierSpent[nullifier]) {
        revert NullifierAlreadySpent(); // Variable gas timing
    }
}
```

**Attack Vector**: Attacker submits proofs with same nullifier repeatedly:
- Valid proof + new nullifier → expensive verification + state change
- Valid proof + spent nullifier → expensive verification + cheaper revert
- Timing difference reveals whether nullifier was spent

**Solution Options**:

**Option A: Circuit Enforcement (PREFERRED)**
- Move nullifier uniqueness check inside circuit
- Circuit verifies nullifier against nullifier tree root
- Requires circuit modification and new trusted setup ceremony

**Option B: Constant-Time Solidity (INTERIM)**
- Add dummy operations to slow path
- All paths take identical gas
- Implemented as interim until circuit update ready

**Option B Implementation**:
```solidity
function verifyProof(
    IDarkPool.Proof calldata proof,
    IDarkPool.ExtData calldata extData
) internal view returns (bool) {
    // ... existing checks ...

    // 5. Call Groth16 verifier FIRST
    bool success = _callVerifier(proof, extData.aspRoot);
    if (!success) {
        revert Errors.InvalidProof();
    }

    // 6. Check nullifiers with constant-time padding
    address shieldedStateAddr = $.shieldedState;
    if (shieldedStateAddr == address(0)) revert Errors.ZeroAddress();

    bool anyNullifierSpent = false;
    for (uint256 i = 0; i < proof.nullifiers.length; i++) {
        bytes32 nullifier = proof.nullifiers[i];
        (bool callSuccess, bytes memory result) = shieldedStateAddr.staticcall(
            abi.encodeWithSignature("nullifierSpent(bytes32)", nullifier)
        );

        if (callSuccess && abi.decode(result, (bool))) {
            anyNullifierSpent = true;
        }

        // CRITICAL: Add dummy operations to equalize gas paths
        // This ensures all paths (spent/unspent) take identical time
        assembly {
            let _ := mload(0x40)  // Load from memory (constant gas)
        }
    }

    if (anyNullifierSpent) {
        revert Errors.NullifierAlreadySpent();
    }

    return true;
}
```

**Recommended Path**: Implement Option B now (takes 30 mins), plan Option A for circuit v2.

---

### 2. ExtDataHash SDK Mismatch ⚠️ [BLOCKING]

**Severity**: CRITICAL
**Location**: `sdk/src/darkpool/proof-builder.ts` lines 543-583
**Issue**: SDK has hardcoded `0n` values and TODOs for `actionType` and `hAssetsReceivers`, while contract expects full binding.

**Current SDK Code Problem**:
```typescript
private computeExtDataHash(
    extInAmounts: bigint[],
    extOutAmounts: bigint[],
    aspRoot: bigint
): bigint {
    // ... padding ...

    // TODO: Once assets/receivers are integrated...
    const hAssetsReceivers = 0n; // ❌ PLACEHOLDER!
    const actionType = 0n;       // ❌ PLACEHOLDER!

    return poseidon2Hash([
        actionType,          // WRONG
        aspRoot,
        hAssetsReceivers,    // WRONG
        hAmounts,
    ]);
}
```

**Problem**: If circuit or contract changes these values, proofs become invalid and unmalleable.

**Required Fix**:

Update `proof-builder.ts` to compute full extDataHash:

```typescript
private computeExtDataHash(
    extInAmounts: bigint[],
    extOutAmounts: bigint[],
    aspRoot: bigint,
    actionType: bigint,
    assets: bigint[],
    receivers: bigint[]
): bigint {
    // Ensure arrays are exactly 4 elements
    const paddedAssets = [...(assets || [])];
    while (paddedAssets.length < 4) paddedAssets.push(0n);

    const paddedReceivers = [...(receivers || [])];
    while (paddedReceivers.length < 4) paddedReceivers.push(0n);

    const paddedExtIn = [...extInAmounts];
    while (paddedExtIn.length < 4) paddedExtIn.push(0n);

    const paddedExtOut = [...extOutAmounts];
    while (paddedExtOut.length < 4) paddedExtOut.push(0n);

    // Layer 1a: Hash assets and receivers (8 values)
    const hAssetsReceivers = poseidon2Hash([
        paddedAssets[0],
        paddedAssets[1],
        paddedAssets[2],
        paddedAssets[3],
        paddedReceivers[0],
        paddedReceivers[1],
        paddedReceivers[2],
        paddedReceivers[3],
    ]);

    // Layer 1b: Hash amounts (8 values)
    const hAmounts = poseidon2Hash([
        paddedExtIn[0],
        paddedExtIn[1],
        paddedExtIn[2],
        paddedExtIn[3],
        paddedExtOut[0],
        paddedExtOut[1],
        paddedExtOut[2],
        paddedExtOut[3],
    ]);

    // Layer 2: Final hash (4 values)
    return poseidon2Hash([
        actionType,
        aspRoot,
        hAssetsReceivers,
        hAmounts,
    ]);
}
```

**Update TransactionInputs Type** in `sdk/src/darkpool/types.ts`:

```typescript
export interface TransactionInputs {
    inputNotes: NoteWithPath[];
    outputNotes: Note[];
    actionType: bigint;           // ADD
    assets: bigint[];             // ADD (asset addresses)
    receivers: bigint[];          // ADD (recipient addresses)
    extIn?: Map<bigint, bigint>;
    extOut?: Map<bigint, bigint>;
    aspRoot?: bigint;
}
```

**Update buildTransaction** to pass these through.

---

### 3. ShieldedState Access Control Blocker ⚠️ [BLOCKING]

**Severity**: CRITICAL
**Location**: `ShieldedState.sol` - all mutation functions use `onlyOwner`
**Issue**: DarkPool cannot call ShieldedState functions when deployed as beacon proxy under different owner.

**Current Architecture Problem**:
- DarkPool initialized with `owner1`
- ShieldedState owned by `owner2`
- DarkPool calls `insertLeaf()` → reverts (`onlyOwner` check fails)
- Multiple external calls per level → multi-million gas overhead

**Solution**: Move tree logic *into* ShieldedState with `onlyDarkPool` guards.

**Required Changes**:

1. **Add DarkPool whitelist to ShieldedState**:

```solidity
contract ShieldedState is Ownable {
    mapping(address => bool) public isDarkPool;

    modifier onlyDarkPool() {
        if (!isDarkPool[msg.sender]) revert Unauthorized();
        _;
    }

    function addDarkPool(address pool) external onlyOwner {
        isDarkPool[pool] = true;
    }

    function removeDarkPool(address pool) external onlyOwner {
        isDarkPool[pool] = false;
    }
}
```

2. **Move insertLeaf logic into ShieldedState**:

```solidity
function insertLeaf(bytes32 leaf) external onlyDarkPool
    returns (uint32 leafIndex, bytes32 newRoot) {
    // Full incremental tree logic here
    leafIndex = nextLeafIndex;
    bytes32 h = leaf;
    uint32 idx = leafIndex;

    for (uint8 level = 0; level < TREE_HEIGHT; ) {
        if ((idx & 1) == 0) {
            // Left position
            filledSubtrees[level] = h;
            h = _poseidon2(h, ZEROS[level]);
        } else {
            // Right position
            h = _poseidon2(filledSubtrees[level], h);
        }
        idx >>= 1;
        unchecked { ++level; }
    }

    nextLeafIndex = leafIndex + 1;
    currentRoot = h;
    rootHistory[rootHistoryIndex] = h;
    rootInHistory[h] = true;

    unchecked {
        rootHistoryIndex = (rootHistoryIndex + 1) % ROOT_HISTORY_SIZE;
    }

    emit RootAdded(h, leafIndex);
    return (leafIndex, h);
}
```

3. **Remove external tree calls from DarkPool** (currently in `LibMerkleTree.insertLeaf`).

**Gas Savings**: Eliminates ~1M gas per insert (external call overhead × TREE_HEIGHT).

---

## HIGH-IMPACT GAS OPTIMIZATIONS

### 4. Precompute Zeros Array

**Severity**: HIGH (Gas)
**Location**: `ShieldedState.sol` + `LibMerkleTree.sol`
**Current Issue**: `getZeroValue(level)` recomputes zeros on every call.

**Solution**:

```solidity
contract ShieldedState {
    // Precomputed ZEROS for tree levels 0..31
    bytes32[32] public constant ZEROS = [
        bytes32(0x0000000000000000000000000000000000000000000000000000000000000000),
        bytes32(0x21cc8c5dd5758a6e3ef26d6b2ae1b4670eadbe58dd5ac3c5a7d56ef6ce75d462),
        // ... (generate via script, see below)
    ];
}
```

**Generation Script** (`sdk/src/circuits/scripts/generate-zeros.ts`):

Already exists but needs to be run and values copied to contract.

```bash
cd sdk
bun run generate-zeros  # Generates zeros.ts with all precomputed values
```

Copy output to `ShieldedState.sol` constant array.

**Gas Savings**: ~150k per insert.

---

### 5. Fixed-Size Nullifier Array

**Severity**: HIGH (Gas)
**Location**: `IDarkPool.sol` Proof struct
**Current Issue**: Dynamic `bytes32[] nullifiers` causes CALLDATALOAD overhead.

**Solution**:

```solidity
// BEFORE
struct Proof {
    uint256[8] groth16Proof;
    bytes32 merkleRoot;
    bytes32[] nullifiers;         // ❌ Dynamic array
    bytes32 extDataHash;
    bytes32[] outCommitments;
}

// AFTER
struct Proof {
    uint256[8] groth16Proof;
    bytes32 merkleRoot;
    bytes32[2] nullifiers;        // ✅ Fixed-size (always 2 nullifiers)
    bytes32 extDataHash;
    bytes32[2] outCommitments;    // ✅ Fixed-size (always 2 outputs)
}
```

**Gas Savings**: ~3k per proof (~0.75%).

---

### 6. Reduce Tree Depth

**Severity**: MEDIUM (Gas + Upgradeability)
**Location**: `ShieldedState.TREE_HEIGHT = 32`
**Current Issue**: Depth 32 = 4.3B capacity, but likely overkill; adds 600 constraints to circuit.

**Recommended**: Change to **depth 24** (16M capacity)
- Balances anonymity set size with gas and capacity
- Matches Semaphore/modern mixer depths
- Reduces per-insert gas by ~4 levels = ~200k gas
- **CRITICAL**: Requires new circuit compilation + ceremony phase 2

**Cannot upgrade in-place**: New circuit → new trusted setup → new verifier contract → full redeployment.

**Decision**: Choose now, cannot change later without full redeploy.

---

## Trusted Setup Ceremony

### Current Status

**Required**: Two phases

**Phase 1: Powers of Tau (Circuit-Agnostic)**
- Can reuse existing ceremonies from community
- **Recommended**: Perpetual Powers of Tau (Tornado/Hermez)
  - https://github.com/privacy-scaling-explorations/perpetualpowersoftau
  - 1114+ participants, publicly audited
  - Download: `powersOfTau28_hez_final_21.ptau` (for 2^21 ≈ 2M constraints)

**Phase 2: Circuit-Specific Setup**
- **MUST** be done for your circuit
- Requires independent contributors (minimum 30-50 for mainnet)
- Current tree depth = 32 → need tau21 or larger
- **MVP approach**: 3-5 contributors for testing

### Implementation Steps

**Phase 1 (Already available)**:

```bash
# Download existing ceremony
wget https://hermez.s3-eu-west-1.amazonaws.com/powersOfTau28_hez_final_21.ptau

# Verify integrity
snarkjs powersoftau verify powersOfTau28_hez_final_21.ptau
```

**Phase 2 (To implement)**:

```bash
# 1. Compile circuit (after depth change to 24)
circom darkpool.circom --r1cs --wasm --sym -o build/

# 2. Start phase 2
snarkjs groth16 setup build/darkpool.r1cs powersOfTau28_hez_final_21.ptau darkpool_0000.zkey

# 3. Contribute (run with MULTIPLE parties)
snarkjs zkey contribute darkpool_0000.zkey darkpool_0001.zkey \
  --name="Contributor 1" -v -e="$(head -c 1024 /dev/urandom | base64)"

# [Repeat for N contributors...]

# 4. Apply random beacon
snarkjs zkey beacon darkpool_final_contrib.zkey darkpool_beacon.zkey \
  0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f 10

# 5. Export verification key
snarkjs zkey export solidityverifier darkpool_final.zkey Verifier.sol
```

**Script to create** (`scripts/trusted-setup-ceremony.sh`):

```bash
#!/bin/bash
set -e

CIRCUIT_NAME="darkpool"
CIRCUIT_PATH="sdk/src/circuits/${CIRCUIT_NAME}.circom"
BUILD_DIR="sdk/src/circuits/build"
POWERS_OF_TAU="powersOfTau28_hez_final_21.ptau"

# Compile circuit
echo "1. Compiling circuit..."
circom "$CIRCUIT_PATH" --r1cs --wasm --sym -o "$BUILD_DIR/"

# Download powers of tau if not present
if [ ! -f "$POWERS_OF_TAU" ]; then
    echo "2. Downloading Powers of Tau (1.5GB)..."
    wget https://hermez.s3-eu-west-1.amazonaws.com/$POWERS_OF_TAU
fi

# Initialize phase 2
echo "3. Initializing phase 2..."
snarkjs groth16 setup "$BUILD_DIR/${CIRCUIT_NAME}.r1cs" "$POWERS_OF_TAU" "${CIRCUIT_NAME}_0000.zkey"

# Phase 2 contributions (adjust N_CONTRIBUTORS for your use case)
N_CONTRIBUTORS=3
for i in $(seq 1 $N_CONTRIBUTORS); do
    prev=$((i - 1))
    echo "4.$i. Contributor $i phase 2 contribution..."
    snarkjs zkey contribute \
        "${CIRCUIT_NAME}_$(printf "%04d" $prev).zkey" \
        "${CIRCUIT_NAME}_$(printf "%04d" $i).zkey" \
        --name="Contributor $i" \
        -v \
        -e="$(openssl rand -hex 32)"
done

# Apply random beacon
echo "5. Applying random beacon..."
FINAL_CONTRIB=$((N_CONTRIBUTORS))
snarkjs zkey beacon \
    "${CIRCUIT_NAME}_$(printf "%04d" $FINAL_CONTRIB).zkey" \
    "${CIRCUIT_NAME}_final.zkey" \
    0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f \
    10 \
    -n="Final Beacon"

# Verify
echo "6. Verifying final zkey..."
snarkjs zkey verify "$BUILD_DIR/${CIRCUIT_NAME}.r1cs" "$POWERS_OF_TAU" "${CIRCUIT_NAME}_final.zkey"

# Export verification key
echo "7. Exporting verification key..."
snarkjs zkey export solidityverifier "${CIRCUIT_NAME}_final.zkey" \
    "contracts/src/darkpool/Verifier.sol"

echo "✅ Trusted setup ceremony complete!"
echo "Verification key exported to: contracts/src/darkpool/Verifier.sol"
```

---

## Implementation Roadmap

### Before Testnet ✅

- [ ] **1. Fix nullifier timing leak** (1-2 hours)
  - Add constant-time padding in `LibVerifier`
  - Test with multiple proof submissions

- [ ] **2. Complete extDataHash SDK** (2-3 hours)
  - Update `TransactionInputs` type
  - Implement full hash computation
  - Update `buildTransaction()`

- [ ] **3. Fix ShieldedState access** (3-4 hours)
  - Move `insertLeaf()` logic into ShieldedState
  - Add `onlyDarkPool` guards
  - Remove external tree calls from DarkPool
  - Test deposit flow

- [ ] **4. Precompute zeros** (1 hour)
  - Run `generate-zeros` script
  - Copy constants to `ShieldedState`
  - Verify values match circuit

- [ ] **5. Optimize Proof struct** (30 mins)
  - Change `nullifiers` to `bytes32[2]`
  - Change `outCommitments` to `bytes32[2]`
  - Update all code that builds/verifies proofs

- [ ] **6. Create ceremony script** (1-2 hours)
  - Write `trusted-setup-ceremony.sh`
  - Test with 3 contributors
  - Document process

- [ ] **7. Documentation** (1-2 hours)
  - Create `SECURITY_AUDIT_FIXES.md` (this file)
  - Update `DARK_POOL.md` with new architecture
  - Document ceremony process

**Estimated Time**: 12-18 hours total

### Before Mainnet

- [ ] **8. Full circuit audit** (4-8 weeks)
  - Engage Trail of Bits or Zellic
  - Both reviews recommend this as critical

- [ ] **9. Public trusted setup ceremony** (1-2 weeks)
  - Recruit 50+ independent contributors
  - Public attestations from each
  - Broadcast ceremony progress

- [ ] **10. Additional features**
  - Recipient hint encryption
  - Relayer/fee support in ExtData
  - Emergency pause timelock

- [ ] **11. Mainnet gas benchmarks** (1-2 days)
  - Test deposit/transact/withdraw
  - Target <400k gas per transact
  - Verify all optimizations working

---

## Success Criteria

**Security**:
- ✅ No timing leaks (nullifier check constant-time)
- ✅ ExtDataHash fully bound (no placeholders)
- ✅ Access control correct (onlyDarkPool)
- ✅ Circuit audit passed

**Gas Efficiency**:
- ✅ Deposit: ~200-300k (down from baseline)
- ✅ Transact: <400k (target, vs Tornado Classic 1.4M)
- ✅ Withdraw: ~150-200k

**Privacy**:
- ✅ Global anonymity set (all deposits in one tree)
- ✅ Trusted setup properly executed (50+ contributors)
- ✅ No leakage via timing/access patterns

---

## References

1. **Nullifier Timing**: Berkeley DeFi research on Tornado gas & security
2. **ExtDataHash**: zkpassport & Tornado Nova design patterns
3. **Tree Depth**: Semaphore, Tornado Classic (depth 20 with 1M capacity)
4. **Trusted Setup**: RAILGUN ceremony docs + Zcash ceremony best practices
5. **Circuit Audit**: Standard for all ZK production systems

---

## Notes

- **Start with testnet** → fix issues → then mainnet ceremony
- **Cannot change tree depth later** → decide now (recommend 24)
- **Timing leak is exploitable** → fix before public testnet
- **SDK hash mismatch is silent failure** → fix before any testing
- **All three issues must be fixed** → blocks soundness + privacy + security

