#!/usr/bin/env bun
/**
 * Knowledge Indexing Script
 *
 * Indexes documentation, contracts, and SDK files for hybrid search.
 * Uses TEI for embedding generation (must be running).
 *
 * Prerequisites:
 *   Start TEI: bun run back/agents/search/semantic/start-tei.ts
 *
 * Usage:
 *   bun run back/agents/search/index-knowledge.ts [--force]
 *
 * Options:
 *   --force    Force re-index all files (ignore cache)
 */

import { indexKnowledge } from './indexer.js';
import { getEmbeddingProvider } from '../providers.js';
import { embeddingConfig, knowledgeConfig } from './config.js';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('index');

async function main() {
  const forceReindex = process.argv.includes('--force');

  log.info('\n');
  log.info('╔═══════════════════════════════════════════════════════════════╗');
  log.info('║          KNOWLEDGE INDEXING                                   ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝\n');

  // Check TEI availability first
  log.info('Checking TEI embedding provider...');
  try {
    const provider = await getEmbeddingProvider();
    const available = await provider.isAvailable();

    if (!available) {
      log.info(`\n❌ TEI not available at ${embeddingConfig.teiUrl}`);
      log.info('');
      log.info('Start the TEI container first:');
      log.info('  bun run back/agents/search/semantic/start-tei.ts');
      log.info('');
      process.exit(1);
    }

    log.info(`✅ TEI available`);
    log.info(`   Model: ${embeddingConfig.model}`);
    log.info(`   Dimensions: ${embeddingConfig.dimensions}`);
    log.info(`   Batch size: ${embeddingConfig.batchSize}`);
    log.info(`   Concurrency: ${embeddingConfig.maxConcurrency}`);
  } catch (error) {
    log.error(`\n❌ Error connecting to TEI: ${error}`);
    process.exit(1);
  }

  log.info('');
  log.info('Knowledge patterns:');
  for (const pattern of knowledgeConfig.include) {
    log.info(`   + ${pattern}`);
  }
  log.info('');

  // Run indexing
  try {
    await indexKnowledge('archivist', forceReindex);
    log.info('\n✅ Indexing completed successfully!');
    log.info('');
    log.info('Next steps:');
    log.info('  1. Test the search: bun run back/agents/search/test-search.ts');
    log.info('  2. Start the agent server: bun run back/agents/server.ts');
    log.info('');
  } catch (error) {
    log.error(`\n❌ Indexing failed: ${error}`);
    process.exit(1);
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    log.error('Fatal error:', error);
    process.exit(1);
  });
