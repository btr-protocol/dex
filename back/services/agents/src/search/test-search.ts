#!/usr/bin/env bun
/**
 * Integrated Hybrid Search Test Suite
 *
 * Tests:
 * 1. TEI embeddings and vector DB availability
 * 2. Lexical (BM25) search with fuzzy matching
 * 3. Semantic (RAG) search via TEI embeddings
 * 4. Hybrid search with RRF fusion
 * 5. Query optimizer with caching and circuit breaker
 *
 * Prerequisites:
 *   - TEI running: bun run back/agents/search/semantic/start-tei.ts
 *   - Knowledge indexed: bun run back/agents/search/index-knowledge.ts [--force]
 *
 * Run: bun run back/agents/search/test-search.ts
 */

import { hybridSearch, getSearchStats } from './hybrid.js';
import { lexicalSearch } from './lexical/search.js';
import { semanticSearch, checkVectorDBAvailability } from './semantic/search.js';
import { optimizeQuery, getCacheStats, clearOptimizationCache } from './optimizer.js';
import { getEmbeddingProvider } from '../providers.js';
import { getStorage } from '../storage.js';
import { embeddingConfig, knowledgeConfig } from './config.js';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('test');

async function checkPrerequisites(): Promise<boolean> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  PREREQUISITE CHECKS');
  log.info('═══════════════════════════════════════════════════════════════\n');

  let allGood = true;

  log.info('1. TEI Embedding Provider...');
  try {
    const provider = await getEmbeddingProvider();
    const available = await provider.isAvailable();
    if (available) {
      log.info(`   ✅ TEI available at ${embeddingConfig.teiUrl}`);
      log.info(`   ✅ Model: ${embeddingConfig.model} (${embeddingConfig.dimensions}D)`);
    } else {
      log.info(`   ❌ TEI not available`);
      allGood = false;
    }
  } catch (error) {
    log.info(`   ❌ TEI error: ${error}`);
    allGood = false;
  }

  log.info('\n2. Vector Database...');
  const vectorStatus = await checkVectorDBAvailability();
  if (vectorStatus.available && vectorStatus.tableExists) {
    log.info(`   ✅ LanceDB available with ${vectorStatus.chunkCount} chunks indexed`);
  } else if (vectorStatus.available) {
    log.info(`   ⚠️  LanceDB available but no knowledge indexed`);
    allGood = false;
  } else {
    log.info(`   ❌ LanceDB not available`);
    allGood = false;
  }

  log.info('\n3. Knowledge Configuration...');
  log.info(`   Include: ${knowledgeConfig.include.join(', ')}`);
  log.info(`   Exclude: ${knowledgeConfig.exclude.length} patterns`);

  log.info('\n4. Agent Registration...');
  try {
    const storage = await getStorage();
    const config = storage.getAgent('archivist');
    if (config) {
      log.info(`   ✅ Archivist agent registered`);
    } else {
      log.info(`   ⚠️  Archivist not registered`);
    }
  } catch (error) {
    log.info(`   ⚠️  Storage error: ${error}`);
  }

  log.info('\n');
  return allGood;
}

async function testEmbeddings(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  TEST 1: EMBEDDING GENERATION');
  log.info('═══════════════════════════════════════════════════════════════\n');

  const testTexts = [
    'How does AMM pricing work?',
    'Liquidity provision in DeFi',
    'Slippage and price impact'
  ];

  try {
    const provider = await getEmbeddingProvider();
    const start = performance.now();
    const embeddings = await provider.generateEmbeddings(testTexts);
    const duration = performance.now() - start;

    log.info(`✅ Generated ${embeddings.length} embeddings in ${duration.toFixed(0)}ms`);
    log.info(`   Dimensions: ${embeddings[0]?.length || 'N/A'}`);
    log.info(`   Sample: [${embeddings[0]?.slice(0, 3).map(v => v.toFixed(4)).join(', ')}...]`);
  } catch (error) {
    log.info(`❌ Embedding generation failed: ${error}`);
  }
  log.info('\n');
}

async function testLexicalSearch(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  TEST 2: LEXICAL (BM25 + FUZZY) SEARCH');
  log.info('═══════════════════════════════════════════════════════════════\n');

  const queries = [
    { query: 'pricing mechanism', expected: 'pricing' },
    { query: 'liquidty', expected: 'liquidity' },  
    { query: 'tradng fees', expected: 'trading fees' }
  ];

  for (const { query, expected } of queries) {
    log.info(`Query: "${query}"${query !== expected ? ` (fuzzy match for "${expected}")` : ''}`);
    try {
      const start = performance.now();
      const results = await lexicalSearch(query);
      const duration = performance.now() - start;

      log.info(`   Found ${results.length} results in ${duration.toFixed(0)}ms`);
      if (results.length > 0) {
        log.info(`   Top result: ${results[0]!.location.file.split('/').slice(-2).join('/')} (score: ${results[0]!.scores.compound.toFixed(4)})`);
        const hasExpected = results.some(r => 
          r.content.toLowerCase().includes(expected) || 
          r.location.file.toLowerCase().includes(expected)
        );
        log.info(`   ${hasExpected ? '✓' : '✗'} Contains expected term: "${expected}"`);
      }
    } catch (error) {
      log.info(`   ❌ Error: ${error}`);
    }
    log.info('');
  }
}

async function testSemanticSearch(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  TEST 3: SEMANTIC (RAG) SEARCH');
  log.info('═══════════════════════════════════════════════════════════════\n');

  const queries = [
    'How does AMM determine token prices?',
    'What happens when adding liquidity?',
    'How are trading fees distributed?'
  ];

  for (const query of queries) {
    log.info(`Query: "${query}"`);
    try {
      const start = performance.now();
      const results = await semanticSearch(query);
      const duration = performance.now() - start;

      log.info(`   Found ${results.length} results in ${duration.toFixed(0)}ms`);
      if (results.length > 0) {
        log.info(`   Top: ${results[0]!.location.file.split('/').slice(-2).join('/')} (similarity: ${results[0]!.scores.compound.toFixed(4)})`);
      }
    } catch (error) {
      log.info(`   ❌ Error: ${error}`);
    }
    log.info('');
  }
}

async function testQueryOptimizer(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  TEST 4: QUERY OPTIMIZER + CIRCUIT BREAKER');
  log.info('═══════════════════════════════════════════════════════════════\n');

  const testQueries: Array<{ query: string; expectedType: string }> = [
    { query: 'What is cooperative arbitrage?', expectedType: 'technical' },
    { query: 'hello there', expectedType: 'direct' },
    { query: 'hi', expectedType: 'direct' },
    { query: 'How does AIMM work?', expectedType: 'technical' },
    { query: 'What is cooperative arbitrage?', expectedType: 'technical' }, 
    { query: 'hello there', expectedType: 'direct' }, 
  ];

  clearOptimizationCache();
  log.info('Cache cleared. Testing optimization + caching...\n');

  for (const { query, expectedType } of testQueries) {
    log.info(`Query: "${query}" (expected: ${expectedType})`);
    try {
      const start = Date.now();
      const result = await optimizeQuery(query);
      const duration = Date.now() - start;

      log.info(`   ✓ Type: ${result.queryType} ${result.queryType === expectedType ? '✓' : '✗'}`);
      if (result.queryType === 'direct') {
        log.info(`   ✓ Direct response: "${result.directResponse?.slice(0, 50)}..."`);
      } else {
        log.info(`   ✓ Rephrased: "${result.rephrasedQuery}"`);
        log.info(`   ✓ Terms: ${[...result.synonyms, ...result.relatedTerms].slice(0, 4).join(', ')}...`);
      }
      log.info(`   ✓ Duration: ${duration}ms | Cache: ${getCacheStats().hitRate} hit rate`);
    } catch (error) {
      log.info(`   ❌ Error: ${error}`);
    }
    log.info('');
  }

  log.info(`Final cache stats: ${getCacheStats().hitRate} hit rate, ${getCacheStats().size} entries\n`);
}

async function testHybridSearch(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  TEST 5: HYBRID SEARCH (LEXICAL + SEMANTIC + RRF)');
  log.info('═══════════════════════════════════════════════════════════════\n');

  const queries = [
    'pricing and fees',
    'How does liquidity affect slippage?',
    'staking rewards distribution'
  ];

  for (const query of queries) {
    log.info(`Query: "${query}"`);
    try {
      const result = await hybridSearch(query, undefined, { skipQueryOptimization: true });

      log.info(`   Mode: ${result.searchMode}`);
      log.info(`   Timing: total=${result.timing.totalDurationMs}ms lex=${result.timing.lexicalSearchMs}ms sem=${result.timing.semanticSearchMs}ms fus=${result.timing.fusionMs}ms`);
      log.info(`   Results: ${result.results.length} (${result.results.filter(r => r.origin === 'hybrid').length} hybrid)`);

      if (result.results.length > 0) {
        log.info(`   Top 3:`);
        for (const r of result.results.slice(0, 3)) {
          const icon = r.origin === 'hybrid' ? '🔗' : r.origin === 'lexical' ? '📝' : '🧠';
          const shortRef = r.location.file.split('/').slice(-2).join('/');
          log.info(`     ${icon} ${shortRef} (${r.scores.compound.toFixed(4)})`);
        }
      }
    } catch (error) {
      log.info(`   ❌ Error: ${error}`);
    }
    log.info('');
  }
}

async function testCircuitBreaker(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  TEST 6: DIRECT RESPONSE CIRCUIT BREAKER');
  log.info('═══════════════════════════════════════════════════════════════\n');

  const testCases = [
    { query: 'hello', expectedType: 'direct', description: 'greeting' },
    { query: 'hi there', expectedType: 'direct', description: 'greeting' },
    { query: 'thanks', expectedType: 'direct', description: 'gratitude' },
    { query: 'What is AMM?', expectedType: 'technical', description: 'technical question' },
    { query: 'How does AIMM work?', expectedType: 'technical', description: 'technical question' }
  ];

  for (const { query, expectedType, description } of testCases) {
    log.info(`Testing ${description}: "${query}"`);
    const optimized = await optimizeQuery(query);
    const match = optimized.queryType === expectedType;
    log.info(`   ${match ? '✓' : '✗'} Type: ${optimized.queryType} (expected: ${expectedType})`);
    
    if (optimized.queryType === 'direct') {
      log.info(`   ✓ Has direct response: ${optimized.directResponse ? 'yes' : 'no'}`);
      if (optimized.directResponse) {
        log.info(`   ✓ Response: "${optimized.directResponse.slice(0, 60)}..."`);
      }
    }
    log.info('');
  }
}

async function printStats(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  SEARCH PIPELINE STATS');
  log.info('═══════════════════════════════════════════════════════════════\n');

  try {
    const stats = await getSearchStats();
    log.info(`Vector DB available: ${stats.vectorDBAvailable}`);
    log.info(`Vector DB chunks: ${stats.vectorDBChunkCount || 'N/A'}`);
    log.info(`Lexical index cached: ${stats.lexicalIndexCached}`);
  } catch (error) {
    log.info(`Error getting stats: ${error}`);
  }

  log.info('\n');
}

async function main() {
  log.info('\n');
  log.info('╔═══════════════════════════════════════════════════════════════╗');
  log.info('║           HYBRID SEARCH TEST SUITE                              ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝\n');

  const prereqOk = await checkPrerequisites();

  if (!prereqOk) {
    log.info('⚠️  Some prerequisites are missing. Tests may fail.\n');
  }

  await testEmbeddings();
  await testLexicalSearch();
  await testSemanticSearch();
  await testQueryOptimizer();
  await testHybridSearch();
  await testCircuitBreaker();
  await printStats();

  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  ALL TESTS COMPLETE');
  log.info('═══════════════════════════════════════════════════════════════\n');
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    log.error('Fatal error:', error);
    process.exit(1);
  });
