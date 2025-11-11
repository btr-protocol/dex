# DarkPool: Privacy-Preserving Trading for BAMM

## Overview

**DarkPool** is a zkSNARK-based privacy layer enabling anonymous trading and liquidity provisioning for BAMM pools. Built on Groth16 proofs, Poseidon commitments, and UTXO-style note accounting, DarkPool provides identity privacy while maintaining public transaction amounts for transparency.

**Core Design:**
- **Beacon Proxy Pattern**: Single DarkPool implementation, one proxy per BAMM pool (mirrors BAMM architecture)
- **Per-Pool Merkle Trees**: Each DarkPool proxy maintains its own commitment tree
- **UTXO-based notes** with variable amounts and partial spends
- **LP notes** stored as scaled shares with live balance via `liquidityIndex`
- **Optional association sets** for regulatory compliance
- **No dedicated relayer** required (users submit proofs directly)

---

## Architecture

### Beacon Proxy Pattern (Consistent with BAMM)

```
DarkPoolFactory
├─ UpgradeableBeacon
│  └─ Points to: DarkPool Implementation (singleton bytecode)
│
├─ Deploy DarkPool Proxy 1 → for BAMM Pool 1
│  └─ Storage: Merkle Tree, Nullifiers, Root History (BAMM Pool 1)
│
├─ Deploy DarkPool Proxy 2 → for BAMM Pool 2
│  └─ Storage: Merkle Tree, Nullifiers, Root History (BAMM Pool 2)
│
└─ Deploy DarkPool Proxy 3 → for BAMM Pool 3
   └─ Storage: Merkle Tree, Nullifiers, Root History (BAMM Pool 3)

All proxies delegatecall to same DarkPool implementation
```

**Comparison with BAMM:**

| BAMM Pattern | DarkPool Pattern |
|--------------|------------------|
| BAMMFactory deploys beacon | DarkPoolFactory deploys beacon |
| BAMMFactory.createPool() → Beacon proxy | DarkPoolFactory.createDarkPool(bamm) → Beacon proxy |
| Each BAMM proxy has own reserves/LPs | Each DarkPool proxy has own merkle tree/nullifiers |
| Upgrade all pools via beacon.upgradeTo() | Upgrade all DarkPools via beacon.upgradeTo() |

**Key Benefits:**
1. **Architectural Consistency**: Mirrors BAMM design users already understand
2. **Maximum Code Reuse**: Single implementation bytecode for all pools (~800kb deployed once)
3. **Independent Storage**: Each pool's privacy set is isolated
4. **Unified Upgrades**: Update all DarkPools simultaneously via beacon
5. **Gas Efficiency**: Beacon proxy is cheaper than UUPS for multiple instances
6. **Simpler Circuits**: No `bammPool` field needed (proxy address identifies pool)

---

## Design Goals

### Primary Objectives
1. **Identity Privacy**: Hide depositor/spender linkage via zero-knowledge proofs
2. **Minimal Footprint**: Single implementation, lightweight proxies (maximum code reuse)
3. **Composability**: Support tokens and LP positions with unified note system
4. **Partial Spends**: Allow variable-amount withdrawals for better obfuscation
5. **Upgradeability**: Beacon pattern for protocol improvements across all pools
6. **Optional Compliance**: Association sets for regulatory requirements (disabled by default)

### Non-Goals
- **Amount Privacy**: Transaction amounts remain public (reduces proof complexity)
- **Cross-Pool Atomic Mixing**: Users trade within each pool's anonymity set (can multi-hop across DarkPools in separate txs)
- **Stealth Addresses**: No ERC-5564 implementation (recipients use off-chain hints)
- **Dedicated Relayer**: Users submit transactions directly (lower complexity)

---

## Technical Specification

### 1. Note System

#### Note Types

**Token Note:**
```solidity
struct TokenNote {
    address assetId;        // ERC-20 token address
    uint8 noteType;         // 0 = TOKEN
    uint256 value;          // Token amount (e.g., 1000e6 USDC)
    bytes32 ownerPubKey;    // Owner's public key
    bytes32 blinding;       // Random blinding factor
    bytes32 salt;           // Additional randomness
}
```

**LP Note:**
```solidity
struct LPNote {
    address assetId;        // Underlying token (not LP token address)
    uint8 noteType;         // 1 = LP
    uint256 scaledShares;   // Scaled LP shares (rebasing tracked via liquidityIndex)
    bytes32 ownerPubKey;    // Owner's public key
    bytes32 blinding;       // Random blinding factor
    bytes32 salt;           // Additional randomness
}
```

**Note:** No `bammPool` field needed since each DarkPool proxy serves exactly one BAMM pool.

**Why Scaled Shares for LP Notes?**

BAMM uses rebasing LP tokens where value accrues via `liquidityIndex`:

```
realLPTokens = (scaledShares * liquidityIndex) / PRECISION

Example:
- Deposit 1000 USDC at liquidityIndex = 1.0e18
- Receive 950 scaledShares (after fees)
- Fees accrue, liquidityIndex grows to 1.05e18
- Withdraw: (950 * 1.05e18) / 1e18 = 997.5 LP tokens
- Worth ~1050 USDC (5% yield)
```

By storing `scaledShares` in the note commitment, DarkPool captures the current rebasing value at spend time without updating commitments.

#### Commitment Scheme

**Poseidon Hash** (zkSNARK-friendly):

```
commitment = Poseidon(
    chainId,           // Chain-specific (prevents replay)
    darkPoolAddress,   // Proxy address (identifies pool)
    assetId,           // Token address
    noteType,          // TOKEN(0) or LP(1)
    value,             // Token amount or scaledShares
    ownerPubKey,       // Public key commitment
    blinding,          // Random factor
    salt               // Additional randomness
)
```

**Domain Separation:** Including `chainId` and `darkPoolAddress` (proxy address) prevents cross-chain and cross-pool replay attacks.

#### Nullifier Scheme

**Prevents Double-Spending:**

```
nullifier = Poseidon(
    chainId,
    darkPoolAddress,   // Proxy address
    nullifierSecret,   // Secret known only to owner (never revealed)
    ownerPubKey        // Ties nullifier to commitment
)
```

Each note has a unique nullifier revealed only when spent. Contract marks nullifiers as spent to prevent reuse.

#### Poseidon Hash Implementation

**Generated Solidity Library:**

The DarkPool uses production-ready Poseidon hash implementations from the `poseidon-solidity` package:

**Location:** `src/darkpool/libraries/generated/`
- `PoseidonT2.sol` - Hash 1 input
- `PoseidonT3.sol` - Hash 2 inputs (merkle tree)
- `PoseidonT4.sol` - Hash 3 inputs
- `PoseidonT5.sol` - Hash 4 inputs (nullifier)
- `PoseidonT6.sol` - Hash 5 inputs
- `Poseidon.sol` - Wrapper library with convenient functions
- `Zeros.sol` - Pre-computed zero values for merkle tree

**Wrapper Functions (Poseidon.sol):**
```solidity
library Poseidon {
    // Core hash functions
    function hash1(uint256 input) internal pure returns (uint256);
    function hash2(uint256 left, uint256 right) internal pure returns (uint256);
    function hash3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256);
    function hash4(uint256 a, uint256 b, uint256 c, uint256 d) internal pure returns (uint256);
    function hash5(uint256 a, uint256 b, uint256 c, uint256 d, uint256 e) internal pure returns (uint256);

    // Nested approach for commitments (8 inputs)
    function hash8(
        uint256 a, uint256 b, uint256 c, uint256 d,
        uint256 e, uint256 f, uint256 g, uint256 h
    ) internal pure returns (uint256);
    // Implementation: hash2(hash4(a,b,c,d), hash4(e,f,g,h))
}
```

**Active Usage in DarkPool:**
- `hash2`: Merkle tree binary hashing (LibMerkleTree.sol)
- `hash4`: Nullifier computation (4 fields: chainId, darkPool, secret, ownerKey)
- `hash8`: Commitment generation (8 fields: chainId, darkPool, assetId, noteType, value, ownerKey, blinding, salt)

**Available for Future Extensions:**
- `hash1`: Single-field operations
- `hash3`: Triple-field operations
- `hash5`: Five-field operations

**Gas Costs:**
- T3 (2 inputs): ~25k gas
- T5 (4 inputs): ~45k gas
- Nested hash8: ~95k gas (2× hash4 + 1× hash2)

---

### 2. Storage Layout

#### EIP-7201 Namespaced Storage (Per Proxy)

```solidity
// Storage slot: keccak256("darkpool.storage.v1") - 1
struct DarkPoolStorage {
    // Associated BAMM Pool
    address bammPool;                          // The BAMM pool this DarkPool serves

    // Merkle Tree State (per-pool)
    uint32 nextLeafIndex;                      // Next available leaf position
    bytes32 currentRoot;                       // Current tree root
    bytes32[ROOT_HISTORY_SIZE] rootHistory;    // Ring buffer of recent roots
    uint32 rootHistoryIndex;                   // Current position in ring buffer

    // Nullifier Tracking (per-pool)
    mapping(bytes32 => bool) nullifierSpent;   // Prevent double-spends

    // Verifier & Config
    address verifier;                          // Groth16 verifier contract
    address admin;                             // Admin for emergency actions
    uint8 treeHeight;                          // Merkle tree depth (e.g., 32)
    uint32 rootHistorySize;                    // Root ring buffer size (e.g., 100)
    bool paused;                               // Emergency pause
    bool requireASP;                           // Require association set proofs

    // Reserved for future upgrades
    uint256[40] __gap;
}
```

**Constants:**
```solidity
uint8 constant TREE_HEIGHT = 32;           // 2^32 = 4.3B leaves (per pool)
uint32 constant ROOT_HISTORY_SIZE = 100;   // Accept proofs against last 100 roots
uint256 constant PRECISION = 1e18;         // Match BAMM precision
uint8 constant NOTE_TYPE_TOKEN = 0;
uint8 constant NOTE_TYPE_LP = 1;
```

#### Merkle Tree (Per Proxy)

**Incremental Poseidon Tree:**
- Height: 32 (supports 4.3B commitments per DarkPool instance)
- Hash: Poseidon T3 (binary tree, 2 inputs → 1 output)
- Updates: O(log N) on-chain, O(log N) off-chain
- Zero values: Pre-computed for empty subtrees (generated via Poseidon iteration)

**Implementation Details:**
- Uses `src/darkpool/libraries/generated/Poseidon.sol` wrapper
- Binary hashing: `hash2(left, right)` for merkle tree operations
- Zero values: `src/darkpool/libraries/generated/Zeros.sol` (pre-computed up to level 32)
- Gas cost: ~25k per hash operation on-chain

**Root History Ring Buffer:**

Proofs can reference any of the last 100 roots, allowing:
- Time for proof generation (3-5 seconds)
- Tolerance for blockchain reorgs
- Multiple users proving against same root

```
rootHistory[0] = root_100  (oldest)
rootHistory[1] = root_101
...
rootHistory[99] = root_199 (newest)
rootHistoryIndex = 0        (next write position)
```

---

### 3. Public Interfaces

#### Initialization

**Initialize (called once after proxy deployment):**
```solidity
function initialize(
    address _bammPool,     // The BAMM pool this DarkPool serves
    address _verifier,     // Groth16 verifier contract
    address _admin         // Admin address
) external initializer;
```

#### Deposit Functions

**Deposit Token (Public Entry):**
```solidity
function depositToken(
    address token,             // Token to deposit
    uint256 amount,            // Amount to deposit
    bytes32 commitment,        // Commitment to shield
    bytes calldata recipientHint  // Optional encrypted hint for recipient discovery
) external nonReentrant;
```

**Flow:**
1. Transfer `amount` of `token` from `msg.sender` to DarkPool
2. Append `commitment` to Merkle tree
3. Emit `Deposit` and `NewCommitment` events
4. Sender identity now unlinkable from future spends

**Deposit and Mint LP (Public Entry):**
```solidity
function depositAndMintLP(
    address token,             // Underlying token
    uint256 amount,            // Token amount to deposit
    bytes32 commitment,        // Commitment to shield LP note
    bytes calldata recipientHint
) external nonReentrant;
```

**Flow:**
1. Transfer `amount` from `msg.sender` to DarkPool
2. Approve and call `IBAMM(bammPool).deposit(token, amount, 0)`
3. Compute `scaledShares = (lpTokens * PRECISION) / liquidityIndex`
4. Append `commitment` (which must encode `scaledShares` off-chain)
5. Emit events

#### Core Private Function

**Transact (ZK-Powered):**
```solidity
function transact(
    Proof calldata proof,           // ZK proof + public inputs
    ExtData calldata extData,       // External action parameters
    bytes calldata recipientHints   // Hints for output note recipients
) external nonReentrant returns (bool);
```

**Proof Structure:**
```solidity
struct Proof {
    uint256[8] groth16Proof;     // Groth16 proof data (a, b, c points)
    bytes32 merkleRoot;          // Root to prove inclusion against
    bytes32[] nullifiers;        // Nullifiers for input notes (2-4 typical)
    bytes32 extDataHash;         // Hash binding external actions
    bytes32[] outCommitments;    // Output note commitments (2-4 typical)
}
```

**ExtData Structure:**
```solidity
struct ExtData {
    uint8 actionType;            // SWAP | LP_DEPOSIT | LP_WITHDRAW | TRANSFER
    address[] assets;            // Tokens involved
    uint256[] extIn;             // External inputs per asset
    uint256[] extOut;            // External outputs per asset
    address[] receivers;         // External payout addresses (or empty to re-shield)
    bytes32 memoHash;            // Optional metadata hash
    bytes32 aspRoot;             // Association set root (if requireASP enabled)
}
```

**Action Types:**
```solidity
enum ActionType {
    TRANSFER,      // Pure note transfer (no external calls)
    SWAP,          // Swap via BAMM
    LP_DEPOSIT,    // Deposit to BAMM for LP
    LP_WITHDRAW    // Withdraw LP from BAMM
}
```

**Transact Flow:**
1. Verify Groth16 proof (calls verifier contract)
2. Check `merkleRoot` exists in `rootHistory`
3. Check all `nullifiers` not in `nullifierSpent`
4. Recompute `extDataHash` and verify matches proof
5. Execute external actions on associated BAMM (swaps, deposits, withdraws)
6. Mark `nullifiers` as spent
7. Append `outCommitments` to Merkle tree
8. Emit events

#### Admin Functions

**Emergency Controls:**
```solidity
function setPaused(bool _paused) external onlyAdmin;
function setRequireASP(bool _requireASP) external onlyAdmin;
```

**Note:** Upgrades are handled via beacon (DarkPoolFactory.upgradeTo), not per-proxy.

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
event Deposit(
    address indexed asset,
    uint256 amount,
    bytes32 indexed commitment
);

event Transact(
    bytes32[] nullifiers,
    bytes32[] outCommitments,
    bytes32 extDataHash
);

event NewCommitment(
    bytes32 indexed commitment,
    uint32 leafIndex,
    bytes recipientHint
);

event NewNullifier(
    bytes32 indexed nullifier
);

event NewRoot(
    bytes32 indexed root,
    uint32 leafIndex
);
```

**Recipient Hints:** Off-chain encrypted tags for recipient discovery without ERC-5564 overhead. Recipients scan logs and decrypt with shared secret (ECDH).

---

### 5. DarkPool Factory

#### Factory Interface

```solidity
interface IDarkPoolFactory {
    function beacon() external view returns (address);

    function createDarkPool(
        address bammPool,
        address verifier,
        address admin
    ) external returns (address darkPool);

    function darkPoolForBAMM(address bammPool) external view returns (address);

    function upgradeTo(address newImplementation) external;
}
```

#### Factory Flow

**Deploy Infrastructure:**
```solidity
1. Deploy DarkPool implementation (singleton)
2. Deploy UpgradeableBeacon(implementation)
3. Deploy DarkPoolFactory(beacon)
```

**Create DarkPool for BAMM:**
```solidity
darkPoolFactory.createDarkPool(
    address(bammPool),    // The BAMM pool to serve
    address(verifier),    // Groth16 verifier
    address(admin)        // Admin
) returns (address darkPoolProxy)
```

**Factory Implementation:**
```solidity
contract DarkPoolFactory {
    address public immutable beacon;
    mapping(address => address) public darkPoolForBAMM;

    constructor(address _beacon) {
        beacon = _beacon;
    }

    function createDarkPool(
        address bammPool,
        address verifier,
        address admin
    ) external returns (address darkPool) {
        require(darkPoolForBAMM[bammPool] == address(0), "DarkPool exists");

        // Deploy beacon proxy
        darkPool = LibClone.deployERC1967BeaconProxy(beacon);

        // Initialize
        DarkPool(darkPool).initialize(bammPool, verifier, admin);

        // Register
        darkPoolForBAMM[bammPool] = darkPool;

        emit DarkPoolCreated(bammPool, darkPool);
    }

    function upgradeTo(address newImplementation) external onlyOwner {
        UpgradeableBeacon(beacon).upgradeTo(newImplementation);
    }
}
```

---

### 6. Circuit Specification

#### JoinSplit Circuit (Circom)

**Template:**
```circom
template JoinSplit(nInputs, nOutputs, treeDepth) {
    // Public inputs (verified on-chain)
    signal input merkleRoot;
    signal input nullifiers[nInputs];
    signal input extDataHash;
    signal input aspRoot;  // Optional association set root

    // Private inputs
    signal input inputNotes[nInputs][8];      // [assetId, noteType, value, ownerKey, blinding, salt, pathBits, secret]
    signal input inputPaths[nInputs][treeDepth];
    signal input outputNotes[nOutputs][6];    // [assetId, noteType, value, ownerKey, blinding, salt]
    signal input extInAmounts[MAX_ASSETS];
    signal input extOutAmounts[MAX_ASSETS];
    signal input extMeta;                     // Packed metadata

    // Constraints:
    // 1. Merkle inclusion for each input note
    // 2. Nullifier = Poseidon(chainId, darkPool, secret, ownerKey)
    // 3. Per-asset conservation: Σ(inputs.value) + extIn == Σ(outputs.value) + extOut
    // 4. Commitment recomputation for outputs
    // 5. ExtDataHash binding
    // 6. (Optional) Association set membership
}
```

**Simplified vs Multi-Pool Design:**
- **No `bammPool` field** (8 inputs → 7 inputs per note)
- **Simpler value conservation** (only assets in single pool)
- **~10% fewer constraints** (~45k vs ~50k for 2×2 circuit)

**Constraint Breakdown:**

**1. Merkle Inclusion:**
```circom
for (i = 0; i < nInputs; i++) {
    // Recompute commitment from note fields
    signal inputCM = Poseidon(8)([
        chainId, darkPool,
        inputNotes[i][0],  // assetId
        inputNotes[i][1],  // noteType
        inputNotes[i][2],  // value
        inputNotes[i][3],  // ownerKey
        inputNotes[i][4],  // blinding
        inputNotes[i][5]   // salt
    ]);

    // Verify Merkle path
    signal computedRoot = MerkleProof(treeDepth)(inputCM, inputPaths[i]);
    computedRoot === merkleRoot;
}
```

**2. Nullifier Computation:**
```circom
for (i = 0; i < nInputs; i++) {
    signal nf = Poseidon(4)([
        chainId,
        darkPool,
        inputNotes[i][7],  // nullifierSecret
        inputNotes[i][3]   // ownerKey
    ]);
    nf === nullifiers[i];
}
```

**3. Per-Asset Value Conservation:**
```circom
// Group inputs/outputs by (assetId, noteType)
signal assetInputSum[MAX_ASSETS];
signal assetOutputSum[MAX_ASSETS];

for (asset = 0; asset < MAX_ASSETS; asset++) {
    assetInputSum[asset] + extInAmounts[asset] ===
        assetOutputSum[asset] + extOutAmounts[asset];
}
```

**Circuit Parameters:**
- `nInputs`: 2-4 (start with 2, expand to 4 for flexibility)
- `nOutputs`: 2-4 (same)
- `treeDepth`: 32 (matches on-chain tree)
- `MAX_ASSETS`: 4 (support up to 4 different assets in single tx)

**Complexity:**
- **2×2 (2 inputs, 2 outputs):** ~45k constraints
- **4×4:** ~110k constraints
- Proving time (2×2): 2-4 seconds on consumer hardware
- Proof size: 128 bytes (Groth16)

---

### 7. BAMM Integration

#### LP Token Accounting

**BAMM's Scaled Share System:**

```solidity
// From BAMM.sol
mapping(address => LPState) public lpStates;
mapping(address => mapping(address => uint256)) public scaledBalances;

struct LPState {
    uint128 totalScaledSupply;
    uint128 liquidityIndex;  // Starts at 1e18, grows with fees
}

// Deposit (BAMM.sol:186-227)
lpTokens = (amountAfterFee * totalScaledSupply * PRECISION) / (reserves * liquidityIndex);
scaledAmount = (lpTokens * PRECISION) / liquidityIndex;

// Withdraw (BAMM.sol:229-276)
amountOut = (scaledAmount * liquidityIndex * reserves) / (totalScaledSupply * PRECISION);
```

**DarkPool Integration:**

When spending an LP note, DarkPool reads `liquidityIndex` to compute current LP tokens:

```solidity
function _computeLPTokens(
    address token,
    uint256 scaledShares
) internal view returns (uint256 lpTokens) {
    address bamm = _getStorage().bammPool;
    IBAMM.LPState memory lpState = IBAMM(bamm).lpStates(token);
    lpTokens = (scaledShares * lpState.liquidityIndex) / PRECISION;
}
```

**Critical Timing:** Read `liquidityIndex` **before** any external calls that could trigger fee accrual (swaps, withdrawals).

#### Interaction Patterns

**Private LP Deposit:**
```
User → transact() with actionType=LP_DEPOSIT
├─ Spend token note(s) of asset A
├─ extOut transfers A to DarkPool (internal)
├─ DarkPool.approve(bammPool, amount)
├─ lpTokens = IBAMM(bammPool).deposit(A, amount, minLP)
├─ scaledShares = (lpTokens * PRECISION) / liquidityIndex
├─ Create LP note with scaledShares
└─ Append LP commitment to tree
```

**Private LP Withdraw:**
```
User → transact() with actionType=LP_WITHDRAW
├─ Spend LP note(s)
├─ Read liquidityIndex at tx start
├─ lpTokens = (scaledShares * liquidityIndex) / PRECISION
├─ amountOut = IBAMM(bammPool).withdraw(token, lpTokens, minOut)
├─ Re-shield as token note(s) OR
└─ Transfer to receiver (extOut)
```

**Private Swap:**
```
User → transact() with actionType=SWAP
├─ Spend token note(s) of tokenIn
├─ extOut transfers tokenIn to DarkPool
├─ DarkPool.approve(bammPool, amountIn)
├─ amountOut = IBAMM(bammPool).swap(tokenIn, tokenOut, amountIn, minOut, address(DarkPool))
├─ Re-shield tokenOut as note(s) OR
└─ Transfer to receiver
```

---

## Multi-Pool Privacy Flows

### Cross-DarkPool Operations

While each DarkPool proxy serves one BAMM, users can achieve cross-pool privacy via multi-step flows:

**Example: Private USDC → WETH Conversion**

```
Step 1: Withdraw from DarkPool A (USDC)
├─ User calls DarkPoolA.transact()
├─ Spend USDC note(s)
├─ Withdraw to fresh address X
└─ Address X now has public USDC

Step 2: Swap on BAMM (optional privacy via new address)
├─ Address X calls BAMM.swap(USDC, WETH)
└─ Address X receives WETH

Step 3: Deposit to DarkPool B (WETH)
├─ Address X calls DarkPoolB.depositToken()
├─ Shield WETH as note(s)
└─ WETH now private in DarkPoolB

Total: 3 transactions, 2 DarkPools
```

**Privacy Properties:**
- Initial USDC depositor not linked to final WETH recipient
- Each DarkPool's anonymity set provides cover
- Can use fresh addresses between steps for additional obfuscation

**Trade-off vs Single DarkPool:**
- More transactions (3 vs 1)
- Smaller per-pool anonymity sets
- BUT: Architecturally consistent, simpler implementation, better gas efficiency per pool

---

## Complete Anonymity Workflow

### Overview: How Privacy Works

DarkPool provides **identity privacy** through zero-knowledge proofs while keeping transaction amounts public. Users interact with shielded notes stored in an on-chain merkle tree.

**Key Privacy Properties**:
- ✅ **Sender anonymity**: Cannot link deposit address to spend address
- ✅ **Recipient anonymity**: Cannot identify who receives notes
- ✅ **Unlinkability**: Cannot link input notes to output notes
- ✅ **Note privacy**: Note contents (value, owner) hidden in commitments
- ⚠️ **Amounts public**: Transaction totals visible (not amounts per note)

### User Journey: Alice's Private Swap

**Scenario**: Alice wants to privately swap 1000 USDC for DAI without revealing her identity.

---

#### **Step 1: Initial Deposit (Public → Private)**

**Action**: Alice shields her USDC

```typescript
// 1. Generate note secrets (off-chain)
const ownerKey = randomFieldElement();      // Alice's private key
const blinding = randomFieldElement();       // Random blinding factor
const salt = randomFieldElement();           // Random salt
const nullifierSecret = randomFieldElement(); // Secret for spending

// 2. Compute commitment (off-chain)
const commitment = Poseidon.hash8(
    chainId,
    darkPoolAddress,
    USDC_ADDRESS,       // assetId
    0,                  // noteType = TOKEN
    1000 * 1e6,         // value = 1000 USDC
    ownerKey,
    blinding,
    salt
);

// 3. Deposit to DarkPool (on-chain)
await darkPool.depositToken(
    USDC_ADDRESS,
    1000 * 1e6,         // amount
    commitment,         // note commitment
    encryptedHint       // optional: encrypted for Alice
);
```

**On-Chain Effects**:
- 1000 USDC transferred from Alice's EOA to DarkPool
- Commitment inserted into merkle tree at index 42
- Event emitted: `NewCommitment(commitment, 42, encryptedHint)`
- **Alice's identity now unlinkable from this commitment**

**Off-Chain**:
- Alice stores note details securely:
  ```json
  {
    "commitment": "0x1234...",
    "assetId": "0xA0b86991...",  // USDC
    "noteType": 0,
    "value": "1000000000",       // 1000 USDC
    "ownerKey": "0xabcd...",
    "blinding": "0xef01...",
    "salt": "0x2345...",
    "nullifierSecret": "0x6789...",
    "leafIndex": 42
  }
  ```

---

#### **Step 2: Wait for Anonymity Set**

**Why Wait?**
- Alice's deposit is visible on-chain
- If she immediately spends, timing analysis links deposit → spend
- **Best practice**: Wait for 10-100 other deposits before spending

**Anonymity Set Growth**:
```
Time    | Deposits | Anonymity Set | Alice's Privacy
--------|----------|---------------|----------------
T+0     | 1 (Alice)| 1/1 = 0%      | No privacy
T+1h    | 15       | 1/15 = 6.7%   | Weak
T+24h   | 127      | 1/127 = 0.8%  | Good
T+1week | 842      | 1/842 = 0.1%  | Strong
```

**Recommended**: Wait for anonymity set ≥ 100 before spending

---

#### **Step 3: Build Private Transaction (Off-Chain)**

**Action**: Alice prepares to spend her note privately

```typescript
// 1. Fetch current merkle tree state
const treeState = await fetchTreeState(darkPool);
const currentRoot = treeState.root;

// 2. Get merkle proof for Alice's note
const merklePath = await tree.getProof(42); // leafIndex = 42

// 3. Create output notes (600 DAI + 400 USDC change)
const daiNote = await createSpendableNote({
    chainId,
    darkPool: darkPoolAddress,
    assetId: DAI_ADDRESS,
    noteType: 0,
    value: 600 * 1e18,    // 600 DAI
    ownerKey: bobPublicKey  // Recipient = Bob
});

const changeNote = await createSpendableNote({
    chainId,
    darkPool: darkPoolAddress,
    assetId: USDC_ADDRESS,
    noteType: 0,
    value: 400 * 1e6,     // 400 USDC
    ownerKey: alicePublicKey // Back to Alice
});

// 4. Prepare external data
const extData = {
    actionType: ActionType.SWAP,
    assets: [USDC_ADDRESS, DAI_ADDRESS],
    extIn: [0, 0],         // No external deposits
    extOut: [0, 0],        // No external withdrawals
    receivers: [],         // All outputs re-shielded
    memoHash: 0,
    aspRoot: 0             // No association set
};

// 5. Build circuit witness
const witness = {
    // Public inputs
    merkleRoot: currentRoot,
    nullifiers: [aliceNullifier],
    extDataHash: computeExtDataHash(extData),
    aspRoot: 0,

    // Private inputs
    chainId,
    darkPool: darkPoolAddress,
    inputNotes: [[
        USDC_ADDRESS, 0, 1000*1e6, aliceOwnerKey,
        blinding, salt, nullifierSecret
    ]],
    inputPaths: [merklePath.pathElements],
    inputPathIndices: [merklePath.pathIndices],
    outputNotes: [
        [DAI_ADDRESS, 0, 600*1e18, bobOwnerKey, ...],
        [USDC_ADDRESS, 0, 400*1e6, aliceOwnerKey, ...]
    ],
    extInAmounts: [0, 0, 0, 0],
    extOutAmounts: [0, 0, 0, 0],
    assetIds: [USDC_ADDRESS, DAI_ADDRESS, 0, 0]
};

// 6. Generate zkSNARK proof (2-5 seconds)
const { proof, publicSignals } = await groth16.fullProve(
    witness,
    "JoinSplit.wasm",
    "JoinSplit_final.zkey"
);
```

**Privacy at This Stage**:
- All computation happens locally
- No network calls revealing Alice's intent
- Proof hides: which note she's spending, her owner key, note secrets
- Proof reveals: nullifier (prevents double-spend), merkle root, extDataHash

---

#### **Step 4: Submit Transaction (On-Chain)**

**Action**: Alice (or anyone) submits the proof

```typescript
// Alice can submit from any address (even Bob can submit for her)
const tx = await darkPool.transact(
    {
        groth16Proof: formatProof(proof),
        merkleRoot: currentRoot,
        nullifiers: [aliceNullifier],
        extDataHash,
        outCommitments: [daiCommitment, changeCommitment]
    },
    extData,
    recipientHints  // Encrypted hints for Bob
);
```

**On-Chain Verification**:
```solidity
function transact(Proof calldata proof, ExtData calldata extData, ...) external {
    // 1. Verify Groth16 proof (~235k gas)
    require(verifier.verifyProof(proof.groth16Proof, publicInputs), "Invalid proof");

    // 2. Check merkle root is recent
    require(isKnownRoot(proof.merkleRoot), "Unknown root");

    // 3. Check nullifiers not spent
    for (uint i = 0; i < proof.nullifiers.length; i++) {
        require(!nullifierSpent[proof.nullifiers[i]], "Note already spent");
        nullifierSpent[proof.nullifiers[i]] = true;  // Mark spent
    }

    // 4. Verify extDataHash
    require(computeExtDataHash(extData) == proof.extDataHash, "Invalid extData");

    // 5. Execute BAMM swap (1000 USDC → ~600 DAI)
    uint256 daiReceived = IBAMM(bammPool).swap(
        USDC_ADDRESS,
        DAI_ADDRESS,
        1000 * 1e6,
        590 * 1e18,  // minOut = 590 DAI (slippage)
        address(this) // DarkPool receives
    );

    // 6. Insert output commitments into tree
    insertLeaf(daiCommitment);    // Index 943
    insertLeaf(changeCommitment); // Index 944

    // 7. Emit events
    emit Transact(proof.nullifiers, proof.outCommitments, proof.extDataHash);
}
```

**On-Chain Observers See**:
- ✅ Nullifier revealed: `0xabcd...` (prevents double-spend)
- ✅ New commitments: `0x1234...`, `0x5678...`
- ✅ Swap: 1000 USDC → 600 DAI (amounts visible)
- ✅ Action type: SWAP
- ❌ **WHO** spent the note (could be anyone in anonymity set)
- ❌ **WHICH** note was spent (just a nullifier, no link to deposit)
- ❌ **WHO** receives the outputs (just commitments)
- ❌ Individual note amounts (just total swap amounts)

---

#### **Step 5: Recipient Receives Note (Off-Chain)**

**Action**: Bob scans events to find his note

```typescript
// 1. Bob monitors NewCommitment events
darkPool.on("NewCommitment", async (commitment, index, hint) => {

    // 2. Try to decrypt hint
    const noteData = await tryDecrypt(hint, bobPrivateKey);

    if (noteData) {
        // 3. Verify commitment matches
        const expectedCommitment = Poseidon.hash8(
            chainId, darkPool, noteData.assetId,
            noteData.noteType, noteData.value, bobOwnerKey,
            noteData.blinding, noteData.salt
        );

        if (expectedCommitment === commitment) {
            // 4. Bob found his note!
            bobWallet.saveNote({
                commitment,
                ...noteData,
                leafIndex: index
            });

            console.log(`Received ${noteData.value / 1e18} DAI`);
        }
    }
});
```

**Bob now has**:
- 600 DAI note at index 943
- Can spend it later (same privacy flow)

**Alice's change**:
- 400 USDC note at index 944
- Can combine with other notes or spend separately

---

### Privacy Guarantees

**What DarkPool Hides**:

1. **Sender Identity**:
   - Cannot link Alice's deposit address to her spend
   - Any address in anonymity set could have spent
   - Timing analysis mitigated by waiting

2. **Recipient Identity**:
   - Bob's address never appears on-chain
   - Only encrypted hints (requires Bob's key to decrypt)
   - Observers see commitments, not recipients

3. **Note Linkage**:
   - Cannot link input notes to output notes
   - Nullifier is unique per note (no reuse)
   - Zero-knowledge proof hides all note details

4. **Transaction Graph**:
   - Cannot build "taint graph" like public blockchain
   - Each transaction is unlinkable from previous
   - Privacy compounds with each hop

**What DarkPool Reveals**:

1. **Total Amounts**:
   - Swap amounts visible: 1000 USDC → 600 DAI
   - Pool reserves change publicly
   - Necessary for AMM price discovery

2. **Action Types**:
   - SWAP, TRANSFER, LP_DEPOSIT, LP_WITHDRAW
   - Helps with statistical analysis
   - Trade-off: simpler implementation

3. **Timing**:
   - Block number of deposit/spend
   - Mitigated by waiting for anonymity set
   - Can submit via relayer for extra privacy

4. **Asset Types**:
   - Which tokens involved in swap
   - Unavoidable for AMM functionality

---

### Best Practices for Maximum Privacy

**For Depositors**:
1. ✅ Use fresh address for deposits
2. ✅ Don't reuse deposit address
3. ✅ Vary deposit amounts (avoid round numbers)
4. ✅ Wait 24-48 hours before spending
5. ✅ Deposit from mixer (Tornado Cash, etc.) for extra layer

**For Spenders**:
1. ✅ Wait for large anonymity set (≥100 deposits)
2. ✅ Submit transaction via relayer (not your EOA)
3. ✅ Vary transaction amounts
4. ✅ Don't withdraw to known addresses
5. ✅ Use multiple hops for large amounts

**For Recipients**:
1. ✅ Use unique owner keys per note
2. ✅ Don't link notes to public identity
3. ✅ Re-shield before withdrawing to public
4. ✅ Encrypt hints with ephemeral keys

**For LP Providers**:
1. ✅ Deposit via DarkPool (not direct to BAMM)
2. ✅ Keep LP notes private
3. ✅ Withdraw via DarkPool after sufficient time
4. ✅ Avoid timing correlation with deposits

---

### Attack Mitigations

**Timing Analysis**:
- **Attack**: Link deposit time to spend time
- **Mitigation**: Wait for anonymity set, random delays
- **Result**: Timing correlation < 1%

**Amount Analysis**:
- **Attack**: Unique deposit amount links to spend
- **Mitigation**: Vary amounts, split/combine notes
- **Result**: Reduced effectiveness with large anonymity set

**IP Correlation**:
- **Attack**: Link IP address to transactions
- **Mitigation**: Use relayers, Tor, VPN
- **Result**: No on-chain linkage

**Sybil Deposits**:
- **Attack**: Attacker deposits majority of anonymity set
- **Mitigation**: Wait for organic growth, monitor pool activity
- **Result**: Economic cost makes attack expensive

**Toxic Waste (Trusted Setup)**:
- **Attack**: Compromise trusted setup to forge proofs
- **Mitigation**: Use multi-party computation ceremony
- **Result**: Requires ALL participants to be malicious

---

## Gas Costs

### Verification Overhead

**Groth16 on BN254 (EVM Precompiles):**

```
Base verification:           ~200k gas
Per public input:            ~7.1k gas

Typical setup (2 inputs, 2 outputs):
├─ merkleRoot                 7.1k
├─ nullifier[0]               7.1k
├─ nullifier[1]               7.1k
├─ extDataHash                7.1k
└─ aspRoot (optional)         7.1k
                             -------
Total verification:          ~235k gas
```

### Per-Operation Breakdown

**Private Token Deposit:**
```
Token transfer                 ~50k
Merkle append                  ~42k (1 leaf)
Event emission                 ~5k
                              -------
Total:                        ~97k gas
```

**Private Swap:**
```
Proof verification            ~235k
Root check (SLOAD)             ~2.1k
Nullifier checks (×2)          ~42k (SSTORE cold × 2)
BAMM.swap()                   ~120k (depends on complexity)
Merkle append (×2)             ~84k (2 output leaves)
Events                         ~10k
                              -------
Total:                        ~493k gas
```

**Private LP Deposit:**
```
Proof verification            ~235k
Nullifier checks              ~42k
BAMM.deposit()                ~150k
LP index read (view)           ~2.1k
Merkle append (×2)             ~84k
                              -------
Total:                        ~513k gas
```

**Comparison:**
- Public BAMM.swap(): ~150k gas
- Private swap: ~493k gas
- **Privacy premium:** ~3.3× (acceptable for high-value privacy)

### Deployment Costs

**Per-Pool Deployment:**
```
DarkPool implementation (once):    ~3M gas (singleton)
UpgradeableBeacon (once):          ~200k gas
DarkPoolFactory (once):            ~500k gas

Per BAMM Pool:
├─ Deploy beacon proxy:            ~100k gas
├─ Initialize:                     ~150k gas
└─ Total per pool:                 ~250k gas
```

**Comparison:**
- 10 pools: 250k × 10 = 2.5M gas (vs 25M for 10 UUPS)
- **Beacon pattern saves ~90% on multi-deployment**

---

## Security Considerations

### 1. Double-Spend Prevention

**Nullifier Tracking:**
```solidity
mapping(bytes32 => bool) public nullifierSpent;

function transact(...) external {
    for (uint i = 0; i < proof.nullifiers.length; i++) {
        require(!nullifierSpent[proof.nullifiers[i]], "Note already spent");
        nullifierSpent[proof.nullifiers[i]] = true;
    }
}
```

**Nullifier Uniqueness:** Each note has a unique nullifier tied to `nullifierSecret` (never revealed). Reusing same note would require revealing same nullifier, which reverts.

### 2. Front-Running Protection

**ExtData Hash Binding:**

All external actions (amounts, receivers, slippage) bound in `extDataHash`:

```solidity
bytes32 computedHash = keccak256(abi.encode(extData));
require(computedHash == proof.extDataHash, "ExtData tampered");
```

Attacker cannot modify:
- Swap amounts
- Receivers
- Slippage limits

### 3. Reentrancy Protection

**All External Calls Within Reentrancy Guard:**

```solidity
function transact(...) external nonReentrant {
    // Read liquidityIndex FIRST
    uint128 startIndex = IBAMM(_getStorage().bammPool).lpStates(token).liquidityIndex;

    // Verify proof
    _verifyProof(proof, extData);

    // Execute external actions with cached index
    _executeActions(extData, startIndex);

    // Update state (nullifiers, tree)
    _updateState(proof);
}
```

### 4. Cross-Pool Isolation

**Per-Proxy Storage Prevents Cross-Contamination:**

Each DarkPool proxy has:
- Separate merkle tree (cannot spend notes from another pool)
- Separate nullifier set (cross-pool double-spend impossible)
- Separate root history

Proxy address in commitment/nullifier ensures domain separation.

### 5. Domain Separation

**Prevents Cross-Chain/Contract Replay:**

```solidity
// In circuit
commitment = Poseidon(chainId, darkPoolAddress, assetId, ...)
nullifier = Poseidon(chainId, darkPoolAddress, nullifierSecret, ...)
```

Cannot replay proofs:
- Across chains (different `chainId`)
- Across DarkPool proxies (different `darkPoolAddress`)

---

## Compliance: Association Sets

### Overview

**Association Sets** enable users to prove their funds originated from legitimate sources without revealing transaction history. Introduced in Vitalik Buterin's Privacy Pools paper (2023), now live on mainnet (0xbow.io, March 2025).

### Architecture

```
┌─────────────────────────────────────┐
│    Association Set Provider (ASP)   │
│                                      │
│  Maintains whitelist of "clean"     │
│  deposit commitments:               │
│                                      │
│  cleanDeposits = {cm1, cm2, ..., cmN}│
│                                      │
│  Publishes merkle root:             │
│  aspRoot = MerkleRoot(cleanDeposits) │
└─────────────────────────────────────┘
                  │
                  │ aspRoot
                  ▼
        ┌─────────────────┐
        │   DarkPool      │
        │                 │
        │  requireASP=true│
        │                 │
        │  Verifies proofs│
        │  include aspRoot│
        └─────────────────┘
```

### Circuit Integration

**Additional Public Input:**
```circom
signal input aspRoot;  // Association set merkle root

if (aspRoot != 0) {
    for (i = 0; i < nInputs; i++) {
        // Prove input commitment is in approved set
        signal aspPathRoot = MerkleProof(ASP_DEPTH)(inputCommitments[i], aspPaths[i]);
        aspPathRoot === aspRoot;
    }
}
```

**On-Chain Verification:**
```solidity
struct DarkPoolStorage {
    bool requireASP;                           // Enable/disable ASP
    mapping(bytes32 => bool) approvedASPRoots; // Whitelist of ASP roots
}

function transact(Proof calldata proof, ExtData calldata extData) external {
    if (_getStorage().requireASP) {
        require(extData.aspRoot != bytes32(0), "ASP required");
        require(_getStorage().approvedASPRoots[extData.aspRoot], "ASP not approved");
    }
    // ... rest of verification
}
```

### Configuration

**Default:** `requireASP = false` (optional compliance)

**Enabling (per-pool):**
```solidity
darkPool.setRequireASP(true);
darkPool.setApprovedASPRoot(aspRoot1);
```

**Use Cases:**
- Regulated markets (institutional DeFi)
- Jurisdictions requiring clean origin proof
- Voluntary compliance signaling

---

## Upgradeability

### Beacon Pattern (ERC-1967)

**Why Beacon vs UUPS?**

| Feature | Beacon | UUPS |
|---------|--------|------|
| Upgrade logic | In beacon | In implementation |
| Multi-instance | Efficient | Expensive |
| Deployment cost | ~100k per proxy | ~200k per proxy |
| Upgrade scope | All instances at once | Per-instance |
| Consistency | Guaranteed | Must upgrade each |

**Beacon is optimal for DarkPool:**
- Multiple instances (one per BAMM pool)
- Unified upgrades (all pools get fixes simultaneously)
- Lowest per-instance deployment cost
- Consistent with BAMM architecture

### Implementation

**Beacon (Solady):**
```solidity
import {UpgradeableBeacon} from "solady/utils/UpgradeableBeacon.sol";

UpgradeableBeacon beacon = new UpgradeableBeacon(darkPoolImplementation, owner);
```

**Proxy Deployment:**
```solidity
import {LibClone} from "solady/utils/LibClone.sol";

address proxy = LibClone.deployERC1967BeaconProxy(address(beacon));
DarkPool(proxy).initialize(bammPool, verifier, admin);
```

**Upgrade Process:**
```solidity
DarkPoolV2 newImpl = new DarkPoolV2();
beacon.upgradeTo(address(newImpl));
// All DarkPool proxies now use V2
```

### Storage Layout Rules

1. Never reorder existing fields
2. Never change types
3. Only append new fields
4. Use storage gap for future expansion

**Example Migration:**
```solidity
// V1
struct DarkPoolStorage {
    address bammPool;
    uint32 nextLeafIndex;
    uint256[40] __gap;  // Reserved
}

// V2 (safe)
struct DarkPoolStorage {
    address bammPool;       // Same position
    uint32 nextLeafIndex;   // Same position
    address newField;       // Uses gap slot 0
    uint256[39] __gap;      // Reduced by 1
}
```

---

## Implementation Roadmap

### Phase 1: Core Infrastructure (Week 1-2)

**Deliverables:**
- [x] `DarkPool.sol` (beacon-compatible implementation)
- [x] `DarkPoolFactory.sol` (beacon + factory)
- [x] `IDarkPool.sol` (interface)
- [x] `DarkPoolErrors.sol` (errors + events)
- [x] `LibMerkleTree.sol` (Poseidon incremental tree)
- [x] `LibNullifier.sol` (nullifier management)
- [x] Generated Poseidon libraries (T2-T6, wrapper, zeros)
- [ ] Deploy scripts (Foundry)

**Milestones:**
- ✅ Contracts compile successfully
- ✅ Poseidon hash functions integrated (T2-T6)
- ✅ Zero values generated for 32-level merkle tree
- ✅ LibMerkleTree uses actual Poseidon (not placeholder)
- [ ] Factory deploys proxies correctly
- [ ] Basic deposits work (no ZK yet)
- [ ] Merkle tree updates correctly
- [ ] Beacon upgrade mechanism works

### Phase 2: Circuit Development (Week 2-4)

**Deliverables:**
- [ ] `JoinSplit.circom` (NI=2, NO=2)
- [ ] Poseidon hash circuits (use circomlib, match Solidity parameters)
- [ ] Merkle proof circuits
- [ ] Value conservation constraints
- [ ] ExtData binding
- [ ] Trusted setup (or use existing Powers of Tau)
- [ ] Generate Solidity verifier

**Critical**: Ensure circuit Poseidon parameters match `poseidon-solidity` (bn254 curve, same rounds/constants)

**Milestones:**
- Circuit compiles
- Test vectors pass
- Proof generation < 5s
- Verifier contract deployed

### Phase 3: Integration (Week 4-5)

**Deliverables:**
- [ ] Connect circuit to DarkPool
- [ ] Proof builder CLI (snarkjs wrapper)
- [ ] BAMM interaction logic (swap, deposit, withdraw)
- [ ] LP accounting (scaledShares)
- [ ] Recipient hint encryption

**Milestones:**
- End-to-end deposit → spend works
- LP deposit/withdraw functional
- Private swaps operational
- Gas costs within targets

### Phase 4: Testing (Week 5-6)

**Deliverables:**
- [ ] Unit tests (Foundry)
  - Merkle tree operations
  - Nullifier tracking
  - Proof verification
- [ ] Integration tests
  - Private swaps
  - Private LP
  - Cross-pool flows (multi-step)
- [ ] Fuzz tests
  - Random deposits/spends
  - Edge cases (empty outputs, max inputs)
- [ ] Gas profiling

**Milestones:**
- 100% test coverage
- All edge cases handled
- Gas within 10% of estimates

### Phase 5: Security (Week 6-10)

**Deliverables:**
- [ ] Internal security review
- [ ] Formal verification (Certora/Halmos)
- [ ] External audit (zkSecurity, Trail of Bits)
- [ ] Bug bounty program
- [ ] Testnet deployment (Sepolia, Holesky)
- [ ] Stress testing

**Milestiles:**
- No critical/high issues
- Medium issues resolved or accepted
- Audit report published

### Phase 6: Production (Week 10-12)

**Deliverables:**
- [ ] Mainnet deployment
- [ ] Documentation (user guide, dev docs)
- [ ] Monitoring dashboard
- [ ] Emergency procedures
- [ ] Governance handoff (if applicable)

**Milestones:**
- Contracts deployed and verified
- Initial deposits processed
- No incidents in first week

---

## Future Optimizations & Migration Path

### V1: Launch Configuration (Current)

**Hash Function: Poseidon (2019)**

The current implementation uses the original Poseidon hash function for production readiness and security:

| Component | Choice | Rationale |
|-----------|--------|-----------|
| **Circuit Hash** | Poseidon (circomlib) | Official, audited by use (Tornado Cash, Semaphore) |
| **Solidity Hash** | Poseidon (poseidon-solidity) | Battle-tested, complete stack (T2-T6), uses T3 + T5 |
| **Constraints** | ~240 per hash (R1CS) | Industry standard for zkSNARKs |
| **Gas Cost** | ~25k per hash (T3) | Acceptable for privacy premium |
| **Security** | Proven in production | Used by major protocols since 2020 |

**Gas Costs (V1)**:
- Groth16 verification: ~235k gas (48% of total)
- Merkle hashing (2× Poseidon T3): ~50k gas (10%)
- Nullifier computation (Poseidon T5): ~45k gas (9%)
- BAMM operations: ~120k gas (24%)
- Other overhead: ~50k gas (10%)
- **Total per private swap: ~500k gas**

### V2: Poseidon2 Migration (Future)

**Target: 6-12 months post-launch**

Poseidon2 (2023) offers significant improvements with minimal security trade-offs:

**Performance Improvements**:
- **40% lower gas** for hash operations (15k vs 25k per hash)
- **Up to 70% fewer constraints** in Plonk circuits (future-proofing)
- **Same constraints for Groth16** (~240 per hash)
- **Same proof generation time** (~4.5 seconds for 127 hashes)
- **30% better circuit efficiency** overall

**Why Not Launch with Poseidon2?**

1. **Circuit Availability**:
   - Poseidon2 circom implementation not yet in official circomlib
   - PR #98 pending since April 2023
   - No production usage at scale

2. **Security Posture**:
   - Poseidon has 5+ years of production use
   - Poseidon2 needs more real-world validation
   - Custom implementation requires extensive audit ($20-40k)

3. **Implementation Risk**:
   - Must implement circuits from scratch
   - Must match Solidity parameters exactly
   - Wrong parameters = invalid proofs = funds stuck

4. **Time to Market**:
   - Poseidon: Ships today
   - Poseidon2: 6-10 weeks delay + audit

**Estimated V2 Gas Savings**:
- Merkle hashing: 50k → 30k (save 20k)
- Nullifier: 45k → 27k (save 18k)
- **Total: ~500k → ~462k (-7.6%)**

### Migration Workflow (V2 Upgrade via Beacon)

**Phase 1: Preparation** (Weeks 1-4)
```
1. Monitor circomlib for official Poseidon2 merge
2. Audit available Poseidon2 implementations
3. Implement/fork Poseidon2 circuits for all variants (T3, T5)
4. Extensive testing on testnet
```

**Phase 2: Deployment** (Week 5)
```
1. Deploy new Poseidon2 Solidity contracts
2. Generate new circuit parameters
3. Run trusted setup (or use existing ceremony)
4. Deploy new Groth16 verifier contract
5. Deploy DarkPool V2 implementation
```

**Phase 3: Upgrade** (Week 6)
```
1. Upgrade beacon to point to V2 implementation
   → All DarkPool proxies instantly use Poseidon2
2. Update frontend SDK to use new circuits
3. Monitor for issues
```

**Backward Compatibility**:
- ✅ Existing deposits remain valid (just commitments on-chain)
- ✅ Existing notes can still be spent (merkle root doesn't change)
- ✅ Old proofs don't break (verifier remains compatible)
- ⚠️ New deposits/spends use Poseidon2
- ⚠️ Cannot mix Poseidon1 and Poseidon2 in same transaction

**Risk Mitigation**:
- Deploy V2 to new test pool first
- Run parallel systems for 1-2 weeks
- Gradual rollout (upgrade 1 pool, then all)
- Rollback via beacon if issues found

### V3+: Advanced Optimizations (18+ months)

**Potential Future Improvements**:

1. **Proof System Upgrades**:
   - PLONK/Plonky2 (no trusted setup, universal)
   - FRI-based (post-quantum security)
   - Recursive proofs (batch verification)

2. **Hash Function Evolution**:
   - Poseidon3 (if released)
   - Neptune (fewer constraints than Poseidon2)
   - Custom optimizations for specific operations

3. **Circuit Optimizations**:
   - Larger input/output counts (4×4 instead of 2×2)
   - Native multi-asset support in circuit
   - Optimized merkle tree depth (32 → 20 for smaller anonymity sets)

4. **EVM Precompiles**:
   - If Ethereum adds Poseidon precompile
   - Native zkSNARK verification opcodes
   - Potential 10× gas reduction

### Technology Watchlist

**Actively Monitor**:
- [circomlib PR #98](https://github.com/iden3/circomlib/pull/98) - Poseidon2 integration
- [zemse/poseidon2-evm](https://github.com/zemse/poseidon2-evm) - Huff implementation audits
- [Poseidon2 Paper](https://eprint.iacr.org/2023/323.pdf) - Updated cryptanalysis
- [zkSNARK Benchmarks](https://arxiv.org/abs/2409.01976) - Latest performance data

**Decision Points**:
- **Poseidon2 Migration**: When circomlib merges OR after independent audit
- **Proof System Change**: When gas savings exceed redeployment costs
- **Architecture Updates**: Based on anonymity set size and usage patterns

### Design Philosophy

**Pragmatic Conservatism**:
- Launch with proven, battle-tested stack
- Optimize after observing real usage
- Upgrade via beacon pattern (minimal disruption)
- Security > Gas optimization (but optimize when safe)

**The Beacon Advantage**:
- All pools upgrade simultaneously
- No fragmentation of security model
- Users automatically benefit from improvements
- Rollback capability if issues arise

---

## Architecture Comparison

### Beacon Proxy vs Single Contract

| Aspect | Beacon Proxy (Chosen) | Single Contract |
|--------|-----------------------|-----------------|
| **Bytecode Reuse** | ✅ One implementation for all pools | ✅ One contract total |
| **Per-Pool Trees** | ✅ Isolated merkle trees | ❌ Single large tree |
| **Anonymity Set** | Pool-specific (~100-1k users) | Global (~10k+ users) |
| **Cross-Pool Mixing** | Via multi-step flows (3 txs) | Single atomic tx |
| **Deployment Cost** | ~250k gas per pool | ~3M gas once |
| **Circuit Complexity** | Simpler (no bammPool field) | More complex (+1 field) |
| **Architecture Consistency** | ✅ Mirrors BAMM pattern | ❌ Different pattern |
| **Upgrade Mechanism** | Beacon (all pools at once) | UUPS (single instance) |
| **Gas per Operation** | Same (~493k for swap) | Same (~493k for swap) |

**Winner: Beacon Proxy**
- Best balance of code reuse and architectural consistency
- Per-pool isolation reduces tree size and complexity
- Unified upgrades via beacon
- Smaller per-pool anonymity sets are acceptable (still 100-1000 users)
- Cross-pool flows achievable via multi-step (not significantly worse UX)

---

## References

### Standards
1. [EIP-1967: Proxy Storage Slots](https://eips.ethereum.org/EIPS/eip-1967)
2. [EIP-1822: UUPS Proxy](https://eips.ethereum.org/EIPS/eip-1822)

### Privacy Pools
3. [Tornado Cash Nova](https://github.com/tornadocash/tornado-nova) - Variable-amount privacy pool
4. [Privacy Pools Paper](https://papers.ssrn.com/sol3/papers.cfm?abstract_id=4563364) - Association sets
5. [0xbow.io Launch](https://cointelegraph.com/news/privacy-pools-launches-ethereum-support-vitalik-buterin) - Mainnet deployment

### zkSNARKs
6. [Groth16 Paper](https://eprint.iacr.org/2016/260) - Original proof system
7. [Circom Documentation](https://docs.circom.io/) - Circuit language
8. [snarkjs](https://github.com/iden3/snarkjs) - Proof generation
9. [Poseidon Hash](https://www.poseidon-hash.info/) - ZK-friendly hash

### Implementation Guides
10. [Solady Beacon Proxy](https://github.com/Vectorized/solady/blob/main/src/utils/UpgradeableBeacon.sol)
11. [Tornado Cash Circuits](https://github.com/tornadocash/tornado-core/tree/master/circuits)
12. [BAMM Architecture](/Users/derpa/Work/btr/dex/contracts/specs/ARCHITECTURE.md)

---

*DarkPool Specification v2.0*
*Architecture: Beacon Proxy Pattern*
*Last Updated: 2025-11-11*
*Status: Draft*
