/**
 * File digest storage using SQLite.
 * Replaces file-digests.json for faster CRUD operations.
 */

import Database from 'bun:sqlite';
import { agentsDigestsDBPath } from '@shared/storage';
import type { FileDigest } from '@shared/types';
import { mkdirSync } from 'fs';
import { dirname } from 'path';

let db: Database | null = null;

function getDB(): Database {
  if (db) return db;

  // Ensure directory exists
  mkdirSync(dirname(agentsDigestsDBPath), { recursive: true });

  db = new Database(agentsDigestsDBPath);
  db.run('PRAGMA journal_mode=WAL');
  db.run('PRAGMA busy_timeout=5000');

  db.exec(`
    CREATE TABLE IF NOT EXISTS file_digests (
      path TEXT PRIMARY KEY,
      digest TEXT NOT NULL,
      size INTEGER NOT NULL,
      lastModified INTEGER NOT NULL,
      chunkCount INTEGER NOT NULL
    )
  `);

  return db;
}

export interface DigestRecord {
  path: string;
  digest: string;
  size: number;
  lastModified: number;
  chunkCount: number;
}

/** Load all digests from SQLite */
export async function loadDigestCache(): Promise<Map<string, FileDigest>> {
  const database = getDB();
  const rows = database.prepare('SELECT * FROM file_digests').all() as DigestRecord[];

  const map = new Map<string, FileDigest>();
  for (const row of rows) {
    map.set(row.path, {
      path: row.path,
      digest: row.digest,
      size: row.size,
      lastModified: row.lastModified,
      chunkCount: row.chunkCount
    });
  }
  return map;
}

/** Save a single digest record (upsert) */
export async function saveDigest(path: string, digest: FileDigest): Promise<void> {
  const database = getDB();
  database.prepare(`
    INSERT INTO file_digests (path, digest, size, lastModified, chunkCount)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(path) DO UPDATE SET
      digest = excluded.digest,
      size = excluded.size,
      lastModified = excluded.lastModified,
      chunkCount = excluded.chunkCount
  `).run(path, digest.digest, digest.size, digest.lastModified, digest.chunkCount);
}

/** Save multiple digest records in a transaction */
export async function saveDigestBatch(entries: [string, FileDigest][]): Promise<void> {
  const database = getDB();
  const stmt = database.prepare(`
    INSERT INTO file_digests (path, digest, size, lastModified, chunkCount)
    VALUES (?, ?, ?, ?, ?)
    ON CONFLICT(path) DO UPDATE SET
      digest = excluded.digest,
      size = excluded.size,
      lastModified = excluded.lastModified,
      chunkCount = excluded.chunkCount
  `);

  database.transaction(() => {
    for (const [path, digest] of entries) {
      stmt.run(path, digest.digest, digest.size, digest.lastModified, digest.chunkCount);
    }
  })();
}

/** Delete a digest record */
export async function deleteDigest(path: string): Promise<void> {
  const database = getDB();
  database.prepare('DELETE FROM file_digests WHERE path = ?').run(path);
}

/** Clear all digest records */
export async function clearDigests(): Promise<void> {
  const database = getDB();
  database.prepare('DELETE FROM file_digests').run();
}

/** Close the database connection */
export function closeDigestStorage(): void {
  if (db) {
    db.close();
    db = null;
  }
}
