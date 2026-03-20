import type { AgentConfig } from '@shared/types';
import { knowledgeConfig, embeddingChunkingConfig, embeddingConfig } from '../search/config.js';
import { zaiBaseUrl } from '@shared/config';

export const config: AgentConfig = {
  agentId: 'archivist',
  name: 'BTR Knowledge Archivist',
  model: 'glm-4.7-flashx',
  embeddingModel: embeddingConfig.model,
  teiUrl: embeddingConfig.teiUrl,
  zaiBaseUrl,
  embeddingDimensions: embeddingConfig.dimensions,

  context: {
    maxContextTokens: 30000,
    compactThreshold: 0.8,
    compactTargetTokens: 8000,
    minRecentMessages: 6,
    ageDecayFactor: 0.95
  },

  retrieval: {
    maxContextTokens: 5000,  // Reduced for faster LLM responses
    ragWeight: 0.6,
    fuzzyWeight: 0.4,
    maxResults: 8,           // Reduced - only top results used anyway
    enableRAG: true,
    useHybridSearch: true
  },

  // Use shared chunking config from search module (840 chars for better code coverage)
  chunking: {
    ...embeddingChunkingConfig,
    chunkSize: 840,
    overlap: 160
  },

  // Use shared knowledge config from search module
  knowledge: knowledgeConfig,

  server: {
    port: 4001,
    corsEnabled: true,
    rateLimitPerSession: 60
  }
};
