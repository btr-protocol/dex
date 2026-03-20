/**
 * Storage initialization utilities
 *
 * Ensures proper storage directory structure:
 * - ${DATA_DIR}/agents/lancedb/  - LanceDB vector store
 * - ${DATA_DIR}/agents/         - SQLite databases
 */

import { mkdir } from 'fs/promises';
import { agentsLanceDBPath } from '@shared/storage';

/**
 * Ensure all storage directories exist
 * Creates directories if they don't exist
 */
export async function ensureStorageDirectories(): Promise<void> {
  try {
    await mkdir(agentsLanceDBPath, { recursive: true });
  } catch (error) {
    // Ignore "already exists" errors
    if ((error as NodeJS.ErrnoException).code !== 'EEXIST') {
      console.error(`Failed to create directory ${agentsLanceDBPath}:`, error);
      throw error;
    }
  }
}

/**
 * Get directory structure info
 */
export function getStorageInfo() {
  return {
    lancedb: agentsLanceDBPath
  };
}
