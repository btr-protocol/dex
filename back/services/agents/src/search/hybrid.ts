import type { SearchResult, AgentConfig, SearchSource, SearchResultLocation, SearchScores } from '@shared/types';
import { logger } from '@btr/sdk/utils';
import { optimizeQuery, buildSearchString, type OptimizedQuery } from './optimizer.js';
import { lexicalSearch } from './lexical/search.js';
import { semanticSearch, checkVectorDBAvailability } from './semantic/search.js';
import { rrfConfig } from './config.js';
import { parseLineRange, updateLineRange, mergeLineRanges, mergeContentWithDedup } from './utils.js';
import { debug } from '@shared/config';

const log = logger.withContext('hybrid');

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

async function withTiming<T>(fn: () => Promise<T>): Promise<TimedResult<T>> {
  const start = performance.now();
  const result = await fn();
  return { result, durationMs: performance.now() - start };
}

/**
 * Reciprocal Rank Fusion (RRF) for combining ranked result lists.
 *
 * Formula: score(d) = Σ 1 / (k + rank_i(d))
 *
 * Features:
 * - Tracks origin (lexical/semantic/hybrid)
 * - Boosts hybrid results (configurable via rrfConfig.hybridBoost)
 * - Merges line ranges when same file found by both methods (e.g., :10-17 + :14-23 = :10-23)
 * - Deduplicates content at merge boundaries
 * - Returns clean SearchResult with location and scores objects
 */
function reciprocalRankFusion(
  lexicalResults: SearchResult[],
  semanticResults: SearchResult[],
  k: number = rrfConfig.k,
  maxResults: number = 10
): SearchResult[] {
  const fusionMap = new Map<string, {
    content: string;
    location: SearchResultLocation;
    scores: SearchScores;
  }>();

  // Helper to get a unique key from location (use only file, not section, to detect overlaps)
  const getKey = (location: SearchResultLocation): string => {
    return location.file;
  };

  // Process lexical results
  for (let i = 0; i < lexicalResults.length; i++) {
    const result = lexicalResults[i]!;
    const key = getKey(result.location);
    const rrfContribution = 1 / (k + i + 1);

    const existing = fusionMap.get(key);
    if (existing) {
      // Already exists from semantic (shouldn't happen in first pass but keep for safety)
      existing.scores.lexicalRank = i + 1;
      existing.scores.type = 'hybrid';
    } else {
      fusionMap.set(key, {
        content: result.content,
        location: result.location,
        scores: {
          type: 'lexical',
          lexicalScore: result.scores.compound,
          lexicalRank: i + 1,
          compound: rrfContribution
        }
      });
    }
  }

  // Process semantic results
  for (let i = 0; i < semanticResults.length; i++) {
    const result = semanticResults[i]!;
    const key = getKey(result.location);
    const rrfContribution = 1 / (k + i + 1);

    const existing = fusionMap.get(key);
    if (existing) {
      // HYBRID: Found in both lexical and semantic - MERGE
      const maxScore = Math.max(existing.scores.lexicalScore || 0, result.scores.compound || 0);
      const boostedScore = Math.min(maxScore * rrfConfig.hybridBoost, rrfConfig.maxScore);

      // Merge line ranges
      const existingRange = parseLineRange(existing.location.file);
      const newRange = parseLineRange(result.location.file);
      const mergedRange = mergeLineRanges(existingRange, newRange);

      // Merge content with line-based deduplication
      const mergedContent = mergeContentWithDedup(existing.content, result.content);

      // Update location with merged line range
      const mergedLocation: SearchResultLocation = {
        ...existing.location,
        file: mergedRange ? updateLineRange(existing.location.file, mergedRange) : existing.location.file
      };

      existing.content = mergedContent;
      existing.location = mergedLocation;
      existing.scores = {
        type: 'hybrid',
        lexicalScore: existing.scores.lexicalScore,
        lexicalRank: existing.scores.lexicalRank,
        semanticScore: result.scores.compound,
        semanticRank: i + 1,
        lexicalMatchCount: existing.scores.lexicalMatchCount,
        compound: boostedScore
      };
    } else {
      fusionMap.set(key, {
        content: result.content,
        location: result.location,
        scores: {
          type: 'semantic',
          semanticScore: result.scores.compound,
          semanticRank: i + 1,
          compound: rrfContribution
        }
      });
    }
  }

  // Convert map to array and sort by compound score
  return Array.from(fusionMap.values())
    .sort((a, b) => b.scores.compound - a.scores.compound)
    .slice(0, maxResults)
    .map(item => ({
      content: item.content,
      origin: item.scores.type,
      location: item.location,
      scores: item.scores
    }));
}

/**
 * Hybrid search pipeline combining lexical (BM25) and semantic (RAG) search.
 *
 * @param query - The user's original search query
 * @param config - Agent configuration
 * @param optionsOrOptimizedQuery - Search options OR pre-optimized query
 * @returns Fused search results with timing metadata
 */
export async function hybridSearch(
  query: string,
  config?: AgentConfig,
  optionsOrOptimizedQuery?: {
    skipQueryOptimization?: boolean;
    skipLexical?: boolean;
    skipSemantic?: boolean;
  } | OptimizedQuery
): Promise<SearchWithTiming> {
  const maxResults = config?.retrieval?.maxResults || 10;
  const pipelineStart = performance.now();

  // Check RAG availability (cached after first check)
  const ragEnabled = config?.retrieval?.enableRAG !== false;
  let vectorDBAvailable = false;

  if (ragEnabled) {
    const vectorDBStatus = await checkVectorDBAvailability();
    vectorDBAvailable = vectorDBStatus.available && vectorDBStatus.tableExists;
  }

  // Determine if we received a pre-optimized query
  const isPreOptimized = optionsOrOptimizedQuery && 'queryType' in optionsOrOptimizedQuery;
  const options = isPreOptimized ? undefined : optionsOrOptimizedQuery as { skipQueryOptimization?: boolean; skipLexical?: boolean; skipSemantic?: boolean } | undefined;
  const preOptimizedQuery = isPreOptimized ? optionsOrOptimizedQuery as OptimizedQuery : undefined;

  // Query optimization
  let optimizedQuery: OptimizedQuery;
  let queryOptimizationMs = 0;
  let searchQueryString: string;

  if (preOptimizedQuery) {
    optimizedQuery = preOptimizedQuery;
    searchQueryString = buildSearchString(preOptimizedQuery);
  } else if (!options?.skipQueryOptimization) {
    const { result, durationMs } = await withTiming(() => optimizeQuery(query));
    optimizedQuery = result;
    queryOptimizationMs = durationMs;
    searchQueryString = buildSearchString(result);
  } else {
    optimizedQuery = {
      queryType: 'technical',
      rephrasedQuery: query,
      synonyms: [],
      relatedTerms: [],
      optimizationReasoning: 'No optimization',
      expandedSearchString: query
    };
    searchQueryString = query;
  }

  // Parallel search execution
  let lexicalSearchMs = 0;
  let semanticSearchMs = 0;
  const searchPromises: Array<Promise<{ type: string; results: SearchResult[]; durationMs: number }>> = [];

  if (!options?.skipLexical) {
    searchPromises.push(
      withTiming(() => lexicalSearch(searchQueryString, config))
        .then(({ result, durationMs }) => {
          lexicalSearchMs = durationMs;
          return { type: 'lexical', results: result, durationMs };
        })
    );
  }

  if (!options?.skipSemantic && ragEnabled && vectorDBAvailable) {
    searchPromises.push(
      withTiming(() => semanticSearch(searchQueryString, config))
        .then(({ result, durationMs }) => {
          semanticSearchMs = durationMs;
          return { type: 'semantic', results: result, durationMs };
        })
    );
  }

  const parallelResults = await Promise.all(searchPromises);

  let lexicalResults: SearchResult[] = [];
  let semanticResults: SearchResult[] = [];

  for (const searchResult of parallelResults) {
    if (searchResult.type === 'lexical') {
      lexicalResults = searchResult.results;
    } else if (searchResult.type === 'semantic') {
      semanticResults = searchResult.results;
    }
  }

  // RRF fusion
  const fusionStart = performance.now();
  const fused = reciprocalRankFusion(lexicalResults, semanticResults, rrfConfig.k, maxResults);
  const fusionDuration = performance.now() - fusionStart;

  const totalPipelineDuration = performance.now() - pipelineStart;

  const searchMode: 'hybrid' | 'lexical-only' | 'semantic-only' =
    lexicalResults.length > 0 && semanticResults.length > 0 ? 'hybrid' :
    lexicalResults.length > 0 ? 'lexical-only' : 'semantic-only';

  if (debug) {
    const hybridCount = fused.filter(r => r.origin === 'hybrid').length;
    log.info(`Search: ${searchMode} | opt=${queryOptimizationMs}ms lex=${lexicalSearchMs}ms sem=${semanticSearchMs}ms | ${fused.length} results (${hybridCount} hybrid)`);
  }

  return {
    results: fused,
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
export function formatSearchSource(result: SearchResult, _index: number): SearchSource {
  const { file, section } = result.location;

  // Extract category from file path
  let category: 'contract' | 'sdk' | 'documentation' | 'test' = 'documentation';
  let displayName = file;
  let contract: string | undefined;
  let funcName: string | undefined;

  if (file.startsWith('contracts/src/') || file.startsWith('contracts/')) {
    category = 'contract';
    const contractMatch = file.match(/(\w+)\.sol/);
    contract = contractMatch ? contractMatch[1] : undefined;
    displayName = contract ? `${contract}.sol` : file.split('/').pop() || file;
  } else if (file.startsWith('sdk/src/') || file.startsWith('sdk/')) {
    category = 'sdk';
    displayName = file.replace(/^.*?(sdk\/)/, '$1');
  } else if (file.startsWith('docs/') || file.startsWith('docs/')) {
    category = 'documentation';
    displayName = file.replace(/^.*?(docs\/)/, '$1');
  } else if (file.includes('test')) {
    category = 'test';
  }

  // Extract function name from section
  if (section) {
    const parts = section.split('.');
    if (parts.length > 1) {
      funcName = parts[parts.length - 1];
    } else {
      funcName = section;
    }
  }

  // Build line range from file if present
  let lineRange: [number, number] | undefined;
  const lineMatch = file.match(/:(\d+)-(\d+)$/);
  if (lineMatch) {
    lineRange = [parseInt(lineMatch[1]), parseInt(lineMatch[2])];
  }

  return {
    ref: file,
    displayName,
    category,
    language: result.location.language,
    contract,
    function: funcName,
    section,
    lineRange,
    score: result.scores.compound,
    rawScore: result.scores.lexicalScore || result.scores.semanticScore || result.scores.compound,
    origin: result.origin,
    preview: result.content.slice(0, 200).trim().replace(/\n/g, ' ')
  };
}

/**
 * Summarize retrieval results for context injection into LLM prompts.
 */
export async function summarizeRetrieval(
  _query: string,
  results: SearchResult[],
  maxChars = 8000
): Promise<string> {
  if (results.length === 0) return '';

  let summary = '';
  let totalChars = 0;

  for (const result of results) {
    const chunk = `[Source: ${result.location.file}]\n${result.content}\n`;

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
    const { getLexicalIndexStats } = await import('./lexical/search.js');
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
