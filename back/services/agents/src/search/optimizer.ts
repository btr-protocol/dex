import { getChatProviderForEnhancement } from '../providers.js';
import { logger } from '@btr/sdk/utils';
import { debug } from '@shared/config';

const log = logger.withContext('optimizer');

/**
 * Query classification type
 */
export type QueryType = 'technical' | 'direct' | 'inappropriate';

/**
 * Result of LLM-based query optimization
 */
export interface OptimizedQuery {
  /** Query classification: technical (needs search), direct (immediate response), or inappropriate */
  queryType: QueryType;

  /** The rephrased, clarified version of the original query (for technical queries) */
  rephrasedQuery: string;

  /** Direct response for greetings or simple queries (no search needed) */
  directResponse?: string;

  /** Synonyms and alternative phrasings for the key concepts (for technical queries) */
  synonyms: string[];

  /** Related technical terms, abbreviations, and domain concepts (for technical queries) */
  relatedTerms: string[];

  /** The reasoning behind the optimization (for transparency/debugging) */
  optimizationReasoning: string;

  /** Combined search string including all terms (for technical queries) */
  expandedSearchString: string;
}

/**
 * Cached optimized query with timestamp
 */
interface CachedOptimization extends OptimizedQuery {
  timestamp: number;
}

/**
 * Simple LRU cache with TTL support
 */
class LRUCache<K, V> {
  private cache: Map<K, { value: V; expires: number }>;
  private maxSize: number;
  private ttl: number;

  constructor(maxSize = 128, ttl = 1000 * 60 * 60) { // 128 items, 1 hour default TTL
    this.cache = new Map();
    this.maxSize = maxSize;
    this.ttl = ttl;
  }

  get(key: K): V | undefined {
    const entry = this.cache.get(key);
    if (!entry) return undefined;

    if (Date.now() > entry.expires) {
      this.cache.delete(key);
      return undefined;
    }

    // Move to end (most recently used)
    this.cache.delete(key);
    this.cache.set(key, entry);
    return entry.value;
  }

  set(key: K, value: V): void {
    // Delete existing if present (will be re-added at end)
    if (this.cache.has(key)) {
      this.cache.delete(key);
    }
    // Evict oldest if at capacity
    else if (this.cache.size >= this.maxSize) {
      const firstKey = this.cache.keys().next().value as K | undefined;
      if (firstKey !== undefined) {
        this.cache.delete(firstKey);
      }
    }

    this.cache.set(key, {
      value,
      expires: Date.now() + this.ttl
    });
  }

  clear(): void {
    this.cache.clear();
  }

  get size(): number {
    return this.cache.size;
  }
}

/**
 * In-flight request deduplication.
 * Tracks ongoing optimizations to avoid duplicate LLM calls.
 */
class InFlightTracker {
  private pending = new Map<string, Promise<OptimizedQuery>>();

  /**
   * Get existing promise or register a new one.
   */
  async track<T>(key: string, fn: () => Promise<T>): Promise<T> {
    const existing = this.pending.get(key);
    if (existing) {
      return existing as Promise<T>;
    }

    const promise = fn().finally(() => {
      this.pending.delete(key);
    });

    this.pending.set(key, promise as Promise<OptimizedQuery>);
    return promise;
  }

  get size(): number {
    return this.pending.size;
  }
}

// Global cache and in-flight tracker
const optimizationCache = new LRUCache<string, CachedOptimization>(256, 60 * 60 * 1000); // 256 items, 1 hour TTL
const inFlight = new InFlightTracker();

// Cache statistics
let cacheHits = 0;
let cacheMisses = 0;

/**
 * Get cache statistics for monitoring
 */
export function getCacheStats() {
  return {
    size: optimizationCache.size,
    hits: cacheHits,
    misses: cacheMisses,
    hitRate: cacheHits + cacheMisses > 0 ? (cacheHits / (cacheHits + cacheMisses) * 100).toFixed(1) + '%' : '0%'
  };
}

/**
 * Clear the optimization cache
 */
export function clearOptimizationCache(): void {
  optimizationCache.clear();
  cacheHits = 0;
  cacheMisses = 0;
}

/**
 * Try to parse JSON from a potentially incomplete string.
 * Returns the parsed object if valid JSON, null otherwise.
 */
function tryParseJSON(content: string): any | null {
  try {
    // Trim and try to find a complete JSON object
    const trimmed = content.trim();
    if (!trimmed.startsWith('{')) return null;

    // Find matching closing brace
    let depth = 0;
    let endIndex = -1;

    for (let i = 0; i < trimmed.length; i++) {
      const char = trimmed[i]!;
      if (char === '{') depth++;
      if (char === '}') {
        depth--;
        if (depth === 0) {
          endIndex = i + 1;
          break;
        }
      }
    }

    if (endIndex === -1) return null;

    const jsonStr = trimmed.slice(0, endIndex);
    return JSON.parse(jsonStr);
  } catch {
    return null;
  }
}

/**
 * Optimize a user query using LLM for maximum clarity and expressiveness.
 *
 * This function:
 * 1. Rephrases the query for clarity and precision
 * 2. Identifies synonyms and alternative phrasings
 * 3. Adds related technical terms and domain concepts
 *
 * Features:
 * - LRU caching with 1-hour TTL
 * - In-flight deduplication (concurrent identical queries share the same LLM call)
 * - Streaming with early abort on valid JSON
 * - JSON mode enforcement
 * - Connection pooling via Undici
 *
 * @param originalQuery - The user's original search query
 * @returns Optimized query with rephrasing and expanded terms
 */
export async function optimizeQuery(originalQuery: string): Promise<OptimizedQuery> {
  // Normalize for cache key
  const cacheKey = originalQuery.toLowerCase().trim();

  // Check cache first
  const cached = optimizationCache.get(cacheKey);
  if (cached) {
    cacheHits++;
    const { timestamp, ...result } = cached;
    return result;
  }
  cacheMisses++;

  // Use in-flight deduplication to avoid duplicate concurrent requests
  return inFlight.track(cacheKey, async () => {
    const startTime = Date.now();
    const chatProvider = await getChatProviderForEnhancement();

    const systemPrompt = `Classify and optimize user queries for a BTR DEX Protocol documentation assistant.

Output ONLY valid JSON matching this exact schema:
{
  "queryType": "technical|direct|inappropriate",
  "rephrasedQuery": "clarified query (for technical)",
  "directResponse": "friendly response (for direct)",
  "synonyms": ["alt1", "alt2"],
  "relatedTerms": ["term1", "term2"]
}

Query Types:
1. "technical": Questions about DEX, AMM, DeFi, blockchain, smart contracts, protocols, trading, liquidity, etc.
   - Must include rephrasedQuery, synonyms, relatedTerms
   - directResponse is omitted

2. "direct": Greetings, introductions, simple social interactions
   - Examples: "hello", "hi", "hey", "thanks", "thank you", "bye", "who are you", "what can you do"
   - Must include directResponse (friendly, helpful, mention you're a documentation assistant)
   - rephrasedQuery, synonyms, relatedTerms can be empty

3. "inappropriate": Offensive, harmful, or completely unrelated content
   - Must include directResponse (polite refusal or redirection)

Requirements:
- synonyms: maximum 8 items, array of strings
- relatedTerms: maximum 12 items, array of strings
- Keep technical terms intact: CLMM, LVR, AIMM, anchor, DLMM, slippage, etc.
- For direct responses: be friendly, concise (max 50 words), mention being a BTR documentation assistant
- Return immediately after completing the JSON object`;

    const userPrompt = `Classify and optimize this user query: "${originalQuery}"`;

    try {
      // Use streaming with early abort on valid JSON
      const responseText = await (chatProvider as any).chatCompletionStreamWithAbort(
        [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: userPrompt }
        ],
        {
          temperature: 0.1,
          maxTokens: 256,  // Reduced from 1024 - we only need a small JSON object
          thinkingDisabled: true,
          jsonMode: true,
          // Abort as soon as we have valid JSON
          abortCallback: (content: string) => {
            const parsed = tryParseJSON(content);
            return parsed !== null;
          }
        }
      );

      // Parse the response
      const parsed = tryParseJSON(responseText);

      if (!parsed) {
        throw new Error('Invalid JSON response');
      }

      const queryType: QueryType = parsed.queryType === 'inappropriate' ? 'inappropriate'
        : parsed.queryType === 'direct' ? 'direct'
        : 'technical'; // default to technical for safety

      const rephrasedQuery = parsed.rephrasedQuery || originalQuery;
      const directResponse = parsed.directResponse?.trim();
      const synonyms = (parsed.synonyms || [])
        .map((s: string) => s.toLowerCase().trim())
        .filter((s: string) => s.length > 0)
        .slice(0, 8); // Enforce max 8
      const relatedTerms = (parsed.relatedTerms || [])
        .map((s: string) => s.toLowerCase().trim())
        .filter((s: string) => s.length > 0)
        .slice(0, 12); // Enforce max 12

      // Build expanded search string with all terms
      const allTerms = [rephrasedQuery, ...synonyms, ...relatedTerms];
      const expandedSearchString = allTerms.join(' ');

      const duration = Date.now() - startTime;

      if (debug) {
        log.info(`Query optimization: ${queryType} in ${duration}ms`);
      }

      const result: OptimizedQuery = {
        queryType,
        rephrasedQuery,
        directResponse,
        synonyms,
        relatedTerms,
        optimizationReasoning: queryType === 'technical'
          ? `Rephrased to "${rephrasedQuery}". Added: ${[...synonyms, ...relatedTerms].join(', ')}`
          : `Direct response: ${directResponse}`,
        expandedSearchString
      };

      // Cache the result
      optimizationCache.set(cacheKey, {
        ...result,
        timestamp: Date.now()
      });

      return result;
    } catch (error) {
      if (debug) log.info(`Query optimization failed: ${error}`);
      // Fall back to treating as technical with original query
      const fallback: OptimizedQuery = {
        queryType: 'technical',
        rephrasedQuery: originalQuery,
        synonyms: [],
        relatedTerms: [],
        optimizationReasoning: 'Optimization failed, treating as technical query',
        expandedSearchString: originalQuery
      };
      return fallback;
    }
  });
}

/**
 * Build a search-optimized string combining rephrased query with expanded terms.
 * This is the actual string sent to the search engines (lexical + semantic).
 */
export function buildSearchString(optimized: OptimizedQuery): string {
  return optimized.expandedSearchString;
}

