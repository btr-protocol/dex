#!/usr/bin/env bun
/**
 * @title Private Transfer Example
 * @notice Example of building a private transfer transaction
 * @dev Demonstrates complete workflow: note creation, merkle tree, proof generation
 */

import {
  createProofBuilder,
  createMerkleTree,
  createSpendableNote,
  addPathToNote,
  randomFieldElement,
  ActionType,
  NoteType,
  type NoteWithPath,
} from "../index";
import { resolve } from "path";

/**
 * Example: Alice sends 600 USDC to Bob, keeps 400 USDC as change
 */
async function main() {
  console.log("🔐 DarkPool Private Transfer Example\n");

  // ========================================
  // 1. Configuration
  // ========================================

  const config = {
    chainId: 1n,
    darkPoolAddress: "0x1234567890123456789012345678901234567890",
    circuitWasmPath: resolve(__dirname, "../../../circuits/build/JoinSplit.wasm"),
    circuitZkeyPath: resolve(__dirname, "../../../circuits/build/JoinSplit_final.zkey"),
    verificationKeyPath: resolve(__dirname, "../../../circuits/build/verification_key.json"),
    merkleTreeLevels: 32,
  };

  console.log("Configuration:");
  console.log(`  Chain ID: ${config.chainId}`);
  console.log(`  DarkPool: ${config.darkPoolAddress}`);
  console.log(`  Tree Levels: ${config.merkleTreeLevels}\n`);

  // ========================================
  // 2. Setup
  // ========================================

  console.log("⚙️  Setting up...");

  // Create proof builder
  const builder = await createProofBuilder(config);
  console.log("✅ Proof builder created");

  // Create merkle tree
  const zerosPath = resolve(__dirname, "../../../circuits/generated/zeros.json");
  const tree = await createMerkleTree(zerosPath, 32);
  console.log("✅ Merkle tree created");
  console.log(`   Tree info: ${JSON.stringify(tree.getInfo())}\n`);

  // ========================================
  // 3. Create Input Note (Alice's existing note)
  // ========================================

  console.log("📝 Creating input note (Alice's existing note)...");

  const USDC_ADDRESS = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48";
  const ALICE_PUBLIC_KEY = randomFieldElement();

  const { commitment: inputCommitment, note: inputNote, nullifier } =
    await createSpendableNote({
      chainId: config.chainId,
      darkPool: BigInt(config.darkPoolAddress),
      assetId: BigInt(USDC_ADDRESS),
      noteType: NoteType.TOKEN,
      value: 1000n * 10n ** 6n, // 1000 USDC (6 decimals)
      ownerKey: ALICE_PUBLIC_KEY,
    });

  console.log(`  Commitment: ${inputCommitment.toString(16)}`);
  console.log(`  Nullifier:  ${nullifier.toString(16)}`);
  console.log(`  Value:      ${inputNote.value / 10n ** 6n} USDC\n`);

  // ========================================
  // 4. Insert into Merkle Tree
  // ========================================

  console.log("🌲 Inserting commitment into merkle tree...");

  const leafIndex = tree.insert(inputCommitment);
  console.log(`  Leaf index: ${leafIndex}`);

  const merkleRoot = await tree.root();
  console.log(`  Merkle root: ${merkleRoot.toString(16)}\n`);

  // ========================================
  // 5. Get Merkle Proof
  // ========================================

  console.log("🔍 Generating merkle proof...");

  const merklePath = await tree.getProof(leafIndex);
  console.log(`  Path elements: ${merklePath.pathElements.length}`);
  console.log(`  Verified root: ${merklePath.root.toString(16)}\n`);

  // Add path to note
  const inputNoteWithPath: NoteWithPath = addPathToNote(inputNote, merklePath);

  // ========================================
  // 6. Create Output Notes
  // ========================================

  console.log("📝 Creating output notes...");

  // Note 1: 600 USDC to Bob
  const BOB_PUBLIC_KEY = randomFieldElement();

  const { note: bobNote } = await createSpendableNote({
    chainId: config.chainId,
    darkPool: BigInt(config.darkPoolAddress),
    assetId: BigInt(USDC_ADDRESS),
    noteType: NoteType.TOKEN,
    value: 600n * 10n ** 6n, // 600 USDC
    ownerKey: BOB_PUBLIC_KEY,
  });

  console.log(`  Output 1 (Bob): ${bobNote.value / 10n ** 6n} USDC`);

  // Note 2: 400 USDC change back to Alice
  const { note: changeNote } = await createSpendableNote({
    chainId: config.chainId,
    darkPool: BigInt(config.darkPoolAddress),
    assetId: BigInt(USDC_ADDRESS),
    noteType: NoteType.TOKEN,
    value: 400n * 10n ** 6n, // 400 USDC
    ownerKey: ALICE_PUBLIC_KEY, // Back to Alice
  });

  console.log(`  Output 2 (Alice change): ${changeNote.value / 10n ** 6n} USDC\n`);

  // ========================================
  // 7. Build Transaction
  // ========================================

  console.log("🔨 Building transaction with proof...");

  try {
    const tx = await builder.buildTransaction({
      inputNotes: [inputNoteWithPath],
      outputNotes: [bobNote, changeNote],
      actionType: ActionType.TRANSFER,
      extIn: new Map(), // No external deposits
      extOut: new Map(), // No external withdrawals
      receivers: [],
    });

    console.log("✅ Transaction built successfully!\n");

    // ========================================
    // 8. Display Transaction Details
    // ========================================

    console.log("📦 Transaction Details:");
    console.log("─".repeat(60));

    console.log("\n🔐 Proof:");
    console.log(`  Merkle Root: 0x${tx.proof.merkleRoot.toString(16)}`);
    console.log(`  Nullifiers:`);
    tx.proof.nullifiers.forEach((n, i) => {
      console.log(`    [${i}] 0x${n.toString(16)}`);
    });
    console.log(`  ExtData Hash: 0x${tx.proof.extDataHash.toString(16)}`);
    console.log(`  Output Commitments:`);
    tx.proof.outCommitments.forEach((c, i) => {
      console.log(`    [${i}] 0x${c.toString(16)}`);
    });

    console.log("\n📄 External Data:");
    console.log(`  Action Type: ${ActionType[tx.extData.actionType]}`);
    console.log(`  Assets: ${tx.extData.assets.join(", ")}`);
    console.log(`  Ext In: ${tx.extData.extIn}`);
    console.log(`  Ext Out: ${tx.extData.extOut}`);
    console.log(`  Receivers: ${tx.extData.receivers.length > 0 ? tx.extData.receivers : "none"}`);

    console.log("\n" + "─".repeat(60));

    // ========================================
    // 9. Simulate On-Chain Submission
    // ========================================

    console.log("\n📤 Next steps:");
    console.log("  1. Submit to DarkPool contract:");
    console.log("     darkPool.transact(proof, extData, recipientHints)");
    console.log("\n  2. Contract will:");
    console.log("     - Verify Groth16 proof");
    console.log("     - Check merkle root is in history");
    console.log("     - Mark nullifiers as spent");
    console.log("     - Insert output commitments");
    console.log("\n  3. Recipients can spend their notes:");
    console.log(`     - Bob receives note with commitment: 0x${tx.proof.outCommitments[0].toString(16).slice(0, 16)}...`);
    console.log(`     - Alice receives change with commitment: 0x${tx.proof.outCommitments[1].toString(16).slice(0, 16)}...\n`);

    // ========================================
    // 10. Value Conservation Check
    // ========================================

    console.log("✅ Value Conservation:");
    const inputSum = inputNote.value;
    const outputSum = bobNote.value + changeNote.value;
    console.log(`  Inputs:  ${inputSum / 10n ** 6n} USDC`);
    console.log(`  Outputs: ${outputSum / 10n ** 6n} USDC`);
    console.log(`  Balance: ${inputSum === outputSum ? "✅ Balanced" : "❌ IMBALANCED"}\n`);

    console.log("🎉 Example completed successfully!\n");

  } catch (error) {
    console.error("\n❌ Error building transaction:", error);
    process.exit(1);
  }
}

// Run example
main().catch((error) => {
  console.error("Fatal error:", error);
  process.exit(1);
});
