import type { SearchResult, AgentConfig, QueryEnhancement } from '../core/types.js';
import { log } from '../../shared/logger.js';

import { optimizeQuery, buildSearchString, formatOptimizationSummary, type OptimizedQuery } from './query-optimizer.js';
import { lexicalSearch } from './lexical.js';
import { semanticSearch, checkVectorDBAvailability } from './semantic.js';


/**
 * Reciprocal Rank Fusion (RRF) constant.
 * Controls how quickly rank contributions diminish.
 */
const RRF_K = 60;

/**
 * Search result with timing metadata
 */
export interface SearchWithTiming {
  results: SearchResult[];
  optimizedQuery: OptimizedQuery;
  timing: {
    totalDurationMs: number;
    queryOptimizationMs: number;
    lexicalSearchMs: number;
    semanticSearchMs: number;
    fusionMs: number;
  };
  searchMode: 'hybrid' | 'lexical-only' | 'semantic-only';
}

/**
 * Timing helper for performance tracking
 */
interface TimedResult<T> {
  result: T;
  durationMs: number;
}

async function withTiming<T>(name: string, fn: () => Promise<T>): Promise<TimedResult<T>> {
  const start = performance.now();
  const result = await fn();
  const duration = performance.now() - start;
  log(`  ⏱️  ${name}: ${duration.toFixed(0)}ms`);
  return { result, durationMs: duration };
}

/**
 * Enhanced search result with fusion metadata
 */
export interface FusedSearchResult extends SearchResult {
  /** Original rank from lexical search (1-indexed, or null if not present) */
  lexicalRank?: number;

  /** Original rank from semantic search (1-indexed, or null if not present) */
  semanticRank?: number;

  /** RRF fusion score */
  rrfScore?: number;
}

/**
 * Reciprocal Rank Fusion (RRF) for combining ranked result lists.
 *
 * Formula: score(d) = Σ 1 / (k + rank_i(d))
 */
function reciprocalRankFusion(
  lexicalResults: SearchResult[],
  semanticResults: SearchResult[],
  k: number = RRF_K,
  maxResults: number = 15
): FusedSearchResult[] {
  const scoreMap = new Map<string, FusedSearchResult>();

  // Process lexical results
  for (let i = 0; i < lexicalResults.length; i++) {
    const result = lexicalResults[i]!;
    const key = result.sourceRef;
    const rrfContribution = 1 / (k + i + 1);

    const existing = scoreMap.get(key);
    if (existing) {
      existing.rrfScore = (existing.rrfScore || 0) + rrfContribution;
    } else {
      scoreMap.set(key, {
        ...result,
        lexicalRank: i + 1,
        semanticRank: undefined,
        rrfScore: rrfContribution,
        score: rrfContribution
      });
    }
  }

  // Process semantic results
  for (let i = 0; i < semanticResults.length; i++) {
    const result = semanticResults[i]!;
    const key = result.sourceRef;
    const rrfContribution = 1 / (k + i + 1);

    const existing = scoreMap.get(key);
    if (existing) {
      existing.rrfScore = (existing.rrfScore || 0) + rrfContribution;
      existing.semanticRank = i + 1;
      existing.score = existing.rrfScore;
    } else {
      scoreMap.set(key, {
        ...result,
        lexicalRank: undefined,
        semanticRank: i + 1,
        rrfScore: rrfContribution,
        score: rrfContribution
      });
    }
  }

  return Array.from(scoreMap.values())
    .sort((a, b) => (b.rrfScore || 0) - (a.rrfScore || 0))
    .slice(0, maxResults);
}

/**
 * Hybrid search pipeline with comprehensive logging.
 *
 * Pipeline steps (logged with timing):
 * 1. Query Optimization (LLM rephrasing + expansion)
 * 2. Parallel Search: Lexical (BM25) + Semantic (RAG)
 * 3. Reciprocal Rank Fusion (RRF)
 *
 * @param query - The user's original search query
 * @param config - Agent configuration
 * @param options - Search options
 * @returns Fused search results with timing metadata
 */
export async function hybridSearch(
  query: string,
  config?: AgentConfig,
  options?: {
    skipQueryOptimization?: boolean;
    skipLexical?: boolean;
    skipSemantic?: boolean;
  }
): Promise<SearchWithTiming> {
  const maxResults = config?.retrieval?.maxResults || 15;
  const pipelineStart = performance.now();

  log(`═══════════════════════════════════════════════════════════════`);
  log(`🔍 HYBRID SEARCH STARTED`);
  log(`═══════════════════════════════════════════════════════════════`);
  log(`📥 INPUT QUERY: "${query}"`);
  log(`   Query length: ${query.length} chars`);

  // ======================================================================
  // STEP 0: Check prerequisites
  // ======================================================================
  log(`\n┌─ STEP 0: PREREQUISITE CHECKS ─────────────────────────────────`);

  const ragEnabled = config?.retrieval?.enableRAG !== false;  // default: true
  let vectorDBAvailable = false;
  let vectorDBChunkCount: number | undefined = undefined;

  if (ragEnabled) {
    const { result: vectorDBStatus } = await withTiming('VectorDB availability check', async () =>
      checkVectorDBAvailability()
    );
    vectorDBAvailable = vectorDBStatus.available && vectorDBStatus.tableExists;
    vectorDBChunkCount = vectorDBStatus.chunkCount;
  }

  log(`   ✓ RAG/VectorDB: ${ragEnabled ? (vectorDBAvailable ? 'ENABLED & AVAILABLE' : 'ENABLED but UNAVAILABLE') : 'DISABLED (config.enableRAG=false)'}`);
  if (vectorDBAvailable && vectorDBChunkCount !== undefined) {
    log(`   ✓ Chunk count: ${vectorDBChunkCount}`);
  }
  log(`   ✓ Lexical search (BM25): ALWAYS ENABLED`);
  log(`   ✓ Max results: ${maxResults}`);

  // ======================================================================
  // STEP 1: Query Optimization (LLM-based)
  // ======================================================================
  log(`\n┌─ STEP 1: QUERY OPTIMIZATION ─────────────────────────────────`);

  let optimizedQuery: OptimizedQuery = {
    rephrasedQuery: query,
    synonyms: [],
    relatedTerms: [],
    optimizationReasoning: 'No optimization'
  };
  let queryOptimizationMs = 0;
  let searchQueryString = query;

  if (!options?.skipQueryOptimization) {
    const { result: optimized, durationMs } = await withTiming('LLM query optimization', async () =>
      optimizeQuery(query)
    );
    optimizedQuery = optimized;
    queryOptimizationMs = durationMs;
    searchQueryString = buildSearchString(optimized);

    log(`   📤 OUTPUT (OPTIMIZED QUERY):`);
    log(`      Rephrased: "${optimized.rephrasedQuery}"`);
    if (optimized.synonyms.length > 0) {
      log(`      Synonyms (${optimized.synonyms.length}): [${optimized.synonyms.join(', ')}]`);
    }
    if (optimized.relatedTerms.length > 0) {
      log(`      Related terms (${optimized.relatedTerms.length}): [${optimized.relatedTerms.join(', ')}]`);
    }
    log(`      Total search string length: ${searchQueryString.length} chars`);
  } else {
    log(`   ⏭️  Query optimization SKIPPED (skipQueryOptimization=true)`);
  }

  // ======================================================================
  // STEP 2: Parallel Lexical + Semantic Search
  // ======================================================================
  log(`\n┌─ STEP 2: PARALLEL SEARCH ────────────────────────────────────`);
  log(`   📥 SEARCH INPUT: "${searchQueryString.slice(0, 150)}${searchQueryString.length > 150 ? '...' : ''}"`);

  let lexicalSearchMs = 0;
  let semanticSearchMs = 0;
  const searchPromises: Array<Promise<{ type: string; results: SearchResult[]; durationMs: number }>> = [];

  // Lexical search (BM25)
  if (!options?.skipLexical) {
    searchPromises.push(
      withTiming('Lexical (BM25) search', async () => lexicalSearch(searchQueryString, config))
        .then(({ result, durationMs }) => {
          lexicalSearchMs = durationMs;
          return { type: 'lexical', results: result, durationMs };
        })
    );
  }

  // Semantic search (RAG)
  if (!options?.skipSemantic && ragEnabled && vectorDBAvailable) {
    searchPromises.push(
      withTiming('Semantic (RAG) search', async () => semanticSearch(searchQueryString, config))
        .then(({ result, durationMs }) => {
          semanticSearchMs = durationMs;
          return { type: 'semantic', results: result, durationMs };
        })
    );
  }

  // Execute all searches in parallel
  const parallelResults = await Promise.all(searchPromises);

  let lexicalResults: SearchResult[] = [];
  let semanticResults: SearchResult[] = [];

  for (const searchResult of parallelResults) {
    if (searchResult.type === 'lexical') {
      lexicalResults = searchResult.results;
      log(`   📤 LEXICAL OUTPUT:`);
      log(`      Results: ${lexicalResults.length} documents`);
      if (lexicalResults.length > 0) {
        log(`      Top result: ${lexicalResults[0]!.sourceRef} (score: ${lexicalResults[0]!.score.toFixed(3)})`);
        const top3 = lexicalResults.slice(0, 3).map(r => r.sourceRef).join(', ');
        log(`      Top 3: [${top3}]`);
      }
    } else if (searchResult.type === 'semantic') {
      semanticResults = searchResult.results;
      log(`   📤 SEMANTIC OUTPUT:`);
      log(`      Results: ${semanticResults.length} documents`);
      if (semanticResults.length > 0) {
        log(`      Top result: ${semanticResults[0]!.sourceRef} (similarity: ${semanticResults[0]!.score.toFixed(3)})`);
        const top3 = semanticResults.slice(0, 3).map(r => r.sourceRef).join(', ');
        log(`      Top 3: [${top3}]`);
      }
    }
  }

  // ======================================================================
  // STEP 3: Reciprocal Rank Fusion
  // ======================================================================
  log(`\n┌─ STEP 3: RESULT FUSION (RRF) ────────────────────────────────`);

  const { result: fused, durationMs: fusionDuration } = await withTiming('RRF fusion', () =>
    Promise.resolve(reciprocalRankFusion(lexicalResults, semanticResults, RRF_K, maxResults))
  );

  log(`   📤 FUSION OUTPUT:`);
  log(`      Fused results: ${fused.length} documents`);
  log(`      RRF k-parameter: ${RRF_K}`);

  if (fused.length > 0) {
    log(`      Top 5 fused results:`);
    for (let i = 0; i < Math.min(5, fused.length); i++) {
      const r = fused[i]!;
      const sources = [];
      if (r.lexicalRank) sources.push(`lexical#${r.lexicalRank}`);
      if (r.semanticRank) sources.push(`semantic#${r.semanticRank}`);
      log(`         ${i + 1}. ${r.sourceRef}`);
      log(`            Sources: [${sources.join(', ') || 'none'}]`);
      log(`            RRF score: ${r.rrfScore?.toFixed(4)}, Final score: ${r.score.toFixed(4)}`);
    }
  }

  const totalPipelineDuration = performance.now() - pipelineStart;

  // Determine search mode
  const searchMode: 'hybrid' | 'lexical-only' | 'semantic-only' =
    lexicalResults.length > 0 && semanticResults.length > 0 ? 'hybrid' :
    lexicalResults.length > 0 ? 'lexical-only' : 'semantic-only';

  log(`\n═══════════════════════════════════════════════════════════════`);
  log(`✅ HYBRID SEARCH COMPLETE`);
  log(`═══════════════════════════════════════════════════════════════`);
  log(`📊 SEARCH MODE: ${searchMode.toUpperCase()}`);
  log(`📊 PERFORMANCE SUMMARY:`);
  log(`   Query optimization: ${queryOptimizationMs.toFixed(0)}ms`);
  log(`   Lexical search: ${lexicalSearchMs.toFixed(0)}ms`);
  log(`   Semantic search: ${semanticSearchMs.toFixed(0)}ms`);
  log(`   RRF fusion: ${fusionDuration.toFixed(0)}ms`);
  log(`   TOTAL PIPELINE: ${totalPipelineDuration.toFixed(0)}ms`);
  log(`📦 OUTPUT: ${fused.length} fused results`);
  log(`═══════════════════════════════════════════════════════════════\n`);

  return {
    results: fused as SearchResult[],
    optimizedQuery,
    timing: {
      totalDurationMs: Math.round(totalPipelineDuration),
      queryOptimizationMs: Math.round(queryOptimizationMs),
      lexicalSearchMs: Math.round(lexicalSearchMs),
      semanticSearchMs: Math.round(semanticSearchMs),
      fusionMs: Math.round(fusionDuration)
    },
    searchMode
  };
}

/**
 * Convert SearchResult to SearchSource format for frontend display
 */
export function formatSearchSource(result: SearchResult, index: number): SearchSource {
  const refParts = result.sourceRef.split(':');
  const filePath = refParts[0] || result.sourceRef;
  const lineNum = refParts[1] ? parseInt(refParts[1], 10) : undefined;

  // Determine display name and category
  let displayName = filePath;
  let category: 'contract' | 'sdk' | 'documentation' | 'test' = 'documentation';
  let contract: string | undefined;
  let funcName: string | undefined;
  let section: string | undefined;

  if (filePath.startsWith('contracts/src/')) {
    category = 'contract';
    const contractMatch = filePath.match(/\/(\w+)\.sol$/);
    contract = contractMatch ? contractMatch[1] : undefined;
    displayName = contract ? `${contract}.sol` : filePath;
  } else if (filePath.startsWith('sdk/src/')) {
    category = 'sdk';
    displayName = filePath.replace('sdk/src/', 'sdk/');
  } else if (filePath.startsWith('docs/')) {
    category = 'documentation';
    displayName = filePath.replace('docs/', '');
  } else if (filePath.includes('test')) {
    category = 'test';
  }

  // Extract function name from metadata
  if (result.metadata.function) {
    funcName = result.metadata.function;
  }

  // Extract section from metadata
  if (result.metadata.section) {
    section = result.metadata.section;
  }

  return {
    ref: result.sourceRef,
    displayName,
    category,
    language: result.metadata.language,
    contract,
    function: funcName,
    section,
    lineRange: result.metadata.lineRange || (lineNum ? [lineNum, lineNum + 5] as [number, number] : undefined),
    score: result.score,
    rawScore: result.metadata.bm25Score || result.score,
    preview: result.content.slice(0, 200).trim().replace(/\n/g, ' ')
  };
}

/**
 * Summarize retrieval results for context injection into LLM prompts.
 */
export async function summarizeRetrieval(
  query: string,
  results: SearchResult[],
  maxChars = 8000
): Promise<string> {
  if (results.length === 0) return '';

  log(`\n📝 SUMMARIZING ${results.length} RESULTS (max ${maxChars} chars)`);

  let summary = '';
  let totalChars = 0;

  for (const result of results) {
    const chunk = '[Source: ' + result.sourceRef + ']\n' + result.content + '\n';

    if (totalChars + chunk.length > maxChars) {
      const remaining = maxChars - totalChars;
      if (remaining > 50) {
        summary += chunk.slice(0, remaining - 3) + '...';
      }
      break;
    }

    summary += chunk;
    totalChars += chunk.length;
  }

  log(`   Summary length: ${summary.length} chars`);

  return summary.trim();
}

/**
 * Debug helper to test query optimization independently.
 */
export async function testQueryOptimization(query: string): Promise<OptimizedQuery> {
  return optimizeQuery(query);
}

/**
 * Get search pipeline statistics for monitoring.
 */
export async function getSearchStats(): Promise<{
  vectorDBAvailable: boolean;
  vectorDBChunkCount?: number;
  lexicalIndexCached: boolean;
}> {
  const vectorDBStatus = await checkVectorDBAvailability();

  let lexicalIndexCached = false;
  try {
    const { getLexicalIndexStats } = await import('./lexical.js');
    const stats = getLexicalIndexStats('archivist');
    lexicalIndexCached = stats !== null;
  } catch {
    lexicalIndexCached = false;
  }

  return {
    vectorDBAvailable: vectorDBStatus.available && vectorDBStatus.tableExists,
    vectorDBChunkCount: vectorDBStatus.chunkCount,
    lexicalIndexCached
  };
}
