# DarkPool Implementation

## Overview

This directory contains the Solidity implementation of the DarkPool privacy layer for BAMM pools. DarkPool uses zkSNARK proofs (Groth16) to enable anonymous trading and liquidity provisioning while maintaining public transaction amounts.

**Architecture:** Beacon Proxy Pattern (mirrors BAMM design)
- Single `DarkPool.sol` implementation
- One beacon proxy per BAMM pool
- Unified upgrades via `UpgradeableBeacon`

---

## Directory Structure

```
interfaces/
├── IDarkPool.sol                 # DarkPool interface
└── IDarkPoolFactory.sol          # Factory interface

darkpool/
├── DarkPool.sol                  # Main implementation contract
├── DarkPoolFactory.sol           # Factory for deploying beacon proxies
├── DarkPoolErrors.sol            # Centralized errors
├── README.md                     # This file│
└── libraries/
    ├── LibStorage.sol            # EIP-7201 namespaced storage
    ├── LibMerkleTree.sol         # Poseidon merkle tree operations
    ├── LibVerifier.sol           # Groth16 proof verification
    └── LibBAMM.sol               # BAMM interaction helpers
```

---

## Implementation Status

### ✅ Completed

1. **Core Contracts**
   - `DarkPool.sol` - Main implementation (beacon-compatible)
   - `DarkPoolFactory.sol` - Beacon proxy factory
   - All interfaces (`IDarkPool`, `IDarkPoolFactory`)
   - Error definitions (`DarkPoolErrors.sol`)

2. **Libraries**
   - `LibStorage.sol` - EIP-7201 storage pattern
   - `LibMerkleTree.sol` - Merkle tree structure (Poseidon placeholder)
   - `LibVerifier.sol` - Proof verification logic
   - `LibBAMM.sol` - BAMM interaction patterns (swap, LP deposit/withdraw)

3. **Deployment Scripts**
   - `DeployDarkPool.s.sol` - Deploy implementation + factory + beacon
   - `CreateDarkPool.s.sol` - Create DarkPool proxy for specific BAMM

4. **Documentation**
   - Comprehensive spec: `contracts/specs/DARK_POOL.md`
   - Implementation README (this file)
   - Inline code documentation (NatSpec)

### ⚠️ TODO: Critical Components

1. **Poseidon Hash Implementation**
   - **Current:** Placeholder using `keccak256` in `LibMerkleTree.sol:82`
   - **Required:** Actual Poseidon T=3 implementation
   - **Options:**
     - Use precompiled contract (if available on target chain)
     - Port circomlibjs Poseidon to Solidity
     - Use existing library (e.g., from Semaphore, Privacy Pools)
   - **Location to update:** `LibMerkleTree.sol:poseidon2()`

2. **Zero Value Generation**
   - **Current:** Placeholder zeros in `LibMerkleTree.sol:44-77`
   - **Required:** Pre-compute Poseidon zero values for tree levels
   - **Formula:** `zeros[i] = Poseidon(zeros[i-1], zeros[i-1])` for i > 0; `zeros[0] = Poseidon(0)`
   - **Tool:** Generate with Circom/snarkjs script
   - **Location to update:** `LibMerkleTree.sol:getZeroValue()`

3. **Circom Circuit**
   - **File:** `circuits/JoinSplit.circom` (not yet created)
   - **Spec:** See `DARK_POOL.md` Section 6
   - **Parameters:** NI=2, NO=2, treeDepth=32, MAX_ASSETS=4
   - **Constraints:**
     - Merkle inclusion (2 inputs)
     - Nullifier computation (2 nullifiers)
     - Per-asset value conservation
     - ExtDataHash binding
     - (Optional) ASP membership

4. **Groth16 Verifier Contract**
   - **Current:** Expected at address set during initialization
   - **Required:** Generate from circuit using snarkjs
   - **Command:** `snarkjs zkey export solidityverifier`
   - **Interface:** `function verifyProof(uint256[8] proof, uint256[] publicInputs) returns (bool)`

5. **Trusted Setup**
   - **Options:**
     - Use existing Powers of Tau (Hermez, Tornado Cash)
     - Run new ceremony for transparency
   - **Files needed:**
     - `powersOfTau28_hez_final_XX.ptau`
     - Circuit-specific setup: `.zkey` file
   - **Tool:** snarkjs

6. **Proof Builder**
   - **Language:** TypeScript/JavaScript (snarkjs)
   - **Inputs:** Private notes, Merkle paths, extData
   - **Outputs:** `Proof` struct, `ExtData` struct
   - **Location:** `scripts/proof-builder/` (not yet created)

### 📋 TODO: Optional Enhancements

1. **Incremental Merkle Tree Optimization**
   - Current implementation recomputes from leaf each time
   - Optimize: Store intermediate hashes for O(1) sibling lookups
   - Reference: Tornado Cash's MerkleTreeWithHistory

2. **EIP-1559 Gas Optimization**
   - Batch multiple deposits in single tx
   - Calldata compression for extData
   - Storage packing for frequently accessed fields

3. **Association Set Provider**
   - Off-chain service maintaining approved deposit registry
   - Dynamic ASP root updates via governance
   - Integration with compliance providers (Chainalysis, TRM)

4. **Recipient Discovery**
   - Implement ECDH encryption for recipient hints
   - Off-chain indexer for scanning `NewCommitment` events
   - Wallet SDK for note management

5. **Testing Suite**
   - Unit tests (Foundry): Merkle tree, nullifiers, verification
   - Integration tests: End-to-end deposit→transact flows
   - Fuzz tests: Random inputs, edge cases
   - Gas benchmarks

---

## Usage

### Integrated Deployment (Recommended)

DarkPool is now integrated with BAMMFactory. Deploy everything at once:

```bash
# 1. Deploy complete infrastructure (BAMM + DarkPool)
forge script script/DeployAll.s.sol:DeployAll \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify

# Outputs:
# - BAMM_FACTORY, DARKPOOL_FACTORY, BAMM_BEACON, DARKPOOL_BEACON
```

### Deploy BAMM Pool with DarkPool

```bash
# 2. Deploy pool with privacy enabled
export ENABLE_DARK_POOL=true  # Enable DarkPool
forge script script/DeployBAMMPoolWithDarkPool.s.sol \
  --rpc-url $RPC_URL \
  --broadcast

# Or enable later for existing pool
forge script script/EnableDarkPool.s.sol \
  --rpc-url $RPC_URL \
  --broadcast
```

**See [DARKPOOL_INTEGRATION.md](../../specs/DARKPOOL_INTEGRATION.md) for complete integration guide.**

### Standalone Deployment (Advanced)

For manual DarkPool deployment without BAMMFactory:

```bash
# 1. Deploy DarkPool implementation + factory + beacon
forge script script/DeployDarkPool.s.sol:DeployDarkPool \
  --rpc-url $RPC_URL \
  --broadcast

# 2. Create DarkPool proxy for specific BAMM pool
export DARKPOOL_FACTORY=0x...
export BAMM_POOL=0x...
export GROTH16_VERIFIER=0x...
export DARKPOOL_ADMIN=0x...

forge script script/CreateDarkPool.s.sol:CreateDarkPool \
  --rpc-url $RPC_URL \
  --broadcast
```

### Interact with DarkPool

**Deposit Token (Public):**
```solidity
// Off-chain: Generate commitment
bytes32 commitment = poseidon(chainId, darkPool, assetId, noteType, value, ownerKey, blinding, salt);
bytes memory recipientHint = encryptECDH(commitment, recipientPubKey);

// On-chain
darkPool.depositToken(
    address(token),
    1000e6, // 1000 USDC
    commitment,
    recipientHint
);
```

**Private Swap:**
```solidity
// Off-chain: Generate proof with witness
Proof memory proof = generateProof(inputNotes, outputNotes, extData);

ExtData memory extData = ExtData({
    actionType: 1, // SWAP
    assets: [tokenIn, tokenOut],
    extIn: [0, minAmountOut],
    extOut: [amountIn, 0],
    receivers: [address(0)], // Re-shield
    memoHash: bytes32(0),
    aspRoot: bytes32(0)
});

// On-chain
darkPool.transact(proof, extData, recipientHints);
```

---

## Security Considerations

### Implemented

1. **Domain Separation:** Commitments and nullifiers include chainId and darkPoolAddress
2. **Front-Running Protection:** ExtDataHash binds all external parameters
3. **Reentrancy Guards:** All state-changing functions protected
4. **Root History:** Accept proofs against last 100 roots (reorg tolerance)
5. **Cross-Pool Isolation:** Per-proxy storage prevents contamination

### To Audit

1. **Merkle Tree Integrity:** Verify zero value generation and path computation
2. **Nullifier Uniqueness:** Ensure no collision possible across notes
3. **LP Accounting:** Validate scaledShares → lpTokens conversion
4. **Circuit Soundness:** Formal verification of value conservation constraints
5. **Verifier Security:** Trusted setup integrity, proof malleability

---

## Gas Estimates

| Operation | Gas Cost | Notes |
|-----------|----------|-------|
| depositToken() | ~97k | 1 leaf insertion |
| depositAndMintLP() | ~247k | BAMM.deposit + tree update |
| transact() (swap, 2×2) | ~493k | Includes Groth16 verification |
| transact() (LP ops, 2×2) | ~513k | Includes liquidityIndex read |

**Privacy Premium:** ~3.3× vs public BAMM operations

---

## Next Steps

1. **Immediate (Week 1-2):**
   - [ ] Implement Poseidon hash in Solidity
   - [ ] Generate zero values for merkle tree
   - [ ] Write JoinSplit.circom circuit
   - [ ] Set up trusted setup (use existing Powers of Tau)

2. **Short-term (Week 3-4):**
   - [ ] Generate Groth16 verifier contract
   - [ ] Build proof generator (TypeScript/snarkjs)
   - [ ] Write unit tests (Foundry)
   - [ ] End-to-end integration test

3. **Medium-term (Week 5-8):**
   - [ ] Internal security review
   - [ ] Gas optimization pass
   - [ ] External audit (zkSecurity, Trail of Bits)
   - [ ] Testnet deployment

4. **Long-term (Week 9-12):**
   - [ ] Mainnet deployment
   - [ ] Wallet SDK for note management
   - [ ] Association set provider (if needed)
   - [ ] Documentation & tutorials

---

## References

- **Spec:** `/contracts/specs/DARK_POOL.md`
- **BAMM:** `/contracts/src/BAMM.sol`
- **Solady:** https://github.com/Vectorized/solady
- **Circom:** https://docs.circom.io/
- **snarkjs:** https://github.com/iden3/snarkjs
- **Tornado Cash Nova:** https://github.com/tornadocash/tornado-nova
- **Privacy Pools:** https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4563364

---

## License

MIT

---

*DarkPool v1.0 - Beacon Proxy Implementation*
*Status: Solidity contracts complete, circuits pending*
*Last Updated: 2025-11-11*
