import type { SearchResult, SearchResultLocation, SearchScores, AgentConfig } from '@shared/types';
import { getEmbeddingProvider } from '../../providers.js';
import { getVectorDB } from '../vector.js';
import { logger } from '@btr/sdk/utils';
import { debug } from '@shared/config';

const log = logger.withContext('semantic');

// Cached VectorDB availability (checked once after indexing)
let cachedVectorDBStatus: { available: boolean; tableExists: boolean; chunkCount?: number } | null = null;

/**
 * Configuration for semantic search
 */
export interface SemanticSearchConfig {
  /** Maximum number of results to return */
  maxResults: number;
  /** Minimum similarity threshold (0-1) */
  minSimilarity: number;
  /** Whether to include metadata in results */
  includeMetadata: boolean;
}

/**
 * Raw semantic search result from LanceDB
 * Matches the new schema aligned with SearchResult structure
 */
interface SemanticResultRaw {
  text: string;
  language: string;
  type: 'code' | 'docs' | 'web-search';
  file: string;
  section: string;
  _distance: number;
}

/**
 * Semantic (RAG) search using vector embeddings.
 * Uses the shared VectorDB which has schema aligned with SearchResult.
 */
export async function semanticSearch(
  searchString: string,
  config?: AgentConfig,
  searchConfig?: Partial<SemanticSearchConfig>
): Promise<SearchResult[]> {
  const maxResults = searchConfig?.maxResults ?? config?.retrieval?.maxResults ?? 15;
  const minSimilarity = searchConfig?.minSimilarity ?? 0.1;

  if (debug) {
    log.info(`Semantic search: "${searchString.slice(0, 50)}..." (max: ${maxResults})`);
  }

  try {
    // Get embedding provider
    const embeddingProvider = await getEmbeddingProvider();

    // Generate query embedding with isQuery flag for EmbeddingGemma
    const embeddings = await embeddingProvider.generateEmbeddings([searchString], { isQuery: true });
    const queryEmbedding = embeddings[0];

    if (!queryEmbedding || queryEmbedding.length === 0) {
      return [];
    }

    // Use shared vector database
    const vectorDB = getVectorDB();

    // Perform similarity search (returns SearchResult format directly)
    const allResults = await vectorDB.search(searchString, maxResults);

    // Filter by similarity threshold
    const filteredResults = allResults.filter(r => r.scores.compound >= minSimilarity);

    return filteredResults;
  } catch (error) {
    if (debug) log.info(`Semantic search failed: ${error}`);
    return [];
  }
}

/**
 * Generate embeddings for a batch of text chunks.
 */
export async function generateChunkEmbeddings(texts: string[]): Promise<number[][]> {
  const embeddingProvider = await getEmbeddingProvider();
  return await embeddingProvider.generateEmbeddings(texts);
}

/**
 * Calculate cosine similarity between two vectors.
 */
export function cosineSimilarity(a: number[], b: number[]): number {
  if (a.length !== b.length) {
    throw new Error('Vector dimensions must match');
  }

  let dotProduct = 0;
  let normA = 0;
  let normB = 0;

  for (let i = 0; i < a.length; i++) {
    dotProduct += a[i] * b[i];
    normA += a[i] * a[i];
    normB += b[i] * b[i];
  }

  return dotProduct / (Math.sqrt(normA) * Math.sqrt(normB));
}

/**
 * Check if the vector database is available and populated.
 * Results are cached after first check (invalidated on reindex).
 */
export async function checkVectorDBAvailability(): Promise<{
  available: boolean;
  tableExists: boolean;
  chunkCount?: number;
}> {
  // Return cached result if available
  if (cachedVectorDBStatus) {
    return cachedVectorDBStatus;
  }

  try {
    const { connect } = await import('@lancedb/lancedb');
    const { agentsLanceDBPath } = await import('@shared/storage');
    const db = await connect(agentsLanceDBPath);
    const tables = await db.tableNames();
    const tableName = 'knowledge';
    const tableExists = tables.includes(tableName);

    if (!tableExists) {
      cachedVectorDBStatus = { available: true, tableExists: false };
      return cachedVectorDBStatus;
    }

    // Use countRows() to check if table has data
    const table = await db.openTable(tableName);
    const chunkCount = await table.countRows() || 0;

    cachedVectorDBStatus = { available: true, tableExists: true, chunkCount };
    return cachedVectorDBStatus;
  } catch (error) {
    if (debug) log.info(`Vector DB availability check failed: ${error}`);
    cachedVectorDBStatus = { available: false, tableExists: false };
    return cachedVectorDBStatus;
  }
}

/**
 * Invalidate cached VectorDB status (call after reindexing).
 */
export function invalidateVectorDBCache(): void {
  cachedVectorDBStatus = null;
}
