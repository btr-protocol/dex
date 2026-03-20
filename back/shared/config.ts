import dotenv from 'dotenv';
import { resolve, dirname, join } from 'path';
import { fileURLToPath } from 'url';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('config');

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

// Load .env from back directory (back/shared/config.ts -> back/.env)
dotenv.config({ path: resolve(__dirname, '../.env') });

// Chat provider (ZAI)
export const zaiBaseUrl = process.env.ZAI_BASE_URL || 'https://api.z.ai/api/coding/paas/v4';
export const zaiApiKey = process.env.ZAI_API_KEY || '';

// AI models for different purposes
export const zaiModelEnhancement = process.env.ZAI_MODEL_ENHANCEMENT || 'glm-4.5-airx';
export const zaiModelReasoning = process.env.ZAI_MODEL_REASONING || 'glm-4.7';

// Server config
export const port = parseInt(process.env.AGENTS_PORT || process.env.PORT || '4001', 10);
export const corsEnabled = process.env.CORS_ENABLED !== 'false';
export const rateLimitPerSession = parseInt(process.env.RATE_LIMIT_PER_SESSION || '60', 10);
export const agentsDir = process.env.AGENTS_DIR || './services/agents';

export const debug = process.env.DEBUG === 'true' || true;
export const nodeEnv = process.env.NODE_ENV || 'development';

if (!zaiApiKey && nodeEnv === 'development') {
  log.warn('⚠️  ZAI_API_KEY not set');
} else if (nodeEnv === 'development') {
  const maskedKey = zaiApiKey ? `${zaiApiKey.slice(0, 8)}...${zaiApiKey.slice(-4)}` : 'not set';
  log.info(`✓ ZAI API Key loaded: ${maskedKey}`);
}

// NB: Embedding config is in back/agents/search/config.ts (TEI-based)
log.info(`📚 Agents config:
  - ZAI Base URL: ${zaiBaseUrl}
  - Port: ${port}
  - CORS: ${corsEnabled ? 'enabled' : 'disabled'}
  - Embeddings: TEI (see back/agents/search/config.ts)
`);
