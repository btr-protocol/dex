# Flash Loans Specification

## Overview

The BAMM protocol implements EIP-3156 compliant flash loans with multi-token batch extensions. Flash loans allow atomically borrowing tokens without collateral.

**Fee Strategy**:
- **Launch**: 0% (free flash loans to bootstrap ecosystem and attract arbitrageurs)
- **Target**: 0.005% (0.5 bps) - **10x cheaper than Aave** (9 bps)
- **Revenue**: 100% to protocol (LPs unaffected by flash loans)

## Key Features

### 1. EIP-3156 Compliance
- Standard `flashLoan()` function with correct event signatures
- `maxFlashLoan()` returns available liquidity (reserves minus minLiquidity)
- `flashFee()` calculates fees based on per-asset `flashFeeBps` parameter (1 unit = 0.0001%, precision = 100,000)
- Compatible with all standard EIP-3156 borrowers

**Fee Precision**: All fees use 100,000 base (1 unit = 0.0001% = 0.01 bps):
- Target flash fee: 50 units = 0.005% = 0.5 bps
- Max uint16 (65,535) = 6.5535% (well above practical limits)

### 2. Fee Distribution (Matches Swap Behavior)
Flash loan fees are split identically to swap fees:
- **Protocol Fee**: `protocolFee = fee * asset.protocolFeeBps / BPS_PRECISION`
- **LP Fee**: `lpFee = fee - protocolFee`

Protocol fees are tracked in `protocolFees[token]` mapping for later collection. LP fees accrue to existing LPs via liquidity index scaling (increases LP token redemption value).

### 3. Security Features

#### minLiquidity Enforcement
Flash loans cannot drain reserves below `asset.minLiquidity`:
```solidity
if (asset.reserves - amount < asset.minLiquidity) revert BelowMinimumLiquidity();
```

This ensures operational liquidity for swaps and withdrawals.

#### Donation Attack Prevention
Balance changes are measured from pre-transfer baseline:
```solidity
uint256 balanceBefore = token.balanceOf(address(this));
// ... outbound transfer ...
// ... callback ...
// ... repayment ...
uint256 balanceAfter = token.balanceOf(address(this));
uint256 actualRepaid = balanceAfter - balanceBefore;
```

Direct token donations during callback do NOT reduce required fee payment.

#### Safe Reserve Casting
All reserve updates use safe casting to prevent silent overflow:
```solidity
asset.reserves = LibUtils.toUint128(newReserves);
```

### 4. Fee-on-Transfer (FOT) Token Support

Assets with `feeOnTransfer` flag enabled support taxed tokens:

**Outbound Transfer FOT Handling**:
```solidity
uint256 actualSent = balanceBefore - token.balanceOf(address(this));
if (actualSent < amount && hasFeeOnTransfer(asset)) {
    // Adjust amount and fee based on actual received
    amount = actualSent;
    fee = (amount * asset.flashFeeBps) / BPS_PRECISION;
}
```

**Repayment**: Measures actual repaid amount, not nominal.

**Configuration**: Enable per-asset via:
```solidity
updateAssetFlags(token, feeOnTransfer: true);
```

### 5. Cache Maintenance

Flash loan fees update `cachedTotalValue` via delta-based O(1) update:
```solidity
$.cachedTotalValue = P.updateTotalValueDelta(
    $.cachedTotalValue,
    asset,
    oracle,
    int256(lpFee)
);
```

This ensures subsequent swap/deposit operations use up-to-date cached values.

## Multi-Token Batch Extension

### batchFlashLoan()

**Non-standard extension** allowing multiple tokens in single transaction:

```solidity
function batchFlashLoan(
    IERC3156FlashBorrower receiver,
    address[] calldata tokens,
    uint256[] calldata amounts,
    bytes calldata data
) external returns (bool);
```

#### Callback Semantics
- Calls `receiver.onFlashLoan()` **once** with first token's parameters
- Full batch info **must be encoded in `data` parameter** for receiver
- Not backwards compatible with standard EIP-3156 borrowers expecting per-token callbacks

#### Fee Distribution
Each token's fees are distributed independently:
- Per-token protocol/LP split based on that asset's `protocolFeeBps`
- LP fees accrue to that token's LPs only (not cross-asset)
- Each token's cache updated separately

#### Duplicate Tokens
Duplicate tokens in batch are allowed (e.g., flash loan DAI twice in same tx). Reserves must cover sum of all borrows for that token.

## Gas Optimizations

1. **Inline fee calculation**: Avoids redundant `flashFee()` validations (~2k gas saved)
2. **Unchecked loops**: All flash loan loops use `unchecked` arithmetic (~30 gas/iteration)
3. **Cached storage pointers**: Asset storage re-fetched once per token in batch (~50 gas/token)

## Integration Guide

### Standard Flash Loan
```solidity
contract Borrower is IERC3156FlashBorrower {
    function executeFlashLoan(address lender, address token, uint256 amount) external {
        IFlashLender(lender).flashLoan(this, token, amount, "");
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        // Use borrowed tokens
        // ...

        // Approve repayment
        IERC20(token).approve(msg.sender, amount + fee);

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
```

### Batch Flash Loan
```solidity
contract BatchBorrower is IERC3156FlashBorrower {
    function executeBatch(address lender, address[] memory tokens, uint256[] memory amounts) external {
        // Encode batch info in data parameter
        bytes memory data = abi.encode(tokens, amounts);

        IBatchFlashLender(lender).batchFlashLoan(this, tokens, amounts, data);
    }

    function onFlashLoan(
        address initiator,
        address token,
        uint256 amount,
        uint256 fee,
        bytes calldata data
    ) external returns (bytes32) {
        // Decode full batch info from data
        (address[] memory tokens, uint256[] memory amounts) = abi.decode(data, (address[], uint256[]));

        // Use all borrowed tokens
        // ...

        // Approve repayment for ALL tokens
        for (uint i = 0; i < tokens.length; i++) {
            uint256 repayAmount = amounts[i] + flashFee(tokens[i], amounts[i]);
            IERC20(tokens[i]).approve(msg.sender, repayAmount);
        }

        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}
```

## Comparison with Other Protocols

| Feature | BAMM | Balancer | Aave | Uniswap V3 |
|---------|------|----------|------|------------|
| Standard | EIP-3156 | Custom | Custom | Custom |
| Launch Fee | 0% (free) | 0% | 0.09% | Swap fee |
| Target Fee | 0.05% (0.5bps) | 0% | 0.09% (9bps) | Swap fee |
| Competitive Edge | **10x cheaper than Aave** | Free | Expensive | Variable |
| Fee Split | Protocol+LP | Protocol | Protocol | LP only |
| Batch Support | ✅ (extension) | ✅ | ✅ | ❌ |
| FOT Support | ✅ (flagged) | ❌ | ❌ | ❌ |
| minLiquidity | ✅ Enforced | ❌ | ✅ (reserve factor) | ❌ |

## Events

### FlashLoan (EIP-3156 Compliant)
```solidity
event FlashLoan(
    address indexed receiver,
    address indexed token,
    uint256 amount,
    uint256 fee
);
```

Emitted once per token in batch operations.

## Error Conditions

- `AssetNotFound`: Token not registered in pool
- `AssetFrozen`: Asset frozen by guardian
- `Unauthorized`: Flash loans disabled for asset
- `ZeroAmount`: Cannot flash loan 0 tokens
- `InsufficientReserves`: Amount exceeds available reserves
- `BelowMinimumLiquidity`: Would drain reserves below minLiquidity
- `FlashLoanCallbackFailed`: Borrower callback returned wrong selector
- `PoolPaused`: Global pool pause active

## Audit Fixes Applied

1. ✅ Flash fee distribution (protocol split + LP index accrual)
2. ✅ Cache invalidation after fee accrual
3. ✅ Safe reserve casting (prevent overflow)
4. ✅ minLiquidity enforcement (per-asset operational minimum)
5. ✅ Donation attack prevention (delta-based verification)
6. ✅ Fee-on-transfer token support (optional per-asset)
7. ✅ EIP-3156 compliant event signature
8. ✅ Unchecked loop optimizations
9. ✅ Inline fee calculation

See `FLASH_LOAN_AUDIT_FIXES.md` for detailed fix descriptions.
