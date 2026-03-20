#!/usr/bin/env bun
/**
 * Query Optimizer Test
 *
 * Tests the optimized query optimization with:
 * - Streaming + early abort
 * - JSON mode
 * - LRU caching
 * - In-flight deduplication
 *
 * Run: bun run back/agents/search/test-optimizer.ts
 */

import { optimizeQuery, getCacheStats, clearOptimizationCache } from './optimizer.js';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('test');

async function testOptimization() {
  log.info('╔═══════════════════════════════════════════════════════════════╗');
  log.info('║              QUERY OPTIMIZER TEST                             ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝\n');

  const testQueries = [
    'What is cooperative arbitrage?',
    'How does AIMM pricing work?',
    'Explain liquidity shaping',
    'What is cooperative arbitrage?', // duplicate - should hit cache
    'How does AIMM pricing work?',    // duplicate - should hit cache
  ];

  // Clear cache to start fresh
  clearOptimizationCache();
  log.info('Cache cleared. Starting tests...\n');

  for (let i = 0; i < testQueries.length; i++) {
    const query = testQueries[i]!;
    log.info(`\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
    log.info(`TEST ${i + 1}: "${query}"`);
    log.info(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);

    const start = Date.now();
    const result = await optimizeQuery(query);
    const duration = Date.now() - start;

    log.info(`\n✓ Completed in ${duration}ms`);
    log.info(`  Rephrased: "${result.rephrasedQuery}"`);
    log.info(`  Synonyms (${result.synonyms.length}): ${result.synonyms.slice(0, 3).join(', ')}${result.synonyms.length > 3 ? '...' : ''}`);
    log.info(`  Related terms (${result.relatedTerms.length}): ${result.relatedTerms.slice(0, 3).join(', ')}${result.relatedTerms.length > 3 ? '...' : ''}`);

    const stats = getCacheStats();
    log.info(`  Cache: ${stats.hitRate} hit rate, ${stats.size} entries`);
  }

  // Test concurrent duplicates (in-flight deduplication)
  log.info(`\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);
  log.info(`TEST: Concurrent duplicate queries (in-flight deduplication)`);
  log.info(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━`);

  const sameQuery = 'What is slippage in trading?';
  log.info(`Running 3 identical queries concurrently...`);

  const start = Date.now();
  await Promise.all([
    optimizeQuery(sameQuery),
    optimizeQuery(sameQuery),
    optimizeQuery(sameQuery)
  ]);
  const duration = Date.now() - start;

  log.info(`✓ All 3 completed in ${duration}ms (should be ~1x query time, not 3x)`);
  log.info(`  Cache: ${getCacheStats().hitRate} hit rate, ${getCacheStats().size} entries`);

  log.info(`\n\n╔═══════════════════════════════════════════════════════════════╗`);
  log.info(`║                    TEST SUMMARY                                ║`);
  log.info(`╚═══════════════════════════════════════════════════════════════╝`);
  const stats = getCacheStats();
  log.info(`Final cache stats:`);
  log.info(`  - Hit rate: ${stats.hitRate}`);
  log.info(`  - Total hits: ${stats.hits}`);
  log.info(`  - Total misses: ${stats.misses}`);
  log.info(`  - Cached entries: ${stats.size}`);
  log.info(`\n`);
}

testOptimization().catch(err => {
  log.error('Test failed:', err);
  process.exit(1);
});
