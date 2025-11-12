# DarkPool: Privacy-Preserving Trading for BAMM

## Overview

**DarkPool** is a zkSNARK-based privacy layer enabling anonymous trading and liquidity provisioning for BAMM pools. Built on Groth16 proofs, Poseidon commitments, and UTXO-style note accounting, DarkPool provides identity privacy while maintaining public transaction amounts.

**Core Design:**
- **Beacon Proxy Pattern**: Single DarkPool implementation, one proxy per BAMM pool
- **Per-Pool Merkle Trees**: Each DarkPool proxy maintains its own commitment tree
- **UTXO-based notes** with variable amounts and partial spends
- **LP notes** stored as scaled shares with live balance via `liquidityIndex`
- **Optional association sets** for regulatory compliance
- **No dedicated relayer** required (users submit proofs directly)

**Design Goals:**
- Identity privacy via zero-knowledge proofs
- Minimal footprint (single implementation, lightweight proxies)
- Composability with BAMM (tokens + LP positions)
- Beacon upgradability across all pools

**Non-Goals:**
- Amount privacy (transaction amounts remain public)
- Cross-pool atomic mixing (multi-hop in separate txs)
- Stealth addresses (off-chain hints only)

---

## Architecture

### Beacon Proxy Pattern

```
DarkPoolFactory
├─ UpgradeableBeacon → DarkPool Implementation (singleton)
│
├─ DarkPool Proxy 1 → BAMM Pool 1
│  └─ Storage: Merkle Tree, Nullifiers, Root History
│
├─ DarkPool Proxy 2 → BAMM Pool 2
│  └─ Storage: Merkle Tree, Nullifiers, Root History
│
└─ DarkPool Proxy 3 → BAMM Pool 3
   └─ Storage: Merkle Tree, Nullifiers, Root History
```

**Pattern Comparison:**

| Aspect | Beacon (Chosen) | UUPS |
|--------|-----------------|------|
| Upgrade logic | In beacon | In implementation |
| Multi-instance | Efficient | Expensive |
| Deployment cost | ~100k per proxy | ~200k per proxy |
| Upgrade scope | All at once | Per-instance |

**Benefits:**
- Mirrors BAMM architecture (consistency)
- Maximum code reuse (~800kb deployed once)
- Independent per-pool storage
- Unified upgrades via beacon
- Simpler circuits (no `bammPool` field)

---

## Technical Specification

### 1. Note System

#### Note Types

**Token Note:**
```solidity
struct TokenNote {
    address assetId;        // ERC-20 token address
    uint8 noteType;         // 0 = TOKEN
    uint256 value;          // Token amount
    bytes32 ownerPubKey;    // Owner's public key
    bytes32 blinding;       // Random blinding factor
    bytes32 salt;           // Additional randomness
}
```

**LP Note:**
```solidity
struct LPNote {
    address assetId;        // Underlying token (not LP token)
    uint8 noteType;         // 1 = LP
    uint256 scaledShares;   // Scaled LP shares (rebasing via liquidityIndex)
    bytes32 ownerPubKey;    // Owner's public key
    bytes32 blinding;       // Random blinding factor
    bytes32 salt;           // Additional randomness
}
```

**LP Rebasing:** `realLPTokens = (scaledShares * liquidityIndex) / PRECISION`

By storing `scaledShares`, DarkPool captures rebasing value at spend time without updating commitments.

#### Commitment Scheme

```
commitment = Poseidon8(
    chainId, darkPoolAddress, assetId, noteType,
    value, ownerPubKey, blinding, salt
)
```

Domain separation via `chainId` and `darkPoolAddress` prevents replay attacks.

#### Nullifier Scheme

```
nullifier = Poseidon4(
    chainId, darkPoolAddress,
    nullifierSecret, ownerPubKey
)
```

Unique nullifier per note, revealed only when spent. Contract tracks spent nullifiers to prevent double-spending.

#### Poseidon Hash Implementation

**Libraries:** `src/darkpool/libraries/generated/`
- `PoseidonT2.sol` - Hash 1 input
- `PoseidonT3.sol` - Hash 2 inputs (merkle tree)
- `PoseidonT5.sol` - Hash 4 inputs (nullifier)
- `Poseidon.sol` - Wrapper with hash1-8 functions
- `Zeros.sol` - Pre-computed zero values for merkle tree

**Gas Costs:**
- T3 (merkle): ~25k gas
- T5 (nullifier): ~45k gas
- hash8 (commitment): ~95k gas (2× T5 + 1× T3)

---

### 2. Storage Layout

#### EIP-7201 Namespaced Storage

```solidity
// Storage slot: keccak256("darkpool.storage.v1") - 1
struct DarkPoolStorage {
    address bammPool;                          // Associated BAMM pool

    // Merkle Tree State
    uint32 nextLeafIndex;
    bytes32 currentRoot;
    bytes32[ROOT_HISTORY_SIZE] rootHistory;    // Ring buffer
    uint32 rootHistoryIndex;

    // Nullifier Tracking
    mapping(bytes32 => bool) nullifierSpent;

    // Config
    address verifier;                          // Groth16 verifier
    address owner;
    uint8 treeHeight;                          // 32
    uint32 rootHistorySize;                    // 100
    bool paused;
    bool requireASP;

    uint256[40] __gap;                         // Reserved
}
```

**Constants:**
```solidity
uint8 constant TREE_HEIGHT = 32;           // 2^32 = 4.3B leaves
uint32 constant ROOT_HISTORY_SIZE = 100;   // Last 100 roots
uint256 constant PRECISION = 1e18;
uint8 constant NOTE_TYPE_TOKEN = 0;
uint8 constant NOTE_TYPE_LP = 1;
```

#### Merkle Tree

**Incremental Poseidon Tree:**
- Height: 32 (4.3B commitments per pool)
- Hash: Poseidon T3 (binary tree)
- Updates: O(log N) on-chain and off-chain
- Zero values: Pre-computed for empty subtrees

**Root History Ring Buffer:**
Stores last 100 roots to allow:
- Time for proof generation (3-5 seconds)
- Tolerance for blockchain reorgs
- Multiple users proving against same root

---

### 3. Public Interfaces

#### Initialization

```solidity
function initialize(
    address _bammPool,
    address _verifier,
    address _owner
) external initializer;
```

#### Deposit Functions

**Deposit Token:**
```solidity
function depositToken(
    address token,
    uint256 amount,
    bytes32 commitment,
    bytes calldata recipientHint
) external nonReentrant;
```

**Flow:** Transfer token → Insert commitment → Emit events

**Deposit and Mint LP:**
```solidity
function depositAndMintLP(
    address token,
    uint256 amount,
    bytes32 commitment,
    bytes calldata recipientHint
) external nonReentrant;
```

**Flow:** Transfer token → BAMM.deposit() → Compute scaledShares → Insert commitment

#### Core Private Function

**Transact:**
```solidity
function transact(
    Proof calldata proof,
    ExtData calldata extData,
    bytes calldata recipientHints
) external nonReentrant returns (bool);
```

**Proof Structure:**
```solidity
struct Proof {
    uint256[8] groth16Proof;     // Groth16 proof (a, b, c)
    bytes32 merkleRoot;
    bytes32[] nullifiers;        // 2-4 typical
    bytes32 extDataHash;
    bytes32[] outCommitments;    // 2-4 typical
}
```

**ExtData Structure:**
```solidity
struct ExtData {
    uint8 actionType;            // SWAP | LP_DEPOSIT | LP_WITHDRAW | TRANSFER
    address[] assets;
    uint256[] extIn;             // External inputs
    uint256[] extOut;            // External outputs
    address[] receivers;         // Payout addresses (empty = re-shield)
    bytes32 memoHash;
    bytes32 aspRoot;             // Association set (optional)
}
```

**Transact Flow:**
1. Verify Groth16 proof
2. Check `merkleRoot` in `rootHistory`
3. Check `nullifiers` not spent
4. Verify `extDataHash` matches
5. Execute BAMM actions (swap, deposit, withdraw)
6. Mark nullifiers spent
7. Append output commitments
8. Emit events

#### Owner Functions

```solidity
function setPaused(bool _paused) external onlyOwner;
function setRequireASP(bool _requireASP) external onlyOwner;
```

**Note:** Upgrades via `DarkPoolFactory.upgradeTo()` (beacon pattern).

#### View Functions

```solidity
function currentRoot() external view returns (bytes32);
function isSpent(bytes32 nullifier) external view returns (bool);
function isKnownRoot(bytes32 root) external view returns (bool);
function getBammPool() external view returns (address);
```

---

### 4. Events

```solidity
event Deposit(address indexed asset, uint256 amount, bytes32 indexed commitment);
event Transact(bytes32[] nullifiers, bytes32[] outCommitments, bytes32 extDataHash);
event NewCommitment(bytes32 indexed commitment, uint32 leafIndex, bytes recipientHint);
event NewNullifier(bytes32 indexed nullifier);
event NewRoot(bytes32 indexed root, uint32 leafIndex);
```

**Recipient Hints:** Encrypted tags for off-chain recipient discovery (ECDH).

---

### 5. DarkPool Factory

#### Interface

```solidity
interface IDarkPoolFactory {
    function beacon() external view returns (address);
    function createDarkPool(address bammPool, address verifier, address owner)
        external returns (address darkPool);
    function darkPoolForBAMM(address bammPool) external view returns (address);
    function upgradeTo(address newImplementation) external;
}
```

#### Deployment Flow

```solidity
// 1. Deploy implementation (once)
DarkPool implementation = new DarkPool();

// 2. Deploy beacon (once)
UpgradeableBeacon beacon = new UpgradeableBeacon(address(implementation));

// 3. Deploy factory (once)
DarkPoolFactory factory = new DarkPoolFactory(address(beacon));

// 4. Create DarkPool for BAMM
address darkPool = factory.createDarkPool(bammPool, verifier, owner);
```

---

### 6. Circuit Specification

#### JoinSplit Circuit (Circom)

```circom
template JoinSplit(nInputs, nOutputs, treeDepth) {
    // Public inputs
    signal input merkleRoot;
    signal input nullifiers[nInputs];
    signal input extDataHash;
    signal input aspRoot;

    // Private inputs
    signal input inputNotes[nInputs][8];      // [assetId, noteType, value, ownerKey, blinding, salt, pathBits, secret]
    signal input inputPaths[nInputs][treeDepth];
    signal input outputNotes[nOutputs][6];    // [assetId, noteType, value, ownerKey, blinding, salt]
    signal input extInAmounts[MAX_ASSETS];
    signal input extOutAmounts[MAX_ASSETS];

    // Constraints:
    // 1. Merkle inclusion
    // 2. Nullifier computation
    // 3. Per-asset value conservation
    // 4. Output commitment generation
    // 5. ExtDataHash binding
    // 6. (Optional) Association set membership
}
```

**Circuit Parameters:**
- `nInputs`: 2-4
- `nOutputs`: 2-4
- `treeDepth`: 32
- `MAX_ASSETS`: 4

**Complexity:**
- **2×2:** ~45k constraints, 2-4s proving time
- **4×4:** ~110k constraints
- Proof size: 128 bytes (Groth16)

---

### 7. BAMM Integration

#### LP Token Accounting

**BAMM Scaled Share System:**
```solidity
lpTokens = (amountAfterFee * totalScaledSupply * PRECISION) / (reserves * liquidityIndex);
scaledAmount = (lpTokens * PRECISION) / liquidityIndex;
```

**DarkPool Integration:**
```solidity
function _computeLPTokens(address token, uint256 scaledShares)
    internal view returns (uint256) {
    IBAMM.LPState memory lpState = IBAMM(bammPool).lpStates(token);
    return (scaledShares * lpState.liquidityIndex) / PRECISION;
}
```

**Critical:** Read `liquidityIndex` before external calls that trigger fee accrual.

#### Interaction Patterns

**Private LP Deposit:**
```
Spend token note(s) → DarkPool.approve(bamm) → IBAMM.deposit()
→ scaledShares = (lpTokens * PRECISION) / liquidityIndex
→ Append LP commitment
```

**Private LP Withdraw:**
```
Spend LP note(s) → Read liquidityIndex
→ lpTokens = (scaledShares * liquidityIndex) / PRECISION
→ IBAMM.withdraw() → Re-shield or transfer
```

**Private Swap:**
```
Spend token note(s) → DarkPool.approve(bamm)
→ IBAMM.swap() → Re-shield or transfer
```

---

## Privacy Model

### Anonymity Workflow

**1. Deposit (Public → Private)**
- User generates note secrets off-chain (ownerKey, blinding, salt, nullifierSecret)
- Computes commitment: `Poseidon8(chainId, darkPool, assetId, noteType, value, ownerKey, blinding, salt)`
- Calls `depositToken()` with commitment
- Identity now unlinkable from commitment

**2. Wait for Anonymity Set**
- Best practice: Wait for 100+ deposits before spending
- Prevents timing analysis linking deposit → spend

**3. Build Private Transaction**
- Fetch merkle tree state and proof for note
- Create output notes (change + recipient)
- Prepare external data (swap params, receivers)
- Generate zkSNARK proof (2-5 seconds)

**4. Submit Transaction**
- Call `transact()` with proof + extData
- Contract verifies proof, checks nullifiers, executes BAMM actions
- Inserts output commitments into tree

**5. Recipient Discovery**
- Recipients monitor `NewCommitment` events
- Decrypt recipient hints with private key
- Verify commitment matches expected note data

### Privacy Guarantees

**What DarkPool Hides:**
- Sender identity (cannot link deposit address to spend)
- Recipient identity (only encrypted hints)
- Note linkage (cannot link inputs to outputs)
- Transaction graph (no "taint" tracking)

**What DarkPool Reveals:**
- Total transaction amounts (necessary for AMM)
- Action types (SWAP, TRANSFER, LP_DEPOSIT, LP_WITHDRAW)
- Timing (block number of deposit/spend)
- Asset types (tokens involved)

### Best Practices

**Depositors:** Fresh addresses, varied amounts, wait 24-48h before spending
**Spenders:** Wait for anonymity set ≥100, use relayers, vary amounts
**Recipients:** Unique owner keys per note, re-shield before public withdrawal
**LP Providers:** Deposit via DarkPool, avoid timing correlation

### Attack Mitigations

| Attack | Mitigation | Result |
|--------|-----------|--------|
| Timing analysis | Wait for anonymity set, random delays | <1% correlation |
| Amount analysis | Vary amounts, split/combine notes | Reduced with large set |
| IP correlation | Relayers, Tor, VPN | No on-chain linkage |
| Sybil deposits | Wait for organic growth | Economically expensive |
| Trusted setup compromise | Multi-party ceremony | Requires ALL malicious |

---

## Gas Costs

### Verification Overhead

**Groth16 on BN254:**
```
Base verification:     ~200k gas
Per public input:      ~7.1k gas

Typical (2 inputs, 2 outputs):
├─ merkleRoot           7.1k
├─ nullifier[0]         7.1k
├─ nullifier[1]         7.1k
├─ extDataHash          7.1k
Total:                ~235k gas
```

### Per-Operation Costs

| Operation | Cost | Breakdown |
|-----------|------|-----------|
| **Private Token Deposit** | ~97k | Transfer (50k) + Merkle (42k) + Events (5k) |
| **Private Swap** | ~493k | Proof (235k) + Root (2k) + Nullifiers (42k) + BAMM (120k) + Merkle (84k) + Events (10k) |
| **Private LP Deposit** | ~513k | Proof (235k) + Nullifiers (42k) + BAMM (150k) + LP read (2k) + Merkle (84k) |

**Privacy Premium:** ~3.3× (493k vs 150k for public swap)

### Deployment Costs

```
DarkPool implementation (once):    ~3M gas
UpgradeableBeacon (once):          ~200k gas
DarkPoolFactory (once):            ~500k gas

Per BAMM Pool:
├─ Deploy beacon proxy:            ~100k gas
├─ Initialize:                     ~150k gas
└─ Total per pool:                 ~250k gas
```

**Beacon Savings:** 10 pools = 2.5M gas (vs 25M for 10 UUPS proxies)

---

## Security Considerations

### 1. Double-Spend Prevention

Nullifier tracking via `mapping(bytes32 => bool) nullifierSpent`. Each note has unique nullifier tied to `nullifierSecret` (never revealed).

### 2. Front-Running Protection

ExtData hash binding prevents modification of:
- Swap amounts
- Receivers
- Slippage limits

### 3. Reentrancy Protection

All external calls within `nonReentrant` guard. Read `liquidityIndex` before external calls.

### 4. Cross-Pool Isolation

Each proxy has:
- Separate merkle tree (cannot spend notes from other pools)
- Separate nullifier set (cross-pool double-spend impossible)
- Separate root history

### 5. Domain Separation

`chainId` and `darkPoolAddress` in commitments/nullifiers prevent replay:
- Across chains (different `chainId`)
- Across proxies (different `darkPoolAddress`)

---

## Compliance: Association Sets

**Association Sets** enable users to prove funds originated from legitimate sources without revealing transaction history (Vitalik's Privacy Pools paper, 2023).

### Architecture

```
Association Set Provider (ASP)
├─ Maintains whitelist: {cm1, cm2, ..., cmN}
├─ Publishes merkle root: aspRoot
└─ DarkPool verifies proofs include aspRoot
```

### Circuit Integration

```circom
signal input aspRoot;  // Association set root

if (aspRoot != 0) {
    for (i = 0; i < nInputs; i++) {
        // Prove input commitment in approved set
        signal aspPathRoot = MerkleProof(ASP_DEPTH)(inputCommitments[i], aspPaths[i]);
        aspPathRoot === aspRoot;
    }
}
```

### Configuration

**Default:** `requireASP = false`

**Enable per-pool:**
```solidity
darkPool.setRequireASP(true);
darkPool.setApprovedASPRoot(aspRoot);
```

**Use Cases:** Regulated markets, jurisdictional compliance, voluntary signaling

---

## Upgradeability

### Beacon Pattern (ERC-1967)

**Beacon Advantages:**
- Multiple instances efficiently managed
- All pools upgrade simultaneously
- Lowest per-instance deployment cost
- Consistent with BAMM architecture

### Implementation

**Beacon (Solady):**
```solidity
UpgradeableBeacon beacon = new UpgradeableBeacon(implementation, owner);
```

**Proxy Deployment:**
```solidity
address proxy = LibClone.deployERC1967BeaconProxy(address(beacon));
DarkPool(proxy).initialize(bammPool, verifier, owner);
```

**Upgrade Process:**
```solidity
DarkPoolV2 newImpl = new DarkPoolV2();
beacon.upgradeTo(address(newImpl));  // All proxies now use V2
```

### Storage Layout Rules

1. Never reorder existing fields
2. Never change types
3. Only append new fields
4. Use storage gap for future expansion

---

## Future Optimizations

### V1: Current (Poseidon)

**Stack:**
- Poseidon (2019) for circuits + Solidity
- ~240 constraints per hash (Groth16)
- ~25k gas per hash (T3)
- Battle-tested (Tornado Cash, Semaphore)

**Gas Breakdown:**
```
Total per private swap: ~500k gas
├─ Groth16 verification:  235k (47%)
├─ Merkle hashing:         50k (10%)
├─ Nullifier:              45k (9%)
├─ BAMM operations:       120k (24%)
└─ Other:                  50k (10%)
```

### V2: Poseidon2 Migration (6-12 months)

**Performance Gains:**
- 40% lower gas for hash ops (15k vs 25k)
- Same constraints for Groth16
- Same proving time
- **Total: ~500k → ~462k (-7.6%)**

**Migration via Beacon:**
1. Deploy Poseidon2 Solidity + circuits
2. Run trusted setup
3. Deploy DarkPool V2 implementation
4. Upgrade beacon → All proxies use V2
5. Update frontend SDK

**Why Not Launch with Poseidon2?**
- Not in official circomlib yet (PR #98 pending)
- Limited production usage
- Poseidon has 5+ years battle-testing
- Time to market: Ships today vs 6-10 weeks delay

### V3+: Advanced (18+ months)

**Potential:**
- Proof systems: PLONK/Plonky2 (no trusted setup), FRI (post-quantum)
- Hash functions: Poseidon3, Neptune
- Circuit optimizations: 4×4 inputs/outputs, native multi-asset
- EVM precompiles: Poseidon precompile, native zkSNARK opcodes (10× gas reduction)

**Technology Watchlist:**
- [circomlib PR #98](https://github.com/iden3/circomlib/pull/98) - Poseidon2
- [zemse/poseidon2-evm](https://github.com/zemse/poseidon2-evm) - Huff implementation
- [Poseidon2 Paper](https://eprint.iacr.org/2023/323.pdf) - Cryptanalysis
- [zkSNARK Benchmarks](https://arxiv.org/abs/2409.01976) - Performance data

---

## Cross-Pool Privacy

While each DarkPool serves one BAMM, users can achieve cross-pool privacy via multi-step flows:

**Example: USDC → WETH**
```
1. DarkPoolA.transact() → Withdraw USDC to fresh address X
2. Address X swaps USDC → WETH on BAMM
3. DarkPoolB.depositToken() → Shield WETH

Total: 3 transactions, 2 DarkPools
Privacy: USDC depositor unlinkable from WETH recipient
```

**Trade-off:** More transactions vs simpler implementation + better gas per pool

---

## Privacy Protocol Comparison

### Overview

This section compares DarkPool with major privacy solutions in the ecosystem: Tornado Cash (original + Nova), Privacy Pools (0xbow.io), and Railgun.

### Comparison Matrix

| Aspect | **DarkPool** | **Tornado Cash (Original)** | **Tornado Cash Nova** | **Privacy Pools (0xbow)** | **Railgun** |
|--------|--------------|----------------------------|----------------------|---------------------------|-------------|
| **Launch Status** | In development | Sanctioned (Aug 2022) | Experimental (Dec 2021) | Live (March 2025) | Live (2021+) |
| **Network** | Ethereum (any EVM) | Ethereum mainnet | Gnosis Chain (L2) | Ethereum + Gnosis | Ethereum, Polygon, Arbitrum, BSC |
| **Amount Model** | Variable (UTXO) | Fixed denominations | Variable (UTXO) | Fixed range (0.1-1 ETH) | Variable (UTXO) |
| **Use Case** | BAMM-specific privacy | General mixing | General mixing + transfers | General mixing + compliance | Universal DeFi privacy |

### Technical Architecture

| Aspect | **DarkPool** | **Tornado Cash** | **Tornado Cash Nova** | **Privacy Pools** | **Railgun** |
|--------|--------------|------------------|----------------------|-------------------|-------------|
| **Proof System** | Groth16 | Groth16 | Groth16 | Groth16 | Groth16 |
| **Hash Function** | Poseidon (T3, T5, T8) | Pedersen | Poseidon | Poseidon | Poseidon (T3) |
| **Merkle Tree** | Incremental Poseidon (height 32) | Pedersen (height 20) | Poseidon | Poseidon | Batch Incremental Poseidon |
| **Circuit Count** | 1-2 (2×2, 4×4) | 1 per denomination | 2 (2×2, 16×2) | 1 | 54 (all I/O combinations) |
| **Circuit Constraints** | ~45k (2×2) | ~30k | ~28k base | Unknown | Varies by circuit |
| **Proving Time** | 2-4 seconds | 5-10 seconds | Similar | Unknown | 20-30 seconds (slower devices) |
| **UTXO Model** | Yes (notes) | No | Yes | No (single pool) | Yes (encrypted UTXOs) |
| **Nullifiers** | Yes (Poseidon4) | Yes | Yes | Yes | Yes |
| **Deployment Pattern** | Beacon proxy per pool | Contract per denomination | Single contract | Single contract | Monolithic + AdaptRelay |

### Gas Costs (Ethereum Mainnet)

| Operation | **DarkPool** | **Tornado Cash** | **Tornado Cash Nova** | **Privacy Pools** | **Railgun** |
|-----------|--------------|------------------|----------------------|-------------------|-------------|
| **Deposit/Shield** | ~97k gas | ~1M gas (~0.05-0.1 ETH @ 50-100 gwei) | Lower (on Gnosis L2) | Unknown (mainnet) | ~150-200k gas (est.) |
| **Private Swap** | ~493k gas | N/A | N/A | N/A | ~600-700k gas (est.) |
| **Withdraw/Unshield** | ~300k gas (est.) | ~400k gas (~0.02-0.04 ETH @ 50-100 gwei) | Lower (on Gnosis L2) | Unknown (mainnet) | ~300-400k gas (est.) |
| **Private Transfer** | ~450k gas (est.) | N/A | ~300-400k gas (Gnosis) | Unknown | ~400-500k gas (est.) |
| **Privacy Premium** | 3.3× vs public swap | N/A (pure mixer) | N/A (pure mixer) | N/A (pure mixer) | ~4-5× vs public tx |

**Note:** Tornado Cash Nova operates on Gnosis Chain with significantly lower gas costs (~10-20× cheaper), but requires bridge transactions.

### Protocol Fees

| Protocol | **Shield/Deposit Fee** | **Unshield/Withdraw Fee** | **Relayer Fee** | **Other Fees** |
|----------|----------------------|--------------------------|----------------|----------------|
| **DarkPool** | 0% (gas only) | 0% (gas only) | Optional (user-chosen) | 0% |
| **Tornado Cash** | 0% | 0% | 0.05%-0.2% | 0% |
| **Tornado Cash Nova** | 0% | 0% | Variable (low relayer count) | 0% |
| **Privacy Pools** | 0% (gas only) | 0% (gas only) | Optional | ASP verification fee (unknown) |
| **Railgun** | 0.25% | 0.25% | ~10% gas premium | 0% |

**Cost Comparison Example (1 ETH transaction on Ethereum @ 50 gwei):**

```
DarkPool (private swap):
├─ Gas: 493k × 50 gwei = 0.0247 ETH (~$62 @ $2500 ETH)
├─ Protocol fee: 0 ETH
└─ Total: 0.0247 ETH ($62)

Tornado Cash (deposit + withdraw):
├─ Gas: 1.4M × 50 gwei = 0.07 ETH (~$175 @ $2500 ETH)
├─ Relayer fee: ~0.001 ETH (0.1%)
└─ Total: 0.071 ETH ($177.50)

Privacy Pools:
├─ Gas: Unknown (similar to Tornado)
├─ ASP fee: Unknown
└─ Total: Unknown

Railgun (shield + swap + unshield):
├─ Gas: ~1M × 50 gwei = 0.05 ETH (~$125 @ $2500 ETH)
├─ Protocol fee: 0.005 ETH (0.25% × 2 operations)
├─ Relayer fee: 0.005 ETH (~10% premium on gas)
└─ Total: 0.06 ETH ($150)
```

### Deployment Costs

| Protocol | **Initial Deployment** | **Per-Instance Cost** | **Upgrade Mechanism** | **Total for 10 Pools** |
|----------|----------------------|---------------------|----------------------|----------------------|
| **DarkPool** | ~3.7M gas (impl + beacon + factory) | ~250k gas per pool | Beacon (all at once) | ~6.2M gas |
| **Tornado Cash** | ~2M gas per denomination | N/A (fixed pools) | Not upgradeable | ~20M+ gas (10 denoms) |
| **Tornado Cash Nova** | ~3M gas (est.) | N/A (single pool) | Not upgradeable | ~3M gas |
| **Privacy Pools** | ~3M gas (est.) | N/A (single pool) | Unknown | ~3M gas |
| **Railgun** | ~5M gas (monolithic + relay) | N/A (single global) | Governance upgrade | ~5M gas |

**DarkPool Advantage:** Beacon pattern enables efficient multi-pool deployment with unified upgrades.

### Anonymity Set

| Protocol | **Anonymity Set Model** | **Typical Size** | **Current Statistics** | **Cross-Asset Mixing** |
|----------|------------------------|----------------|----------------------|----------------------|
| **DarkPool** | Per-pool | 100-1,000 users | N/A (not launched) | Via multi-hop (separate txs) |
| **Tornado Cash** | Per-denomination | Varies by pool | 100 ETH pool: ~5,800 deposits (pre-sanction) | No (separate pools) |
| **Tornado Cash Nova** | Single global pool | Unknown (experimental) | Low (experimental status) | Yes (within pool) |
| **Privacy Pools** | Single pool + ASP filtering | Unknown (new) | Unknown (launched March 2025) | Unknown |
| **Railgun** | Single global pool | Large (cross-chain) | ~$90M TVL (Dec 2024) | Yes (any asset) |

**Anonymity Set Trade-offs:**

```
Global Pool (Railgun):
✅ Larger anonymity set (~1000s users)
✅ Cross-asset mixing
❌ Single point of failure
❌ Harder to isolate compromised funds

Per-Pool (DarkPool):
✅ Isolated risk per pool
✅ BAMM-specific optimizations
✅ Easier regulatory compliance
❌ Smaller anonymity set (~100-1k users per pool)
❌ Multi-hop for cross-pool privacy

Per-Denomination (Tornado):
✅ Strong amount privacy (fixed denoms)
✅ Proven track record
❌ Fragmented liquidity
❌ Amount constraints limit usability
```

### Privacy Properties

| Feature | **DarkPool** | **Tornado Cash** | **Tornado Cash Nova** | **Privacy Pools** | **Railgun** |
|---------|--------------|------------------|----------------------|-------------------|-------------|
| **Sender Anonymity** | ✅ Full | ✅ Full | ✅ Full | ✅ Full | ✅ Full |
| **Recipient Anonymity** | ✅ Full (hints) | ✅ Full | ✅ Full (UTXO) | ✅ Full | ✅ Full (stealth) |
| **Amount Privacy** | ❌ Public totals | ✅ Full (fixed denoms) | ❌ Public totals | ❌ Public totals | ❌ Public totals |
| **Timing Privacy** | ⚠️ Mitigated (wait for set) | ⚠️ Mitigated | ⚠️ Mitigated | ⚠️ Mitigated | ⚠️ Mitigated |
| **Asset Privacy** | ❌ Public | ❌ Public (per pool) | ❌ Public | ❌ Public | ✅ Cross-asset within pool |
| **Compliance** | ✅ Optional ASP | ❌ None | ❌ None | ✅ Mandatory ASP | ✅ Optional PoI |

**Legend:** ✅ Supported | ❌ Not supported | ⚠️ Partially supported

### DeFi Integration

| Capability | **DarkPool** | **Tornado Cash** | **Tornado Cash Nova** | **Privacy Pools** | **Railgun** |
|------------|--------------|------------------|----------------------|-------------------|-------------|
| **Private Swaps** | ✅ Direct BAMM | ❌ Must exit/re-enter | ❌ Must exit/re-enter | ❌ Must exit/re-enter | ✅ Via Adapt Modules |
| **Private LP** | ✅ Native (scaledShares) | ❌ No | ❌ No | ❌ No | ✅ Via cross-contract |
| **Universal DeFi** | ❌ BAMM only | ❌ No | ❌ No | ❌ No | ✅ Any protocol |
| **Atomic Composability** | ✅ Single tx | N/A | N/A | N/A | ✅ Single tx (multi-call) |
| **External Protocol Support** | ❌ BAMM only | ❌ Pure mixer | ❌ Pure mixer | ❌ Pure mixer | ✅ Universal |

### Compliance Features

| Feature | **DarkPool** | **Tornado Cash** | **Tornado Cash Nova** | **Privacy Pools** | **Railgun** |
|---------|--------------|------------------|----------------------|-------------------|-------------|
| **Association Sets** | ✅ Optional (per-pool) | ❌ None | ❌ None | ✅ Mandatory | ✅ Optional (PoI) |
| **Regulatory Mode** | ✅ Toggle per pool | ❌ No | ❌ No | ✅ Built-in | ✅ Optional |
| **Sanctions Screening** | ✅ Via ASP | ❌ No | ❌ No | ✅ Via ASP | ✅ Via PoI |
| **Audit Trail** | ⚠️ Via proof of origin | ❌ No | ❌ No | ✅ Full | ✅ Via PoI |
| **Legal Status** | ✅ Compliant-by-design | ❌ Sanctioned (US) | ❌ Sanctioned (US) | ✅ Compliant | ✅ Compliant |

### Strengths and Weaknesses

**DarkPool:**
```
Strengths:
✅ BAMM-specific optimizations (LP rebasing, coverage ratio)
✅ Lower gas than universal solutions (~493k vs ~700k)
✅ Beacon upgradability across all pools
✅ Optional compliance (ASP) without sacrificing privacy
✅ No protocol fees (just gas)
✅ Per-pool risk isolation

Weaknesses:
❌ BAMM-only (not universal DeFi)
❌ Smaller anonymity sets per pool vs global
❌ Multi-hop required for cross-pool privacy
❌ Amount privacy not supported
❌ Requires circuit development (not live yet)
```

**Tornado Cash (Original):**
```
Strengths:
✅ Battle-tested (5+ years)
✅ Strong amount privacy (fixed denominations)
✅ Proven anonymity model
✅ No protocol fees

Weaknesses:
❌ Sanctioned (unusable in US/compliant jurisdictions)
❌ Very high gas costs (~1M deposit, ~400k withdraw)
❌ Fixed denominations limit flexibility
❌ No DeFi composability
❌ Fragmented liquidity across pools
```

**Tornado Cash Nova:**
```
Strengths:
✅ Variable amounts (more flexible)
✅ Internal transfers (stay shielded)
✅ L2 deployment (lower gas)
✅ UTXO model

Weaknesses:
❌ Sanctioned (unusable in US/compliant jurisdictions)
❌ Experimental (low relayer count, bridge issues)
❌ L2 bridge adds complexity/risk
❌ Small anonymity set
❌ No DeFi composability
```

**Privacy Pools (0xbow.io):**
```
Strengths:
✅ Vitalik Buterin endorsed
✅ Compliant-by-design (ASP mandatory)
✅ Live on mainnet (March 2025)
✅ Trusted setup with 514 contributors
✅ Legal to use in US

Weaknesses:
❌ Very new (limited track record)
❌ Unknown gas costs (likely similar to Tornado)
❌ Mandatory ASP may reduce anonymity set
❌ 1 ETH deposit cap initially
❌ No DeFi composability
❌ Limited documentation
```

**Railgun:**
```
Strengths:
✅ Universal DeFi support (any protocol)
✅ 54 circuits (maximum flexibility)
✅ Large global anonymity set (~$90M TVL)
✅ Multi-chain deployment
✅ Proven traction (Vitalik uses it)
✅ Optional compliance (Proof of Innocence)
✅ Active development (v3 coming)

Weaknesses:
❌ Higher gas costs (~600-700k for swaps)
❌ 0.25% protocol fee + 10% relayer fee
❌ Complex architecture (harder to audit)
❌ Slower proof generation (20-30s on slow devices)
❌ Must support ALL DeFi patterns (generic)
❌ Single point of failure (monolithic)
```

### Use Case Fit

**When to use DarkPool:**
- You're trading on BAMM specifically
- You want lowest gas costs for BAMM operations
- You want per-pool privacy (isolated risk)
- You need LP rebasing support
- Compliance is important (optional ASP)

**When to use Tornado Cash:**
- You can't (sanctioned in most jurisdictions)
- You need strong amount privacy (if legal)
- You're willing to pay high gas costs

**When to use Privacy Pools (0xbow):**
- You need compliant privacy on Ethereum
- You're okay with ASP screening
- Simple mixing is sufficient (no DeFi)
- You want Vitalik-endorsed solution

**When to use Railgun:**
- You need privacy across multiple DeFi protocols
- You're okay with 0.25% fees + 10% relayer premium
- You want largest anonymity set
- You need multi-chain support
- You're doing complex DeFi operations

### Competitive Position

**DarkPool's Niche:**
```
DarkPool occupies a unique position as:

1. Domain-Specific Privacy Layer
   - Only solution optimized for BAMM
   - Understands LP rebasing, coverage ratio, BAMM fees
   - Lower gas than universal solutions

2. Compliance-Ready
   - Optional ASP (not mandatory like 0xbow)
   - Per-pool isolation (easier to manage risk)
   - Legal to deploy and use

3. Efficient Architecture
   - Beacon pattern: lowest per-pool deployment cost
   - Direct integration: no adapter overhead
   - Upgradeable: all pools get fixes simultaneously

DarkPool competes with:
- Railgun (for DeFi privacy) → DarkPool wins on gas + BAMM specificity
- Privacy Pools (for compliant privacy) → DarkPool wins on flexibility + DeFi
- Tornado (if unsanctioned) → DarkPool wins on usability + legality
```

### Conclusion

**DarkPool is best-in-class for BAMM-specific privacy:**
- 40% lower gas than Railgun for swaps (493k vs 700k)
- No protocol fees (vs Railgun's 0.25% + 10%)
- Native BAMM integration (LP rebasing, coverage ratio)
- Beacon upgradability (vs monolithic Railgun)
- Optional compliance (vs mandatory in Privacy Pools)

**Trade-off: Domain specificity for efficiency**
- DarkPool sacrifices universal DeFi support for BAMM optimizations
- Acceptable trade-off: users needing universal privacy use Railgun
- Users trading on BAMM get best experience with DarkPool

---

## Architecture Comparison

| Aspect | Beacon Proxy (Chosen) | Single Contract |
|--------|-----------------------|-----------------|
| Bytecode Reuse | ✅ One implementation | ✅ One contract |
| Per-Pool Trees | ✅ Isolated | ❌ Single large tree |
| Anonymity Set | Pool-specific (~100-1k) | Global (~10k+) |
| Cross-Pool Mixing | Multi-step (3 txs) | Single tx |
| Deployment Cost | ~250k per pool | ~3M once |
| Circuit Complexity | Simpler (no bammPool field) | More complex |
| Architecture Consistency | ✅ Mirrors BAMM | ❌ Different pattern |

**Winner: Beacon Proxy** - Best balance of code reuse, consistency, and simplicity

---

## References

### Standards
- [EIP-1967: Proxy Storage Slots](https://eips.ethereum.org/EIPS/eip-1967)
- [EIP-1822: UUPS Proxy](https://eips.ethereum.org/EIPS/eip-1822)

### Privacy Pools
- [Tornado Cash Nova](https://github.com/tornadocash/tornado-nova)
- [Privacy Pools Paper](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4563364)
- [0xbow.io Launch](https://cointelegraph.com/news/privacy-pools-launches-ethereum-support-vitalik-buterin)

### zkSNARKs
- [Groth16 Paper](https://eprint.iacr.org/2016/260)
- [Circom Documentation](https://docs.circom.io/)
- [snarkjs](https://github.com/iden3/snarkjs)
- [Poseidon Hash](https://www.poseidon-hash.info/)

### Implementation
- [Solady Beacon Proxy](https://github.com/Vectorized/solady/blob/main/src/utils/UpgradeableBeacon.sol)
- [Tornado Cash Circuits](https://github.com/tornadocash/tornado-core/tree/master/circuits)

---

*DarkPool Specification v2.1*
*Architecture: Beacon Proxy Pattern*
*Last Updated: 2025-11-12*
*Status: Draft*
