# BTR DEX SDK

Modular TypeScript SDK for interacting with BTR DEX. Supports AMM flows, oracle keepers, circuit breaker guardians, and privacy features via zkSNARKs.

## Features

- 🔄 **AMM Flows**: Deposit, swap, and withdraw from AIMM pools
- 📡 **Oracles**: Real-time price feeds (Binance WebSocket, extensible)
- 🛡️ **Guardians**: Circuit breaker monitoring and protection
- 🔐 **Privacy**: zkSNARK-based private transactions (DarkPool)
- 🌳 **Tree-shakeable**: Use only what you need (light frontend bundle)
- ⚡ **Viem-powered**: Built on top of viem for type safety and performance

## Installation

```bash
# Using bun
bun add @btr/dex-sdk viem

# Using npm
npm install @btr/dex-sdk viem

# Using pnpm
pnpm add @btr/dex-sdk viem
```

## Quick Start

### Frontend Integration (Light Bundle)

Only import what you need - tree-shaking ensures you don't bundle oracle/guardian code:

```typescript
import { deposit, swap, withdraw } from '@btr/dex-sdk/flows';
import { AIMM_ABI } from '@btr/dex-sdk/abis';
import { createPublicClient, createWalletClient, http } from 'viem';
import { mainnet } from 'viem/chains';

// Setup clients
const publicClient = createPublicClient({
  chain: mainnet,
  transport: http(),
});

const walletClient = createWalletClient({
  chain: mainnet,
  transport: http(),
});

// Execute a swap
const result = await swap(publicClient, walletClient, AIMM_ABI, {
  poolAddress: '0x...',
  tokenIn: '0x...', // USDC
  tokenOut: '0x...', // ETH
  amountIn: 1000_000_000n, // 1000 USDC (6 decimals)
  slippageBps: 50, // 0.5% slippage tolerance
});

console.log(`Swap executed: ${result.hash}`);
```

### Oracle Keeper

Run a price oracle keeper that monitors Binance and updates on-chain prices:

```typescript
import { BinanceOracle } from '@btr/dex-sdk/oracles';
import { AIMM_ABI } from '@btr/dex-sdk/abis';
import { createPublicClient, createWalletClient, http } from 'viem';
import { mainnet } from 'viem/chains';

const publicClient = createPublicClient({
  chain: mainnet,
  transport: http(),
});

const walletClient = createWalletClient({
  chain: mainnet,
  transport: http(),
  account: privateKeyToAccount(process.env.KEEPER_PRIVATE_KEY),
});

const oracle = new BinanceOracle(
  publicClient,
  walletClient,
  {
    poolAddress: '0x...', // Your AIMM pool
    assets: [
      { address: '0x...', symbol: 'ETH', decimals: 18 },
      { address: '0x...', symbol: 'BTC', decimals: 8 },
      { address: '0x...', symbol: 'USDC', decimals: 6 },
    ],
    updateInterval: 60000, // Check every minute
    divergenceThreshold: 50, // Update if price diverges by 0.5%
  },
  AIMM_ABI
);

// Start monitoring (runs indefinitely)
await oracle.start();
```

### Circuit Breaker Guardian

Monitor for de-pegging events and trigger circuit breakers:

```typescript
import { CircuitBreakerGuardian } from '@btr/dex-sdk/guardians';
import { AIMM_ABI } from '@btr/dex-sdk/abis';

const guardian = new CircuitBreakerGuardian(
  publicClient,
  walletClient,
  {
    poolAddress: '0x...',
    assets: [
      {
        address: '0x...', // USDC
        name: 'USDC',
        referenceAsset: '0x...', // DAI
        maxDivergence: 100, // 1% - freeze if USDC deviates > 1% from DAI
      },
      {
        address: '0x...', // wstETH
        name: 'wstETH',
        referenceAsset: '0x...', // WETH
        maxDivergence: 300, // 3% - freeze if relative weekly change differs by > 3%
      },
    ],
    checkInterval: 300000, // Check every 5 minutes
    cooldownPeriod: 3600, // 1 hour cooldown
  },
  AIMM_ABI,
  oracleProvider // Implement OracleProvider interface
);

await guardian.start();
```

### DarkPool Private Transactions

Create private deposits and withdrawals using zkSNARKs:

```typescript
import { Note, MerkleTree, ProofBuilder } from '@btr/dex-sdk/darkpool';
import { DARKPOOL_ABI } from '@btr/dex-sdk/abis';

// Create a private note
const amount = 1000000000000000000n; // 1 ETH
const note = Note.createRandom(amount);

// Deposit (public)
const commitment = note.getCommitment();
const encryptedNote = note.encrypt();

await walletClient.writeContract({
  address: '0x...', // DarkPool address
  abi: DARKPOOL_ABI,
  functionName: 'deposit',
  args: [commitment, encryptedNote],
  value: amount,
});

// Later: Withdraw privately
const merkleTree = new MerkleTree(20); // Load commitments
const proof = await ProofBuilder.buildWithdrawProof({
  note,
  recipient: '0x...', // Recipient address
  relayer: '0x0000000000000000000000000000000000000000',
  fee: 0n,
  refund: 0n,
  merkleTree,
});

await walletClient.writeContract({
  address: '0x...', // DarkPool address
  abi: DARKPOOL_ABI,
  functionName: 'withdraw',
  args: [
    proof.proof,
    proof.root,
    proof.nullifierHash,
    proof.recipient,
    proof.relayer,
    proof.fee,
    proof.refund,
  ],
});
```

## Module Structure

The SDK is organized into tree-shakeable modules:

```
@btr/dex-sdk/
├── /abis        - Contract ABIs (AIMM, DarkPool)
├── /common      - Shared types, constants, utilities
├── /flows       - Transaction builders (deposit, swap, withdraw)
├── /oracles     - Price oracle implementations (Binance, extensible)
├── /guardians   - Circuit breaker and monitoring
├── /darkpool    - Privacy features (notes, Merkle trees, proofs)
└── /circuits    - ZK circuit utilities
```

### Import What You Need

Frontend (light bundle):
```typescript
import { swap } from '@btr/dex-sdk/flows';
import { AIMM_ABI } from '@btr/dex-sdk/abis';
```

Backend keeper:
```typescript
import { BinanceOracle } from '@btr/dex-sdk/oracles';
import { CircuitBreakerGuardian } from '@btr/dex-sdk/guardians';
```

Privacy features:
```typescript
import { Note, MerkleTree, ProofBuilder } from '@btr/dex-sdk/darkpool';
```

## API Reference

### Flows

#### `deposit(publicClient, walletClient, poolAbi, params)`

Deposit tokens into a AIMM pool and receive LP tokens.

**Parameters:**
- `publicClient`: viem PublicClient
- `walletClient`: viem WalletClient
- `poolAbi`: AIMM contract ABI
- `params`:
  - `poolAddress`: Pool contract address
  - `token`: Token to deposit
  - `amount`: Amount to deposit (in wei)
  - `minLpTokens?`: Minimum LP tokens to receive (optional, calculated from slippage)
  - `slippageBps?`: Slippage tolerance in basis points (e.g., 50 = 0.5%)

**Returns:** `Promise<{ hash: Hash }>`

#### `swap(publicClient, walletClient, poolAbi, params)`

Swap one token for another in a AIMM pool.

**Parameters:**
- `params`:
  - `poolAddress`: Pool contract address
  - `tokenIn`: Input token address
  - `tokenOut`: Output token address
  - `amountIn`: Input amount (in wei)
  - `minAmountOut?`: Minimum output amount (optional, calculated from slippage)
  - `slippageBps?`: Slippage tolerance in basis points

**Returns:** `Promise<{ hash: Hash }>`

#### `withdraw(publicClient, walletClient, poolAbi, params)`

Withdraw tokens from a AIMM pool by burning LP tokens.

**Parameters:**
- `params`:
  - `poolAddress`: Pool contract address
  - `token`: Token to withdraw
  - `lpTokens`: LP tokens to burn
  - `minAmount?`: Minimum tokens to receive (optional, calculated from slippage)
  - `slippageBps?`: Slippage tolerance in basis points

**Returns:** `Promise<{ hash: Hash }>`

### Oracles

#### `BinanceOracle`

Real-time price oracle using Binance WebSocket streams.

```typescript
const oracle = new BinanceOracle(publicClient, walletClient, config, poolAbi);
await oracle.start();
```

**Config:**
- `poolAddress`: AIMM pool to update
- `assets`: Array of assets to monitor
- `updateInterval`: How often to check prices (ms)
- `divergenceThreshold`: Trigger update if price diverges by this many bps
- `wsEndpoint?`: Custom Binance WebSocket endpoint
- `restEndpoint?`: Custom Binance REST API endpoint

### Guardians

#### `CircuitBreakerGuardian`

Monitor for de-pegging and trigger circuit breakers.

```typescript
const guardian = new CircuitBreakerGuardian(
  publicClient,
  walletClient,
  config,
  poolAbi,
  oracleProvider
);
await guardian.start();
```

**Config:**
- `poolAddress`: AIMM pool to monitor
- `assets`: Array of assets with circuit breaker configs
- `checkInterval`: How often to check (ms)
- `cooldownPeriod`: Cooldown after triggering (seconds)

### DarkPool

#### `Note`

Create and manage private notes for anonymous transactions.

```typescript
const note = Note.createRandom(amount);
const commitment = note.getCommitment();
const nullifier = note.getNullifier();
```

#### `MerkleTree`

Manage commitment Merkle tree.

```typescript
const tree = new MerkleTree(levels);
tree.insert(commitment);
const { root, pathElements, pathIndices } = tree.path(index);
```

#### `ProofBuilder`

Generate zkSNARK proofs for private transactions.

```typescript
const proof = await ProofBuilder.buildWithdrawProof({
  note,
  recipient,
  merkleTree,
  relayer,
  fee,
  refund,
});
```

## Development

```bash
# Install dependencies
bun install

# Type check
bun run typecheck

# Run tests
bun test

# Generate circuit utilities
bun run generate-zeros
bun run generate-poseidon
```

## Contributing

Contributions welcome! Please open an issue or PR.

## License

MIT
