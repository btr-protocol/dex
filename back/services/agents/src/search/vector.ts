import { connect } from '@lancedb/lancedb';
import type { KnowledgeChunk, SearchResult, SearchResultLocation, SearchScores, VectorDB } from '@shared/types';
import { embeddingConfig } from './config.js';
import { logger as sdkLogger } from '@btr/sdk/utils';
import { escapeSqlString, inferLanguage } from './utils.js';
import { agentsLanceDBPath } from '@shared/storage';
import { ensureStorageDirectories } from './storage-init.js';

const log = sdkLogger.withContext('vector');


/**
 * LanceDB schema aligned with SearchResult structure:
 * - id: auto-increment primary key
 * - vector: embedding vector (768D for EmbeddingGemma)
 * - text: chunk content (maps to SearchResult.content)
 * - language: programming language (maps to SearchResultLocation.language)
 * - type: 'code' | 'docs' | 'web-search' (maps to SearchResultLocation.type)
 * - file: file path with optional line range (maps to SearchResultLocation.file)
 * - section: section identifier (maps to SearchResultLocation.section)
 * - fileDigest: SHA256 hash of the source file (for lazy reindexing)
 * - indexedAt: timestamp
 */
interface LanceDBSchema {
  id: number;
  vector: number[];
  text: string;
  language: string;
  type: 'code' | 'docs' | 'web-search';
  file: string;
  section: string;
  fileDigest: string;
  indexedAt: string;
}

class LanceDBAdapter implements VectorDB {
  private db: any = null;
  private dbPath: string;
  private tableName: string;

  constructor() {
    this.dbPath = agentsLanceDBPath;
    this.tableName = 'knowledge';
  }

  async initialize(): Promise<void> {
    await ensureStorageDirectories();

    try {
      this.db = await connect(this.dbPath);
      log.info('LanceDB connected');
    } catch (error) {
      log.info(`LanceDB init error: ${error}`);
      throw error;
    }
  }

  async addChunks(chunks: KnowledgeChunk[]): Promise<void> {
    if (!this.db) await this.initialize();

    if (chunks.length === 0) return;

    const validChunks = chunks.filter(c => c.vector && c.vector.length > 0);
    if (validChunks.length !== chunks.length) {
      log.info(`Warning: ${chunks.length - validChunks.length} chunks have no vector`);
    }

    if (validChunks.length === 0) return;

    try {
      const tables = await this.db.tableNames();

      if (tables.includes(this.tableName)) {
        // Append to existing table (lazy indexing - don't drop)
        const table = await this.db.openTable(this.tableName);

        // Get current max ID to avoid collisions
        let nextId = 1;
        const maxIdResult = await table.query().select(['id']).toArray();
        if (maxIdResult.length > 0) {
          const maxId = Math.max(...maxIdResult.map((r: any) => r.id || 0));
          nextId = maxId + 1;
        }

        const data = validChunks.map((c, i) => this.chunkToSchema(c, nextId + i));
        await table.add(data);
        log.info(`Appended ${validChunks.length} chunks to existing LanceDB table`);
      } else {
        // Create new table with schema matching SearchResult structure
        const data = validChunks.map((c, i) => this.chunkToSchema(c, i + 1));
        await this.db.createTable(this.tableName, data);
        log.info(`Created new table and added ${validChunks.length} chunks to LanceDB`);
      }
    } catch (error) {
      log.info(`Error adding chunks: ${error}`);
      throw error;
    }
  }

  /**
   * Convert KnowledgeChunk to LanceDB schema format.
   * New KnowledgeChunk format is already aligned with SearchResult structure.
   */
  private chunkToSchema(chunk: KnowledgeChunk, id: number): LanceDBSchema {
    return {
      id,
      vector: Array.from(chunk.vector),
      text: chunk.text,
      language: chunk.language,
      type: chunk.type,
      file: chunk.file,
      section: chunk.section,
      fileDigest: chunk.fileDigest || '',
      indexedAt: chunk.indexedAt || new Date().toISOString()
    };
  }

  /**
   * Delete all chunks matching the given file and digest.
   * Called before re-indexing a modified file to prevent stale chunks.
   *
   * @param file - The file path
   * @param digest - The old file digest to delete chunks for
   * @returns Number of chunks deleted
   */
  async deleteChunksByFileDigest(file: string, digest: string): Promise<number> {
    if (!this.db) await this.initialize();

    try {
      const tables = await this.db.tableNames();
      if (!tables.includes(this.tableName)) {
        return 0;
      }

      const table = await this.db.openTable(this.tableName);

      // Count chunks before deletion
      const beforeCount = await table.countRows();

      // Delete chunks matching both file and digest
      // This ensures we only delete chunks from the specific version of the file
      // Note: LanceDB stores as fileDigest but SQL needs quoted identifier
      await table.delete(`file = '${escapeSqlString(file)}' AND "fileDigest" = '${escapeSqlString(digest)}'`);

      const afterCount = await table.countRows();
      const deleted = beforeCount - afterCount;

      if (deleted > 0) {
        log.info(`Deleted ${deleted} stale chunks for ${file.split('/').pop()} (digest: ${digest.slice(0, 8)}...)`);
      }

      return deleted;
    } catch (error) {
      log.info(`Error deleting chunks for ${file}: ${error}`);
      return 0;
    }
  }

  /**
   * Convert LanceDB result to SearchResult format.
   */
  private schemaToSearchResult(row: any, similarity: number): SearchResult {
    const location: SearchResultLocation = {
      language: row.language || 'unknown',
      type: row.type || 'docs',
      file: row.file || '',
      section: row.section || ''
    };

    const scores: SearchScores = {
      type: 'semantic',
      semanticScore: similarity,
      semanticRank: 0, // Set by caller
      compound: similarity
    };

    return {
      content: row.text,
      origin: 'semantic',
      location,
      scores
    };
  }

  async search(query: string, k = 10): Promise<SearchResult[]> {
    if (!this.db) await this.initialize();

    try {
      const tables = await this.db.tableNames();
      if (!tables.includes(this.tableName)) {
        log.info('No knowledge table found, returning empty results');
        return [];
      }

      const embeddings = await this.getQueryEmbedding(query);

      const table = await this.db.openTable(this.tableName);
      const results = await table
        .vectorSearch(embeddings)
        .limit(k)
        .toArray();

      return results.map((r: any) => {
        const similarity = 1 - r._distance;
        const result = this.schemaToSearchResult(r, similarity);
        result.scores.semanticRank = results.indexOf(r) + 1;
        return result;
      });
    } catch (error) {
      log.info(`Search error: ${error}`);
      return [];
    }
  }

  private async getQueryEmbedding(query: string): Promise<number[]> {
    const mod = await import('../providers.js');
    const provider = await mod.getEmbeddingProvider();
    // Use isQuery: true for EmbeddingGemma (adds "query:" prefix)
    const embeddings = await provider.generateEmbeddings([query], { isQuery: true });
    return embeddings[0] || [];
  }

  async clear(): Promise<void> {
    if (!this.db) await this.initialize();

    await this.db.dropTable(this.tableName);
    // Create empty table with new schema
    const schema: LanceDBSchema[] = [{
      id: 0,
      vector: Array(embeddingConfig.dimensions).fill(0),
      text: '',
      language: '',
      type: 'docs',
      file: '',
      section: '',
      fileDigest: '',
      indexedAt: new Date().toISOString()
    }];
    await this.db.createTable(this.tableName, schema);
    log.info('LanceDB cleared');
  }

  close(): void {
    if (this.db) {
      this.db.close();
      this.db = null;
    }
  }
}

let instance: LanceDBAdapter | null = null;

export const getVectorDB = (): VectorDB => {
  if (!instance) {
    instance = new LanceDBAdapter();
  }
  return instance;
}
