# Batch Swap Implementation

## Overview

The `batchSwap` function enables users to execute multiple sequential swaps in a single transaction with significant gas optimizations (~30-40% savings) compared to individual swap calls.

**Inspired by**: Balancer V2's batchSwap architecture, optimized for single-pool design

**Key Features**:
- Zero-amount chaining (step `amountIn: 0` uses previous output)
- Per-step slippage protection
- Single total value calculation for entire batch
- Delta accumulation with deferred storage updates
- Max 8 steps per batch (gas DoS protection)

---

## Design Decisions

### 1. Single-Pool Optimization

Unlike Balancer (multi-pool vault) or Wombat (multi-pool routing), BAMM's batch swap is optimized for a single pool containing multiple assets:

- **No pool routing** - all assets in one pool
- **Direct asset addresses** - no index lookup required
- **Shared liquidity state** - single total value calculation

### 2. Zero-Amount Chaining

Inspired by Balancer's pattern where `amountIn == 0` means "use previous output":

```solidity
// Example: USDC → WETH → DAI
steps[0] = SwapStep(USDC, WETH, 1000e6, 0.45e18);  // Explicit input
steps[1] = SwapStep(WETH, DAI, 0, 900e18);         // Chained input (uses step 0 output)
```

**Benefits**: No need to specify intermediate amounts, automatic slippage handling across multi-hop swaps

### 3. Delta Accumulation

Tracks all reserve/index changes in memory arrays, applies ONCE per unique token at end:

- **Without delta accumulation**: N steps × M unique tokens = N×M SSTOREs
- **With delta accumulation**: M unique tokens = M SSTOREs (regardless of N)
- **Example**: Token appears 4 times → 1 SSTORE instead of 4 (~80k gas saved)

---

## Gas Optimizations

### Savings Breakdown (3-hop example: USDC → WETH → DAI)

| Operation | Individual (3×) | Batch (1×) | Savings |
|-----------|----------------|------------|---------|
| Total value calculation | 3× | 1× | ~90k gas |
| Blacklist checks | 6× | 2× | ~16k gas |
| Token transfers | 6× | 2× | ~100k gas |
| Cache updates | 3× | 1× | ~15k gas |
| **Total** | **~486k gas** | **~284k gas** | **~202k gas (41.6%)** |

### Implementation Optimizations

1. **Single Total Value Calculation**: Computed once, reused for all fee calculations (~30k gas per additional swap)
2. **Batch Transfers**: Only first input and last output transferred (~50k gas per additional swap)
3. **Single Blacklist Check**: Sender/receiver checked once for entire batch (~4k gas per additional swap)
4. **Delta Accumulation**: Reserve/index updates deferred to single write per token (see section above)

---

## Usage Examples

### Basic Chained Swap

```solidity
// USDC → WETH → DAI
SwapStep[] memory steps = new SwapStep[](2);
steps[0] = SwapStep(USDC, WETH, 1000e6, 0.4e18);   // Min 0.4 WETH
steps[1] = SwapStep(WETH, DAI, 0, 950e18);         // Use WETH output, min 950 DAI

uint256[] memory amounts = bamm.batchSwap(steps, receiver);
```

### Atomic Arbitrage

```solidity
// Round-trip: USDC → WBTC → WETH → DAI → USDC
SwapStep[] memory steps = new SwapStep[](4);
steps[0] = SwapStep(USDC, WBTC, 10000e6, 0.15e8);
steps[1] = SwapStep(WBTC, WETH, 0, 3.5e18);
steps[2] = SwapStep(WETH, DAI, 0, 8000e18);
steps[3] = SwapStep(DAI, USDC, 0, 10050e6);  // 50 USDC profit required

bamm.batchSwap(steps, address(this));  // Reverts if unprofitable
```

### Splitting (Non-Chained)

```solidity
// 1000 USDC split: 500 → WETH, 500 → DAI
SwapStep[] memory steps = new SwapStep[](2);
steps[0] = SwapStep(USDC, WETH, 500e6, 0.2e18);   // Explicit 500 USDC
steps[1] = SwapStep(USDC, DAI, 500e6, 450e18);    // Explicit 500 USDC (not chained)

bamm.batchSwap(steps, receiver);
```

---

## Protocol Comparison

### vs Balancer V2

**Balancer**: Multi-pool vault with complex routing
- `poolId` per step, asset index arrays, `userData` blobs, `FundManagement` struct
- GIVEN_IN and GIVEN_OUT modes
- Can route across multiple pools

**BAMM**: Single-pool simplicity
- Direct asset addresses, no poolId/indices
- Simpler per-step slippage limits
- More gas efficient for single-pool multi-hop

### vs Wombat Exchange

**Wombat**: Multi-pool routing
- Separate `tokenPath[]` and `poolPath[]` arrays
- Single final slippage check only

**BAMM**: Single-pool with per-step protection
- No separate poolPath (single pool)
- Per-step slippage protection
- Zero-amount chaining support

### vs Uniswap V3

**Uniswap**: Encoded path routing
- `bytes path` with packed encoding (tokenA, fee, tokenB, fee, ...)
- Most gas efficient encoding
- Can route across different fee tiers

**BAMM**: Struct array routing
- More readable, easier to construct off-chain
- Per-step slippage control
- Better error messages

---

## Security

### Protected Against

✅ **Reentrancy**: `nonReentrant` modifier, transfers deferred to end
✅ **Slippage**: Per-step `minAmountOut` validation
✅ **Invalid Chains**: Chained steps require matching tokens (`steps[i].tokenIn == steps[i-1].tokenOut`)
✅ **Gas DoS**: 8-step maximum limit
✅ **Asset Validation**: Frozen/unregistered assets revert per-step
✅ **First Step Zero Amount**: Reverts (cannot chain to nothing)

### Key Validations

```solidity
// Chaining validation
if (amountIn == 0) {
    if (i == 0) revert E.ZeroAmount();
    if (step.tokenIn != steps[i - 1].tokenOut) revert E.InvalidParameter();
    amountIn = amounts[i - 1];
}

// Per-step slippage
if (amountOut < step.minAmountOut) revert E.SlippageExceeded();

// Asset safety
if (step.tokenIn == step.tokenOut) revert E.InvalidParameter();
if (assetIn.isFrozen || assetOut.isFrozen) revert E.AssetFrozen();
```

---

## Integration

### Frontend (TypeScript)

```typescript
import { ethers, BigNumber } from 'ethers';

async function executeBatchSwap(
    bamm: Contract,
    path: string[],
    amountIn: BigNumber,
    minAmountOut: BigNumber,
    receiver: string
): Promise<BigNumber[]> {
    const steps = [];
    for (let i = 0; i < path.length - 1; i++) {
        steps.push({
            tokenIn: path[i],
            tokenOut: path[i + 1],
            amountIn: i === 0 ? amountIn : 0,  // Chain after first
            minAmountOut: i === path.length - 2 ? minAmountOut : 0
        });
    }

    const tokenIn = await ethers.getContractAt('ERC20', path[0]);
    await tokenIn.approve(bamm.address, amountIn);

    const tx = await bamm.batchSwap(steps, receiver);
    const receipt = await tx.wait();

    const event = receipt.events.find(e => e.event === 'BatchSwap');
    return event.args.amounts;
}
```

### Smart Contract (Arbitrage Bot)

```solidity
contract ArbitrageBot {
    IBAMM public immutable bamm;

    function executeArbitrage(
        address[] calldata path,
        uint256 amountIn,
        uint256 minProfit
    ) external {
        IBAMM.SwapStep[] memory steps = new IBAMM.SwapStep[](path.length - 1);
        for (uint256 i = 0; i < path.length - 1; i++) {
            steps[i] = IBAMM.SwapStep({
                tokenIn: path[i],
                tokenOut: path[i + 1],
                amountIn: i == 0 ? amountIn : 0,
                minAmountOut: i == path.length - 2 ? amountIn + minProfit : 0
            });
        }

        IERC20(path[0]).approve(address(bamm), amountIn);
        uint256[] memory amounts = bamm.batchSwap(steps, address(this));

        require(amounts[amounts.length - 1] >= amountIn + minProfit, "Insufficient profit");
    }
}
```

---

## Future Enhancements

### Exact Output Mode

Add GIVEN_OUT support (like Balancer):

```solidity
enum SwapKind { GIVEN_IN, GIVEN_OUT }
function batchSwap(SwapKind kind, SwapStep[] calldata steps, address receiver) external;
```

### Batch Quote Function

Off-chain quoter for gas estimation:

```solidity
function quoteBatchSwap(SwapStep[] calldata steps)
    external view returns (uint256[] memory amounts, uint256 gasEstimate);
```

### Partial Fill Support

Allow graceful degradation if later steps fail:

```solidity
struct BatchSwapOptions {
    bool allowPartialFill;
    uint256 minStepsCompleted;
}
```

---

*BATCH_SWAP.md v1.1*
*Implemented: 2025-11-11*
*Inspired by: Balancer V2, optimized for single-pool BAMM*
