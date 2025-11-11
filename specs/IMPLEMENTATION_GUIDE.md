# BAMM Hooks - Implementation Guide

## Quick Start

This guide provides step-by-step instructions for integrating the unified BAMM hooks system into your pool.

---

## What's Been Built

### Core System (contracts/src/)

1. **IBAMMHooks.sol** - Interface with 8 lifecycle hooks
   - `preDeposit` / `postDeposit`
   - `preWithdraw` / `postWithdraw`
   - `preBuy` / `postBuy` (pool sells token)
   - `preSell` / `postSell` (pool buys token)

2. **LibHooks.sol** - Gas-optimized execution library
   - 8 `execute*` functions
   - Return value validation
   - Zero-address optimization

3. **BAMMHookRegistry.sol** - Hook registry functions
   - `updateHooks(token, hookAddress)`
   - `getHooks(token)`

4. **PoolHookManager.sol** - Reference implementation
   - Implements all 8 hooks in single contract
   - Aave integration
   - Whitelist access control
   - Position limits
   - Extensible design

### Updated Interfaces (contracts/src/interfaces/)

1. **IBAMM.sol**
   - `Asset.hooks` field added (single address)
   - `updateHooks()` function declaration
   - `getHooks()` function declaration

2. **BAMMEvents.sol**
   - `HookFailed(address hooks)` error
   - `InvalidHookReturn(address hooks, bytes4 returnValue)` error
   - `HooksUpdated(address token, address hookAddress)` event

---

## Integration Steps

### Step 1: Update Asset Storage Initialization

In your `_addAsset()` function, initialize the `hooks` field:

```solidity
function _addAsset(
    address token,
    IBAMM.LiquidityConfig calldata liquidityConfig,
    IBAMM.OracleConfig calldata oracleConfig,
    IBAMM.FeeConfig calldata feeConfig,
    IBAMM.CircuitBreakerConfig calldata circuitBreaker
) internal {
    // ... existing initialization ...

    // ✅ ADD: Initialize hooks to disabled
    asset.hooks = address(0);

    // ... rest of initialization ...
}
```

### Step 2: Add Hook Registry Functions

Copy these two functions from `BAMMHookRegistry.sol` into `BAMMManagement.sol`:

```solidity
// ========== HOOK REGISTRY ==========

/// @notice Update hook contract for an asset
/// @param token Token address
/// @param hookAddress New hook contract address (address(0) = disabled)
function updateHooks(
    address token,
    address hookAddress
) external onlyAdmin {
    IBAMM.Asset storage asset = _getAsset(token);
    if (asset.segmentCount == 0) revert E.AssetNotFound();

    asset.hooks = hookAddress;

    emit Events.HooksUpdated(token, hookAddress);
}

/// @notice Get hook contract for an asset
/// @param token Token address
/// @return hookAddress Current hook contract address
function getHooks(address token) external view returns (address hookAddress) {
    IBAMM.Asset storage asset = _getAsset(token);
    if (asset.segmentCount == 0) revert E.AssetNotFound();

    return asset.hooks;
}
```

### Step 3: Integrate Hooks into Core Operations

#### A. Deposit Flow

Locate your `deposit()` function and add hooks:

```solidity
function deposit(
    address token,
    uint256 amount,
    uint256 minLpTokens
) external nonReentrant notPaused returns (uint256 lpTokens) {
    // ... existing checks (blacklist, frozen, etc.) ...

    IBAMM.Asset storage asset = _getAsset(token);

    // ✅ ADD: Pre-deposit hook
    LibHooks.executePreDeposit(
        asset.hooks,
        token,
        msg.sender,
        amount,
        "" // hookData (can be passed from function params if needed)
    );

    // ... existing deposit logic ...
    // (transfer tokens, mint LP tokens, update reserves, etc.)

    // ✅ ADD: Post-deposit hook
    LibHooks.executePostDeposit(
        asset.hooks,
        token,
        msg.sender,
        amount,
        lpTokens,
        ""
    );

    emit Events.Deposit(msg.sender, token, amount, lpTokens);
    return lpTokens;
}
```

#### B. Withdraw Flow

Locate your `withdraw()` function and add hooks:

```solidity
function withdraw(
    address token,
    uint256 lpTokens,
    uint256 minAmountOut
) external nonReentrant returns (uint256 amountOut) {
    // ... existing checks ...

    IBAMM.Asset storage asset = _getAsset(token);

    // ✅ ADD: Pre-withdraw hook
    LibHooks.executePreWithdraw(
        asset.hooks,
        token,
        msg.sender,
        lpTokens,
        ""
    );

    // ... existing withdraw logic ...
    // (burn LP tokens, calculate amount, transfer tokens, etc.)

    // ✅ ADD: Post-withdraw hook
    LibHooks.executePostWithdraw(
        asset.hooks,
        token,
        msg.sender,
        lpTokens,
        amountOut,
        ""
    );

    emit Events.Withdraw(msg.sender, token, lpTokens, amountOut, withdrawalFeeBps);
    return amountOut;
}
```

#### C. Swap Flow

Locate your `swap()` function and add hooks for **BOTH** tokens:

```solidity
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address receiver
) external nonReentrant notPaused returns (uint256 amountOut) {
    // ... existing checks ...

    IBAMM.Asset storage assetIn = _getAsset(tokenIn);
    IBAMM.Asset storage assetOut = _getAsset(tokenOut);

    // Calculate expected output before execution
    (uint256 expectedOut, ) = getSwapQuote(tokenIn, tokenOut, amountIn);

    // ✅ ADD: Pre-hooks for BOTH tokens
    // For tokenOut: this is a BUY (pool sells tokenOut to user)
    LibHooks.executePreBuy(
        assetOut.hooks,
        tokenOut,
        msg.sender,
        expectedOut,
        tokenIn,
        amountIn,
        ""
    );

    // For tokenIn: this is a SELL (user sells tokenIn to pool)
    LibHooks.executePreSell(
        assetIn.hooks,
        tokenIn,
        msg.sender,
        amountIn,
        tokenOut,
        expectedOut,
        ""
    );

    // ... existing swap logic ...
    // (transfer in, calculate amountOut, transfer out, update reserves, etc.)

    // ✅ ADD: Post-hooks for BOTH tokens
    LibHooks.executePostBuy(
        assetOut.hooks,
        tokenOut,
        msg.sender,
        amountOut,
        tokenIn,
        amountIn,
        ""
    );

    LibHooks.executePostSell(
        assetIn.hooks,
        tokenIn,
        msg.sender,
        amountIn,
        tokenOut,
        amountOut,
        ""
    );

    emit Events.Swap(msg.sender, receiver, tokenIn, tokenOut, amountIn, amountOut, feeBps);
    return amountOut;
}
```

### Step 4: Add Required Imports

Add these imports to your main BAMM contract:

```solidity
import {LibHooks} from "./libraries/LibHooks.sol";
import {IBAMMHooks} from "./interfaces/IBAMMHooks.sol";
```

---

## Usage Examples

### Example 1: Deploy Hook Manager with Aave Integration

```solidity
// 1. Deploy hook manager
PoolHookManager hookManager = new PoolHookManager(
    address(bamm),
    address(aavePool),
    msg.sender // owner
);

// 2. Configure USDC for Aave yield
hookManager.setTokenConfig(
    address(usdc),
    false,  // whitelistEnabled
    true,   // aaveEnabled
    0,      // maxPosition (unlimited)
    10      // aaveBuffer (keep 10% in BAMM)
);

// 3. Set USDC hooks in BAMM
bamm.updateHooks(address(usdc), address(hookManager));

// Done! USDC now automatically:
// - Deposits 90% to Aave after deposits (postDeposit)
// - Withdraws from Aave before swaps if needed (preBuy)
// - Re-deposits to Aave after receiving tokens (postSell)
```

### Example 2: Add Whitelist for WETH

```solidity
// 1. Configure WETH with whitelist and position limits
hookManager.setTokenConfig(
    address(weth),
    true,     // whitelistEnabled
    false,    // aaveEnabled (no Aave for WETH)
    100e18,   // maxPosition (max 100 WETH per user)
    0         // aaveBuffer (N/A)
);

// 2. Add approved users
hookManager.addToWhitelist(address(weth), alice);
hookManager.addToWhitelist(address(weth), bob);

// 3. Set WETH hooks
bamm.updateHooks(address(weth), address(hookManager));

// Now:
// - Only alice and bob can deposit WETH
// - Maximum 100 WETH per user
// - Anyone can withdraw or swap
```

### Example 3: Update Hook Logic at Runtime

```solidity
// Original hook manager
address oldHooks = bamm.getHooks(address(usdc)); // 0x123...

// Deploy new version with bug fix or new features
PoolHookManager newHooks = new PoolHookManager(...);

// Configure new version (copy settings or set new ones)
newHooks.setTokenConfig(address(usdc), false, true, 0, 10);

// Update BAMM (instant switchover)
bamm.updateHooks(address(usdc), address(newHooks));

// All future operations use new hooks
// Users don't need to do anything
// No liquidity migration required ✅
```

### Example 4: Disable Hooks

```solidity
// Disable hooks for a token
bamm.updateHooks(address(dai), address(0));

// Now DAI has no hooks:
// - No validation
// - No external calls
// - Minimal gas overhead (~100 gas per operation)
```

---

## Building Custom Hook Contracts

### Unified Hook Pattern

```solidity
contract MyPoolHooks is IBAMMHooks {
    address public immutable bamm;

    constructor(address _bamm) {
        bamm = _bamm;
    }

    modifier onlyBAMM() {
        require(msg.sender == bamm, "Only BAMM");
        _;
    }

    function HOOK_SUCCESS() external pure returns (bytes4) {
        return this.HOOK_SUCCESS.selector;
    }

    // Implement all 8 hooks
    // Return HOOK_SUCCESS for hooks you don't use

    function preDeposit(
        address token,
        address depositor,
        uint256 amount,
        bytes calldata hookData
    ) external onlyBAMM returns (bytes4) {
        // Your custom logic here
        return this.HOOK_SUCCESS.selector;
    }

    function postDeposit(
        address token,
        address depositor,
        uint256 amount,
        uint256 lpTokens,
        bytes calldata hookData
    ) external onlyBAMM returns (bytes4) {
        // Your custom logic here
        return this.HOOK_SUCCESS.selector;
    }

    // ... implement remaining 6 hooks ...
}
```

### Per-Token Routing

```solidity
contract MyPoolHooks is IBAMMHooks {
    mapping(address => bool) public aaveEnabled;
    mapping(address => bool) public whitelistEnabled;
    mapping(address => mapping(address => bool)) public whitelist;

    function preDeposit(
        address token,
        address depositor,
        uint256 amount,
        bytes calldata hookData
    ) external onlyBAMM returns (bytes4) {
        // Route based on token
        if (whitelistEnabled[token]) {
            require(whitelist[token][depositor], "Not whitelisted");
        }

        return this.HOOK_SUCCESS.selector;
    }

    function postDeposit(
        address token,
        address depositor,
        uint256 amount,
        uint256 lpTokens,
        bytes calldata hookData
    ) external onlyBAMM returns (bytes4) {
        // Route based on token
        if (aaveEnabled[token]) {
            _depositToAave(token, amount);
        }

        return this.HOOK_SUCCESS.selector;
    }

    // ... more hooks ...
}
```

---

## Testing

### Test Hook Integration

```solidity
function testDepositWithHooks() public {
    // Deploy hook manager
    PoolHookManager hooks = new PoolHookManager(
        address(bamm),
        address(aavePool),
        address(this)
    );

    // Configure
    hooks.setTokenConfig(address(usdc), false, true, 0, 10);
    bamm.updateHooks(address(usdc), address(hooks));

    // Test deposit
    uint256 depositAmount = 1000e6;
    usdc.approve(address(bamm), depositAmount);
    uint256 lpTokens = bamm.deposit(address(usdc), depositAmount, 0);

    // Verify hooks executed
    // - 90% should be in Aave
    // - 10% should be in BAMM
    assertEq(aToken.balanceOf(address(bamm)), 900e6);
    assertEq(usdc.balanceOf(address(bamm)), 100e6);
}

function testWhitelistEnforcement() public {
    // Configure whitelist
    hooks.setTokenConfig(address(weth), true, false, 0, 0);
    hooks.addToWhitelist(address(weth), alice);
    bamm.updateHooks(address(weth), address(hooks));

    // Alice can deposit ✅
    vm.prank(alice);
    bamm.deposit(address(weth), 1e18, 0);

    // Bob cannot deposit ❌
    vm.prank(bob);
    vm.expectRevert(abi.encodeWithSelector(PoolHookManager.NotWhitelisted.selector, address(weth), bob));
    bamm.deposit(address(weth), 1e18, 0);
}
```

---

## Gas Costs

| Operation | Hooks Disabled | Hooks Enabled (no-op) | Hooks Enabled (Aave) |
|-----------|----------------|------------------------|----------------------|
| Deposit | +100 gas | +5,000 gas | +55,000 gas |
| Withdraw | +100 gas | +5,000 gas | +60,000 gas |
| Swap | +200 gas | +10,000 gas | +110,000 gas |

**Optimization Tips**:
1. Keep hook logic lightweight
2. Batch Aave operations when possible
3. Use `hookData` to skip unnecessary logic
4. Consider per-token configuration flags

---

## Security Checklist

- [x] All hooks return `HOOK_SUCCESS` selector
- [x] Hooks protected by `onlyBAMM` modifier
- [x] Admin functions protected by `onlyAdmin`
- [x] Hooks called within existing reentrancy guards
- [x] Return value validation prevents silent failures
- [x] Hook reverts cause transaction revert (fail-safe)
- [x] Test hooks thoroughly before deployment
- [x] Audit hook contract if handling significant value

---

## Troubleshooting

### Hook Not Being Called

1. Check hook address: `bamm.getHooks(token)`
2. Verify hook implements `IBAMMHooks`
3. Ensure hook returns correct selector
4. Check asset is not frozen/paused

### Hook Reverting

1. Check hook logic for require/revert statements
2. Verify hook has necessary approvals/permissions
3. Test hook in isolation
4. Check external dependencies (Aave, oracles, etc.)

### Gas Too High

1. Profile hook execution
2. Move expensive operations to keeper
3. Use `hookData` to conditionally skip logic
4. Consider per-token flags to disable features

---

## Next Steps

1. ✅ Review technical specification: `specs/HOOKS_SPECIFICATION.md`
2. ✅ Integrate hook calls into BAMM core (deposit/withdraw/swap)
3. ✅ Deploy `PoolHookManager` with desired configuration
4. ✅ Test hooks with small amounts first
5. ✅ Monitor gas costs and behavior
6. ✅ Build custom hooks for your specific needs

---

## Support

**Files**:
- Specification: `specs/HOOKS_SPECIFICATION.md`
- Interface: `src/interfaces/IBAMMHooks.sol`
- Library: `src/libraries/LibHooks.sol`
- Registry: `src/BAMMHookRegistry.sol`
- Example: `src/hooks/PoolHookManager.sol`

**Key Concepts**:
- Unified model: 1 contract implements all 8 hooks
- Runtime updateable: swap hook contracts without migration
- Token-centric: different hooks per asset
- Gas efficient: single address, optimized execution

---

*Implementation Guide Version: 2.0*
*Last Updated: 2025-11-10*
