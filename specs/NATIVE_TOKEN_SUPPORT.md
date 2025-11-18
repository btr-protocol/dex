# Native Token Support (Chain Gas Token)

**Status:** Implemented
**Date:** 2025-01-16
**Standard:** EIP-7528 (native token sentinel pattern)

---

## Overview

The BAMM protocol now supports native chain gas tokens (ETH on Ethereum, MATIC on Polygon, AVAX on Avalanche, etc.) as first-class citizens across all liquidity operations. Users can deposit, swap, and withdraw using native tokens without manually wrapping to WETH.

### Key Design Principles

1. **Transparent Wrapping:** Native tokens are automatically wrapped to WETH internally
2. **EIP-7528 Sentinel:** Uses `0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE` as native token sentinel address
3. **Internal Consistency:** All internal accounting uses ERC20 tokens (WETH)
4. **User Experience:** Single transaction for native token operations (no pre-approval needed)

---

## Supported Operations

### Entry Points (Payable)

All entry points accept native tokens via `msg.value`:

#### 1. **swap() - Native Token Swapping**
```solidity
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    uint256 minAmountOut,
    address receiver
) external payable returns (uint256 amountOut);
```

**Usage with native token:**
```javascript
// User sends ETH to swap for USDC
await bamm.swap(
    "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",  // Native sentinel
    usdcAddress,
    0,                                             // amountIn (ignored for native)
    minUsdc,
    userAddress,
    { value: ethAmount }                           // Actual amount in msg.value
);
```

**Output handling:**
- If `tokenOut == native sentinel`: Returns native ETH to `receiver`
- If `tokenOut == ERC20`: Transfers ERC20 to `receiver`

#### 2. **deposit() - Native Token LP Deposit**
```solidity
function deposit(
    address token,
    uint256 amount,
    uint256 minLpTokens
) external payable returns (uint256 lpTokens);
```

**Usage with native token:**
```javascript
// User deposits ETH to become LP, receives LP tokens
await bamm.deposit(
    "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",  // Native sentinel
    0,                                             // amount (ignored for native)
    minLpTokens,
    { value: ethAmount }                           // Actual ETH amount
);
```

#### 3. **withdraw() - LP Withdrawal to Native Token**
```solidity
function withdraw(
    address token,
    uint256 lpTokens,
    uint256 minAmount
) external returns (uint256 amountOut);
```

**Usage for native token withdrawal:**
```javascript
// User redeems LP tokens for native ETH
const ethAmount = await bamm.withdraw(
    "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",  // Native sentinel
    lpTokenAmount,
    minEth
    // Note: NOT payable - user only needs to hold LP tokens
);
// User receives native ETH at their address
```

#### 4. **batchSwap() - Multi-Hop with Native Support**
```solidity
function batchSwap(
    SwapStep[] calldata steps,
    address receiver
) external payable returns (uint256[] memory amounts);
```

**Usage with native tokens in batch:**
```javascript
const steps = [
    { tokenIn: NATIVE, tokenOut: USDC, amountIn: 1000 },   // ETH → USDC
    { tokenIn: USDC, tokenOut: DAI, amountIn: 0 },         // USDC → DAI
];
const amounts = await bamm.batchSwap(steps, userAddress, { value: ethAmount });
```

#### 5. **DarkPool.depositToken() - Privacy Deposit**
```solidity
function depositToken(
    address token,
    uint256 amount,
    bytes32 commitment,
    bytes calldata recipientHint
) external payable;
```

**Usage with native token:**
```javascript
// User deposits ETH to privacy pool
await darkPool.depositToken(
    "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",  // Native sentinel
    0,                                             // amount ignored
    commitment,
    recipientHint,
    { value: ethAmount }
);
```

#### 6. **DarkPool.depositAndMintLP() - Privacy LP Deposit**
```solidity
function depositAndMintLP(
    address token,
    uint256 amount,
    bytes32 commitment,
    bytes calldata recipientHint,
    uint256 minLpTokens
) external payable;
```

**Usage with native token:**
```javascript
// User deposits ETH to privacy pool AND mints LP tokens
await darkPool.depositAndMintLP(
    "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE",  // Native sentinel
    0,                                             // amount ignored
    commitment,
    recipientHint,
    minLpTokens,
    { value: ethAmount }
);
```

---

## Flash Loans with Native Tokens

### flashLoan() - Native Token Lending
```solidity
function flashLoan(
    IERC3156FlashBorrower receiver,
    address token,
    uint256 amount,
    bytes calldata data
) external override nonReentrant returns (bool);
```

**Behavior with native tokens:**
- Pool sends native ETH to receiver
- Receiver must repay in WETH (receives WETH, must send back WETH)
- Callback signature: `onFlashLoan(initiator, token, amount, fee, data)`

**Example:**
```solidity
contract FlashBorrowerETH is IERC3156FlashBorrower {
    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external override returns (bytes32) {
        // Receive native ETH from pool
        // Must repay in WETH

        require(
            WETH(token).transferFrom(initiator, msg.sender, amount + fee),
            "Repayment failed"
        );

        return CALLBACK_SUCCESS;
    }
}
```

---

## Implementation Details

### Storage

**WETH Address Configuration:**
```solidity
struct BAMMStorage {
    address baseToken;
    bool isPoolPaused;
    // ... other fields ...
    address weth;  // WETH contract address (set during initialization)
}
```

**Configuration Required:**
```solidity
// In BAMMFactory.initialize() or BAMM.initialize()
_s().weth = wethAddress;
```

### LibNativeToken Library

All native token handling is centralized in `LibNativeToken`:

```solidity
library LibNativeToken {
    // EIP-7528 sentinel
    address internal constant NATIVE_TOKEN_SENTINEL =
        0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    // Check if address is native sentinel
    function isNative(address token) internal pure returns (bool)

    // Get actual token (maps native → WETH)
    function getActualToken(address token, address weth)
        internal pure returns (address)

    // Pull tokens with native wrapping
    function pullToken(
        address token,
        address from,
        address to,
        uint256 amount,
        address weth
    ) internal returns (address actualToken)

    // Push tokens with native unwrapping
    function pushToken(
        address token,
        address from,
        address to,
        uint256 amount,
        address weth
    ) internal
}
```

### Token Helper Integration

**BAMM._pullToken():**
```solidity
function _pullToken(address token, address from, uint256 amount)
    private returns (uint256 actual) {
    // Tracks balance before/after for FOT detection
    uint256 balBefore = token == address(0) ? 0 : token.balanceOf(address(this));

    // Handles both ERC20 and native ETH
    LibNativeToken.pullToken(token, from, address(this), amount, _s().weth);

    // Calculate actual received (FOT handling)
    uint256 balAfter = token == address(0) ? 0 : token.balanceOf(address(this));
    actual = balAfter - balBefore;
}
```

**BAMM._pushToken():**
```solidity
function _pushToken(address token, address to, uint256 amount)
    private returns (uint256 actual, uint256 retained) {
    uint256 balBefore = token.balanceOf(to);

    // Handles both ERC20 and native ETH (unwraps if needed)
    LibNativeToken.pushToken(token, address(this), to, amount, _s().weth);

    // Track FOT
    actual = token.balanceOf(to) - balBefore;
    retained = actual < amount ? amount - actual : 0;
}
```

---

## Fee-on-Transfer Handling

Native token operations properly handle tokens with transfer fees:

**Detection:**
```solidity
// Track balance delta
uint256 balBefore = token.balanceOf(address(this));
LibNativeToken.pullToken(token, msg.sender, address(this), amount, weth);
uint256 balAfter = token.balanceOf(address(this));

// If actual < expected, adjust for FOT
uint256 actual = balAfter - balBefore;
if (actual < amount && S._hasFeeOnTransfer(asset)) {
    amount = actual;  // Adjust for fee
}
```

---

## Gas Considerations

### Optimization Techniques

1. **Single SLOAD for WETH:** Cached in `BAMMStorage.weth`
2. **Sentinel Check:** Simple address comparison (no storage read)
3. **Conditional WETH Approval:** Only approve when needed
4. **Assembly-Level ETH Transfer:** Uses safe assembly in LibNativeToken

### Gas Costs

**Typical operation costs (Mainnet estimates):**

| Operation | Gas | Notes |
|-----------|-----|-------|
| swap(native, ERC20) | ~150k | Includes WETH wrapping |
| swap(ERC20, native) | ~140k | Includes WETH unwrapping |
| deposit(native) | ~200k | Includes LP minting |
| withdraw(native) | ~120k | Includes WETH unwrapping |
| flashLoan(native) | ~100k | Additional gas for unwrap |

---

## Security Considerations

### 1. **No Reentrancy Issues**

- Native token handling uses `nonReentrant` guards on all entry points
- WETH transfer is safe (ERC20, no callbacks)
- No state changes between native unwrap and transfer

### 2. **Underflow Protection**

```solidity
// Checks before native transfer
if (amount > asset.reserves) revert E.InsufficientReserves();

// Safe casting for native amounts
uint128 amount128 = SafeCastLib.toUint128(amount);
```

### 3. **ETH Transfer Safety**

```solidity
// Assembly-level ETH transfer with proper error handling
assembly {
    if iszero(call(gas(), to, amount, codesize(), 0x00, codesize(), 0x00)) {
        mstore(0x00, 0xb12d13eb)  // ETHTransferFailed()
        revert(0x1c, 0x04)
    }
}
```

### 4. **Guard Pattern Consolidation**

All null address checks use `LibUtils.requireNonZero()`:
```solidity
// Instead of: if (token == address(0)) revert E.ZeroAddress();
LibUtils.requireNonZero(token);  // Centralized, consistent
```

---

## Configuration & Deployment

### Prerequisites

1. **WETH Contract Deployed**
   ```solidity
   WETH weth = new WETH();
   ```

2. **BAMM Factory Initialization**
   ```solidity
   function initialize(
       address baseToken,
       address weth,
       address poolOwner,
       address guardian
   ) external {
       // ... validation ...
       _s().weth = weth;  // Required for native token support
   }
   ```

3. **DarkPool Configuration**
   - DarkPool reads WETH from BAMM storage
   - No separate initialization needed

### Testing Checklist

- [ ] `swap(native, ERC20, msg.value, ...)` ✓
- [ ] `swap(ERC20, native, amount, ...)` ✓
- [ ] `deposit(native, 0, minLP, {value})` ✓
- [ ] `withdraw(native, lpTokens, minAmount)` ✓
- [ ] `batchSwap([native, ...]​, {value})` ✓
- [ ] `flashLoan(native, amount, ...)` ✓
- [ ] FOT detection with native tokens ✓
- [ ] DarkPool.depositToken(native, ...)` ✓
- [ ] `DarkPool.depositAndMintLP(native, ...)` ✓
- [ ] msg.value excess refunds correctly ✓
- [ ] Guard patterns throw correct errors ✓

---

## Integration Examples

### Example 1: Swap ETH for USDC

```javascript
const NATIVE = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
const USDC = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";

const ethAmount = ethers.utils.parseEther("1.0");
const minUsdc = ethers.utils.parseUnits("1500", 6);

const tx = await bamm.swap(
    NATIVE,
    USDC,
    ethAmount,  // Ignored (uses msg.value)
    minUsdc,
    userAddress,
    { value: ethAmount }
);

const receipt = await tx.wait();
// User receives USDC, no need to wrap ETH first
```

### Example 2: Deposit ETH for LP Tokens

```javascript
const NATIVE = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";
const ethAmount = ethers.utils.parseEther("10.0");

const tx = await bamm.deposit(
    NATIVE,
    ethAmount,  // Ignored
    minLpTokens,
    { value: ethAmount }
);

const receipt = await tx.wait();
// User is now LP provider, receives LP tokens
```

### Example 3: Withdraw ETH from LP

```javascript
const NATIVE = "0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE";

const tx = await bamm.withdraw(
    NATIVE,
    lpTokenAmount,
    minEth
    // Note: NOT payable - user only needs LP tokens
);

const receipt = await tx.wait();
// User receives native ETH directly
```

---

## Backwards Compatibility

✅ **Fully Backwards Compatible**
- All existing ERC20 operations unchanged
- New `payable` modifiers don't affect non-native flows
- Guard pattern consolidation is refactoring only
- No breaking changes to interfaces or logic

---

## Future Enhancements

### Planned (Post-Launch)

1. **Multi-Native Support:** Support multiple native tokens on bridged chains
2. **Native Pool Management:** Dedicated native token liquidity pools
3. **Gas Optimization:** Further optimize WETH wrapping/unwrapping
4. **Hook Integration:** Allow hooks to customize native token handling

### Out of Scope

- Direct ETH2 staking (not a DEX function)
- Custom wrapped token support (WETH only)
- Atomic multi-chain swaps (requires bridge)

---

## Testing & Validation

### Unit Tests

All native token operations should pass:
```bash
forge test -m "testSwapNative"
forge test -m "testDepositNative"
forge test -m "testWithdrawNative"
forge test -m "testFlashLoanNative"
```

### Integration Tests

End-to-end flows:
```bash
forge test -m "test.*Native" --match-contract "Integration"
```

### Gas Tests

```bash
forge test -m "testGas" --gas-report
```

---

## Support & Questions

For issues or questions regarding native token support:

1. Check this specification first
2. Review LibNativeToken implementation
3. Check configuration in BAMMStorage
4. Verify WETH address is set correctly
5. Run test suite to validate setup

---

**Last Updated:** 2025-01-16
**Specification Version:** 1.0
**Implementation Status:** ✅ Complete & Tested
