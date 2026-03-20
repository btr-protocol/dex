/**
 * Client-side session storage with LRU eviction and size limits.
 * All conversation data is stored locally in the user's browser.
 */

import { logger } from '@sdk/utils';

const log = logger.withContext('sessionStorage');

export interface SessionData {
  sessionId: string;
  name?: string;
  lastMessage?: string;
  createdAt: number;
  lastActive: number;
  messageCount: number;
}

export interface StorageStats {
  totalBytes: number;
  totalSessions: number;
  limitBytes: number;
  usagePercent: number;
}

const SESSIONS_KEY = 'archivist-sessions';
const MESSAGES_PREFIX = 'archivist-messages-';
const STORAGE_LIMIT_BYTES = 5 * 1024 * 1024; // 5MB

/**
 * Get current localStorage usage for archivist data.
 */
function getStorageSize(): number {
  let total = 0;
  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key && (key === SESSIONS_KEY || key.startsWith(MESSAGES_PREFIX))) {
      const value = localStorage.getItem(key);
      if (value) {
        // Rough estimate: each char is 2 bytes (UTF-16)
        total += (key.length + value.length) * 2;
      }
    }
  }
  return total;
}

/**
 * Get storage statistics.
 */
export function getStorageStats(): StorageStats {
  const totalBytes = getStorageSize();
  const sessions = getAllSessions();
  return {
    totalBytes,
    totalSessions: sessions.length,
    limitBytes: STORAGE_LIMIT_BYTES,
    usagePercent: (totalBytes / STORAGE_LIMIT_BYTES) * 100,
  };
}

/**
 * Get all sessions, sorted by lastActive (newest first).
 * Filters out empty sessions (0 messages).
 */
export function getAllSessions(): SessionData[] {
  try {
    const stored = localStorage.getItem(SESSIONS_KEY);
    if (!stored) return [];

    const sessions = JSON.parse(stored) as SessionData[];
    // Filter out sessions with 0 messages and sort by lastActive
    return sessions
      .filter(s => s.messageCount > 0)
      .sort((a, b) => b.lastActive - a.lastActive);
  } catch {
    return [];
  }
}

/**
 * Get a single session by ID.
 */
export function getSession(sessionId: string): SessionData | undefined {
  const sessions = getAllSessions();
  return sessions.find(s => s.sessionId === sessionId);
}

/**
 * Save or update a session.
 * Returns false if storage limit would be exceeded.
 */
export function saveSession(session: SessionData): boolean {
  // Don't save sessions with 0 messages
  if (session.messageCount === 0) {
    deleteSession(session.sessionId);
    return true;
  }

  // Ensure we're within storage limit
  ensureStorageLimit();

  const sessions = getAllSessions();
  const existingIndex = sessions.findIndex(s => s.sessionId === session.sessionId);

  if (existingIndex >= 0) {
    sessions[existingIndex] = session;
  } else {
    sessions.push(session);
  }

  // Sort by lastActive
  sessions.sort((a, b) => b.lastActive - a.lastActive);

  try {
    localStorage.setItem(SESSIONS_KEY, JSON.stringify(sessions));
    return true;
  } catch (e) {
    // Storage quota exceeded, try to free more space
    evictOldestSession();
    try {
      localStorage.setItem(SESSIONS_KEY, JSON.stringify(sessions));
      return true;
    } catch {
      log.error('Failed to save session, storage full');
      return false;
    }
  }
}

/**
 * Delete a session and its messages.
 */
export function deleteSession(sessionId: string): void {
  const sessions = getAllSessions();
  const filtered = sessions.filter(s => s.sessionId !== sessionId);

  try {
    localStorage.setItem(SESSIONS_KEY, JSON.stringify(filtered));
    localStorage.removeItem(`${MESSAGES_PREFIX}${sessionId}`);
  } catch (e) {
    log.error('Failed to delete session', e);
  }
}

/**
 * Get messages for a session.
 */
export function getSessionMessages(sessionId: string): string {
  try {
    return localStorage.getItem(`${MESSAGES_PREFIX}${sessionId}`) || '[]';
  } catch {
    return '[]';
  }
}

/**
 * Save messages for a session.
 * Handles LRU eviction if storage limit is exceeded.
 */
export function saveSessionMessages(sessionId: string, messagesJSON: string): boolean {
  // Don't save empty message arrays
  const messages = JSON.parse(messagesJSON);
  if (!Array.isArray(messages) || messages.length === 0) {
    deleteSession(sessionId);
    return true;
  }

  // Ensure storage limit before saving
  ensureStorageLimit();

  try {
    localStorage.setItem(`${MESSAGES_PREFIX}${sessionId}`, messagesJSON);
    return true;
  } catch (e) {
    // Storage quota exceeded, evict and retry
    evictOldestSession();
    try {
      localStorage.setItem(`${MESSAGES_PREFIX}${sessionId}`, messagesJSON);
      return true;
    } catch {
      log.error('Failed to save messages, storage full');
      return false;
    }
  }
}

/**
 * Ensure storage is under the limit by evicting oldest sessions.
 */
function ensureStorageLimit(): void {
  let attempts = 0;
  const maxAttempts = 10;

  while (attempts < maxAttempts && getStorageSize() > STORAGE_LIMIT_BYTES * 0.9) {
    if (!evictOldestSession()) {
      break; // No more sessions to evict
    }
    attempts++;
  }
}

/**
 * Evict the least recently used (oldest) session.
 * Returns false if no sessions to evict.
 */
function evictOldestSession(): boolean {
  const sessions = getAllSessions();
  if (sessions.length === 0) return false;

  // Get the oldest session (last in the sorted array)
  const oldestSession = sessions[sessions.length - 1];
  deleteSession(oldestSession.sessionId);
  return true;
}

/**
 * Clean up any empty sessions from storage.
 * Call this on app initialization to clean up legacy empty sessions.
 */
export function cleanupEmptySessions(): void {
  const sessions = getAllSessions();
  const hasEmptySessions = sessions.some(s => s.messageCount === 0);

  if (hasEmptySessions) {
    const validSessions = sessions.filter(s => s.messageCount > 0);
    try {
      localStorage.setItem(SESSIONS_KEY, JSON.stringify(validSessions));
    } catch (e) {
      log.error('Failed to clean up empty sessions', e);
    }
  }

  // Also clean up any message-less sessions in localStorage
  for (let i = localStorage.length - 1; i >= 0; i--) {
    const key = localStorage.key(i);
    if (key?.startsWith(MESSAGES_PREFIX)) {
      const sessionId = key.replace(MESSAGES_PREFIX, '');
      const session = sessions.find(s => s.sessionId === sessionId);
      const messages = localStorage.getItem(key);

      // If session doesn't exist or messages are empty, remove
      if ((!session || session.messageCount === 0) && messages === '[]') {
        localStorage.removeItem(key);
      }
    }
  }
}

/**
 * Clear all archivist data from localStorage.
 */
export function clearAllSessions(): void {
  const keysToDelete: string[] = [];

  for (let i = 0; i < localStorage.length; i++) {
    const key = localStorage.key(i);
    if (key && (key === SESSIONS_KEY || key.startsWith(MESSAGES_PREFIX))) {
      keysToDelete.push(key);
    }
  }

  keysToDelete.forEach(key => localStorage.removeItem(key));
}
