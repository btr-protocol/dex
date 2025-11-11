# DarkPool SDK

TypeScript/Bun SDK for building zkSNARK proofs and transactions for the DarkPool privacy layer.

## Installation

```bash
cd common
bun install
```

## Quick Start

```typescript
import {
  createProofBuilder,
  createMerkleTree,
  createSpendableNote,
  addPathToNote,
  ActionType,
  NoteType,
} from "@dex/common/darkpool";

// 1. Configure proof builder
const builder = await createProofBuilder({
  chainId: 1n,
  darkPoolAddress: "0x1234...",
  circuitWasmPath: "../circuits/build/JoinSplit.wasm",
  circuitZkeyPath: "../circuits/build/JoinSplit_final.zkey",
  verificationKeyPath: "../circuits/build/verification_key.json",
  merkleTreeLevels: 32,
});

// 2. Create notes and build transaction
const tx = await builder.buildTransaction({
  inputNotes: [noteWithPath],
  outputNotes: [outputNote],
  actionType: ActionType.TRANSFER,
  extIn: new Map(),
  extOut: new Map(),
});

// 3. Submit to DarkPool contract
await darkPool.transact(tx.proof, tx.extData, tx.recipientHints);
```

## API Reference

### Note Creation

#### `createNote(params)`

Create a new note commitment.

```typescript
const { commitment, note } = await createNote({
  chainId: 1n,
  darkPool: BigInt("0x..."),
  assetId: BigInt("0x..."), // Token address
  noteType: NoteType.TOKEN,
  value: 1000n * 10n ** 6n,
  ownerKey: BigInt("0x..."),
  blinding: randomFieldElement(), // Optional
  salt: randomFieldElement(), // Optional
});
```

#### `createSpendableNote(params)`

Create a spendable note with nullifier secret.

```typescript
const { commitment, note, nullifier } = await createSpendableNote({
  chainId: 1n,
  darkPool: BigInt("0x..."),
  assetId: BigInt("0x..."),
  noteType: NoteType.TOKEN,
  value: 1000n * 10n ** 6n,
  ownerKey: BigInt("0x..."),
  nullifierSecret: randomFieldElement(), // Optional
});
```

#### `createLPNote(params)`

Create an LP note with scaled shares.

```typescript
const { commitment, note, nullifier } = await createLPNote({
  chainId: 1n,
  darkPool: BigInt("0x..."),
  assetId: BigInt("0x..."),
  scaledShares: 1000n * 10n ** 18n,
  ownerKey: BigInt("0x..."),
});

// Compute actual LP tokens from scaled shares
const lpTokens = computeLPTokens(
  scaledShares,
  liquidityIndex,
  BigInt(1e18)
);
```

### Merkle Tree

#### `createMerkleTree(zerosFilePath, levels)`

Create a merkle tree from generated zero values.

```typescript
const tree = await createMerkleTree(
  "../circuits/generated/zeros.json",
  32
);
```

#### `MerkleTree.insert(leaf)`

Insert a commitment into the tree.

```typescript
const leafIndex = tree.insert(commitment);
```

#### `MerkleTree.getProof(leafIndex)`

Get merkle proof for a leaf.

```typescript
const proof = await tree.getProof(leafIndex);
// Returns: { pathElements, pathIndices, leafIndex, root }
```

#### `MerkleTree.root()`

Compute current root.

```typescript
const root = await tree.root();
```

### Proof Building

#### `createProofBuilder(config)`

Create a proof builder instance.

```typescript
const builder = await createProofBuilder({
  chainId: 1n,
  darkPoolAddress: "0x...",
  circuitWasmPath: "./JoinSplit.wasm",
  circuitZkeyPath: "./JoinSplit_final.zkey",
  verificationKeyPath: "./verification_key.json", // Optional
  merkleTreeLevels: 32,
});
```

#### `ProofBuilder.buildTransaction(inputs)`

Build complete transaction with proof.

```typescript
const tx = await builder.buildTransaction({
  inputNotes: [noteWithPath1, noteWithPath2], // Max 2
  outputNotes: [outputNote1, outputNote2], // Max 2
  actionType: ActionType.TRANSFER,
  extIn: new Map([[assetId, amount]]), // Optional
  extOut: new Map([[assetId, amount]]), // Optional
  receivers: ["0x..."], // Optional
  memo: "Payment for services", // Optional
  aspRoot: 0n, // Optional (association set)
});
```

Returns:
```typescript
{
  proof: {
    groth16Proof: bigint[8],
    merkleRoot: bigint,
    nullifiers: bigint[],
    extDataHash: bigint,
    outCommitments: bigint[]
  },
  extData: {
    actionType: ActionType,
    assets: string[],
    extIn: bigint[],
    extOut: bigint[],
    receivers: string[],
    memoHash: bigint,
    aspRoot: bigint
  },
  recipientHints: string
}
```

#### `ProofBuilder.verifyProof(proof, publicSignals)`

Verify proof locally (requires verification key).

```typescript
const isValid = await builder.verifyProof(proof, publicSignals);
```

### Utilities

#### `randomFieldElement()`

Generate cryptographically secure random field element.

```typescript
const blinding = randomFieldElement();
const salt = randomFieldElement();
const nullifierSecret = randomFieldElement();
```

#### `computeCommitment(note)`

Compute note commitment hash.

```typescript
const commitment = await computeCommitment(note);
```

#### `computeNullifier(chainId, darkPool, nullifierSecret, ownerKey)`

Compute nullifier hash.

```typescript
const nullifier = await computeNullifier(
  chainId,
  darkPool,
  nullifierSecret,
  ownerKey
);
```

#### `serializeNote(note)` / `deserializeNote(json)`

Serialize/deserialize notes for storage.

```typescript
const json = serializeNote(spendableNote);
localStorage.setItem(`note-${commitment}`, json);

const note = deserializeNote(json);
```

#### `validateNote(note)`

Validate note format.

```typescript
validateNote(note); // Throws if invalid
```

## Transaction Types

### Private Transfer

Transfer tokens privately between parties.

```typescript
const tx = await builder.buildTransaction({
  inputNotes: [senderNoteWithPath],
  outputNotes: [receiverNote, changeNote],
  actionType: ActionType.TRANSFER,
});
```

### Private Swap

Swap one token for another privately.

```typescript
const tx = await builder.buildTransaction({
  inputNotes: [usdcNoteWithPath],
  outputNotes: [daiNote, changeNote],
  actionType: ActionType.SWAP,
});
```

### LP Deposit

Deposit tokens and receive LP note.

```typescript
const tx = await builder.buildTransaction({
  inputNotes: [tokenNoteWithPath],
  outputNotes: [lpNote],
  actionType: ActionType.LP_DEPOSIT,
});
```

### LP Withdraw

Burn LP note and receive tokens.

```typescript
const tx = await builder.buildTransaction({
  inputNotes: [lpNoteWithPath],
  outputNotes: [tokenNote],
  actionType: ActionType.LP_WITHDRAW,
});
```

### External Deposit

Deposit tokens from public balance to create private note.

```typescript
const tx = await builder.buildTransaction({
  inputNotes: [], // No private inputs
  outputNotes: [privateNote],
  actionType: ActionType.TRANSFER,
  extIn: new Map([[assetId, 1000n * 10n ** 6n]]), // Deposit 1000 USDC
});
```

### External Withdrawal

Burn private note and withdraw to public balance.

```typescript
const tx = await builder.buildTransaction({
  inputNotes: [privateNoteWithPath],
  outputNotes: [], // No private outputs
  actionType: ActionType.TRANSFER,
  extOut: new Map([[assetId, 1000n * 10n ** 6n]]), // Withdraw 1000 USDC
  receivers: ["0x..."], // Recipient address
});
```

## Examples

See `examples/` directory for complete examples:

- `private-transfer.ts` - Simple private transfer
- `private-swap.ts` - Private token swap
- `lp-deposit.ts` - Private LP deposit
- `lp-withdraw.ts` - Private LP withdrawal
- `mixed-transaction.ts` - Complex multi-asset transaction

## Type Definitions

All TypeScript types are exported from `types.ts`:

```typescript
import type {
  Note,
  SpendableNote,
  NoteWithPath,
  NoteType,
  ActionType,
  Proof,
  ExtData,
  Transaction,
  MerklePath,
  ProofBuilderConfig,
} from "@dex/common/darkpool";
```

## Security Best Practices

### Random Number Generation

Always use cryptographically secure random numbers:

```typescript
// ✅ Good
const secret = randomFieldElement();

// ❌ Bad
const secret = BigInt(Math.floor(Math.random() * 1e18));
```

### Note Storage

Store notes encrypted and backed up:

```typescript
import { encrypt, decrypt } from "./encryption";

// Store
const encrypted = await encrypt(serializeNote(note), password);
localStorage.setItem(`note-${commitment}`, encrypted);

// Retrieve
const encrypted = localStorage.getItem(`note-${commitment}`);
const note = deserializeNote(await decrypt(encrypted, password));
```

### Nullifier Secrets

Never reuse nullifier secrets across notes:

```typescript
// ✅ Good - unique secret per note
const note1 = await createSpendableNote({
  ...params,
  nullifierSecret: randomFieldElement(),
});
const note2 = await createSpendableNote({
  ...params,
  nullifierSecret: randomFieldElement(),
});

// ❌ Bad - reused secret
const secret = randomFieldElement();
const note1 = await createSpendableNote({ ...params, nullifierSecret: secret });
const note2 = await createSpendableNote({ ...params, nullifierSecret: secret });
```

## Performance

### Proof Generation

Typical proof generation times (Apple M1):

- Witness calculation: ~500ms
- Proof generation: ~2-5s
- Verification: ~50ms

For better performance:
- Use WASM witness calculator (default)
- Cache Poseidon instance
- Batch transactions when possible

### Merkle Tree

For large trees (100k+ leaves):
- Enable caching: `tree.clearCache()` after insertions
- Export/import state: `tree.exportState()` / `MerkleTree.importState()`
- Consider using on-chain merkle root updates

## Troubleshooting

### "Proof verification failed"

1. Check public inputs match exactly
2. Verify circuit version matches zkey
3. Test locally: `builder.verifyProof()`

### "Value conservation failed"

Ensure: `sum(inputs) + extIn = sum(outputs) + extOut` for each asset

### "Invalid merkle path"

1. Verify leaf exists: `tree.getLeaf(index)`
2. Recompute root: `await tree.root()`
3. Check path length matches tree levels

## License

MIT

## Support

For issues and questions:
- GitHub: https://github.com/yourusername/dex
- Docs: See `circuits/SETUP.md`
