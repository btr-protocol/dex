# BTR DEX SDK

Modular TypeScript SDK for interacting with BTR DEX. Supports AMM flows, oracle keepers, circuit breaker guardians, and privacy features via zkSNARKs.

## Features

- 🔄 **AMM Flows**: Deposit, swap, and withdraw from AIMM pools
- 📡 **Oracles**: Real-time price feeds (Binance WebSocket, extensible)
- 🛡️ **Guardians**: Circuit breaker monitoring and protection
- 🔐 **Privacy**: zkSNARK-based private transactions (DarkPool)
- 🌳 **Tree-shakeable**: Use only what you need (light frontend bundle)
- ⚡ **Zero Dependencies**: Custom lightweight eth client (no viem/ethers dependency)

## Installation

```bash
# Using bun
bun add @btr/sdk

# Using npm
npm install @btr/sdk
```

## Quick Start

### Frontend Integration (Light Bundle)

Only import what you need - tree-shaking ensures you don't bundle oracle/guardian code:

```typescript
import { createWalletClient, ethCall, sendTransaction, getChainId } from '@btr/sdk/eth';
import { encodeFn, decodeFn } from '@btr/sdk/eth';
import type { Address, Hex } from '@btr/sdk/eth';

// Use injected wallet provider
const provider = window.ethereum;
const [account] = await provider.request({ method: 'eth_requestAccounts' });

// Create client
const client = createWalletClient(provider, account as Address);

// Execute a swap
const swapData = encodeFn({
  abi: POOL_ABI,
  functionName: 'swap',
  args: [tokenIn, tokenOut, amountIn, minAmountOut, recipient],
});

const txHash = await client.sendTransaction({
  to: poolAddress,
  data: swapData,
});

console.log(`Swap executed: ${txHash}`);
```

### Backend Integration (Private Key Client)

```typescript
import { createPrivateKeyClient } from '@btr/sdk/eth';

const client = createPrivateKeyClient(
  'http://localhost:8545', // RPC URL
  '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80' // Private key
);

// Sign and send transaction without user approval
const txHash = await client.sendTransaction({
  to: poolAddress,
  data: swapData,
  value: 0n,
});
```

### Oracle Keeper

Run a price oracle keeper that monitors Binance and updates on-chain prices:

```typescript
import { BinanceOracle } from '@btr/sdk/oracles';
import { createPrivateKeyClient } from '@btr/sdk/eth';

const client = createPrivateKeyClient(rpcUrl, process.env.KEEPER_PRIVATE_KEY!);

const oracle = new BinanceOracle(
  client.provider,
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
  POOL_ABI
);

// Start monitoring (runs indefinitely)
await oracle.start();
```

### Circuit Breaker Guardian

Monitor for de-pegging events and trigger circuit breakers:

```typescript
import { CircuitBreakerGuardian } from '@btr/sdk/guardians';

const guardian = new CircuitBreakerGuardian(
  client.provider,
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
  POOL_ABI,
  oracleProvider // Implement OracleProvider interface
);

await guardian.start();
```

### DarkPool Private Transactions

Create private deposits and withdrawals using zkSNARKs:

```typescript
import { Note, MerkleTree, ProofBuilder } from '@btr/sdk/darkpool';

// Create a private note
const amount = 1000000000000000000n; // 1 ETH
const note = Note.createRandom(amount);

// Deposit (public)
const commitment = note.getCommitment();
const encryptedNote = note.encrypt();

const depositData = encodeFn({
  abi: DARKPOOL_ABI,
  functionName: 'deposit',
  args: [commitment, encryptedNote],
});

await client.sendTransaction({
  to: darkPoolAddress,
  data: depositData,
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

const withdrawData = encodeFn({
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

await client.sendTransaction({
  to: darkPoolAddress,
  data: withdrawData,
});
```

## Module Structure

The SDK is organized into tree-shakeable modules:

```
@btr/sdk/
├── /eth         - Custom eth client, ABI encoder/decoder, RPC utils
├── /pool        - Pool interaction utilities
├── /utils       - Shared types, constants, utilities
├── /flows       - Transaction builders (deposit, swap, withdraw)
├── /oracles     - Price oracle implementations (Binance, extensible)
├── /guardians   - Circuit breaker and monitoring
├── /darkpool    - Privacy features (notes, Merkle trees, proofs)
└── /circuits    - ZK circuit utilities
```

### Import What You Need

Frontend (light bundle):
```typescript
import { createWalletClient, encodeFn, decodeFn } from '@btr/sdk/eth';
```

Backend keeper:
```typescript
import { createPrivateKeyClient } from '@btr/sdk/eth';
import { BinanceOracle } from '@btr/sdk/oracles';
import { CircuitBreakerGuardian } from '@btr/sdk/guardians';
```

Privacy features:
```typescript
import { Note, MerkleTree, ProofBuilder } from '@btr/sdk/darkpool';
```

## Eth Client API

The SDK includes a lightweight, zero-dependency Ethereum client:

### Client Types

```typescript
// Browser: Uses injected wallet (MetaMask, etc.)
const client = createWalletClient(window.ethereum, accountAddress);

// Backend: Uses private key for signing
const client = createPrivateKeyClient(rpcUrl, privateKey);

// Read-only: No signing capability
const client = createPublicClient(rpcUrl);
```

### ABI Encoding

```typescript
import { encodeFn, decodeFn, encodeAbiParameters, decodeAbiParameters } from '@btr/sdk/eth';

// Encode function call
const data = encodeFn({
  abi: POOL_ABI,
  functionName: 'swap',
  args: [tokenIn, tokenOut, amountIn, minOut, recipient],
});

// Decode function result
const result = decodeFn({
  abi: POOL_ABI,
  functionName: 'getSwapQuote',
  data: resultHex,
});
```

### RPC Methods

```typescript
import {
  ethCall,
  sendTransaction,
  getNativeBalance,
  getChainId,
  switchChain,
  waitForTransaction,
} from '@btr/sdk/eth';

// Read contract state
const result = await ethCall(provider, contractAddress, calldata);

// Get balance
const balance = await getNativeBalance(provider, address);

// Send transaction (requires connected wallet)
const hash = await sendTransaction(provider, { to, data, value });

// Wait for confirmation
const receipt = await waitForTransaction(provider, hash);
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
