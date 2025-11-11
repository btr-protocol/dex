/**
 * @title Merkle Tree Utilities
 * @notice Client-side incremental Poseidon merkle tree
 * @dev Matches LibMerkleTree.sol behavior
 */

import { buildPoseidon } from "circomlibjs";
import type { MerkleTreeConfig, MerklePath } from "./types";

let poseidonInstance: any = null;

/**
 * Get or build Poseidon instance (singleton)
 */
async function getPoseidon() {
  if (!poseidonInstance) {
    poseidonInstance = await buildPoseidon();
  }
  return poseidonInstance;
}

/**
 * Compute Poseidon hash of two field elements
 */
export async function poseidon2(left: bigint, right: bigint): Promise<bigint> {
  const poseidon = await getPoseidon();
  const hash = poseidon([left, right]);
  return poseidon.F.toObject(hash);
}

/**
 * Incremental Merkle Tree
 */
export class MerkleTree {
  private levels: number;
  private zeroValues: bigint[];
  private leaves: Map<number, bigint>;
  private nextIndex: number;
  private cache: Map<string, bigint>;

  constructor(config: MerkleTreeConfig) {
    this.levels = config.levels;
    this.zeroValues = config.zeroValues;
    this.leaves = new Map();
    this.nextIndex = 0;
    this.cache = new Map();

    if (this.zeroValues.length !== this.levels + 1) {
      throw new Error(
        `Invalid zero values: expected ${this.levels + 1}, got ${this.zeroValues.length}`
      );
    }
  }

  /**
   * Insert a new leaf and return its index
   */
  insert(leaf: bigint): number {
    const index = this.nextIndex;
    this.leaves.set(index, leaf);
    this.nextIndex++;

    // Clear cache as tree structure changed
    this.cache.clear();

    return index;
  }

  /**
   * Insert multiple leaves
   */
  insertBatch(leaves: bigint[]): number[] {
    const indices: number[] = [];
    for (const leaf of leaves) {
      indices.push(this.insert(leaf));
    }
    return indices;
  }

  /**
   * Get leaf at index
   */
  getLeaf(index: number): bigint | undefined {
    return this.leaves.get(index);
  }

  /**
   * Get merkle proof for a leaf
   */
  async getProof(leafIndex: number): Promise<MerklePath> {
    if (!this.leaves.has(leafIndex)) {
      throw new Error(`Leaf at index ${leafIndex} does not exist`);
    }

    const pathElements: bigint[] = [];
    const pathIndices: bigint[] = [];

    let currentIndex = leafIndex;
    let currentHash = this.leaves.get(leafIndex)!;

    for (let level = 0; level < this.levels; level++) {
      const isLeft = currentIndex % 2 === 0;
      const siblingIndex = isLeft ? currentIndex + 1 : currentIndex - 1;

      // Get sibling (from leaves or cache, or use zero value)
      let sibling: bigint;
      if (this.leaves.has(siblingIndex)) {
        sibling = await this.getNodeHash(siblingIndex, level);
      } else {
        sibling = this.zeroValues[level];
      }

      pathElements.push(sibling);
      pathIndices.push(isLeft ? 0n : 1n);

      // Compute parent hash
      if (isLeft) {
        currentHash = await poseidon2(currentHash, sibling);
      } else {
        currentHash = await poseidon2(sibling, currentHash);
      }

      currentIndex = Math.floor(currentIndex / 2);
    }

    const root = currentHash;

    return {
      pathElements,
      pathIndices,
      leafIndex,
      root,
    };
  }

  /**
   * Get hash of node at (index, level)
   */
  private async getNodeHash(index: number, level: number): Promise<bigint> {
    const cacheKey = `${level}:${index}`;

    if (this.cache.has(cacheKey)) {
      return this.cache.get(cacheKey)!;
    }

    let hash: bigint;

    if (level === 0) {
      // Leaf level
      hash = this.leaves.get(index) ?? this.zeroValues[0];
    } else {
      // Internal node
      const leftIndex = index * 2;
      const rightIndex = index * 2 + 1;

      const leftHash = await this.getNodeHash(leftIndex, level - 1);
      const rightHash = await this.getNodeHash(rightIndex, level - 1);

      hash = await poseidon2(leftHash, rightHash);
    }

    this.cache.set(cacheKey, hash);
    return hash;
  }

  /**
   * Compute current root
   */
  async root(): Promise<bigint> {
    if (this.nextIndex === 0) {
      return this.zeroValues[this.levels];
    }

    // Build tree from leaves to root
    let currentLevel: bigint[] = [];
    const maxLeafIndex = this.nextIndex - 1;

    // Level 0 (leaves)
    for (let i = 0; i <= maxLeafIndex; i++) {
      currentLevel[i] = this.leaves.get(i) ?? this.zeroValues[0];
    }

    // Build up the tree
    for (let level = 0; level < this.levels; level++) {
      const nextLevel: bigint[] = [];
      const levelSize = Math.ceil(currentLevel.length / 2);

      for (let i = 0; i < levelSize; i++) {
        const left = currentLevel[i * 2] ?? this.zeroValues[level];
        const right = currentLevel[i * 2 + 1] ?? this.zeroValues[level];
        nextLevel[i] = await poseidon2(left, right);
      }

      currentLevel = nextLevel;
    }

    return currentLevel[0] ?? this.zeroValues[this.levels];
  }

  /**
   * Verify a merkle proof
   */
  static async verifyProof(
    leaf: bigint,
    proof: MerklePath,
    root: bigint
  ): Promise<boolean> {
    let currentHash = leaf;

    for (let i = 0; i < proof.pathElements.length; i++) {
      const pathElement = proof.pathElements[i];
      const isLeft = proof.pathIndices[i] === 0n;

      if (isLeft) {
        currentHash = await poseidon2(currentHash, pathElement);
      } else {
        currentHash = await poseidon2(pathElement, currentHash);
      }
    }

    return currentHash === root;
  }

  /**
   * Get tree info
   */
  getInfo() {
    return {
      levels: this.levels,
      nextIndex: this.nextIndex,
      leafCount: this.leaves.size,
      capacity: 2 ** this.levels,
    };
  }

  /**
   * Export tree state
   */
  exportState() {
    return {
      levels: this.levels,
      nextIndex: this.nextIndex,
      leaves: Array.from(this.leaves.entries()).map(([k, v]) => [
        k,
        v.toString(),
      ]),
      zeroValues: this.zeroValues.map((z) => z.toString()),
    };
  }

  /**
   * Import tree state
   */
  static importState(state: any): MerkleTree {
    const tree = new MerkleTree({
      levels: state.levels,
      zeroValues: state.zeroValues.map((z: string) => BigInt(z)),
    });

    tree.nextIndex = state.nextIndex;
    for (const [k, v] of state.leaves) {
      tree.leaves.set(k, BigInt(v));
    }

    return tree;
  }

  /**
   * Clear cache (call after insertions)
   */
  clearCache() {
    this.cache.clear();
  }
}

/**
 * Load zero values from generated file
 */
export async function loadZeroValues(
  filePath: string
): Promise<bigint[]> {
  const fs = await import("fs/promises");
  const data = await fs.readFile(filePath, "utf-8");
  const json = JSON.parse(data);

  if (!json.zeros || !Array.isArray(json.zeros)) {
    throw new Error("Invalid zeros.json format");
  }

  return json.zeros.map((z: string) => BigInt(z));
}

/**
 * Create merkle tree from zero values file
 */
export async function createMerkleTree(
  zerosFilePath: string,
  levels?: number
): Promise<MerkleTree> {
  const zeroValues = await loadZeroValues(zerosFilePath);

  const treeLevels = levels ?? zeroValues.length - 1;

  if (treeLevels >= zeroValues.length) {
    throw new Error(
      `Requested ${treeLevels} levels but only ${zeroValues.length - 1} zero values available`
    );
  }

  return new MerkleTree({
    levels: treeLevels,
    zeroValues: zeroValues.slice(0, treeLevels + 1),
  });
}
