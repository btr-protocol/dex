# Development Mock Tokens

## Overview

The deployment uses **mock ERC20 tokens** instead of real BSC tokens for clean, reproducible testing across all environments (local, testnet, mainnet).

## Mock Token Contract

Location: `evm/src/mocks/MockERC20.sol`

Features:
- Simple ERC20 implementation using Solady
- Public `mint(address, uint256)` function - anyone can mint
- Public `faucet(uint256)` function - mint to yourself
- Prefixed symbols (e.g., `mUSDC`, `mWETH`) to distinguish from real tokens

## Deployed Mock Tokens

### Pool Zero (Multi-Asset)
| Token | Symbol | Name | Initial Balance |
|-------|--------|------|----------------|
| USDC  | mUSDC  | Mock USD Coin | 100,000 |
| USDT  | mUSDT  | Mock Tether USD | 100,000 |
| WETH  | mWETH  | Mock Wrapped Ether | 100 |
| WBTC  | mWBTC  | Mock Wrapped Bitcoin | 10 |
| WBNB  | mWBNB  | Mock Wrapped BNB | 100 |
| SOL   | mSOL   | Mock Solana | 100 |
| ZEC   | mZEC   | Mock Zcash | 100 |
| PAXG  | mPAXG  | Mock Paxos Gold | 100 |

### Pool Stable (Stablecoins)
| Token | Symbol | Name | Initial Balance |
|-------|--------|------|----------------|
| DAI   | mDAI   | Mock Dai Stablecoin | 100,000 |
| TUSD  | mTUSD  | Mock TrueUSD | 100,000 |
| FDUSD | mFDUSD | Mock First Digital USD | 100,000 |
| USDD  | mUSDD  | Mock Decentralized USD | 100,000 |
| USDP  | mUSDP  | Mock Pax Dollar | 100,000 |
| crvUSD | mcrvUSD | Mock Curve USD | 100,000 |
| lisUSD | mlisUSD | Mock Lista USD | 100,000 |
| AUSD  | mAUSD  | Mock Agora Dollar | 100,000 |
| frxUSD | mfrxUSD | Mock Frax USD | 100,000 |

## Initial Funding

The test address `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266` is automatically funded with the initial balances above during deployment.

## Minting More Tokens

### Using Cast

```bash
# Mint 1000 mUSDC to yourself
cast send <mUSDC_ADDRESS> "mint(address,uint256)" <YOUR_ADDRESS> 1000ether --private-key <YOUR_KEY> --rpc-url http://localhost:8545

# Or use the faucet function
cast send <mUSDC_ADDRESS> "faucet(uint256)" 1000ether --private-key <YOUR_KEY> --rpc-url http://localhost:8545
```

### Using Ethers/Viem

```typescript
import { MockERC20 } from './abis/MockERC20';

const token = new Contract(tokenAddress, MockERC20.abi, signer);

// Mint to any address
await token.mint(recipientAddress, ethers.parseEther("1000"));

// Mint to yourself
await token.faucet(ethers.parseEther("1000"));
```

## Benefits

✅ **Clean**: No whale address dependencies or transfers
✅ **Reproducible**: Works identically on local, testnet, and mainnet
✅ **Flexible**: Mint unlimited amounts for testing
✅ **Identifiable**: `m` prefix clearly marks mocks in block explorers
✅ **Simple**: Public mint function - no access control needed for testing

## Production Deployment

For production (mainnet with real tokens):
1. Update deployment script to use real token addresses
2. Remove mock token deployment step
3. Configure proper initial liquidity provision
