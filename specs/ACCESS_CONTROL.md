# Access Control & Security

## Overview

BAMM uses role-based access control with timelock delays for admin operations.

**Roles:**
- **ADMIN_ROLE**: Pool governance (add assets, pause, config, treasury address)
- **GUARDIAN_ROLE**: Emergency protection (circuit breakers, asset freezing, blacklisting)
- **TREASURY_ROLE**: Protocol fee collection only

---

## Role Management

### Role Definitions

```solidity
bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
bytes32 public constant TREASURY_ROLE = keccak256("TREASURY_ROLE");
```

### Initialization

```solidity
function initialize(
    address baseToken,
    address admin,
    address guardian,
    address treasury  // Defaults to admin if address(0)
) external initializer {
    _roles[ADMIN_ROLE][admin] = true;
    _roles[GUARDIAN_ROLE][guardian] = true;
    _roles[TREASURY_ROLE][treasury == address(0) ? admin : treasury] = true;
}
```

---

## Timelock Mechanism

### Admin Role Grants

**Delay:** 4 days
**Acceptance window:** 3 days

```solidity
function grantRole(bytes32 role, address account, address replacing)
    external onlyAdmin
```

**Flow:**
1. Admin calls `grantRole(ADMIN_ROLE, newAdmin, oldAdmin)`
2. **Wait 4 days** (timelock delay)
3. New admin calls `acceptRole(ADMIN_ROLE)` (within 3-day window)
4. New admin receives role, old admin optionally revoked

**Purpose:**
- Prevents instant admin takeover
- Allows detection of malicious transfers
- Community oversight window

### Guardian and Treasury Role Grants

**No timelock** - instant grant

```solidity
if (role == GUARDIAN_ROLE || role == TREASURY_ROLE) {
    _roles[role][account] = true;
    emit RoleGranted(account, role);
    return;
}
```

**Rationale:**
- **Guardian**: Need quick rotation for emergency response, permissions limited to protective actions only
- **Treasury**: Limited permissions (only collect protocol fees), no impact on pool operations
- Both roles have narrow, non-governance permissions

---

## Admin Permissions

### Asset Management

```solidity
function addAsset(...) external onlyAdmin
```

Add new tradeable assets to pool.

### Pool Control

```solidity
function pausePool() external onlyAdmin
function unpausePool() external onlyAdmin
```

Emergency pause (blocks swaps/deposits, allows withdrawals).

### Asset Control

```solidity
function freezeAsset(address token, string calldata reason) external
// Can be called by ADMIN or GUARDIAN

function unfreezeAsset(address token) external
// Can be called by ADMIN or GUARDIAN
```

Freeze/unfreeze specific assets (permission symmetry).

**When an asset is frozen:**
- `isFrozen` flag set to true
- `currentAllocBps` and `targetAllocBps` automatically set to 0
- Asset excluded from pool allocation calculations
- No deposits allowed for that asset
- No swaps allowed (either as input or output)
- Withdrawals still allowed (redeem-only mode)
- Remaining assets re-balanced to sum to 100% allocation among themselves

**Unfreezing:**
- Both admin and guardian can unfreeze (permission symmetry)
- `targetAllocBps` must be manually set via `updateTargetAllocation()` after unfreezing
- This ensures intentional re-activation with proper allocation planning

### Base Token Updates

```solidity
function updateBaseAsset(address newBaseAsset) external onlyAdmin
```

Change pool's base denomination token (recalculates all prices).

### Circuit Breaker Config

```solidity
function updateCircuitBreaker(
    address token,
    address referenceAsset,
    uint16 maxDeviation
) external onlyAdmin
```

Configure automated freeze triggers.

### Target Allocation Updates

**REMOVED:** `updateTargetAllocation` - No longer needed. ALM model uses coverage-based fees, not target allocations.

---

## Guardian Permissions

The guardian role is responsible for emergency protective actions. Guardian has the following permissions:

### 1. Circuit Breaker Checks

```solidity
function checkCircuitBreaker(address token) external onlyGuardian returns (bool)
```

Trigger circuit breaker to freeze an asset. **All deviation analysis is performed off-chain.**

When triggered:
- Asset is frozen (`isFrozen = true`)
- Allocations set to 0 (`currentAllocBps = targetAllocBps = 0`)
- If base asset, entire pool is paused
- Remaining assets re-balanced

### 2. Asset Freezing/Unfreezing

```solidity
function freezeAsset(address token, string calldata reason) external
// Shared with admin - either role can call

function unfreezeAsset(address token) external
// Shared with admin - either role can call (permission symmetry)
```

Emergency freeze/unfreeze of specific assets. Guardian has symmetric permissions.

**Use cases for freezing:**
- Oracle failures
- Asset de-pegging
- Smart contract vulnerabilities in token
- Regulatory concerns

**Use cases for unfreezing:**
- Oracle restored
- De-pegging resolved
- Vulnerability patched
- False positive correction

### 3. Blacklist Management

```solidity
function blacklistAddress(address account) external onlyGuardian

function removeFromBlacklist(address account) external
// Shared with admin - either role can call (permission symmetry)
```

Add/remove addresses to/from blacklist. Guardian has symmetric permissions.

**Blacklist effects:**
- Blocked addresses cannot call `swap()` (neither as sender nor receiver)
- Can still deposit and withdraw their own funds
- Checked on every swap for both `msg.sender` and `receiver`

**Permission symmetry:**
- Guardian can add and remove from blacklist
- Admin can also add and remove from blacklist
- Allows quick response in both directions

### 4. Oracle Updates

```solidity
function updateOracle(
    address token,
    uint64 newPrice,
    uint32 newVolatility
) external onlyGuardian
```

Update internal oracle prices and volatility measurements.

**Constraints:**
- Only for assets using internal oracle (`mainOracle == address(this)`)
- Price changes limited by `maxTWAPChange` parameter
- Updates both fast and slow EMAs

### 5. Liquidity Profile Updates

```solidity
function updateLiquidityProfile(
    address token,
    LiquidityProfileParams calldata profile
) external onlyGuardian
```

Adjust liquidity distribution curves for assets.

**Guardian permissions are limited to emergency protective actions and do not include governance powers.**

---

## Treasury Permissions

### Protocol Fee Collection

```solidity
function collectProtocolFees(address[] calldata tokens) external onlyTreasury
```

Collect accrued protocol fees from specified tokens.

**Features:**
- Can collect from one or multiple tokens at once
- Only the treasury role holder can call this
- Fees are automatically transferred to the caller
- No impact on LP funds or pool operations

**Constraints:**
- Cannot access LP funds
- Cannot modify fee parameters
- Cannot pause or freeze
- Cannot add/remove assets

**Treasury role is strictly limited to collecting protocol fees.**

---

## Role Transfer Process

### Admin Transfer Example

**Day 0:**
```solidity
currentAdmin.grantRole(ADMIN_ROLE, newAdmin, currentAdmin);
// Event: RolePending(newAdmin, ADMIN_ROLE, timestamp)
```

**Day 1-3:** Pending (timelock)
```solidity
newAdmin.acceptRole(ADMIN_ROLE);
// Revert: Locked() - too early
```

**Day 4-6:** Acceptance window
```solidity
newAdmin.acceptRole(ADMIN_ROLE);
// Success!
// Event: RoleAccepted(newAdmin, ADMIN_ROLE)
// currentAdmin loses role if replacing=currentAdmin
```

**Day 7+:** Expired
```solidity
newAdmin.acceptRole(ADMIN_ROLE);
// Revert: Expired() - too late, must re-initiate
```

### Multiple Admins

**Possible** - no restriction on number:
```solidity
admin1.grantRole(ADMIN_ROLE, admin2, address(0));  // Don't replace
// After timelock + acceptance:
// Both admin1 and admin2 have ADMIN_ROLE
```

**Revoking:**
```solidity
anyAdmin.revokeRole(ADMIN_ROLE, admin2);
```

**Protection:**
```solidity
// Cannot revoke the designated main admin
if (role == ADMIN_ROLE && account == _admin) revert Unauthorized();
```

---

## Emergency Recovery

### Asset Rescue

**Purpose:** Recover stuck tokens (user mistakes, airdrops, etc.)

**Delay:** 2 days
**Validity:** 7 days after delay

```solidity
function requestRescue(address token) external onlyAdmin
```

**Flow:**
1. Admin calls `requestRescue(token)`
2. **Wait 2 days**
3. Admin calls `executeRescue()` (within 7-day window)
4. Tokens transferred to admin

**Cancellation:**
```solidity
function cancelRescue() external onlyAdmin
```

### Example

**Day 0:**
```
User accidentally sends 100 USDC to pool contract
Admin: requestRescue(USDC)
```

**Day 2:** (minimum)
```
Admin: executeRescue()
// 100 USDC sent to admin
```

**Day 9+:** (expired)
```
Admin: executeRescue()
// Revert: Expired() - must re-request
```

---

## Security Model

### Trust Assumptions

**Admin:**
- ✅ Trusted for governance (asset addition, config)
- ✅ Cannot steal user funds directly
- ✅ Can pause (but users can still withdraw)
- ⚠️ Can add malicious assets (users should verify)
- ⚠️ Can rescue accidentally sent tokens

**Guardian:**
- ✅ Limited to emergency protective actions
- ✅ Cannot add assets or change governance parameters
- ✅ Cannot upgrade contracts
- ✅ Symmetric permissions (can freeze/unfreeze, blacklist/unlist)
- ⚠️ Can freeze/unfreeze assets (but only blocks trading, allows withdrawals)
- ⚠️ Can blacklist/unlist addresses
- ⚠️ Can update internal oracle prices (within safety bounds)
- ⚠️ Requires monitoring/redundancy

**Treasury:**
- ✅ Limited to protocol fee collection only
- ✅ Cannot access LP funds
- ✅ Cannot modify any pool parameters
- ✅ Transparent on-chain (ProtocolFeesCollected event)
- ⚠️ Can collect fees at any time (no vesting)

**User:**
- ✅ Can always withdraw (even when paused)
- ✅ Slippage protection on all operations
- ✅ Minimum liquidity enforced
- ⚠️ Subject to oracle accuracy
- ⚠️ Subject to dynamic fees

### Attack Vectors & Mitigations

**1. Admin Compromise**
- Mitigation: 4-day timelock on transfers
- Monitoring: Watch for `RolePending` events
- Response: Community can exit before acceptance

**2. Guardian Compromise**
- Mitigation: Cannot steal funds or change governance
- Mitigation: Admin can override guardian actions (unfreeze, unlist)
- Mitigation: Price updates limited by `maxTWAPChange`
- Mitigation: Guardian has symmetric permissions (can undo their own actions)
- Response: Admin can revoke guardian role instantly
- Response: Users can still withdraw even if assets frozen

**3. Oracle Manipulation**
- Mitigation: Dual EMA smoothing
- Mitigation: Circuit breaker vs reference
- Mitigation: Slow EMA provides trend baseline

**4. Flash Loan Attacks**
- Mitigation: Reentrancy guards
- Mitigation: State updates before transfers
- Mitigation: Check-effects-interaction pattern

**5. Precision Loss**
- Mitigation: Safe casting with revert
- Mitigation: High precision (1e18)
- Mitigation: Overflow checks on all math

---

## Modifiers

### onlyAdmin

```solidity
modifier onlyAdmin() {
    if (!_roles[ADMIN_ROLE][msg.sender]) revert Unauthorized();
    _;
}
```

### onlyGuardian

```solidity
modifier onlyGuardian() {
    if (!_roles[GUARDIAN_ROLE][msg.sender]) revert Unauthorized();
    _;
}
```

### onlyTreasury

```solidity
modifier onlyTreasury() {
    if (!_roles[TREASURY_ROLE][msg.sender]) revert Unauthorized();
    _;
}
```

### notPaused

```solidity
modifier notPaused() {
    if (paused) revert Paused();
    _;
}
```

Applied to: `swap()`, `deposit()`
**NOT** applied to: `withdraw()` (always allowed)

### notFrozen

```solidity
modifier notFrozen(address token) {
    if (assets[token].isFrozen) revert AssetFrozen();
    _;
}
```

Applied to: `deposit()` for specific asset
Checked in: `swap()` for both input/output assets

---

## Events

```solidity
event RoleGranted(address indexed account, bytes32 indexed role);
event RolePending(address indexed account, bytes32 indexed role, uint256 timestamp);
event RoleRevoked(address indexed account, bytes32 indexed role);
event RescueRequested(address indexed requester, address indexed token, uint256 amount);
event RescueExecuted(address indexed receiver, address indexed token, uint256 amount);
event RescueCancelled(address indexed requester, address indexed token);
```

---

## Constants

```solidity
ROLE_DELAY = 4 days;
ROLE_WINDOW = 3 days;
RESCUE_DELAY = 2 days;
RESCUE_WINDOW = 7 days;
```

---

## Factory Admin

Separate from pool admin:

```solidity
contract BAMMFactory {
    address public admin;

    function upgradeBeacon(address newImpl) external {
        require(msg.sender == admin);
        beacon.upgradeTo(newImpl);
    }

    function transferAdmin(address newAdmin) external {
        require(msg.sender == admin);
        // Timelock similar to pool admin
    }
}
```

**Scope:**
- Upgrade all pools simultaneously
- No access to individual pool state
- Cannot pause/freeze
- Cannot modify pool configs

---

## Best Practices

### For Admins

1. **Use multi-sig** for admin role
2. **Monitor pending role transfers** (4-day window)
3. **Test on testnet** before mainnet config changes
4. **Communicate** asset additions to community
5. **Maintain** backup admin keys securely

### For Guardians

1. **Run redundant** guardian instances
2. **Monitor** oracle deviations and asset health
3. **Verify** price sources before submitting
4. **Alert** on extreme volatility or de-pegging
5. **Log** all actions (freezes, unfreezes, blacklists, unlists, oracle updates) for audit trail
6. **Document** reasons for all protective actions
7. **Act quickly** in both directions (freeze/unfreeze, blacklist/unlist) as situations change
8. **Coordinate** with admin for governance decisions

### For Users

1. **Verify** asset addresses before depositing
2. **Monitor** role transfer events
3. **Use** slippage protection
4. **Understand** dynamic fees
5. **Withdraw** if suspicious activity

---

## Upgrade Safety

### Beacon Upgrade Process

1. **Deploy** new implementation
2. **Test** thoroughly on testnet
3. **Audit** changes if significant
4. **Announce** upgrade with delay
5. **Execute** `factory.upgradeBeacon(newImpl)`

**All pools upgrade atomically** - no partial state.

### Storage Compatibility

**Must maintain:**
- Storage layout compatibility
- Same variable types and order
- Append-only for new variables

**Breaking changes require:**
- New deployment
- User migration
- Liquidity migration tools

---

## Future Enhancements

- **Multi-sig integration:** Gnosis Safe, Timelock contracts
- **Governance:** Token-weighted voting
- **Emergency pause automation:** Circuit breakers auto-pause
- **Decentralized guardians:** Chainlink Automation, Gelato
- **Insurance fund:** Protocol fees accumulate for coverage
- **On-chain blacklist governance:** Community voting for blacklist decisions

---

## Blacklist System

### Overview

The blacklist system allows the guardian to prevent specific addresses from swapping, providing protection against:
- Sanctioned addresses
- Exploiters/hackers
- MEV bots causing issues
- Regulatory compliance requirements

### Functionality

**Adding to blacklist:**
```solidity
function blacklistAddress(address account) external onlyGuardian
```

**Removing from blacklist:**
```solidity
function removeFromBlacklist(address account) external
// Can be called by ADMIN or GUARDIAN (permission symmetry)
```

**Checking status:**
```solidity
function isBlacklisted(address account) external view returns (bool)
```

### Effects of Blacklisting

**Blocked operations:**
- `swap()` - blocked as both sender (`msg.sender`) and receiver
  - Users cannot swap to send tokens out
  - Users cannot swap to receive tokens

**Allowed operations:**
- `deposit()` - blacklisted users can still add liquidity
- `withdraw()` - blacklisted users can still remove liquidity
- Transfers of LP tokens (ERC1155 standard)

### Swap Receiver Parameter

The `swap()` function now accepts a `receiver` parameter:

```solidity
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address receiver  // NEW: destination for swapped tokens
) external returns (uint256 amountOut)
```

**Blacklist checks:**
- Both `msg.sender` (the swapper) and `receiver` are checked
- If either is blacklisted, the transaction reverts with `Blacklisted()` error

**Use cases for receiver parameter:**
- Swapping directly to another address (reducing transactions)
- Contract-based strategies (vault swaps to user)
- Gas optimization (no intermediate transfer needed)

### Governance Process

**Blacklisting (Guardian or Admin):**
1. Guardian/admin identifies address requiring blacklisting
2. Documents reason (exploit, sanctions, etc.)
3. Calls `blacklistAddress(account)`
4. Event `AddressBlacklisted(account)` emitted

**Removal (Guardian or Admin):**
1. Guardian/admin reviews situation
2. Validates reason is no longer applicable
3. Calls `removeFromBlacklist(account)`
4. Event `AddressRemovedFromBlacklist(account)` emitted

**Permission symmetry benefits:**
- Guardian can quickly add and remove (emergency response both ways)
- Admin can override guardian decisions if needed
- Prevents prolonged false positives
- Maintains operational flexibility
- Admin can still revoke guardian role if compromised

### Events

```solidity
event AddressBlacklisted(address indexed account);
event AddressRemovedFromBlacklist(address indexed account);
```

### Best Practices

**For Guardians:**
1. **Document** all blacklist additions/removals with clear reasoning
2. **Verify** addresses before blacklisting (no typos!)
3. **Coordinate** with legal/compliance teams
4. **Monitor** blacklisted addresses for off-chain activity
5. **Review** blacklist periodically and remove when appropriate
6. **Act promptly** to remove false positives

**For Users:**
1. **Check** blacklist status before integrating
2. **Understand** that blacklist affects swap receiver too
3. **Monitor** events for blacklist changes
4. **Use** alternative addresses if blacklisted
5. **Contact** protocol team if incorrectly blacklisted
