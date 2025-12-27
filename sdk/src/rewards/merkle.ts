/**
 * Minimal Merkle tree builder for reward distributions
 * Uses @noble/hashes for keccak256
 */

import { keccak256, toHex, concat, pad, type Hex } from '../eth/index.js';

export type MerkleTree = {
  root: Hex;
  layers: Hex[][];
};

export type MerkleLeaf = {
  index: number;
  account: string;
  amount: bigint;
};

/**
 * Build Merkle tree from leaves
 * Uses sorted pair hashing for canonical tree structure
 */
export function buildMerkleTree(leaves: Hex[]): MerkleTree {
  if (leaves.length === 0) {
    return { root: '0x' as Hex, layers: [] };
  }

  let layer = leaves.slice();
  const layers: Hex[][] = [layer];

  while (layer.length > 1) {
    const next: Hex[] = [];
    for (let i = 0; i < layer.length; i += 2) {
      const left = layer[i];
      const right = i + 1 < layer.length ? layer[i + 1] : left;
      next.push(hashPair(left, right));
    }
    layer = next;
    layers.push(layer);
  }

  return { root: layer[0], layers };
}

/**
 * Hash two nodes together (sorted for canonical ordering)
 */
function hashPair(a: Hex, b: Hex): Hex {
  const [first, second] = a.toLowerCase() < b.toLowerCase() ? [a, b] : [b, a];
  return keccak256(concat([first, second]));
}

/**
 * Get Merkle proof for a leaf at given index
 * Returns array of sibling hashes from leaf to root
 */
export function getMerkleProof(tree: MerkleTree, leafIndex: number): Hex[] {
  const proof: Hex[] = [];
  let index = leafIndex;

  for (let level = 0; level < tree.layers.length - 1; level++) {
    const layer = tree.layers[level];
    const pairIndex = index ^ 1; // Toggle last bit to get sibling
    if (pairIndex < layer.length) {
      proof.push(layer[pairIndex]);
    }
    index = index >> 1; // Move to parent index
  }

  return proof;
}

/**
 * Create leaf hash matching on-chain format:
 * keccak256(abi.encodePacked(uint256 index, address account, uint256 amount))
 */
export function makeLeaf(entry: MerkleLeaf): Hex {
  // abi.encodePacked does not pad, so we need to manually pack:
  // uint256 (32 bytes) + address (20 bytes) + uint256 (32 bytes) = 84 bytes total
  const indexHex = pad(toHex(BigInt(entry.index)), 32);
  const accountHex = entry.account.toLowerCase() as Hex;
  const amountHex = pad(toHex(entry.amount), 32);

  return keccak256(concat([indexHex, accountHex, amountHex]));
}

/**
 * Verify a Merkle proof (useful for testing)
 */
export function verifyProof(proof: Hex[], root: Hex, leaf: Hex): boolean {
  let computedHash = leaf;
  for (const sibling of proof) {
    computedHash = hashPair(computedHash, sibling);
  }
  return computedHash.toLowerCase() === root.toLowerCase();
}

/**
 * Build complete distribution from user entries
 * Returns tree + proofs for each user
 */
export type DistributionData = {
  root: Hex;
  entries: (MerkleLeaf & { proof: Hex[] })[];
  totalAmount: bigint;
};

export function buildDistribution(entries: MerkleLeaf[]): DistributionData {
  // Sort by index to ensure deterministic ordering
  const sorted = entries.slice().sort((a, b) => a.index - b.index);

  // Build leaves
  const leaves = sorted.map(makeLeaf);

  // Build tree
  const tree = buildMerkleTree(leaves);

  // Generate proofs for each entry
  const withProofs = sorted.map((entry, idx) => ({
    ...entry,
    proof: getMerkleProof(tree, idx),
  }));

  // Calculate total amount
  const totalAmount = sorted.reduce((sum, e) => sum + e.amount, 0n);

  return {
    root: tree.root,
    entries: withProofs,
    totalAmount,
  };
}
