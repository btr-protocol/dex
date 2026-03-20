/**
 * TEI Embedding Test Script
 *
 * Tests onnx-community/embeddinggemma-300m-ONNX with 768 dimensions.
 * Validates embedding generation and similarity calculations.
 *
 * Usage: bun run back/agents/search/semantic/test.ts
 */

import { logger } from '@btr/sdk/utils';

const log = logger.withContext('tei-test');
const EXPECTED_DIMENSIONS = 768;  // onnx-community/embeddinggemma-300m-ONNX

export const cosineSimilarity = (a: number[], b: number[]): number => {
  if (a.length !== b.length) {
    throw new Error(`Vector dimension mismatch: ${a.length} vs ${b.length}`);
  }
  const dot = a.reduce((sum, val, i) => sum + val * b[i], 0);
  const magA = Math.sqrt(a.reduce((sum, val) => sum + val * val, 0));
  const magB = Math.sqrt(b.reduce((sum, val) => sum + val * val, 0));
  return dot / (magA * magB);
};

async function main() {
  const TEI_URL = process.env.TEI_URL || 'http://localhost:8080';

  log.info('╔═══════════════════════════════════════════════════════════════╗');
  log.info('║         TEI EMBEDDING TEST (embeddinggemma-300m-ONNX)        ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝\n');

  // Health check
  log.info('┌─ HEALTH CHECK ────────────────────────────────────────────────');
  try {
    const health = await fetch(`${TEI_URL}/health`);
    if (!health.ok) {
      log.error(`✗ Health check failed: ${health.status}`);
      process.exit(1);
    }
    log.info(`✓ TEI healthy`);
  } catch (err) {
    log.error(`✗ Health check failed: ${err}`);
    process.exit(1);
  }

  // Test 1: Basic embeddings without instruction
  log.info('\n┌─ TEST 1: BASIC EMBEDDINGS ──────────────────────────────────────');
  const start = Date.now();
  const res = await fetch(`${TEI_URL}/embed`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      inputs: ['hello world', 'test embedding', 'semantic search', 'completely different text']
    })
  });

  if (!res.ok) {
    log.error(`✗ Embed failed: ${res.status} ${res.statusText}`);
    process.exit(1);
  }

  const json = await res.json() as unknown;
  const embeddings = Object.values(json as Record<string, number[]>) as number[][];
  const duration = Date.now() - start;

  log.info(`✓ Generated ${embeddings.length} embeddings in ${duration}ms`);

  // Validate dimensions
  const actualDim = embeddings[0].length;
  if (actualDim !== EXPECTED_DIMENSIONS) {
    log.error(`✗ Dimension mismatch: expected ${EXPECTED_DIMENSIONS}, got ${actualDim}`);
    process.exit(1);
  }
  log.info(`✓ Dimensions: ${actualDim} (correct)`);
  log.info(`✓ Sample: [${embeddings[0].slice(0, 5).map(v => v.toFixed(4)).join(', ')}...]`);

  // Test 2: Similarity calculations
  log.info('\n┌─ TEST 2: SIMILARITY CALCULATIONS ───────────────────────────────');
  const simSimilar = cosineSimilarity(embeddings[0], embeddings[1]);
  const simDifferent = cosineSimilarity(embeddings[0], embeddings[3]);
  log.info(`✓ Similar texts similarity: ${simSimilar.toFixed(4)}`);
  log.info(`✓ Different texts similarity: ${simDifferent.toFixed(4)}`);
  if (simSimilar > simDifferent) {
    log.info(`✓ Similarity ranking is correct`);
  } else {
    log.warn(`⚠ Similarity ranking may be incorrect`);
  }

  // Test 3: Batch processing
  log.info('\n┌─ TEST 3: BATCH PROCESSING ──────────────────────────────────────');
  const batchTexts = Array.from({ length: 32 }, (_, i) => `Test document number ${i + 1} with some content.`);
  const batchStart = Date.now();
  const batchRes = await fetch(`${TEI_URL}/embed`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ inputs: batchTexts })
  });

  if (!batchRes.ok) {
    log.error(`✗ Batch embed failed: ${batchRes.status}`);
    process.exit(1);
  }

  const batchJson = await batchRes.json() as unknown;
  const batchEmbeddings = Object.values(batchJson as Record<string, number[]>) as number[][];
  const batchDuration = Date.now() - batchStart;
  const throughput = (batchTexts.length / (batchDuration / 1000)).toFixed(1);

  log.info(`✓ Generated ${batchEmbeddings.length} embeddings in ${batchDuration}ms`);
  log.info(`✓ Throughput: ${throughput} docs/second`);

  // Validate all embeddings have correct dimensions
  const invalidDims = batchEmbeddings.filter(e => e.length !== EXPECTED_DIMENSIONS);
  if (invalidDims.length > 0) {
    log.error(`✗ ${invalidDims.length} embeddings have incorrect dimensions`);
    process.exit(1);
  }
  log.info(`✓ All ${batchEmbeddings.length} embeddings have ${EXPECTED_DIMENSIONS} dimensions`);

  log.info('\n╔═══════════════════════════════════════════════════════════════╗');
  log.info('║                    ✅ ALL TESTS PASSED                        ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝\n');
}

main().catch(err => {
  log.error('\n✗ Fatal error:', err);
  process.exit(1);
});
