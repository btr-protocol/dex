/**
 * @title Note Utilities
 * @notice Functions for creating and managing DarkPool notes
 * @dev Uses Poseidon hash for commitments and nullifiers
 */

import { buildPoseidon } from "circomlibjs";
import type {
  Note,
  SpendableNote,
  NoteCommitment,
  NoteWithPath,
  MerklePath,
} from "./types";
import { NoteType } from "./types";

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
 * Generate random field element
 */
export function randomFieldElement(): bigint {
  const bytes = new Uint8Array(31); // 248 bits to stay in bn254 field
  crypto.getRandomValues(bytes);
  return BigInt("0x" + Buffer.from(bytes).toString("hex"));
}

/**
 * Compute note commitment
 * commitment = Poseidon(chainId, darkPool, assetId, noteType, value, ownerKey, blinding, salt)
 */
export async function computeCommitment(note: Note): Promise<bigint> {
  const poseidon = await getPoseidon();

  const inputs = [
    note.chainId,
    note.darkPool,
    note.assetId,
    BigInt(note.noteType),
    note.value,
    note.ownerKey,
    note.blinding,
    note.salt,
  ];

  const hash = poseidon(inputs);
  return poseidon.F.toObject(hash);
}

/**
 * Compute nullifier
 * nullifier = Poseidon(chainId, darkPool, nullifierSecret, ownerKey)
 */
export async function computeNullifier(
  chainId: bigint,
  darkPool: bigint,
  nullifierSecret: bigint,
  ownerKey: bigint
): Promise<bigint> {
  const poseidon = await getPoseidon();

  const inputs = [chainId, darkPool, nullifierSecret, ownerKey];

  const hash = poseidon(inputs);
  return poseidon.F.toObject(hash);
}

/**
 * Create a new note
 */
export async function createNote(params: {
  chainId: bigint;
  darkPool: bigint;
  assetId: bigint;
  noteType: NoteType;
  value: bigint;
  ownerKey: bigint;
  blinding?: bigint;
  salt?: bigint;
}): Promise<NoteCommitment> {
  const note: Note = {
    chainId: params.chainId,
    darkPool: params.darkPool,
    assetId: params.assetId,
    noteType: params.noteType,
    value: params.value,
    ownerKey: params.ownerKey,
    blinding: params.blinding ?? randomFieldElement(),
    salt: params.salt ?? randomFieldElement(),
  };

  const commitment = await computeCommitment(note);

  return { commitment, note };
}

/**
 * Create a spendable note (with nullifier secret)
 */
export async function createSpendableNote(params: {
  chainId: bigint;
  darkPool: bigint;
  assetId: bigint;
  noteType: NoteType;
  value: bigint;
  ownerKey: bigint;
  nullifierSecret?: bigint;
  blinding?: bigint;
  salt?: bigint;
}): Promise<{ commitment: bigint; note: SpendableNote; nullifier: bigint }> {
  const nullifierSecret = params.nullifierSecret ?? randomFieldElement();

  const note: SpendableNote = {
    chainId: params.chainId,
    darkPool: params.darkPool,
    assetId: params.assetId,
    noteType: params.noteType,
    value: params.value,
    ownerKey: params.ownerKey,
    blinding: params.blinding ?? randomFieldElement(),
    salt: params.salt ?? randomFieldElement(),
    nullifierSecret,
  };

  const commitment = await computeCommitment(note);
  const nullifier = await computeNullifier(
    note.chainId,
    note.darkPool,
    nullifierSecret,
    note.ownerKey
  );

  return { commitment, note, nullifier };
}

/**
 * Create LP note with scaled shares
 * @param scaledShares Scaled shares amount (stored in value field)
 * @param liquidityIndex Current liquidity index (for reference, not stored in note)
 */
export async function createLPNote(params: {
  chainId: bigint;
  darkPool: bigint;
  assetId: bigint;
  scaledShares: bigint;
  ownerKey: bigint;
  nullifierSecret?: bigint;
  blinding?: bigint;
  salt?: bigint;
}): Promise<{ commitment: bigint; note: SpendableNote; nullifier: bigint }> {
  return createSpendableNote({
    ...params,
    noteType: NoteType.LP,
    value: params.scaledShares, // Store scaledShares in value field
  });
}

/**
 * Compute LP tokens from scaled shares
 * lpTokens = (scaledShares * liquidityIndex) / PRECISION
 */
export function computeLPTokens(
  scaledShares: bigint,
  liquidityIndex: bigint,
  precision: bigint = BigInt(1e18)
): bigint {
  return (scaledShares * liquidityIndex) / precision;
}

/**
 * Compute scaled shares from LP tokens
 * scaledShares = (lpTokens * PRECISION) / liquidityIndex
 */
export function computeScaledShares(
  lpTokens: bigint,
  liquidityIndex: bigint,
  precision: bigint = BigInt(1e18)
): bigint {
  return (lpTokens * precision) / liquidityIndex;
}

/**
 * Serialize note to JSON (for storage/transmission)
 */
export function serializeNote(note: SpendableNote): string {
  return JSON.stringify({
    chainId: note.chainId.toString(),
    darkPool: note.darkPool.toString(),
    assetId: note.assetId.toString(),
    noteType: note.noteType,
    value: note.value.toString(),
    ownerKey: note.ownerKey.toString(),
    blinding: note.blinding.toString(),
    salt: note.salt.toString(),
    nullifierSecret: note.nullifierSecret.toString(),
  });
}

/**
 * Deserialize note from JSON
 */
export function deserializeNote(json: string): SpendableNote {
  const obj = JSON.parse(json);
  return {
    chainId: BigInt(obj.chainId),
    darkPool: BigInt(obj.darkPool),
    assetId: BigInt(obj.assetId),
    noteType: obj.noteType as NoteType,
    value: BigInt(obj.value),
    ownerKey: BigInt(obj.ownerKey),
    blinding: BigInt(obj.blinding),
    salt: BigInt(obj.salt),
    nullifierSecret: BigInt(obj.nullifierSecret),
  };
}

/**
 * Add merkle path to note
 */
export function addPathToNote(
  note: SpendableNote,
  path: MerklePath
): NoteWithPath {
  return {
    ...note,
    leafIndex: path.leafIndex,
    pathElements: path.pathElements,
    pathIndices: path.pathIndices,
  };
}

/**
 * Validate note format
 */
export function validateNote(note: Note): void {
  if (note.chainId < 0n) throw new Error("Invalid chainId");
  if (note.darkPool < 0n) throw new Error("Invalid darkPool address");
  if (note.assetId < 0n) throw new Error("Invalid assetId");
  if (note.noteType !== NoteType.TOKEN && note.noteType !== NoteType.LP) {
    throw new Error("Invalid noteType");
  }
  if (note.value < 0n) throw new Error("Invalid value");
  if (note.ownerKey < 0n) throw new Error("Invalid ownerKey");
  if (note.blinding < 0n) throw new Error("Invalid blinding");
  if (note.salt < 0n) throw new Error("Invalid salt");
}
