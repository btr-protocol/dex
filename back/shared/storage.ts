/**
 * Centralized storage paths for all backend services.
 *
 * Services: agents | collector | api
 * Each service has its own directory under DATA_DIR.
 *
 * Structure:
 *   DATA_DIR/
 *   ├── agents/
 *   │   ├── agents.db       (SQLite sessions/agents)
 *   │   ├── digests.db      (SQLite file digests for indexing)
 *   │   └── lancedb/        (LanceDB vectors)
 *   ├── collector/
 *   │   └── collector.db    (SQLite market data)
 *   └── api/
 *       └── users.db        (SQLite users/auth)
 */

import { resolve, dirname } from 'path';
import { fileURLToPath } from 'url';
import { mkdirSync, existsSync } from 'fs';

const __filename = fileURLToPath(import.meta.url);
const __dirname = dirname(__filename);

/** Base data directory - set via DATA_DIR env, defaults to ./.data from back/ */
export const DATA_DIR = process.env.DATA_DIR || resolve(__dirname, '../.data');

/** Service names matching our backend services */
export type ServiceName = 'agents' | 'collector' | 'api';

/**
 * Get the data directory for a specific service.
 * Ensures the directory exists.
 */
export function getServiceDir(service: ServiceName): string {
  const dir = resolve(DATA_DIR, service);
  if (!existsSync(dir)) {
    mkdirSync(dir, { recursive: true });
  }
  return dir;
}

/**
 * Get the SQLite database path for a service.
 * @param service - Service name (agents, collector, api)
 * @param name - Database filename without extension
 */
export function getDBPath(service: ServiceName, name: string): string {
  return resolve(getServiceDir(service), `${name}.db`);
}

/**
 * Get the LanceDB path for a service.
 * LanceDB stores its data as a directory, not a file.
 */
export function getLanceDBPath(service: ServiceName): string {
  return resolve(getServiceDir(service), 'lancedb');
}

// Service directories (exported for convenience)
export const agentsDir = getServiceDir('agents');
export const collectorDir = getServiceDir('collector');
export const apiDir = getServiceDir('api');

// SQLite database paths
export const agentsDBPath = getDBPath('agents', 'agents');
export const agentsDigestsDBPath = getDBPath('agents', 'digests');
export const collectorDBPath = getDBPath('collector', 'collector');
export const apiUsersDBPath = getDBPath('api', 'users');

// LanceDB paths
export const agentsLanceDBPath = getLanceDBPath('agents');
