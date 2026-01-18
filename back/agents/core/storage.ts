import Database from 'bun:sqlite';
import { log } from '../../shared/logger.js';

import type { AgentConfig, ConversationMessage, RetrievalContext, SessionContext, SessionStats, Storage } from './types.js';


class StorageAdapter implements Storage {
  private db: Database | null = null;
  private dbPath: string;

  constructor(dbPath: string = './back/agents/.data/agents.db') {
    this.dbPath = dbPath;
  }

  async initialize(): Promise<void> {
    const parentDir = this.dbPath.split('/').slice(0, -1).join('/');
    await Bun.write(Bun.file(`${parentDir}/.keep`), '');

    this.db = new Database(this.dbPath);
    this.db.run('PRAGMA journal_mode=WAL');
    this.db.run('PRAGMA busy_timeout=5000');
    this.db.run('PRAGMA foreign_keys=ON');

    this.db.exec(`
      CREATE TABLE IF NOT EXISTS agents (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        config_json TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    `);

    this.db.exec(`
      CREATE TABLE IF NOT EXISTS sessions (
        session_id TEXT PRIMARY KEY,
        user_id TEXT,
        agent_id TEXT NOT NULL,
        created_at TEXT NOT NULL,
        last_active TEXT NOT NULL,
        total_tokens INTEGER DEFAULT 0,
        FOREIGN KEY (agent_id) REFERENCES agents(id)
      )
    `);

    this.db.exec('CREATE INDEX IF NOT EXISTS idx_sessions_agent ON sessions(agent_id, last_active DESC)');

    this.db.exec(`
      CREATE TABLE IF NOT EXISTS messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        tokens INTEGER,
        timestamp TEXT NOT NULL,
        importance REAL DEFAULT 0.5,
        is_retrieval BOOLEAN DEFAULT 0,
        protected BOOLEAN DEFAULT 0,
        FOREIGN KEY (session_id) REFERENCES sessions(session_id)
      )
    `);

    this.db.exec('CREATE INDEX IF NOT EXISTS idx_messages_session ON messages(session_id, timestamp DESC)');
    this.db.exec('CREATE INDEX IF NOT EXISTS idx_messages_protected ON messages(protected, timestamp DESC)');

    this.db.exec(`
      CREATE TABLE IF NOT EXISTS retrieval_contexts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        message_id INTEGER,
        source_type TEXT NOT NULL,
        source_ref TEXT NOT NULL,
        content TEXT NOT NULL,
        relevance REAL,
        timestamp TEXT NOT NULL,
        protected BOOLEAN DEFAULT 1,
        FOREIGN KEY (session_id) REFERENCES sessions(session_id),
        FOREIGN KEY (message_id) REFERENCES messages(id)
      )
    `);

    this.db.exec('CREATE INDEX IF NOT EXISTS idx_retrieval_session ON retrieval_contexts(session_id, timestamp DESC)');

    log('Storage initialized');
  }

  async registerAgent(config: AgentConfig): Promise<void> {
    if (!this.db) await this.initialize();

    const now = new Date().toISOString();
    const existing = this.db!.prepare('SELECT id FROM agents WHERE id = ?').get(config.agentId);

    if (existing) {
      this.db!.prepare(
        'UPDATE agents SET name = ?, config_json = ?, updated_at = ? WHERE id = ?'
      ).run(config.name, JSON.stringify(config), now, config.agentId);
      log(`Agent ${config.agentId} updated`);
    } else {
      this.db!.prepare(
        'INSERT INTO agents (id, name, config_json, created_at, updated_at) VALUES (?, ?, ?, ?, ?)'
      ).run(config.agentId, config.name, JSON.stringify(config), now, now);
      log(`Agent ${config.agentId} registered`);
    }
  }

  getAgent(agentId: string): AgentConfig | null {
    if (!this.db) return null;

    const row = this.db.prepare('SELECT config_json FROM agents WHERE id = ?').get(agentId) as {
      config_json?: string;
    } | undefined;

    if (!row?.config_json) return null;
    return JSON.parse(row.config_json) as AgentConfig;
  }

  listAgents(): AgentConfig[] {
    if (!this.db) return [];

    const rows = this.db.prepare('SELECT config_json FROM agents').all() as {
      config_json: string;
    }[];

    return rows.map((r) => JSON.parse(r.config_json) as AgentConfig);
  }

  async createSession(sessionId: string, agentId: string, userId?: string): Promise<void> {
    if (!this.db) await this.initialize();

    const now = new Date().toISOString();
    this.db!.prepare(
      'INSERT OR REPLACE INTO sessions (session_id, user_id, agent_id, created_at, last_active) VALUES (?, ?, ?, ?, ?)'
    ).run(sessionId, userId ?? null, agentId, now, now);
    log(`Session ${sessionId} created for agent ${agentId}`);
  }

  async updateSessionActivity(sessionId: string): Promise<void> {
    if (!this.db) await this.initialize();

    const now = new Date().toISOString();
    this.db!.prepare(
      'UPDATE sessions SET last_active = ? WHERE session_id = ?'
    ).run(now, sessionId);
  }

  getSession(sessionId: string): SessionContext | null {
    if (!this.db) return null;

    const session = this.db.prepare(
      'SELECT * FROM sessions WHERE session_id = ?'
    ).get(sessionId) as {
      session_id: string;
      user_id: string | null;
      agent_id: string;
      created_at: string;
      last_active: string;
      total_tokens: number;
    } | undefined;

    if (!session) return null;

    const messages = this.db
      .prepare('SELECT * FROM messages WHERE session_id = ? ORDER BY timestamp ASC')
      .all(sessionId) as {
        id: number;
        role: string;
        content: string;
        tokens: number;
        timestamp: string;
        importance: number;
      }[];

    const conversationMessages = messages.map((m) => ({
      id: m.id.toString(),
      role: (m.role === 'user' || m.role === 'assistant' ? m.role : 'assistant') as 'user' | 'assistant',
      content: m.content,
      timestamp: new Date(m.timestamp).getTime(),
      tokens: m.tokens,
      importance: m.importance,
    }));

    const retrievals = this.db
      .prepare('SELECT * FROM retrieval_contexts WHERE session_id = ? ORDER BY timestamp DESC')
      .all(sessionId) as {
        id: number;
        source_type: string;
        source_ref: string;
        content: string;
        relevance: number;
        timestamp: string;
        protected: number;
      }[];

    const retrievalContexts = retrievals.map((r) => ({
      id: r.id.toString(),
      sourceType: (r.source_type === 'rag' || r.source_type === 'fuzzy' ? r.source_type : 'rag') as 'rag' | 'fuzzy',
      sourceRef: r.source_ref,
      content: r.content,
      relevance: r.relevance ?? 0,
      protected: Boolean(r.protected),
      timestamp: new Date(r.timestamp).getTime(),
    }));

    return {
      sessionId: session.session_id,
      userId: session.user_id ?? undefined,
      agentId: session.agent_id,
      messages: conversationMessages,
      retrievalContexts,
      totalTokens: session.total_tokens,
      lastCompacted: 0,
      createdAt: new Date(session.created_at).getTime(),
      lastActive: new Date(session.last_active).getTime(),
    };
  }

  getSessionStats(sessionId: string): SessionStats | null {
    if (!this.db) return null;

    const session = this.db.prepare(
      'SELECT session_id, total_tokens FROM sessions WHERE session_id = ?'
    ).get(sessionId) as {
      session_id: string;
      total_tokens: number;
    } | undefined;

    if (!session) return null;

    const messageCount = this.db.prepare(
      'SELECT COUNT(*) as count FROM messages WHERE session_id = ?'
    ).get(sessionId) as {
      count: number;
    } | undefined;

    return {
      sessionId: session.session_id,
      messageCount: messageCount?.count ?? 0,
      totalTokens: session.total_tokens,
      compactedCount: 0
    };
  }

  async addMessage(
    sessionId: string,
    role: 'user' | 'assistant',
    content: string,
    tokens: number,
    importance = 0.5,
    isProtected = false
  ): Promise<void> {
    if (!this.db) await this.initialize();

    const now = new Date().toISOString();
    this.db!.prepare(
      'INSERT INTO messages (session_id, role, content, tokens, timestamp, importance, protected) VALUES (?, ?, ?, ?, ?, ?, ?)'
    ).run(sessionId, role, content, tokens, now, importance, isProtected ? 1 : 0);

    this.db!.prepare(
      'UPDATE sessions SET total_tokens = total_tokens + ?, last_active = ? WHERE session_id = ?'
    ).run(tokens, now, sessionId);
  }

  async addRetrievalContext(
    sessionId: string,
    sourceType: 'rag' | 'fuzzy',
    sourceRef: string,
    content: string,
    relevance: number
  ): Promise<void> {
    if (!this.db) await this.initialize();

    const now = new Date().toISOString();
    this.db!.prepare(
      'INSERT INTO retrieval_contexts (session_id, source_type, source_ref, content, relevance, timestamp, protected) VALUES (?, ?, ?, ?, ?, ?, ?)'
    ).run(sessionId, sourceType, sourceRef, content, relevance, now, 1);
  }

  async clearSession(sessionId: string): Promise<void> {
    if (!this.db) await this.initialize();

    this.db!.prepare('DELETE FROM retrieval_contexts WHERE session_id = ?').run(sessionId);
    this.db!.prepare('DELETE FROM messages WHERE session_id = ?').run(sessionId);
    this.db!.prepare('DELETE FROM sessions WHERE session_id = ?').run(sessionId);

    log(`Session ${sessionId} cleared`);
  }

  async compactSession(
    sessionId: string,
    keepMessageIds: number[],
    stats: { beforeTokens: number; afterTokens: number }
  ): Promise<void> {
    if (!this.db) await this.initialize();

    if (keepMessageIds.length > 0) {
      const placeholders = keepMessageIds.map(() => '?').join(',');
      this.db!.prepare(
        `DELETE FROM messages WHERE session_id = ? AND id NOT IN (${placeholders})`
      ).run(sessionId, ...keepMessageIds);
    }

    this.db!.prepare(
      'UPDATE sessions SET total_tokens = ? WHERE session_id = ?'
    ).run(stats.afterTokens, sessionId);

    log(`Session ${sessionId} compacted: ${stats.beforeTokens} -> ${stats.afterTokens} tokens`);
  }

  close(): void {
    if (this.db) {
      this.db.close();
      this.db = null;
    }
  }
}
let instance: StorageAdapter | null = null;
let initPromise: Promise<void> | null = null;

export async function getStorage(): Promise<Storage> {
  if (!instance) {
    instance = new StorageAdapter();
    initPromise = instance.initialize();
  }
  if (initPromise) {
    await initPromise;
  }
  return instance;
}

export async function ensureStorageInitialized(): Promise<void> {
  if (initPromise) {
    await initPromise;
  }
}
