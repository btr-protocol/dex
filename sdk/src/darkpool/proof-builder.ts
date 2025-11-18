/**
 * @title Proof Builder
 * @notice Main proof generation for DarkPool transactions
 * @dev Uses snarkjs for Groth16 proof generation and poseidon2 for hashing
 */

import { groth16 } from "snarkjs";
import { poseidon2Hash as hash2Poseidon } from "@zkpassport/poseidon2";
import type {
  ProofBuilderConfig,
  TransactionInputs,
  Transaction,
  Proof,
  ExtData,
  CircuitWitness,
  SnarkProof,
  PublicSignals,
  ActionType,
  AssetBalance,
  NoteWithPath,
  Note,
} from "./types";
import { computeCommitment } from "./note";

/**
 * Poseidon2 hash function wrapper for BN254 field (alt_bn128)
 * @dev Uses @zkpassport/poseidon2 which accepts array of inputs
 * @param inputs Variable-length array of bigints to hash
 * @returns Single bigint hash output
 */
const poseidon2Hash = (inputs: bigint[]): bigint => {
  return hash2Poseidon(inputs);
};

/**
 * Main Proof Builder
 */
export class ProofBuilder {
  private config: ProofBuilderConfig;
  private chainId: bigint;
  private darkPool: bigint;

  constructor(config: ProofBuilderConfig) {
    this.config = config;
    this.chainId = config.chainId;
    this.darkPool = BigInt(config.darkPoolAddress);
  }

  /**
   * Build complete transaction with proof using Poseidon2
   */
  async buildTransaction(inputs: TransactionInputs): Promise<Transaction> {
    // 1. Validate inputs
    this.validateInputs(inputs);

    // 2. Build circuit witness
    const witness = this.buildWitness(inputs);

    // 3. Generate proof
    const { proof, publicSignals } = await this.generateProof(witness);

    // 4. Compute output commitments
    const outCommitments = await Promise.all(
      inputs.outputNotes.map((note) => computeCommitment(note))
    );

    // 5. Build ExtData
    const extData = this.buildExtData(inputs, witness);

    // 6. Build Proof struct
    const proofStruct: Proof = {
      groth16Proof: this.formatGroth16Proof(proof),
      merkleRoot: BigInt(publicSignals[0]),
      nullifiers: [BigInt(publicSignals[1]), BigInt(publicSignals[2])],
      extDataHash: BigInt(publicSignals[3]),
      outCommitments,
    };

    return {
      proof: proofStruct,
      extData,
      recipientHints: inputs.outputNotes.length > 0 ? "0x" : "0x", // TODO: Implement encryption
    };
  }

  /**
   * Build circuit witness from transaction inputs using Poseidon2
   */
  private buildWitness(
    inputs: TransactionInputs
  ): CircuitWitness {
    const nInputs = 2;
    const nOutputs = 2;
    const maxAssets = 4;

    // Pad input notes to exactly 2
    const paddedInputs = this.padInputNotes(inputs.inputNotes, nInputs);

    // Pad output notes to exactly 2
    const paddedOutputs = this.padOutputNotes(inputs.outputNotes, nOutputs);

    // Build asset tracking
    const assetBalances = this.computeAssetBalances(
      paddedInputs,
      paddedOutputs,
      inputs.extIn ?? new Map(),
      inputs.extOut ?? new Map()
    );

    // Extract unique asset IDs (up to maxAssets)
    const assetIds = Array.from(assetBalances.keys()).slice(0, maxAssets);
    while (assetIds.length < maxAssets) {
      assetIds.push(0n); // Pad with zeros
    }

    // Build external amounts arrays
    const extInAmounts = assetIds.map(
      (id) => assetBalances.get(id)?.extIn ?? 0n
    );
    const extOutAmounts = assetIds.map(
      (id) => assetBalances.get(id)?.extOut ?? 0n
    );

    // Build input notes array
    const inputNotes = paddedInputs.map((note) => [
      note.assetId,
      BigInt(note.noteType),
      note.value,
      note.ownerKey,
      note.blinding,
      note.salt,
      note.nullifierSecret,
    ]);

    // Build output notes array
    const outputNotes = paddedOutputs.map((note) => [
      note.assetId,
      BigInt(note.noteType),
      note.value,
      note.ownerKey,
      note.blinding,
      note.salt,
    ]);

    // Build merkle paths
    const inputPaths = paddedInputs.map((note) => note.pathElements);
    const inputPathIndices = paddedInputs.map((note) => note.pathIndices);

    // Compute public inputs
    // First, compute the commitment for the first input note to use as the leaf
    let merkleRoot = 0n;
    if (paddedInputs[0].pathElements.length > 0 && paddedInputs[0].value > 0n) {
      // Compute the leaf commitment for the first input note
      const leafCommitment = this.computeCommitmentForNote(paddedInputs[0]);
      merkleRoot = this.computeRootFromPath(
        leafCommitment,
        paddedInputs[0].pathElements,
        paddedInputs[0].pathIndices
      );
    }

    const nullifiers = paddedInputs.map((note) =>
      this.computeNullifier(note.nullifierSecret, note.ownerKey)
    );

    const extDataHash = this.computeExtDataHash(
      extInAmounts,
      extOutAmounts,
      inputs.aspRoot ?? 0n
    );

    const aspRoot = inputs.aspRoot ?? 0n;

    return {
      // Public inputs
      merkleRoot,
      nullifiers,
      extDataHash,
      aspRoot,

      // Private inputs
      chainId: this.chainId,
      darkPool: this.darkPool,
      inputNotes,
      inputPaths,
      inputPathIndices,
      outputNotes,
      extInAmounts,
      extOutAmounts,
      assetIds,
    };
  }

  /**
   * Generate Groth16 proof using snarkjs
   */
  private async generateProof(witness: CircuitWitness): Promise<{
    proof: SnarkProof;
    publicSignals: PublicSignals;
  }> {
    const input = {
      merkleRoot: witness.merkleRoot.toString(),
      nullifiers: witness.nullifiers.map((n) => n.toString()),
      extDataHash: witness.extDataHash.toString(),
      aspRoot: witness.aspRoot.toString(),
      chainId: witness.chainId.toString(),
      darkPool: witness.darkPool.toString(),
      inputNotes: witness.inputNotes.map((note) =>
        note.map((n) => n.toString())
      ),
      inputPaths: witness.inputPaths.map((path) =>
        path.map((p) => p.toString())
      ),
      inputPathIndices: witness.inputPathIndices.map((indices) =>
        indices.map((i) => i.toString())
      ),
      outputNotes: witness.outputNotes.map((note) =>
        note.map((n) => n.toString())
      ),
      extInAmounts: witness.extInAmounts.map((a) => a.toString()),
      extOutAmounts: witness.extOutAmounts.map((a) => a.toString()),
      assetIds: witness.assetIds.map((id) => id.toString()),
    };

    const { proof, publicSignals } = await groth16.fullProve(
      input,
      this.config.circuitWasmPath,
      this.config.circuitZkeyPath
    );

    return { proof, publicSignals };
  }

  /**
   * Verify proof (optional, for testing)
   */
  async verifyProof(
    proof: SnarkProof,
    publicSignals: PublicSignals
  ): Promise<boolean> {
    if (!this.config.verificationKeyPath) {
      throw new Error("Verification key path not configured");
    }

    const fs = await import("fs/promises");
    const vKey = JSON.parse(
      await fs.readFile(this.config.verificationKeyPath, "utf-8")
    );

    return await groth16.verify(vKey, publicSignals, proof);
  }

  /**
   * Format Groth16 proof for Solidity
   * Solidity expects: uint256[8] = [pi_a[0], pi_a[1], pi_b[0][1], pi_b[0][0], pi_b[1][1], pi_b[1][0], pi_c[0], pi_c[1]]
   */
  private formatGroth16Proof(proof: SnarkProof): bigint[] {
    return [
      BigInt(proof.pi_a[0]),
      BigInt(proof.pi_a[1]),
      BigInt(proof.pi_b[0][1]),
      BigInt(proof.pi_b[0][0]),
      BigInt(proof.pi_b[1][1]),
      BigInt(proof.pi_b[1][0]),
      BigInt(proof.pi_c[0]),
      BigInt(proof.pi_c[1]),
    ];
  }

  /**
   * Build ExtData struct
   */
  private buildExtData(
    inputs: TransactionInputs,
    witness: CircuitWitness
  ): ExtData {
    const extIn = inputs.extIn ?? new Map();
    const extOut = inputs.extOut ?? new Map();

    // Build assets array (unique asset addresses)
    const assets: string[] = [];
    const extInArray: bigint[] = [];
    const extOutArray: bigint[] = [];

    for (const assetId of witness.assetIds) {
      if (assetId === 0n) continue;

      // Convert assetId (bigint) to address string
      const address = "0x" + assetId.toString(16).padStart(40, "0");
      assets.push(address);
      extInArray.push(extIn.get(assetId) ?? 0n);
      extOutArray.push(extOut.get(assetId) ?? 0n);
    }

    return {
      actionType: inputs.actionType,
      assets,
      extIn: extInArray,
      extOut: extOutArray,
      receivers: inputs.receivers ?? [],
      memoHash: 0n, // TODO: Implement memo hashing
      aspRoot: inputs.aspRoot ?? 0n,
    };
  }

  /**
   * Compute asset balances for conservation check
   */
  private computeAssetBalances(
    inputs: NoteWithPath[],
    outputs: Note[],
    extIn: Map<bigint, bigint>,
    extOut: Map<bigint, bigint>
  ): Map<bigint, AssetBalance> {
    const balances = new Map<bigint, AssetBalance>();

    // Process input notes
    for (const note of inputs) {
      if (!balances.has(note.assetId)) {
        balances.set(note.assetId, {
          assetId: note.assetId,
          inputSum: 0n,
          outputSum: 0n,
          extIn: extIn.get(note.assetId) ?? 0n,
          extOut: extOut.get(note.assetId) ?? 0n,
        });
      }
      const balance = balances.get(note.assetId)!;
      balance.inputSum += note.value;
    }

    // Process output notes
    for (const note of outputs) {
      if (!balances.has(note.assetId)) {
        balances.set(note.assetId, {
          assetId: note.assetId,
          inputSum: 0n,
          outputSum: 0n,
          extIn: extIn.get(note.assetId) ?? 0n,
          extOut: extOut.get(note.assetId) ?? 0n,
        });
      }
      const balance = balances.get(note.assetId)!;
      balance.outputSum += note.value;
    }

    // Add assets with only external amounts
    for (const [assetId, amount] of extIn) {
      if (!balances.has(assetId)) {
        balances.set(assetId, {
          assetId,
          inputSum: 0n,
          outputSum: 0n,
          extIn: amount,
          extOut: extOut.get(assetId) ?? 0n,
        });
      }
    }

    for (const [assetId, amount] of extOut) {
      if (!balances.has(assetId)) {
        balances.set(assetId, {
          assetId,
          inputSum: 0n,
          outputSum: 0n,
          extIn: extIn.get(assetId) ?? 0n,
          extOut: amount,
        });
      }
    }

    return balances;
  }

  /**
   * Validate transaction inputs
   */
  private validateInputs(inputs: TransactionInputs): void {
    if (inputs.inputNotes.length > 2) {
      throw new Error("Maximum 2 input notes allowed");
    }
    if (inputs.outputNotes.length > 2) {
      throw new Error("Maximum 2 output notes allowed");
    }

    // Validate value conservation for each asset
    const balances = this.computeAssetBalances(
      inputs.inputNotes,
      inputs.outputNotes,
      inputs.extIn ?? new Map(),
      inputs.extOut ?? new Map()
    );

    for (const [assetId, balance] of balances) {
      const totalIn = balance.inputSum + balance.extIn;
      const totalOut = balance.outputSum + balance.extOut;

      if (totalIn !== totalOut) {
        throw new Error(
          `Value conservation failed for asset ${assetId}: ${totalIn} in != ${totalOut} out`
        );
      }
    }
  }

  /**
   * Pad input notes to required count
   */
  private padInputNotes(
    notes: NoteWithPath[],
    count: number
  ): NoteWithPath[] {
    const padded = [...notes];

    while (padded.length < count) {
      // Create dummy note
      padded.push({
        chainId: this.chainId,
        darkPool: this.darkPool,
        assetId: 0n,
        noteType: 0,
        value: 0n,
        ownerKey: 0n,
        blinding: 0n,
        salt: 0n,
        nullifierSecret: 0n,
        leafIndex: 0,
        pathElements: Array(this.config.merkleTreeLevels ?? 32).fill(0n),
        pathIndices: Array(this.config.merkleTreeLevels ?? 32).fill(0n),
      });
    }

    return padded;
  }

  /**
   * Pad output notes to required count
   */
  private padOutputNotes(notes: Note[], count: number): Note[] {
    const padded = [...notes];

    while (padded.length < count) {
      // Create dummy note
      padded.push({
        chainId: this.chainId,
        darkPool: this.darkPool,
        assetId: 0n,
        noteType: 0,
        value: 0n,
        ownerKey: 0n,
        blinding: 0n,
        salt: 0n,
      });
    }

    return padded;
  }

  /**
   * Compute commitment for a note (for merkle root calculation)
   * @dev Uses Poseidon2 two-layer hash matching on-chain contract
   */
  private computeCommitmentForNote(note: NoteWithPath): bigint {
    // Commitment = Poseidon2(chainId, darkPool, assetId, noteType, value, ownerKey, blinding, salt)
    // Using nested hash: hash(hash(first 4), hash(last 4))
    const hash1 = poseidon2Hash([
      note.chainId,
      BigInt(note.darkPool),
      note.assetId,
      BigInt(note.noteType),
    ]);
    const hash2 = poseidon2Hash([
      note.value,
      note.ownerKey,
      note.blinding,
      note.salt,
    ]);
    const commitment = poseidon2Hash([hash1, hash2]);
    return commitment;
  }

  /**
   * Compute nullifier using Poseidon2
   */
  private computeNullifier(
    nullifierSecret: bigint,
    ownerKey: bigint
  ): bigint {
    return poseidon2Hash([
      this.chainId,
      this.darkPool,
      nullifierSecret,
      ownerKey,
    ]);
  }

  /**
   * Compute merkle root from path using Poseidon2
   * @param leaf The actual leaf commitment
   * @param pathElements Sibling hashes along the path
   * @param pathIndices Direction indicators (0 = left, 1 = right)
   * @returns The computed merkle root
   */
  private computeRootFromPath(
    leaf: bigint,
    pathElements: bigint[],
    pathIndices: bigint[]
  ): bigint {
    let currentHash = leaf; // Start with the actual leaf commitment

    for (let i = 0; i < pathElements.length; i++) {
      const isLeft = pathIndices[i] === 0n;
      const sibling = pathElements[i];

      if (isLeft) {
        // Current node is left, sibling is right
        currentHash = poseidon2Hash([currentHash, sibling]);
      } else {
        // Current node is right, sibling is left
        currentHash = poseidon2Hash([sibling, currentHash]);
      }
    }

    return currentHash;
  }

  /**
   * Compute extDataHash using two-layer Poseidon2 to match contract
   * @dev Matches contract LibVerifier._computeExtDataHash()
   *
   * Layer 1:
   *   - hAssetsReceivers = Poseidon2([asset0, asset1, asset2, asset3, receiver0, receiver1, receiver2, receiver3])
   *   - hAmounts = Poseidon2([extIn0, extIn1, extIn2, extIn3, extOut0, extOut1, extOut2, extOut3])
   *
   * Layer 2:
   *   - extDataHash = Poseidon2([actionType, aspRoot, hAssetsReceivers, hAmounts])
   *
   * @param extInAmounts Array of external input amounts (padded to 4)
   * @param extOutAmounts Array of external output amounts (padded to 4)
   * @param aspRoot Anti-sandwich protection root
   * @returns Two-layer Poseidon2 hash matching on-chain verifier
   */
  private computeExtDataHash(
    extInAmounts: bigint[],
    extOutAmounts: bigint[],
    aspRoot: bigint
  ): bigint {
    // Ensure arrays are exactly 4 elements (pad with zeros if needed)
    const paddedExtIn = [...extInAmounts];
    while (paddedExtIn.length < 4) paddedExtIn.push(0n);

    const paddedExtOut = [...extOutAmounts];
    while (paddedExtOut.length < 4) paddedExtOut.push(0n);

    // TODO: Once assets and receivers are integrated into TransactionInputs,
    // compute hAssetsReceivers = poseidon2Hash([asset0, asset1, asset2, asset3, receiver0, receiver1, receiver2, receiver3])
    // For now, using placeholder (this MUST match circuit computation)

    // Layer 1b: Hash amounts [extIn0, extIn1, extIn2, extIn3, extOut0, extOut1, extOut2, extOut3]
    const hAmounts = poseidon2Hash([
      paddedExtIn[0],
      paddedExtIn[1],
      paddedExtIn[2],
      paddedExtIn[3],
      paddedExtOut[0],
      paddedExtOut[1],
      paddedExtOut[2],
      paddedExtOut[3],
    ]);

    // Layer 2: Combine with actionType and aspRoot
    // CONTRACT REQUIREMENT: Must match LibVerifier._computeExtDataHash()
    // For now, using simplified structure with placeholder for assets/receivers
    const actionType = 0n; // TODO: Pass from TransactionInputs
    const hAssetsReceivers = 0n; // TODO: Compute from assets and receivers once available

    return poseidon2Hash([
      actionType,
      aspRoot,
      hAssetsReceivers,
      hAmounts,
    ]);
  }
}

/**
 * Helper: Create proof builder from config
 */
export async function createProofBuilder(
  config: ProofBuilderConfig
): Promise<ProofBuilder> {
  return new ProofBuilder(config);
}
