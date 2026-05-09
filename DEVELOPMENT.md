# Development Environment Setup

This repository uses CREATE3 deterministic deployments for all user-facing contracts (BTR, Treasury, Bridge, Pools).

## Quick Start

```bash
bun run dev
```

This will:
1. Start Anvil with BSC fork (persistent state unless `--reset` flag)
2. Deploy contracts to deterministic addresses
3. Start frontend on http://localhost:3000
4. Start backend collector on http://localhost:3001

## Deterministic Deployments

### Architecture

All user-facing contracts are deployed via CREATE3 to deterministic addresses that are **consistent across all chains**:

- **Anvil (31337)** - Local development fork
- **BNB Chain (56)** - Mainnet
- **Ethereum (1)** - Mainnet
- **Base (8453)** - Mainnet
- **Arbitrum (42161)** - Mainnet

### CREATE3 Process

```
Salt Pattern: keccak256(DEPLOYER || NONCE)
Deployer: 0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3
CreateX Factory: 0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed (all chains)
```

**Result:** Same address on every chain for the same salt.

### Deterministic Addresses

| Contract | Salt File | Address Pattern |
|----------|-------------|----------------|
| Pool Zero | salts/b712_b712.txt | 0xb712... |
| Pool Stable | salts/b712_b712.txt | 0xb712... |
| Mock Tokens | salts/bbbb_bb.txt | 0xbbbb... |
| BTR Token | TBD | 0x... |
| Treasury | salts/b712_b712.txt | 0xb712... |
| Bridge | salts/b712_b712.txt | 0xb712... |

## Security

### ⚠️ CRITICAL: Private Key Management

**NEVER commit private keys to version control!**

The `DEPLOYER_PK` private key controls all deployments across all chains. If compromised:
- Attacker can deploy to YOUR deterministic addresses
- Can front-run your deployments on mainnet
- Can drain treasury if same address

### Recommended Setup

1. **Use Environment Variables**
   ```bash
   # Terminal
   export DEPLOYER_PK=0x9e135...
   bun run dev
   ```

2. **Use Local .env.local**
   ```bash
   # Create .env.local (not tracked by git)
   echo "DEPLOYER_PK=0x9e135..." > .env.local
   bun run dev
   ```

3. **Use Secrets Manager** (Production)
   - AWS Secrets Manager
   - GCP Secret Manager
   - Hashicorp Vault
   - 1Password Secrets Automation

### Current Status

- ✅ `.env` is in `.gitignore`
- ⚠️ `DEPLOYER_PK` removed from committed `.env` files
- ⚠️ Use environment variables or `.env.local` for development

## Resetting State

To start fresh (clear all state and redeploy):

```bash
bun run dev --reset
```

This will:
- Clear `.anvil/state.json`
- Clear `front/public/deployment.json`
- Redeploy all contracts to Anvil

## Troubleshooting

### Anvil won't start

```bash
# Kill existing anvil on port 8545
lsof -ti:8545 | xargs kill -9

# Check if anvil is installed
which anvil  # Should show /path/to/anvil
```

### Deployment fails

```bash
# Run deployment manually to see detailed output
cd evm
forge script script/DeployBSCFork.s.sol --rpc-url http://localhost:8545 --broadcast --code-size-limit 100000
```

### Frontend can't find contracts

1. Check `front/public/deployment.json` exists
2. Verify chainId matches deployment (31337 for Anvil)
3. Check browser console for fetch errors

## Testing Transaction Flows

### Connecting to Anvil from Wallet

1. Open http://localhost:3000
2. Click "Connect Wallet"
3. Switch network to "Localhost 31337" or "Anvil"
4. Import Anvil account for testing:
   - Address: `0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`
   - Private Key: `0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`

### Executing Transactions

All mock tokens are prefunded with mintable balances. You can:

- **Swap:** Exchange tokens (e.g., mUSDC → mWETH)
- **Deposit:** Add liquidity to pools
- **Withdraw:** Remove liquidity from pools
- **Mint:** Call `mint()` on any mock token

### Pre-funded Test Account

```
Address:  0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
Balance:  10000 ETH
Tokens:  100000 mUSDC, 100 mWETH, etc. (all mintable)
```

## Deployment Script Architecture

### `scripts/dev.ts`

- Starts Anvil with BSC fork
- Persistent state via `--state` and `--load-state` flags
- Funds DEPLOYER account via `anvil_setBalance` RPC
- Deploys contracts using `DeployBSCFork.s.sol`
- Exports addresses to `front/public/deployment.json`

### `evm/script/DeployBSCFork.s.sol`

- Uses CREATE3 via CreateX factory
- Deploys mock tokens (deterministic addresses from `salts/bbbb_bb.txt`)
- Deploys Pool Zero and Pool Stable (deterministic from `salts/b712_b712.txt`)
- Exports deployment.json and mock-tokens.json

## Configuration Files

- **`.env`** - Environment variables (not committed)
- **`.env.example`** - Template (committed)
- **`salts/b712_b712.txt`** - Pool deployment salts
- **`salts/bbbb_bb.txt`** - Mock token deployment salts
