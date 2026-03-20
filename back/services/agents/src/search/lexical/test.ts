/**
 * Fuzzy Matching Test
 *
 * Run: bun run back/agents/search/lexical/test.ts
 *
 * This script tests the Levenshtein-based fuzzy matching in BM25 lexical search.
 */

import { lexicalSearch } from './search.js';
import { getStorage } from '../../storage.js';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('test');

async function testFuzzyMatching() {
  log.info('Initializing storage...');
  const storage = await getStorage();
  const config = storage.getAgent('archivist');

  if (!config) {
    log.error('❌ ERROR: Archivist config not found. Make sure the agent is registered.');
    process.exit(1);
  }

  log.info('✅ Config loaded');
  log.info('');

  // Test cases with intentional typos
  const testQueries = [
    { query: 'pricng', expectedMatch: 'pricing', description: 'Single typo (missing i)' },
    { query: 'liquidty', expectedMatch: 'liquidity', description: 'Single typo (missing i)' },
    { query: 'tradng', expectedMatch: 'trading', description: 'Single typo (missing i)' },
    { query: 'slippge', expectedMatch: 'slippage', description: 'Single typo (missing a)' },
    { query: 'inventry', expectedMatch: 'inventory', description: 'Single typo (e instead of o)' },
    { query: 'feez', expectedMatch: 'fees', description: 'Single typo (z instead of s)' },
    { query: 'amm', expectedMatch: 'amm', description: 'Exact match (no typo)' },
  ];

  log.info('═══════════════════════════════════════════════════════════════');
  log.info('FUZZY MATCHING TEST');
  log.info('═══════════════════════════════════════════════════════════════\n');

  for (const testCase of testQueries) {
    log.info(`Testing: "${testCase.query}" (${testCase.description})`);
    log.info(`Expected to match: "${testCase.expectedMatch}"`);

    try {
      const results = await lexicalSearch(testCase.query, config);

      if (results.length > 0) {
        log.info(`✅ Found ${results.length} results`);
        const topResult = results[0]!;
        log.info(`   Top result: ${topResult.location.file} (score: ${topResult.scores.compound.toFixed(4)})`);

        // Check if any result content contains the expected match
        const matchFound = results.some(r =>
          r.content.toLowerCase().includes(testCase.expectedMatch.toLowerCase()) ||
          r.location.file.toLowerCase().includes(testCase.expectedMatch.toLowerCase())
        );

        if (matchFound) {
          log.info(`   ✓ Content matches expected term "${testCase.expectedMatch}"`);
        } else {
          log.info(`   ⚠️  Warning: No content contains "${testCase.expectedMatch}"`);
        }
      } else {
        log.info(`❌ No results found`);
      }
    } catch (error) {
      log.error(`❌ ERROR: ${error}`);
    }

    log.info('');
  }

  log.info('═══════════════════════════════════════════════════════════════');
  log.info('TEST COMPLETE');
  log.info('═══════════════════════════════════════════════════════════════');
}

// Run tests
testFuzzyMatching()
  .then(() => {
    log.info('All tests completed');
    process.exit(0);
  })
  .catch((error) => {
    log.error(`Fatal error: ${error}`);
    process.exit(1);
  });
