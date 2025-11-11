/**
 * @title DarkPool Types
 * @notice TypeScript types for DarkPool proof generation
 * @dev Matches Solidity structs and circuit inputs
 */

export type BigIntish = string | number | bigint;

// ========================================
// Circuit Types
// ========================================

/**
 * Public inputs to the JoinSplit circuit
 */
export interface PublicInputs {
  merkleRoot: bigint;
  nullifiers: bigint[];
  extDataHash: bigint;
  aspRoot: bigint;
}

/**
 * Private inputs to the JoinSplit circuit
 */
export interface PrivateInputs {
  // Circuit constants (compile-time parameters)
  chainId: bigint;
  darkPool: bigint; // Address as bigint

  // Input notes: [assetId, noteType, value, ownerKey, blinding, salt, nullifierSecret]
  inputNotes: bigint[][];

  // Merkle paths for input notes
  inputPaths: bigint[][];
  inputPathIndices: bigint[][];

  // Output notes: [assetId, noteType, value, ownerKey, blinding, salt]
  outputNotes: bigint[][];

  // External amounts per asset
  extInAmounts: bigint[];
  extOutAmounts: bigint[];

  // Asset IDs being tracked
  assetIds: bigint[];
}

/**
 * Complete witness for circuit
 */
export interface CircuitWitness extends PublicInputs, PrivateInputs {}

// ========================================
// Note Types
// ========================================

export enum NoteType {
  TOKEN = 0,
  LP = 1,
}

/**
 * Note structure matching Solidity commitment
 */
export interface Note {
  chainId: bigint;
  darkPool: bigint;
  assetId: bigint;
  noteType: NoteType;
  value: bigint;
  ownerKey: bigint;
  blinding: bigint;
  salt: bigint;

  // For LP notes: scaledShares stored in value field
  // To compute actual LP tokens: (value * liquidityIndex) / PRECISION
}

/**
 * Extended note with secret (for spending)
 */
export interface SpendableNote extends Note {
  nullifierSecret: bigint;
}

/**
 * Computed note commitment
 */
export interface NoteCommitment {
  commitment: bigint;
  note: Note;
}

/**
 * Note with merkle path (for proving membership)
 */
export interface NoteWithPath extends SpendableNote {
  leafIndex: number;
  pathElements: bigint[];
  pathIndices: bigint[];
}

// ========================================
// Transaction Types
// ========================================

export enum ActionType {
  TRANSFER = 0,
  SWAP = 1,
  LP_DEPOSIT = 2,
  LP_WITHDRAW = 3,
}

/**
 * External transaction data (matches Solidity ExtData)
 */
export interface ExtData {
  actionType: ActionType;
  assets: string[]; // Token addresses
  extIn: bigint[]; // External deposits per asset
  extOut: bigint[]; // External withdrawals per asset
  receivers: string[]; // Recipients for external withdrawals
  memoHash: bigint; // Hash of encrypted memo
  aspRoot: bigint; // Association set root (0 if disabled)
}

/**
 * Groth16 proof (matches Solidity Proof)
 */
export interface Proof {
  groth16Proof: bigint[]; // uint256[8]
  merkleRoot: bigint;
  nullifiers: bigint[];
  extDataHash: bigint;
  outCommitments: bigint[];
}

/**
 * Complete transaction data
 */
export interface Transaction {
  proof: Proof;
  extData: ExtData;
  recipientHints: string; // Encrypted hints for recipients
}

// ========================================
// Merkle Tree Types
// ========================================

/**
 * Merkle tree configuration
 */
export interface MerkleTreeConfig {
  levels: number;
  zeroValues: bigint[];
}

/**
 * Merkle proof
 */
export interface MerklePath {
  pathElements: bigint[];
  pathIndices: bigint[];
  leafIndex: number;
  root: bigint;
}

// ========================================
// Proof Generation Types
// ========================================

/**
 * Asset balance tracking
 */
export interface AssetBalance {
  assetId: bigint;
  inputSum: bigint;
  outputSum: bigint;
  extIn: bigint;
  extOut: bigint;
}

/**
 * Proof builder configuration
 */
export interface ProofBuilderConfig {
  chainId: bigint;
  darkPoolAddress: string;
  circuitWasmPath: string;
  circuitZkeyPath: string;
  verificationKeyPath?: string;
  merkleTreeLevels?: number;
}

/**
 * Transaction builder inputs
 */
export interface TransactionInputs {
  // Notes to spend
  inputNotes: NoteWithPath[];

  // New notes to create
  outputNotes: Note[];

  // External data
  actionType: ActionType;
  extIn?: Map<bigint, bigint>; // assetId -> amount
  extOut?: Map<bigint, bigint>; // assetId -> amount
  receivers?: string[];
  memo?: string;
  aspRoot?: bigint;
}

/**
 * snarkjs Groth16 proof format
 */
export interface SnarkProof {
  pi_a: BigIntish[];
  pi_b: BigIntish[][];
  pi_c: BigIntish[];
  protocol: string;
  curve: string;
}

/**
 * snarkjs public signals
 */
export type PublicSignals = BigIntish[];
