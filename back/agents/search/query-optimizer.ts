import { getChatProvider } from '../core/models.js';

const log = (msg: string) => console.log(`[${new Date().toISOString().slice(11,23)}] query-optimizer: ${msg}`);

/**
 * Result of LLM-based query optimization
 */
export interface OptimizedQuery {
  /** The rephrased, clarified version of the original query */
  rephrasedQuery: string;

  /** Synonyms and alternative phrasings for the key concepts */
  synonyms: string[];

  /** Related technical terms, abbreviations, and domain concepts */
  relatedTerms: string[];

  /** The reasoning behind the optimization (for transparency/debugging) */
  optimizationReasoning: string;

  /** Combined search string including all terms */
  expandedSearchString: string;
}

/**
 * Optimize a user query using LLM for maximum clarity and expressiveness.
 *
 * This function:
 * 1. Rephrases the query for clarity and precision
 * 2. Identifies synonyms and alternative phrasings
 * 3. Adds related technical terms and domain concepts
 *
 * @param originalQuery - The user's original search query
 * @returns Optimized query with rephrasing and expanded terms
 */
export async function optimizeQuery(originalQuery: string): Promise<OptimizedQuery> {
  try {
    const chatProvider = await getChatProvider();

    const systemPrompt = `Optimize search queries for our DEX Protocol (on-chain exchange) and underlying AMM docs. Output JSON only:
{
  "rephrasedQuery": "clarified query",
  "synonyms": ["alt1", "alt2"],
  "relatedTerms": ["term1", "term2"]
}
Keep terms like CLMM, LVR, AIMM, anchor. Add abbreviations and related concepts.`;

    const userPrompt = `Optimize: "${originalQuery}"`;

    const response = await chatProvider.chatCompletion([
      { role: 'system', content: systemPrompt },
      { role: 'user', content: userPrompt }
    ], { temperature: 0.1, maxTokens: 200 });

    // Extract JSON from response
    const jsonMatch = response.match(/\{[\s\S]*\}/);
    if (jsonMatch) {
      const parsed = JSON.parse(jsonMatch[0]);

      const rephrasedQuery = parsed.rephrasedQuery || originalQuery;
      const synonyms = (parsed.synonyms || []).map((s: string) => s.toLowerCase().trim()).filter(Boolean);
      const relatedTerms = (parsed.relatedTerms || []).map((s: string) => s.toLowerCase().trim()).filter(Boolean);

      // Build expanded search string with all terms
      const allTerms = [rephrasedQuery, ...synonyms, ...relatedTerms];
      const expandedSearchString = allTerms.join(' ');

      log(`Query optimization complete:`);
      log(`  Original: "${originalQuery}"`);
      log(`  Rephrased: "${rephrasedQuery}"`);
      log(`  Added ${synonyms.length} synonyms, ${relatedTerms.length} related terms`);

      return {
        rephrasedQuery,
        synonyms,
        relatedTerms,
        optimizationReasoning: `Rephrased to "${rephrasedQuery}". Added: ${[...synonyms, ...relatedTerms].join(', ')}`,
        expandedSearchString
      };
    }
  } catch (error) {
    log(`Query optimization failed: ${error}`);
  }

  // Fallback to original query
  log(`Using original query without optimization`);
  return {
    rephrasedQuery: originalQuery,
    synonyms: [],
    relatedTerms: [],
    optimizationReasoning: 'Optimization failed, using original query',
    expandedSearchString: originalQuery
  };
}

/**
 * Build a search-optimized string combining rephrased query with expanded terms.
 * This is the actual string sent to the search engines (lexical + semantic).
 */
export function buildSearchString(optimized: OptimizedQuery): string {
  return optimized.expandedSearchString;
}

/**
 * Format the optimization metadata for display/transparency
 */
export function formatOptimizationSummary(optimized: OptimizedQuery): string {
  const parts: string[] = [];

  if (optimized.rephrasedQuery !== optimized.rephrasedQuery) {
    parts.push(`rephrased: "${optimized.rephrasedQuery}"`);
  }

  if (optimized.synonyms.length > 0) {
    parts.push(`synonyms: ${optimized.synonyms.join(', ')}`);
  }

  if (optimized.relatedTerms.length > 0) {
    parts.push(`related: ${optimized.relatedTerms.join(', ')}`);
  }

  return parts.length > 0 ? parts.join(' | ') : 'no optimization applied';
}
