# Protocol Upgradeability

## Overview

The BAMM protocol uses **EIP-1967 Beacon Proxy pattern** for upgradeability across all major components: BAMM pools, DarkPools, and Oracles. This architecture enables atomic upgrades of all deployed instances while preserving individual storage and minimizing gas costs.

**Key Benefits:**
- ✅ Single upgrade affects all instances
- ✅ Atomic upgrades across entire protocol
- ✅ Each instance maintains isolated storage
- ✅ Gas-efficient proxy implementation
- ✅ Safe ownership migration (EOA → multisig)

---

## Architecture

### Beacon Proxy Pattern

```
┌─────────────────────────────────────────────────────────────┐
│                     BAMM Ecosystem                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  BAMMFactory (owner: multisig)                              │
│       │                                                      │
│       ├─► UpgradeableBeacon                                 │
│       │      └─► implementation: BAMMv2 ────────┐          │
│       │                                          │          │
│       ├─► Pool Proxy #1                         │          │
│       │      storage: {reserves, LPs, ...}  ────┤          │
│       │                                          │          │
│       ├─► Pool Proxy #2                         │          │
│       │      storage: {reserves, LPs, ...}  ────┤          │
│       │                                          │          │
│       └─► Pool Proxy #N                         │          │
│              storage: {reserves, LPs, ...}  ────┤          │
│                                                  │          │
│      Each proxy delegates ALL calls to beacon ──┴────────► │
│      Beacon queries return implementation address          │
│                                                             │
│  Upgrade: factory.upgradeBeacon(BAMMv3)                    │
│           → All pools instantly use BAMMv3 logic           │
└─────────────────────────────────────────────────────────────┘
```

### Contract Hierarchy

```
BeaconFactory (abstract base)
├─ Ownable (Solady)
├─ UpgradeableBeacon _beacon
└─ upgradeBeacon() function

BAMMFactory extends BeaconFactory
├─ Deploys BAMM beacon proxies
├─ Can upgrade all BAMM pools
└─ Ownership transfer: EOA → multisig

DarkPoolFactory extends BeaconFactory
├─ Deploys DarkPool beacon proxies
├─ Can upgrade all DarkPools
└─ Independent from BAMMFactory

OracleFactory extends BeaconFactory
├─ Deploys Oracle beacon proxies
├─ Can upgrade all Oracles
└─ Independent from other factories
```

---

## How Upgrades Work

### Live Implementation Lookup

**Every function call performs these steps:**
```solidity
// Beacon Proxy Runtime (pseudo-code)
1. CALLDATACOPY          // Copy function call data to memory
2. SLOAD beaconAddress   // Load beacon address from storage slot
3. STATICCALL beacon.implementation()  // Query current implementation
4. MLOAD implAddress     // Get implementation from return data
5. DELEGATECALL impl     // Execute function on implementation
6. RETURNDATACOPY        // Copy result back
7. RETURN                // Return result to caller
```

**Critical:** Steps 3-4 happen **on every single call**. There is no caching.

### Upgrade is Instant and Atomic

```solidity
// Before upgrade
pool1.swap(...) → queries beacon → returns BAMMv1 → delegatecall BAMMv1.swap()
pool2.swap(...) → queries beacon → returns BAMMv1 → delegatecall BAMMv1.swap()
poolN.swap(...) → queries beacon → returns BAMMv1 → delegatecall BAMMv1.swap()

// Factory owner upgrades beacon
factory.upgradeBeacon(address(BAMMv2))
// ↑ Single transaction changes beacon.implementation = BAMMv2

// After upgrade (next block, same second)
pool1.swap(...) → queries beacon → returns BAMMv2 → delegatecall BAMMv2.swap()
pool2.swap(...) → queries beacon → returns BAMMv2 → delegatecall BAMMv2.swap()
poolN.swap(...) → queries beacon → returns BAMMv2 → delegatecall BAMMv2.swap()
```

**Result:** All pools use new logic immediately. No migration needed.

---

## Component Upgradeability

### 1. BAMM Pools

**Implementation:** BAMM.sol (combines BAMMManagement + BAMMFlashLender + pricing logic)

**Storage:** Each pool proxy has its own isolated storage
```solidity
// Per-pool storage (preserved across upgrades)
- address baseToken
- mapping(address => Asset) assets
- mapping(address => LPState) lpStates
- mapping(address => mapping(address => uint256)) scaledBalances
- address[] registeredAssets
- FeeParameters feeParams
- bool isPoolPaused
```

**Upgrade Process:**
```solidity
// 1. Deploy new implementation
BAMMv2 newImpl = new BAMMv2();

// 2. Upgrade beacon (requires factory ownership)
bammFactory.upgradeBeacon(address(newImpl));

// ✅ ALL pools now use BAMMv2 logic
// ✅ Each pool retains its storage (balances, LPs, etc.)
// ✅ No per-pool migration required
```

**Ownership:**
- Factory owner controls upgrades
- Pool owner controls pool-specific settings
- Guardian can pause individual pools

---

### 2. DarkPools

**Implementation:** DarkPool.sol (privacy layer with Merkle tree + ZK proofs)

**Storage:** Each DarkPool proxy has its own isolated storage
```solidity
// Per-DarkPool storage (preserved across upgrades)
- address bammPool (immutable reference)
- address verifier (Groth16 verifier)
- bytes32 currentRoot
- mapping(bytes32 => bool) nullifierSpent
- uint32 nextLeafIndex
```

**Upgrade Process:**
```solidity
// 1. Deploy new implementation
DarkPoolv2 newImpl = new DarkPoolv2();

// 2. Upgrade beacon (requires factory ownership)
darkPoolFactory.upgradeBeacon(address(newImpl));

// ✅ ALL DarkPools now use DarkPoolv2 logic
// ✅ Merkle trees and nullifier sets preserved
// ✅ Each DarkPool maintains commitment privacy
```

**Ownership:**
- Factory owner controls upgrades
- DarkPool owner controls pause/settings
- Independent from BAMM ownership

---

### 3. Oracles

**Implementation:** ExternalOracle.sol (multi-asset price feed aggregator)

**Storage:** Each Oracle proxy has its own isolated storage
```solidity
// Per-Oracle storage (preserved across upgrades)
- mapping(address => AssetData) assets
- address[] registeredAssets
- GlobalConfig config (minUpdateInterval, staleAfter)
```

**Upgrade Process:**
```solidity
// 1. Deploy new implementation
ExternalOraclev2 newImpl = new ExternalOraclev2();

// 2. Upgrade beacon (requires factory ownership)
oracleFactory.upgradeBeacon(address(newImpl));

// ✅ ALL Oracles now use ExternalOraclev2 logic
// ✅ Price data preserved across upgrade
// ✅ Update mechanisms can be enhanced
```

**Ownership:**
- Factory owner controls upgrades
- Oracle owner controls price feeds
- Oracle role can push prices

---

### 4. Factories

**Implementation:** BAMMFactory, DarkPoolFactory, OracleFactory

**Upgradeability:** Factories themselves are **NOT upgradeable**

**Rationale:**
- Factories are lightweight deployment contracts
- Core logic is in beacon implementations (upgradeable)
- Factory upgrades would add unnecessary complexity
- New factory versions can coexist with old ones

**If Factory Update Needed:**
```solidity
// Deploy new factory with updated logic
BAMMFactoryV2 newFactory = new BAMMFactoryV2(newImpl, owner);

// Optionally transfer beacon ownership
bammFactory.transferOwnership(address(newFactory));
// After timelock...
newFactory.completeOwnershipHandover();

// Old factory still works for existing pools
// New deployments use new factory
```

---

## Storage Compatibility Rules

### ✅ SAFE Upgrades

**1. Adding new storage variables at the END:**
```solidity
// V1
contract BAMMv1 {
    uint256 public reserves;   // slot 0
    address public token;      // slot 1
}

// V2 (SAFE)
contract BAMMv2 {
    uint256 public reserves;   // slot 0 (same)
    address public token;      // slot 1 (same)
    uint256 public newFeature; // slot 2 (NEW - safe!)
}
```

**2. Adding new functions:**
```solidity
// V2 can add any new functions
function newFeature() external { ... }
```

**3. Modifying function logic:**
```solidity
// V2 can change implementation of existing functions
function swap() external {
    // New logic using same storage
}
```

**4. Using storage gaps for flexibility:**
```solidity
contract BAMMv1 {
    uint256 public reserves;
    uint256[50] private __gap;  // Reserve slots for future use
}

contract BAMMv2 {
    uint256 public reserves;
    uint256 public newFeature;  // Uses __gap[0]
    uint256[49] private __gap;  // Reduced by 1
}
```

---

### ❌ UNSAFE Upgrades

**1. Reordering storage variables:**
```solidity
// V1
contract BAMMv1 {
    uint256 public reserves;  // slot 0
    address public token;     // slot 1
}

// V2 (UNSAFE!)
contract BAMMv2 {
    address public token;     // slot 0 (was slot 1 - WRONG!)
    uint256 public reserves;  // slot 1 (was slot 0 - WRONG!)
}
// Result: Addresses interpreted as uint256, uint256 as addresses → broken!
```

**2. Changing variable types:**
```solidity
// V1
contract BAMMv1 {
    uint256 public reserves;  // slot 0
}

// V2 (UNSAFE!)
contract BAMMv2 {
    uint128 public reserves;  // slot 0 (different size - WRONG!)
}
// Result: Data corruption
```

**3. Deleting storage variables:**
```solidity
// V1
contract BAMMv1 {
    uint256 public reserves;  // slot 0
    address public token;     // slot 1
    uint256 public fees;      // slot 2
}

// V2 (UNSAFE!)
contract BAMMv2 {
    uint256 public reserves;  // slot 0
    // token removed - WRONG!
    uint256 public fees;      // slot 1 (was slot 2 - WRONG!)
}
// Result: fees variable now reads token slot
```

**4. Modifying mappings or arrays:**
```solidity
// V1
mapping(address => uint256) public balances;

// V2 (UNSAFE!)
mapping(address => uint128) public balances;  // Different value type
// Result: Data corruption
```

---

## Upgrade Procedures

### Standard Upgrade (BAMM Pool Example)

**Prerequisites:**
- New implementation audited and tested
- Storage layout verified compatible
- Deployment script prepared
- Factory ownership confirmed

**Steps:**
```bash
# 1. Deploy new implementation to testnet
forge create BAMMv2 --constructor-args <params>

# 2. Verify contract
forge verify-contract <address> BAMMv2

# 3. Test with single pool on testnet
bammFactory.upgradeBeacon(newImplAddress)
# Test all functions, edge cases, etc.

# 4. Deploy to mainnet
forge create BAMMv2 --rpc-url $MAINNET_RPC

# 5. Upgrade beacon (requires multisig for production)
cast send $FACTORY "upgradeBeacon(address)" $NEW_IMPL \
  --from $OWNER_MULTISIG

# 6. Monitor all pools for 24h
# Check events, balances, swaps, etc.

# 7. If issues found: rollback
cast send $FACTORY "upgradeBeacon(address)" $OLD_IMPL \
  --from $OWNER_MULTISIG
```

### Emergency Rollback

```solidity
// If critical bug discovered after upgrade:

// 1. Deploy fixed implementation or rollback to previous
address fixedImpl = address(new BAMMv2_1());
// OR
address previousImpl = 0x...OldWorkingImplementation;

// 2. Immediate upgrade (requires multisig)
factory.upgradeBeacon(fixedImpl);

// ✅ All pools instantly use fixed/previous implementation
// ✅ No per-pool interaction needed
```

---

## Ownership & Access Control

### Factory Ownership

**Initial Deployment:**
```solidity
// Deploy with EOA for initial setup
BAMMFactory factory = new BAMMFactory(bammImpl, msg.sender);
```

**Transfer to Multisig:**
```solidity
// 1. EOA initiates transfer
factory.transferOwnership(multisigAddress);

// 2. Multisig accepts (after timelock if configured)
factory.completeOwnershipHandover(); // Called by multisig

// ✅ Factory now controlled by multisig
// ✅ Upgrades require multisig approval
```

**Ownership Powers:**
- Upgrade beacon implementation
- Deploy new pools
- Configure DarkPool factory reference
- Set default verifier for DarkPools

### Pool Ownership (Independent)

Each pool has its own ownership structure:
```solidity
struct Roles {
    address owner;      // Can add assets, set fees, update oracles
    address guardian;   // Can pause/unpause pool
    address treasury;   // Receives protocol fees
}
```

**Pool owner CANNOT:**
- Upgrade pool implementation (only factory can)
- Affect other pools

---

## Security Considerations

### 1. Storage Layout Protection

**Best Practice:** Use OpenZeppelin's storage layout checker
```bash
# Generate storage layout before upgrade
forge inspect BAMMv1 storage-layout > v1_layout.json
forge inspect BAMMv2 storage-layout > v2_layout.json

# Compare layouts
diff v1_layout.json v2_layout.json
```

### 2. Initialization Protection

**Problem:** Implementations can be re-initialized if not protected

**Solution:** Use Solady's `Initializable` or similar guard
```solidity
contract BAMM is Initializable {
    function initialize(...) external initializer {
        // Can only be called once per proxy
    }
}
```

### 3. Selector Collisions

**Problem:** New functions can accidentally collide with existing selectors

**Solution:** Review all function signatures before deployment
```bash
# Check for selector collisions
forge inspect BAMMv2 methods
```

### 4. Delegatecall Safety

**Problem:** Implementation can `selfdestruct` or corrupt beacon storage

**Solution:**
- Never use `selfdestruct` in implementations
- Never write to beacon-owned slots
- Audit all low-level calls

### 5. Upgrade Timing

**Best Practices:**
- Announce upgrades in advance (transparency)
- Upgrade during low-activity periods (minimize impact)
- Have rollback plan ready (previous impl address)
- Monitor closely for 24-48h post-upgrade

---

## Testing Upgrades

### Unit Tests

```solidity
function testUpgradePreservesStorage() public {
    // Deploy v1
    BAMM pool = deployPoolV1();

    // Add liquidity
    pool.deposit(token, 1000e18, 0);
    uint256 balanceBefore = pool.balanceOf(user, tokenId);

    // Upgrade to v2
    BAMMv2 implV2 = new BAMMv2();
    factory.upgradeBeacon(address(implV2));

    // Verify storage preserved
    assertEq(pool.balanceOf(user, tokenId), balanceBefore);

    // Test new v2 features
    pool.newFeature();
}
```

### Integration Tests

```solidity
function testMultiPoolUpgrade() public {
    // Deploy 3 pools
    address pool1 = factory.deployPool(...);
    address pool2 = factory.deployPool(...);
    address pool3 = factory.deployPool(...);

    // Add liquidity to all
    addLiquidity(pool1);
    addLiquidity(pool2);
    addLiquidity(pool3);

    // Upgrade beacon
    factory.upgradeBeacon(address(new BAMMv2()));

    // Verify all pools upgraded
    assertEq(BAMM(pool1).version(), 2);
    assertEq(BAMM(pool2).version(), 2);
    assertEq(BAMM(pool3).version(), 2);

    // Verify all pools functional
    testSwaps(pool1);
    testSwaps(pool2);
    testSwaps(pool3);
}
```

---

## Upgrade History

### BAMM Implementation

| Version | Date | Changes | Storage Changes |
|---------|------|---------|-----------------|
| v1.0.0 | TBD | Initial deployment | N/A |
| v1.1.0 | TBD | Added flash loan fee parameter | +1 slot (uint16 flashFeeBps) |
| v2.0.0 | TBD | Coverage ratio ALM | +multiple slots |

### DarkPool Implementation

| Version | Date | Changes | Storage Changes |
|---------|------|---------|-----------------|
| v1.0.0 | TBD | Initial deployment | N/A |

### Oracle Implementation

| Version | Date | Changes | Storage Changes |
|---------|------|---------|-----------------|
| v1.0.0 | TBD | Initial deployment | N/A |

---

## FAQ

**Q: What happens to in-flight transactions during an upgrade?**
A: Transactions are atomic. A tx either completes with old impl or new impl, never partially. Mempool txs will use whichever impl is current when they execute.

**Q: Can I upgrade just one pool?**
A: No. Beacon upgrades affect ALL pools. For isolated changes, deploy a new factory with different beacon.

**Q: What if I need to change storage layout?**
A: Deploy a new factory/implementation. Old pools continue with old impl, new deployments use new impl.

**Q: How do I test storage compatibility?**
A: Use forge storage layout comparison and extensive integration tests on testnet.

**Q: Can users prevent their pool from being upgraded?**
A: No. Factory owner controls beacon. If desired, deploy pool with separate factory under user's control.

**Q: What's the gas cost of the beacon pattern?**
A: ~2,600 gas per call (SLOAD + STATICCALL + DELEGATECALL overhead). Negligible for most operations.

**Q: Can the beacon implementation be changed back?**
A: Yes. Simply call `upgradeBeacon(previousImplementation)`. This is the rollback mechanism.

**Q: Is there a timelock on upgrades?**
A: Not in the contract. Recommend using a TimelockController for factory ownership in production.

---

## Resources

- [EIP-1967: Proxy Storage Slots](https://eips.ethereum.org/EIPS/eip-1967)
- [OpenZeppelin: Proxy Upgrade Pattern](https://docs.openzeppelin.com/upgrades-plugins/1.x/proxies)
- [Solady: UpgradeableBeacon](https://github.com/Vectorized/solady/blob/main/src/utils/UpgradeableBeacon.sol)
- [Solady: LibClone](https://github.com/Vectorized/solady/blob/main/src/utils/LibClone.sol)

---

## Summary

The BAMM protocol uses a battle-tested beacon proxy pattern for upgradeability:

✅ **Single upgrade affects all instances**
✅ **Atomic and instant updates**
✅ **Storage preservation per proxy**
✅ **Rollback capability**
✅ **Safe ownership transfer (EOA → multisig)**
✅ **Gas-efficient Solady implementation**

Upgrades require careful storage layout management and thorough testing, but provide maximum flexibility for protocol evolution while maintaining decentralization and security.
