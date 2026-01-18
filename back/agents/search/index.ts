/**
 * Search module exports
 *
 * Architecture:
 * - query-optimizer.ts: LLM-based query rephrasing and expansion
 * - lexical.ts: BM25-based lexical search (formerly fuzzy)
 * - semantic.ts: Vector embedding similarity search (RAG)
 * - hybrid.ts: Orchestrates lexical + semantic with RRF fusion
 * - indexing.ts: Document chunking and embedding generation
 */

// Main search API
export { hybridSearch, summarizeRetrieval, testQueryOptimization, getSearchStats } from './hybrid.js';

// Individual search components (for direct use if needed)
export { lexicalSearch, clearLexicalIndex, getLexicalIndexStats } from './lexical.js';
export { semanticSearch, generateChunkEmbeddings, cosineSimilarity, checkVectorDBAvailability } from './semantic.js';
export { optimizeQuery, buildSearchString, formatOptimizationSummary } from './query-optimizer.js';

// Types
export type { OptimizedQuery } from './query-optimizer.js';
export type { SemanticSearchResult, SemanticSearchConfig } from './semantic.js';
export type { FusionMetadata, FusedSearchResult } from './hybrid.js';

// Indexing (background processing)
export * from './indexing.js';

// Vector DB (legacy export for compatibility)
export { getVectorDB } from '../core/vector.js';
