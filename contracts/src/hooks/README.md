# BAMM Hooks - Example Implementations

This directory contains example hook implementations demonstrating the BAMM hooks system.

## Available Examples

### 1. BaseBAMMHook.sol
**Purpose**: Base contract with no-op implementations of all hook functions.

**Usage**: Inherit from this contract and override only the hooks you need.

```solidity
contract MyHook is BaseBAMMHook {
    constructor(address _bamm) BaseBAMMHook(_bamm) {}

    // Override only what you need
    function afterBuy(...) external override returns (bytes4) {
        // Custom logic
        return this.HOOK_SUCCESS.selector;
    }
}
```

### 2. AaveYieldHook.sol
**Purpose**: Automatically deposit all reserves into Aave for yield generation.

**Features**:
- Deposits 100% of reserves into Aave for maximum yield
- Withdraws from Aave before swaps if needed
- Re-deposits proceeds after swaps
- Configurable buffer option available (see comments in code)

**Use Case**: Yield optimization for stablecoins and idle reserves.

**Note**: Fees automatically compound in BAMM by default via the liquidity index mechanism. No separate fee compounding hook is needed.

### 3. WhitelistHook.sol
**Purpose**: Enforce whitelist access control on deposits.

**Features**:
- Admin-controlled whitelist
- Batch whitelist operations
- Only restricts deposits (withdrawals/swaps unrestricted)

**Use Case**: Permissioned pools, compliance requirements, early access.

## Development Guide

### Quick Start

1. **Inherit from BaseBAMMHook** for simplest development:
```solidity
import {BaseBAMMHook} from "./BaseBAMMHook.sol";

contract MyHook is BaseBAMMHook {
    constructor(address _bamm) BaseBAMMHook(_bamm) {}
}
```

2. **Override hooks as needed**:
```solidity
function beforeDeposit(
    address token,
    address depositor,
    uint256 amount,
    bytes calldata hookData
) external override onlyBAMM returns (bytes4) {
    // Your logic here
    return this.HOOK_SUCCESS.selector;
}
```

3. **Deploy and configure**:
```solidity
MyHook hook = new MyHook(address(bamm));
bamm.updateHook(token, IBAMM.HookType.DEPOSIT, address(hook));
```

### Hook Types

- **DEPOSIT**: `beforeDeposit`, `afterDeposit`
- **WITHDRAW**: `beforeWithdraw`, `afterWithdraw`
- **BUY**: `beforeBuy`, `afterBuy` (pool sells token)
- **SELL**: `beforeSell`, `afterSell` (pool buys token)

### Best Practices

✅ Always return `this.HOOK_SUCCESS.selector`
✅ Use `onlyBAMM` modifier
✅ Keep logic lightweight for gas efficiency
✅ Test thoroughly before deployment
✅ Handle reverts carefully (they fail the entire transaction)

## Common Use Cases

| Use Case | Hook Types | Example |
|----------|-----------|---------|
| Yield optimization | All | AaveYieldHook |
| Access control | DEPOSIT | WhitelistHook |
| Analytics/logging | All (after) | Custom event logger |
| MEV protection | BUY, SELL (before) | Slippage checker |
| Liquidity mining | DEPOSIT, WITHDRAW | Rewards distributor |
| Dynamic fees | BUY, SELL (before) | Oracle-based pricer |
| Position limits | DEPOSIT | Max position checker |

## Integration

See `BAMM_HOOKS_INTEGRATION_GUIDE.md` in the contracts root for complete integration instructions.

## Security

- All hooks called within BAMM's reentrancy guard
- Hooks cannot call back into BAMM (protected)
- Return value validation prevents silent failures
- Only admin can update hooks
- Hooks are optional (address(0) = disabled)

## Testing

Example test structure:

```solidity
function testHookIntegration() public {
    // 1. Deploy hook
    MyHook hook = new MyHook(address(bamm));

    // 2. Configure BAMM
    bamm.updateHook(address(usdc), IBAMM.HookType.DEPOSIT, address(hook));

    // 3. Test operation
    bamm.deposit(address(usdc), 1000e6, 0);

    // 4. Verify hook effects
    assertEq(hook.callCount(), 1);
}
```

## Gas Costs

- Hook disabled: ~100 gas overhead
- Hook enabled: ~2,500 gas + execution cost
- Deposit with hooks: ~5,000 gas overhead
- Swap with hooks: ~10,000 gas overhead (4 hooks)

## Support

For more information:
- See [HOOKS_SPECIFICATION.md](../../specs/HOOKS_SPECIFICATION.md) for complete technical specification
- Interface: `src/interfaces/IBAMMHooks.sol`
- Library: `src/libraries/LibHooks.sol`
