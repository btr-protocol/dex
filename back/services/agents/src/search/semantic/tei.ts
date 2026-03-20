import type { EmbeddingProvider } from '@shared/types';
import { embeddingConfig } from '../config.js';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('tei');

interface TEIEmbedResponse {
  [index: number]: number[];
}

export class TEIEmbeddingProvider implements EmbeddingProvider {
  private url: string;
  private readonly dimensions: number;
  private readonly maxRetries = 3;
  private readonly batchSize: number;
  private readonly maxConcurrency: number;
  private readonly useQueryPrefix: boolean;  // Whether to use "query:" prefix (EmbeddingGemma)

  constructor(url?: string, useQueryPrefix = false) {
    this.url = url || embeddingConfig.teiUrl;
    this.dimensions = embeddingConfig.dimensions;
    this.batchSize = embeddingConfig.batchSize;
    this.maxConcurrency = embeddingConfig.maxConcurrency;
    // EmbeddingGemma uses "query:" prefix for search queries
    // BGE models don't use prefixes
    this.useQueryPrefix = useQueryPrefix || embeddingConfig.model.includes('gemma');
  }

  async isAvailable(): Promise<boolean> {
    try {
      const healthUrl = this.url.replace('/embed', '/health');
      const res = await fetch(healthUrl, {
        signal: AbortSignal.timeout(5000)
      });
      return res.ok;
    } catch {
      return false;
    }
  }

  async warmUp(): Promise<void> {
    log.info('Warming up TEI embedding provider...');
    await this.generateEmbeddings(['warmup'], { isQuery: false });
    log.info('TEI provider ready');
  }

  getDimensions(): number {
    return this.dimensions;
  }

  /**
   * Generate embeddings with batched parallel processing.
   * Uses configurable batch size and concurrency for optimal throughput.
   *
   * @param texts - Texts to embed
   * @param options - Optional: { isQuery: true } adds "query:" prefix for EmbeddingGemma
   */
  async generateEmbeddings(
    texts: string[],
    options?: { isQuery?: boolean }
  ): Promise<number[][]> {
    const isQuery = options?.isQuery ?? false;
    return this.generateEmbeddingsWithPrefix(texts, isQuery);
  }

  /**
   * Generate embeddings with query/document prefix support (EmbeddingGemma feature).
   * - For search queries: adds "query:" prefix
   * - For documents: no prefix (plain text)
   *
   * @param texts - Texts to embed
   * @param isQuery - Whether these are search queries (adds prefix) or documents (no prefix)
   * @returns Embedding vectors
   */
  async generateEmbeddingsWithPrefix(
    texts: string[],
    isQuery = false
  ): Promise<number[][]> {
    if (!texts.length) return [];

    // EmbeddingGemma uses "query:" prefix for search queries
    // Documents are embedded without prefix
    const processedTexts = (this.useQueryPrefix && isQuery)
      ? texts.map(t => `query: ${t}`)
      : texts;

    // Split into batches
    const batches: string[][] = [];
    for (let i = 0; i < processedTexts.length; i += this.batchSize) {
      batches.push(processedTexts.slice(i, Math.min(i + this.batchSize, processedTexts.length)));
    }

    const typeLabel = isQuery ? 'queries' : 'documents';
    log.info(`Generating embeddings: ${texts.length} ${typeLabel} in ${batches.length} batches (batch size: ${this.batchSize}, concurrency: ${this.maxConcurrency})`);

    // Process batches with limited concurrency
    const results: number[][][] = [];
    for (let i = 0; i < batches.length; i += this.maxConcurrency) {
      const concurrentBatches = batches.slice(i, Math.min(i + this.maxConcurrency, batches.length));
      const batchResults = await Promise.all(
        concurrentBatches.map((batch, idx) =>
          this.fetchEmbeddings(batch, i + idx + 1, batches.length)
        )
      );
      results.push(...batchResults);
    }

    return results.flat();
  }

  private async fetchEmbeddings(texts: string[], batchNum?: number, totalBatches?: number): Promise<number[][]> {
    const batchLabel = batchNum && totalBatches ? `[${batchNum}/${totalBatches}]` : '';

    for (let attempt = 0; attempt < this.maxRetries; attempt++) {
      try {
        const start = performance.now();
        const res = await fetch(this.url, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ inputs: texts }),
          signal: AbortSignal.timeout(60_000)
        });

        if (!res.ok) {
          if (res.status >= 500 && attempt < this.maxRetries - 1) {
            log.info(`${batchLabel} TEI server error (${res.status}), retrying in ${Math.pow(2, attempt)}s...`);
            await Bun.sleep(1000 * Math.pow(2, attempt));
            continue;
          }
          throw new Error(`TEI error: ${res.status} ${res.statusText}`);
        }

        const data = await res.json() as TEIEmbedResponse;
        const embeddings = Object.values(data).map(e => Array.from(e as number[]));

        const duration = performance.now() - start;
        if (batchLabel) {
          log.info(`${batchLabel} Generated ${embeddings.length} embeddings in ${duration.toFixed(0)}ms`);
        }

        // Validate dimensions
        if (embeddings.length > 0 && embeddings[0].length !== this.dimensions) {
          log.info(`⚠️  Dimension mismatch: expected ${this.dimensions}, got ${embeddings[0].length}`);
        }

        return embeddings;
      } catch (err) {
        if (attempt === this.maxRetries - 1) {
          log.info(`${batchLabel} Failed after ${this.maxRetries} attempts: ${err}`);
          throw err;
        }
        log.info(`${batchLabel} Attempt ${attempt + 1} failed, retrying...`);
        await Bun.sleep(1000 * Math.pow(2, attempt));
      }
    }

    throw new Error('Max retries exceeded');
  }
}
