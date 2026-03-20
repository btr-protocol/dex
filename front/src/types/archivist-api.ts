/**
 * Archivist/Chat types - Centralized for backend & frontend consistency
 * Re-exports backend types for frontend consumption
 */

// ─────────────────────────────────────────────────────────────
// Chat Message Types
// ─────────────────────────────────────────────────────────────

/**
 * Chat message (used by both backend and frontend)
 * Backend name: ConversationMessage, Frontend name: ArchivistMessage
 */
export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
  timestamp?: number;
}

/**
 * Chat options (used by backend)
 */
export interface ChatOptions {
  temperature?: number;
  maxTokens?: number;
  stream?: boolean;
}

// ─────────────────────────────────────────────────────────────
// AI Response Types
// ─────────────────────────────────────────────────────────────

/**
 * Source reference for AI responses
 * Backend name: SearchSource, Frontend name: ArchivistSource
 */
export interface SourceReference {
  ref: string;
  displayName: string;
  category: 'contract' | 'sdk' | 'documentation' | 'test';
  language?: string;
  contract?: string;
  function?: string;
  section?: string;
  lineRange?: [number, number];
  score: number;
  rawScore: number;
  /** Origin of result: 'lexical', 'semantic', or 'hybrid' (both) */
  origin?: 'lexical' | 'semantic' | 'hybrid';
  preview: string;
}

/**
 * Query enhancement details
 */
export interface QueryEnhancement {
  originalQuery: string;
  rephrasedQuery: string;
  synonyms: string[];
  relatedTerms: string[];
  durationMs: number;
}

/**
 * Complete AI response with metadata
 * Backend name: EnhancedSearchResponse, Frontend name: ArchivistResponse
 */
export interface AIResponse {
  response: string;
  rawResponse: string;
  enhancement: QueryEnhancement;
  sources: SourceReference[];
  metrics: {
    totalDurationMs: number;
    queryOptimizationMs: number;
    lexicalSearchMs: number;
    semanticSearchMs: number;
    responseGenerationMs: number;
    documentsRetrieved: number;
    searchMode: 'hybrid' | 'lexical-only' | 'semantic-only';
  };
  sessionId: string;
  stats: {
    sessionId: string;
    messageCount: number;
    totalTokens: number;
    compactedCount: number;
  };
}

// ─────────────────────────────────────────────────────────────
// Session Types
// ─────────────────────────────────────────────────────────────

/**
 * Chat session
 * Backend name: SessionContext, Frontend name: ArchivistSession
 */
export interface ChatSession {
  sessionId: string;
  name?: string;
  lastMessage?: string;
  createdAt: number;
  lastActive: number;
  messageCount: number;
}

// ─────────────────────────────────────────────────────────────
// Backend-Only Types (for reference, not exported)
// ─────────────────────────────────────────────────────────────

/**
 * These types are defined in back/agents/core/types.ts
 * They are NOT exported here because they are internal to the backend:
 * - AgentConfig
 * - ContextConfig
 * - RetrievalConfig
 * - ChunkingConfig
 * - KnowledgeConfig
 * - ServerConfig
 * - ConversationMessage (same as ChatMessage)
 * - RetrievalContext
 * - SessionContext (same as ChatSession)
 * - SearchResult
 * - SearchResultMetadata
 * - KnowledgeChunk
 * - FileDigest
 * - WSClient
 * - EmbeddingProvider
 * - ChatProvider
 * - Storage
 * - VectorDB
 * - CompactionStats
 * - SessionStats
 */
