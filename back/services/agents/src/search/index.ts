/**
 * Search module exports
 *
 * Architecture:
 * - config.ts: Shared configuration for knowledge, chunking, embeddings
 * - optimizer.ts: LLM-based query rephrasing and expansion
 * - lexicalfrom ".. BM25-based lexical search with fuzzy matching
 * - semantic/search.ts: Vector embedding similarity search (RAG via TEI)
 * - hybrid.ts: Orchestrates lexical + semantic with RRF fusion
 * - indexer.ts: Document chunking and embedding generation
 *
 * Embedding Provider: TEI (Text Embeddings Inference)
 * - High-performance embeddings via Docker container
 * - Start with: bun run back/agents/search/semantic/start-tei.ts
 */

// Configuration (shared across all agents)
export {
  searchConfig,
  knowledgeConfig,
  embeddingChunkingConfig,
  embeddingConfig,
  type SearchConfig,
  type ContextConfig,
  type EmbeddingConfig,
  type RRFConfig,
  type BM25Config,
  type FuzzyConfig,
  type ChunkingConfig
} from './config.js';

// Main search API
export { hybridSearch, summarizeRetrieval, testQueryOptimization, getSearchStats } from './hybrid.js';

// Individual search components (for direct use if needed)
export { lexicalSearch, clearLexicalIndex, getLexicalIndexStats } from './lexical/search.js';
export { semanticSearch, generateChunkEmbeddings, cosineSimilarity, checkVectorDBAvailability, invalidateVectorDBCache } from './semantic/search.js';
export { optimizeQuery, buildSearchString } from './optimizer.js';

// Types
export type { OptimizedQuery } from './optimizer.js';
export type { SemanticSearchConfig } from './semantic/search.js';
export type { SearchWithTiming } from './hybrid.js';

// Indexing (background processing)
export { indexKnowledge } from './indexer.js';

// Vector DB
export { getVectorDB } from './vector.js';

// TEI Provider
export { TEIEmbeddingProvider } from './semantic/tei.js';
