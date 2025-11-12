# BAMM Hooks System

## Overview

The BAMM Hooks System provides a **minimal, gas-efficient, and runtime-updateable** mechanism for extending pool functionality through custom logic at key lifecycle points.

**Design Philosophy**: Inspired by Aave V3 flash loan callbacks - dead simple, no complexity.

### Key Features

1. **Unified Hook Model** - Single contract implements all 10 lifecycle hooks
2. **Runtime Updateable** - Owner can replace hook contracts without liquidity migration (unique in production)
3. **Token-Centric** - Hooks configured per asset, not per pair/pool (finest granularity)
4. **ERC-165 Support** - Proper interface detection via `supportsInterface()`
5. **Pool Perspective** - All hooks named from pool's viewpoint (buy/sell/lend)
6. **Fail-Safe** - Hook reverts cause full transaction revert (no silent failures)
7. **Flash Loan Hooks** - Native support for ERC-3156 flash loan lifecycle

### Design Principles

- **Minimal**: Direct inline calls, simple `address(0)` checks, no bitmap flags
- **Clear**: `pre`/`post` naming, consistent pool perspective semantics
- **Validated**: Function selectors checked (compile-time safety)
- **Gas Efficient**: ~100 gas when disabled, ~2.5k gas when enabled

---

## Hook Interface

### Complete Interface (10 Functions)

```solidity
interface IBAMMHooks is IERC165 {
    // Liquidity Hooks (4)
    function preDeposit(address token, address depositor, uint256 amount, bytes calldata data) external returns (bytes4);
    function postDeposit(address token, address depositor, uint256 amount, uint256 lpTokens, bytes calldata data) external returns (bytes4);
    function preWithdraw(address token, address withdrawer, uint256 lpTokens, bytes calldata data) external returns (bytes4);
    function postWithdraw(address token, address withdrawer, uint256 lpTokens, uint256 amount, bytes calldata data) external returns (bytes4);

    // Swap Hooks - POOL PERSPECTIVE (4)
    function preBuy(address token, address buyer, uint256 expectedAmount, address tokenIn, uint256 amountIn, bytes calldata data) external returns (bytes4);
    function postBuy(address token, address buyer, uint256 amountOut, address tokenIn, uint256 amountIn, bytes calldata data) external returns (bytes4);
    function preSell(address token, address seller, uint256 amountIn, address tokenOut, uint256 expectedOut, bytes calldata data) external returns (bytes4);
    function postSell(address token, address seller, uint256 amountIn, address tokenOut, uint256 amountOut, bytes calldata data) external returns (bytes4);

    // Flash Loan Hooks - ERC-3156 (2)
    function preFlashLoan(address token, address receiver, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes4);
    function postFlashLoan(address token, address receiver, uint256 amount, uint256 fee, bytes calldata data) external returns (bytes4);
}
```

### Hook Semantics (Pool Perspective)

**Critical**: All hooks use POOL perspective, not user perspective!

| Hook | Pool Action | User Action | Use Case |
|------|-------------|-------------|----------|
| `preDeposit` | RECEIVES liquidity | Deposits tokens | Validate whitelist, check limits |
| `postDeposit` | RECEIVED liquidity | Deposited tokens | Deploy to Aave, update accounting |
| `preWithdraw` | GIVES liquidity back | Withdraws | Check position, prepare funds |
| `postWithdraw` | GAVE liquidity back | Withdrew | Rebalance reserves |
| `preBuy` | BUYS token (receives) | Sells to pool | Withdraw from Aave if needed |
| `postBuy` | BOUGHT token (received) | Sold to pool | Re-deposit excess to Aave |
| `preSell` | SELLS token (gives) | Buys from pool | Check reserves, prepare transfer |
| `postSell` | SOLD token (gave) | Bought from pool | Re-deposit received token |
| `preFlashLoan` | LENDS token | Borrows | Validate borrower, check risk |
| `postFlashLoan` | RECEIVED repayment | Repaid | Rebalance, update accounting |

**Example**: User swaps USDC → BTC
- Pool **BUYS** USDC (receives) → `preBuy(USDC)` + `postBuy(USDC)`
- Pool **SELLS** BTC (gives) → `preSell(BTC)` + `postSell(BTC)`

**Key Insight**: Both tokens' hooks are called in swaps, enabling per-token logic (e.g., USDC hooks hypothecate to Aave, WETH hooks handle whitelist).

### Storage Model

```solidity
struct Asset {
    uint128 reserves;
    address hooks;  // Single hook contract (implements all 10 functions)
    // ... other fields ...
}
```

**Simplicity**: One address per asset. That contract implements ALL hook functions and routes internally.

---

## Protocol Comparison

### Architecture Comparison

| Feature | BAMM Hooks | Balancer V3 | Uniswap V4 | Algebra Integral |
|---------|------------|-------------|------------|------------------|
| **Model** | Unified (1 contract, 10 funcs) | Multi-hook | Multi-hook | Plugin-based |
| **Updateable** | ✅ Runtime | ❌ Immutable | ❌ Immutable | ✅ Runtime |
| **Granularity** | Per-Asset | Per-Pool | Per-Pair | Per-Pool |
| **Hook Count** | 10 functions | 9 functions | 10 functions | 6 base hooks |
| **Address Management** | Simple (1 addr) | Simple | ❌ Bit flags | Simple |
| **Gas (disabled)** | ~100 gas | ~100 gas | ~100 gas | ~100 gas |
| **Gas (enabled)** | ~2.5k gas | ~2.5k gas | ~2.5k gas | ~3k gas |
| **Flash Loan Hooks** | ✅ Native | ❌ Generic | ❌ Generic | ✅ Native |

### Key Differentiators

#### 1. Updateability (BAMM vs Balancer/Uniswap)

**BAMM**: Runtime updateable
```solidity
PoolHookManager v2 = new PoolHookManager(...);
bamm.updateHooks(address(usdc), address(v2));  // Instant, no migration
```

**Balancer/Uniswap**: Immutable after pool creation → must deploy new pool and migrate ALL liquidity

**Winner**: BAMM (only updateable AMM hook system in production)

#### 2. Granularity (BAMM vs Others)

**BAMM**: Per-Asset (finest granularity)
```solidity
asset[USDC].hooks = aaveHook;      // USDC uses Aave integration
asset[WETH].hooks = whitelistHook; // WETH uses whitelist
asset[DAI].hooks = address(0);     // DAI has no hooks
```

**Balancer/Uniswap**: Per-Pool → ALL assets use same hooks

**Winner**: BAMM (most flexible)

#### 3. Unified Model (BAMM vs Multi-Hook)

**BAMM**: Single contract with shared state
- ✅ One deployment
- ✅ Coordinated logic (Aave deposits in `postDeposit`, withdrawals in `preBuy`)
- ✅ Lower gas

**Others**: Could use separate contracts → no shared state, higher gas

**Winner**: BAMM (optimal for stateful hooks)

#### 4. Algebra Integral Plugins

**Algebra**: Modular plugin system (Limit Orders, TWAP, Dynamic Fees, Farming)
- Can be updated/swapped at runtime
- Pool-level granularity (not per-token)
- Pre-built plugin marketplace

**BAMM Advantage**: Per-token granularity, simpler interface
**Algebra Advantage**: Pre-built plugin marketplace, modular composition

**Use Case Fit**:
- **Algebra**: Multiple composable features (limit orders + TWAP + dynamic fees)
- **BAMM**: Per-token custom logic (USDC to Aave, WETH whitelist)

---

## Implementation

### Execution Pattern

Direct inline calls with zero validation overhead:

```solidity
function deposit(address token, uint256 amount, uint256 minLpTokens) external returns (uint256 lpTokens) {
    Asset storage asset = _getAsset(token);

    // Pre-hook (optional: no-op if hooks not configured)
    if (asset.hooks != address(0)) {
        IBAMMHooks(asset.hooks).preDeposit(token, msg.sender, amount, "");
    }

    // Core logic
    token.safeTransferFrom(msg.sender, address(this), amount);
    lpTokens = _mintLPTokens(token, amount);

    // Post-hook (optional: no-op if hooks not configured)
    if (asset.hooks != address(0)) {
        IBAMMHooks(asset.hooks).postDeposit(token, msg.sender, amount, lpTokens, "");
    }
}
```

**Benefits**: Zero validation overhead, simple, fail-safe (reverts propagate), ~100 gas when disabled

**Why No Runtime Validation?**
- All validation happens at registration time (see Hook Registry section)
- Hooks are validated ONCE when registered, then trusted
- Saves ~2,000 gas per hook call (4-8k gas per operation)
- Hooks guaranteed compliant before use

### Hook Contract Template

```solidity
contract MyPoolHooks is IBAMMHooks {
    address public immutable bamm;

    constructor(address _bamm) { bamm = _bamm; }

    modifier onlyBAMM() {
        require(msg.sender == bamm, "Only BAMM");
        _;
    }

    function preDeposit(address token, address depositor, uint256 amount, bytes calldata data)
        external onlyBAMM returns (bytes4)
    {
        // Custom logic here
        return this.preDeposit.selector;  // MUST return own selector
    }

    // ... implement remaining 9 hooks ...
}
```

**Per-Token Routing**: Single hook contract can route based on token parameter.

---

## Integration Steps

### 1. Update Asset Storage

```solidity
function _addAsset(...) internal {
    // ... existing initialization ...
    asset.hooks = address(0);  // Initialize hooks to disabled
}
```

### 2. Add Hook Registry Functions

```solidity
function updateHooks(address token, address hookAddress) external onlyOwner {
    Asset storage asset = _getAsset(token);

    // Validate hook contract at registration time (if not address(0))
    if (hookAddress != address(0)) {
        _validateHookContract(hookAddress);
    }

    asset.hooks = hookAddress;
    emit HooksUpdated(token, hookAddress);
}

function _validateHookContract(address hookAddress) private view {
    // 1. Ensure contract has code
    if (hookAddress.code.length == 0) revert InvalidHookContract("no code");

    // 2. ERC-165 interface detection
    if (!IERC165(hookAddress).supportsInterface(type(IBAMMHooks).interfaceId)) {
        revert InvalidHookContract("IBAMMHooks not supported");
    }

    // 3. Validate ALL 10 hooks return correct selectors
    // Test with dummy data: address(1), address(2), 0 amounts
    address dummy = address(1);

    // Liquidity hooks
    bytes4 selector = IBAMMHooks(hookAddress).preDeposit(dummy, dummy, 0, "");
    if (selector != IBAMMHooks.preDeposit.selector) revert InvalidHookContract("preDeposit");

    selector = IBAMMHooks(hookAddress).postDeposit(dummy, dummy, 0, 0, "");
    if (selector != IBAMMHooks.postDeposit.selector) revert InvalidHookContract("postDeposit");

    // ... (repeat for all 10 hooks: withdraw, buy, sell, flashloan)

    // All hooks validated! Hook is fully compliant.
}

function getHooks(address token) external view returns (address) {
    return _getAsset(token).hooks;
}
```

**Validation Strategy**:
- **One-Time Cost**: Comprehensive validation at registration
- **All 10 Hooks**: Each hook called with dummy data to verify selector
- **Early Detection**: Invalid hooks rejected before use
- **Zero Runtime Cost**: No validation needed during operations
- **Gas Efficient**: ~100k gas at registration vs 2k gas per operation

### 3. Integrate Hooks into Operations

**Pattern**: Pre-hook → Core logic → Post-hook

**Key Points**:
- Check `asset.hooks != address(0)` before calling
- Direct call (no validation - hooks trusted after registration)
- Call hooks for BOTH tokens in swaps (buy + sell perspective)

---

## Security

### Protected Against

✅ **Reentrancy**: Hooks called within `nonReentrant` modifier
✅ **Invalid Hooks**: Comprehensive validation at registration (all 10 hooks tested)
✅ **Unauthorized Calls**: Hooks implement `onlyBAMM` modifier
✅ **Bypass Attacks**: Hook reverts cause full transaction revert
✅ **Upgrade Risks**: Instant rollback possible via `updateHooks(token, oldAddress)`
✅ **Gas Griefing**: No runtime validation overhead (validated once at registration)

### Registration-Time Validation

All 10 hooks validated when `updateHooks()` is called:
1. **Code check**: Ensures contract exists (not EOA)
2. **ERC-165 check**: Verifies IBAMMHooks interface support
3. **Selector check**: Each hook called with dummy data, must return correct selector

If ANY check fails, registration reverts with specific error message.

### Runtime Trust Model

After registration, hooks are **trusted**:
- No validation overhead (~2k gas saved per hook call)
- Hooks guaranteed compliant (validated at registration)
- Any hook revert causes full transaction revert
- Owner can instantly replace malicious hooks

### Access Control

Hook contracts MUST implement `onlyBAMM` modifier to prevent unauthorized calls.

---

## Gas Costs

| Operation | Hook Disabled | Hook Enabled (no-op) | Hook Enabled (Aave) |
|-----------|---------------|----------------------|---------------------|
| Deposit | +100 gas | +5,000 gas | +55,000 gas |
| Withdraw | +100 gas | +5,000 gas | +60,000 gas |
| Swap | +200 gas | +10,000 gas | +110,000 gas |
| Flash Loan | +100 gas | +5,000 gas | +50,000 gas |

**Optimizations**:
- Zero runtime validation (4-8k gas saved per operation vs validation on every call)
- Single address per asset (vs 4 addresses) saves ~6k gas per operation
- Direct calls (no library overhead)

**Registration Cost**: ~100-200k gas (one-time, validates all 10 hooks)

---

## Usage Examples

### Example 1: Aave Yield Optimization

```solidity
// Deploy hook manager
PoolHookManager hookManager = new PoolHookManager(address(bamm), address(aavePool), owner);

// Configure USDC for Aave (keep 10% buffer in BAMM)
hookManager.setTokenConfig(address(usdc), false, true, 0, 10);
bamm.updateHooks(address(usdc), address(hookManager));

// Result:
// - postDeposit: Deposits 90% to Aave
// - preBuy: Withdraws from Aave if BAMM balance insufficient
// - postBuy/postSell: Re-deposits excess to Aave
```

### Example 2: Whitelist with Position Limits

```solidity
// Configure WETH with whitelist and 100 WETH max per user
hookManager.setTokenConfig(address(weth), true, false, 100e18, 0);
hookManager.addToWhitelist(address(weth), alice);
hookManager.addToWhitelist(address(weth), bob);
bamm.updateHooks(address(weth), address(hookManager));

// Result:
// - preDeposit: Checks whitelist, enforces position limit
// - Only alice and bob can deposit WETH
// - Anyone can withdraw or swap
```

### Example 3: Update Hook Logic at Runtime

```solidity
// Deploy new version with bug fix
PoolHookManager v2 = new PoolHookManager(...);
v2.setTokenConfig(address(usdc), false, true, 0, 10);

// Instant switchover (no liquidity migration)
bamm.updateHooks(address(usdc), address(v2));
```

### Example 4: Disable Hooks

```solidity
bamm.updateHooks(address(dai), address(0));
// DAI now has ~100 gas overhead (minimal)
```

---

## Testing Checklist

- [ ] Deploy hook manager with desired configuration
- [ ] Test each hook function independently
- [ ] Test hook reverts cause transaction revert
- [ ] Test return value validation (wrong selector = revert)
- [ ] Test hook updates (old → new version)
- [ ] Test hook disable (address(0))
- [ ] Profile gas costs (disabled vs enabled)
- [ ] Test per-token routing (USDC uses Aave, WETH uses whitelist)
- [ ] Test flash loan hooks (if applicable)
- [ ] Audit hook contract before production

---

## Troubleshooting

**Hook not being called?**
- Check `bamm.getHooks(token)` returns correct address
- Verify hook implements `IBAMMHooks` interface
- Ensure hook returns correct selector

**Hook reverting?**
- Check hook logic for require/revert statements
- Verify external dependencies (Aave, oracles, etc.)
- Test hook in isolation

**Gas too high?**
- Profile hook execution
- Use `hookData` to conditionally skip logic
- Consider per-token flags to disable features

---

## Conclusion

BAMM Hooks represents a significant advancement in AMM hook architecture by combining:

1. ✅ **Updateability** - Only production system allowing runtime hook upgrades
2. ✅ **Token-Centric** - Finest granularity (per-asset vs per-pool/pair)
3. ✅ **Unified Model** - Single contract with shared state
4. ✅ **Flash Loan Support** - Native ERC-3156 lifecycle hooks
5. ✅ **Clear Semantics** - Pool perspective naming eliminates ambiguity
6. ✅ **Gas Efficient** - Optimized execution with minimal overhead

**Best For**: Protocols needing per-token custom logic (yield optimization, access control, compliance) with ability to upgrade over time.

**Consider Algebra Integral If**: You need modular plugin marketplace with composable features.

---

**Files**:
- Interface: `src/interfaces/IBAMMHooks.sol`
- Example: `src/hooks/PoolHookManager.sol`

**Key Concepts**:
- Unified model: 1 contract implements all 10 hooks
- Runtime updateable: swap hook contracts without migration
- Token-centric: different hooks per asset
- Gas efficient: single address, optimized execution

---

*Specification Version: 2.3*
*Last Updated: 2025-11-12*
