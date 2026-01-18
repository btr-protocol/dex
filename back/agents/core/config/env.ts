import dotenv from 'dotenv';

dotenv.config();

export const zaiBaseUrl = process.env.ZAI_BASE_URL || 'https://open.bigmodel.cn/api/paas/v4';
export const zaiApiKey = process.env.ZAI_API_KEY || '';
export const ollamaUrl = process.env.OLLAMA_URL || 'http://localhost:11434';
export const embeddingModel = process.env.OLLAMA_MODEL || 'embeddinggemma:latest';
export const embeddingDimensions = parseInt(process.env.EMBEDDING_DIMENSIONS || '768', 10);
export const port = parseInt(process.env.PORT || '4001', 10);
export const corsEnabled = process.env.CORS_ENABLED !== 'false';
export const rateLimitPerSession = parseInt(process.env.RATE_LIMIT_PER_SESSION || '60', 10);
export const agentsDir = process.env.AGENTS_DIR || './back/agents';
export const dataDir = process.env.DATA_DIR || './back/agents/.data';
export const debug = process.env.DEBUG === 'true';
export const nodeEnv = process.env.NODE_ENV || 'development';

if (!zaiApiKey && nodeEnv === 'development') {
  console.warn('⚠️  ZAI_API_KEY not set');
}

console.log(`📚 Agents config:
  - ZAI Base URL: ${zaiBaseUrl}
  - Ollama URL: ${ollamaUrl}
  - Embedding Model: ${embeddingModel} (${embeddingDimensions}D)
  - Port: ${port}
  - CORS: ${corsEnabled ? 'enabled' : 'disabled'}
`);
