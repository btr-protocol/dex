import type { AgentConfig } from '../core/types';

export const config: AgentConfig = {
  agentId: 'archivist',
  name: 'BTR Knowledge Archivist',
  model: 'glm-4.5-air',
  embeddingModel: 'embeddinggemma:latest',
  embeddingProvider: 'ollama',
  ollamaUrl: 'http://localhost:11434',
  zaiBaseUrl: 'https://api.z.ai/api/coding/paas/v4',
  embeddingDimensions: 768,

  context: {
    maxContextTokens: 30000,
    compactThreshold: 0.8,
    compactTargetTokens: 8000,
    minRecentMessages: 6,
    ageDecayFactor: 0.95
  },

  retrieval: {
    maxContextTokens: 8000,
    ragWeight: 0.6,
    fuzzyWeight: 0.4,
    maxResults: 15,
    enableRAG: false  // Disabled due to server capacity constraints
  },

  chunking: {
    chunkSize: 2000,  // ~500 tokens, safe for embeddinggemma's 2048 token context
    overlap: 300,     // 15% overlap
    minChunkSize: 300
  },

  knowledge: {
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
  },

  server: {
    port: 4001,
    corsEnabled: true,
    rateLimitPerSession: 60
  }
};
