// Import shared types from back/shared/types.ts to avoid duplication
import type { KnowledgeConfig, ChunkingConfig } from '@shared/types';

export type { KnowledgeConfig, ChunkingConfig };

export interface SearchConfig {
  maxResults: number;
  minSimilarity: number;
  includeMetadata: boolean;
}

/** Context limits for LLM prompt construction */
export interface ContextConfig {
  /** Maximum number of sources/results to include in context */
  maxResults: number;
  /** Maximum characters per source/result */
  maxCharsPerResult: number;
  /** Hard cap on total context characters */
  maxTotalChars: number;
}

export interface EmbeddingConfig {
  /** Model ID for TEI (must be a sentence-transformers compatible model) */
  model: string;
  /** Embedding dimensions (must match model output) */
  dimensions: number;
  /** TEI server URL */
  teiUrl: string;
  /** Batch size for embedding requests */
  batchSize: number;
  /** Max concurrent batch requests */
  maxConcurrency: number;
}

/** Reciprocal Rank Fusion (RRF) configuration */
export interface RRFConfig {
  /** Damping constant for RRF scoring (higher = more even weighting) */
  k: number;
  /** Score boost multiplier for hybrid results (found by both lexical + semantic) */
  hybridBoost: number;
  /** Maximum score after boosting (capped to prevent >1.0) */
  maxScore: number;
}

/** BM25 lexical search parameters */
export interface BM25Config {
  /** Term frequency saturation parameter (1.0-2.0 typical) */
  k1: number;
  /** Length normalization parameter (0.0-1.0, 0.75 is standard) */
  b: number;
  /** Score normalization divisor (raw BM25 scores divided by this) */
  scoreNormalizationDivisor: number;
}

/** Fuzzy matching configuration */
export interface FuzzyConfig {
  /** Enable fuzzy matching */
  enabled: boolean;
  /** Max normalized edit distance (0-1) */
  maxDistance: number;
  /** Only apply fuzzy to words >= this length */
  minLength: number;
}

export const searchConfig: SearchConfig = {
  maxResults: 32,          // Return more results than context needs for selection
  minSimilarity: 0.1,
  includeMetadata: true
};

/** Default context limits for LLM prompt construction
 * These values control how much retrieved context is passed to the LLM.
 * More sources = more context = slower but potentially more accurate responses.
 */
export const contextConfig: ContextConfig = {
  maxResults: 10,           // Top-k chunks for retrieval (fits 840*10=8400 tokens in LLM context)
  maxCharsPerResult: 4096,  // Allow multiple chunks per result
  maxTotalChars: 40960,     // ~10 results × 4096 chars for full context
};

export const knowledgeConfig: KnowledgeConfig = {
  include: [
    'docs/**/*.md',
    'contracts/src/**/*.sol',
    'sdk/src/**/*.ts',
  ],
  exclude: [
    '**/node_modules/**',
    '**/.next/**',
    '**/dist/**',
    '**/build/**',
    '**/test*.ts',
    '**/*.test.ts',
  ]
};

export const embeddingChunkingConfig: ChunkingConfig = {
  chunkSize: 840,   // Optimal for code - captures full functions/classes
  overlap: 160,     // ~19% overlap to prevent breaking logic at boundaries
  minChunkSize: 100
};

// TEI-only embedding configuration
// Using ONNX-community EmbeddingGemma 300m - 768D with MRL support
// Model: onnx-community/embeddinggemma-300m-ONNX (CPU-optimized, gated, requires HF_TOKEN)
// Requires "query:" prefix for search queries, plain text for documents
//
// NOTE: Q4 quantized model has a batch size limit of 8 (TEI enforced)
// We use higher concurrency (16) to maintain throughput: 8 x 16 = 128 concurrent embeddings
const teiUrl = process.env.TEI_URL || 'http://localhost';
const teiPort = process.env.TEI_PORT || '8080';
export const embeddingConfig: EmbeddingConfig = {
  model: process.env.TEI_MODEL || 'onnx-community/embeddinggemma-300m-ONNX',
  dimensions: 768,  // Full dimensions for max accuracy (MRL supports truncation to 512/256/128 if needed)
  teiUrl: `${teiUrl}:${teiPort}/embed`,
  batchSize: 8,   // Q4 model limit (TEI enforces max_batch_requests=8)
  maxConcurrency: 16  // Higher concurrency to compensate for smaller batch size
};

/** Reciprocal Rank Fusion configuration */
export const rrfConfig: RRFConfig = {
  k: 60,            // Standard RRF damping constant
  hybridBoost: 1.1, // 10% boost for results found by both lexical + semantic
  maxScore: 1.0     // Cap scores at 1.0
};

/** BM25 lexical search parameters */
export const bm25Config: BM25Config = {
  k1: 1.2,                      // Term frequency saturation
  b: 0.75,                      // Length normalization
  scoreNormalizationDivisor: 10 // Normalize raw BM25 to 0-1 range
};

/** Fuzzy matching configuration */
export const fuzzyConfig: FuzzyConfig = {
  enabled: true,
  maxDistance: 0.2, // Max 20% edit distance
  minLength: 4      // Only apply to words >= 4 chars
};
