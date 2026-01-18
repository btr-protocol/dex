import { connect } from '@lancedb/lancedb';
import { log } from '../../shared/logger.js';

import type { KnowledgeChunk, SearchResult, VectorDB } from './types.js';
import { getStorage } from './storage.js';


class LanceDBAdapter implements VectorDB {
  private db: any = null;
  private dbPath: string;
  private tableName: string;

  constructor() {
    if (import.meta.dir) {
      this.dbPath = `${import.meta.dir}/../.data/lancedb`;
    } else {
      this.dbPath = `${process.cwd()}/back/agents/.data/lancedb`;
    }
    this.tableName = 'knowledge';
  }

  async initialize(): Promise<void> {
    try {
      const parentDir = this.dbPath.split('/').slice(0, -1).join('/');
      await Bun.write(Bun.file(`${parentDir}/.keep`), '');

      this.db = await connect(this.dbPath);
      log('LanceDB connected');
    } catch (error) {
      log(`LanceDB init error: ${error}`);
      throw error;
    }
  }

  async addChunks(chunks: KnowledgeChunk[]): Promise<void> {
    if (!this.db) await this.initialize();

    if (chunks.length === 0) return;

    const validChunks = chunks.filter(c => c.vector && c.vector.length > 0);
    if (validChunks.length !== chunks.length) {
      log(`Warning: ${chunks.length - validChunks.length} chunks have no vector`);
    }

    if (validChunks.length === 0) return;

    const data = validChunks.map((c, i) => ({
      id: i + 1,
      vector: Array.from(c.vector),
      text: c.text,
      sourceType: c.sourceType,
      sourceRef: c.sourceRef,
      metadata: JSON.stringify(c.metadata),
      indexedAt: c.indexedAt
    }));

    try {
      const tables = await this.db.tableNames();
      if (tables.includes(this.tableName)) {
        await this.db.dropTable(this.tableName);
        log('Dropped existing table');
      }

      await this.db.createTable(this.tableName, data);
      log(`Created table and added ${validChunks.length} chunks to LanceDB`);
    } catch (error) {
      log(`Error adding chunks: ${error}`);
      throw error;
    }
  }

  async search(query: string, k = 10): Promise<SearchResult[]> {
    if (!this.db) await this.initialize();

    try {
      const tables = await this.db.tableNames();
      if (!tables.includes(this.tableName)) {
        log('No knowledge table found, returning empty results');
        return [];
      }

      const storage = await getStorage();
      const agentConfig = storage.getAgent('archivist');
      const dimensions = agentConfig?.embeddingDimensions || 768;

      const embeddings = await this.getQueryEmbedding(query, dimensions);

      const table = await this.db.openTable(this.tableName);
      const results = await table
        .vectorSearch(embeddings)
        .limit(k)
        .toArray();

      return results.map((r: any) => ({
        content: r.text,
        sourceType: r.sourceType,
        sourceRef: r.sourceRef,
        metadata: JSON.parse(r.metadata || '{}'),
        score: 1 - r._distance
      }));
    } catch (error) {
      log(`Search error: ${error}`);
      return [];
    }
  }

  private async getQueryEmbedding(query: string, dimensions: number): Promise<number[]> {
    const mod = await import('./models.js');
    const provider = await mod.getEmbeddingProvider();
    const embeddings = await provider.generateEmbeddings([query]);
    return embeddings[0] || [];
  }

  async clear(): Promise<void> {
    if (!this.db) await this.initialize();

    await this.db.dropTable(this.tableName);
    const schema = [
      { id: 0, vector: Array(1024).fill(0), text: '', sourceType: '', sourceRef: '', metadata: '{}', indexedAt: new Date().toISOString() }
    ];
    await this.db.createTable(this.tableName, schema);
    log('LanceDB cleared');
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
