/**
 * @title DarkPool SDK
 * @notice Complete SDK for DarkPool proof generation and transaction building
 */

// Types
export * from "./types";

// Note utilities
export {
  randomFieldElement,
  computeCommitment,
  computeNullifier,
  createNote,
  createSpendableNote,
  createLPNote,
  computeLPTokens,
  computeScaledShares,
  serializeNote,
  deserializeNote,
  addPathToNote,
  validateNote,
} from "./note";

// Merkle tree
export {
  poseidon2,
  MerkleTree,
  loadZeroValues,
  createMerkleTree,
} from "./merkle-tree";

// Proof builder
export {
  ProofBuilder,
  createProofBuilder,
} from "./proof-builder";
