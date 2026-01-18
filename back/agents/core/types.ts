export interface AgentConfig {
  agentId: string;
  name: string;
  model: string;
  embeddingModel: string;
  embeddingProvider: string;
  ollamaUrl: string;
  zaiBaseUrl: string;
  embeddingDimensions: number;
  context: ContextConfig;
  retrieval: RetrievalConfig;
  chunking: ChunkingConfig;
  knowledge: KnowledgeConfig;
  server: ServerConfig;
}

export interface ContextConfig {
  maxContextTokens: number;
  compactThreshold: number;
  compactTargetTokens: number;
  minRecentMessages: number;
  ageDecayFactor: number;
}

export interface RetrievalConfig {
  maxContextTokens: number;
  ragWeight: number;
  fuzzyWeight: number;
  maxResults: number;
  enableRAG?: boolean;  // Enable/disable semantic RAG search (default: true)
}

export interface ChunkingConfig {
  chunkSize: number;
  overlap: number;
  minChunkSize: number;
}

export interface KnowledgeConfig {
  include: string[];
  exclude: string[];
}

export interface ServerConfig {
  port: number;
  corsEnabled: boolean;
  rateLimitPerSession: number;
}

export interface ConversationMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  timestamp: number;
  tokens: number;
  importance: number;
}

export interface RetrievalContext {
  id: string;
  sourceType: 'rag' | 'fuzzy';
  sourceRef: string;
  content: string;
  relevance: number;
  protected: boolean;
  timestamp: number;
}

export interface SessionContext {
  sessionId: string;
  userId?: string;
  agentId: string;
  messages: ConversationMessage[];
  retrievalContexts: RetrievalContext[];
  totalTokens: number;
  lastCompacted: number;
  createdAt: number;
  lastActive: number;
}

export interface SearchResult {
  content: string;
  sourceType: 'code' | 'doc' | 'markdown';
  sourceRef: string;
  metadata: SearchResultMetadata;
  score: number;
}

export interface SearchResultMetadata {
  language?: string;
  section?: string;
  function?: string;
  contract?: string;
  lineRange?: [number, number];
  bm25Score?: number;
  matchCount?: number;
}

/**
 * Enhanced search source with display metadata for frontend
 */
export interface SearchSource {
  /** Original source reference */
  ref: string;
  /** Display name (file path or contract name) */
  displayName: string;
  /** Source type category */
  category: 'contract' | 'sdk' | 'documentation' | 'test';
  /** Programming language (for code) */
  language?: string;
  /** Contract name (for Solidity) */
  contract?: string;
  /** Function name (if applicable) */
  function?: string;
  /** Documentation section */
  section?: string;
  /** Line range in file */
  lineRange?: [number, number];
  /** Relevance score (0-1) */
  score: number;
  /** Raw BM25 score */
  rawScore: number;
  /** Preview content (first 200 chars) */
  preview: string;
}

/**
 * Query enhancement details
 */
export interface QueryEnhancement {
  /** Original user query */
  originalQuery: string;
  /** Rephrased/optimized query */
  rephrasedQuery: string;
  /** Synonyms added */
  synonyms: string[];
  /** Related terms added */
  relatedTerms: string[];
  /** Enhancement duration in ms */
  durationMs: number;
}

/**
 * Enhanced search response with full metadata
 */
export interface EnhancedSearchResponse {
  /** The main response (compiled markdown) */
  response: string;
  /** Raw response before markdown compilation */
  rawResponse: string;
  /** Query enhancement details */
  enhancement: QueryEnhancement;
  /** Sources ordered by relevance */
  sources: SearchSource[];
  /** Performance metrics */
  metrics: {
    /** Total pipeline duration in ms */
    totalDurationMs: number;
    /** Query optimization duration in ms */
    queryOptimizationMs: number;
    /** Lexical search duration in ms */
    lexicalSearchMs: number;
    /** Response generation duration in ms */
    responseGenerationMs: number;
    /** Number of documents retrieved */
    documentsRetrieved: number;
    /** Search mode used */
    searchMode: 'hybrid' | 'lexical-only' | 'semantic-only';
  };
  /** Session info */
  sessionId: string;
  /** Session statistics */
  stats: {
    sessionId: string;
    messageCount: number;
    totalTokens: number;
    compactedCount: number;
  };
}

export interface KnowledgeChunk {
  id: number;
  vector: number[];
  text: string;
  sourceType: 'code' | 'doc' | 'markdown';
  sourceRef: string;
  metadata: SearchResultMetadata;
  indexedAt: string;
  fileDigest?: string;
}

export interface FileDigest {
  path: string;
  digest: string;
  size: number;
  lastModified: number;
  chunkCount: number;
}

export interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}

export interface ChatOptions {
  temperature?: number;
  maxTokens?: number;
  stream?: boolean;
}

export interface WSClient {
  sessionId: string;
  agentId: string;
}

export interface EmbeddingProvider {
  generateEmbeddings(texts: string[]): Promise<number[][]>;
  getDimensions(): number;
  isAvailable(): Promise<boolean>;
  warmUp?(): Promise<void>;
}

export interface ChatProvider {
  chatCompletion(
    messages: ChatMessage[],
    options?: ChatOptions
  ): Promise<string | AsyncGenerator<string>>;
  countTokens(text: string): number;
  isAvailable(): Promise<boolean>;
}

export interface Storage {
  initialize(): Promise<void>;
  registerAgent(config: AgentConfig): Promise<void>;
  getAgent(agentId: string): AgentConfig | null;
  listAgents(): AgentConfig[];
  createSession(sessionId: string, agentId: string, userId?: string): Promise<void>;
  getSession(sessionId: string): SessionContext | null;
  getSessionStats(sessionId: string): SessionStats | null;
  updateSessionActivity(sessionId: string): Promise<void>;
  addMessage(sessionId: string, role: 'user' | 'assistant', content: string, tokens: number, importance?: number, isProtected?: boolean): Promise<void>;
  addRetrievalContext(sessionId: string, sourceType: 'rag' | 'fuzzy', sourceRef: string, content: string, relevance: number): Promise<void>;
  clearSession(sessionId: string): Promise<void>;
  compactSession(sessionId: string, keepMessageIds: number[], stats: { beforeTokens: number; afterTokens: number }): Promise<void>;
  close(): void;
}

export interface VectorDB {
  initialize(): Promise<void>;
  addChunks(chunks: KnowledgeChunk[]): Promise<void>;
  search(query: string, k?: number): Promise<SearchResult[]>;
  clear(): Promise<void>;
  close(): void;
}

export interface CompactionStats {
  beforeTokens: number;
  afterTokens: number;
  messagesRemoved: number;
  retrievalContextsProtected: number;
  timestamp: number;
}

export interface SessionStats {
  sessionId: string;
  messageCount: number;
  totalTokens: number;
  lastCompacted?: number;
  compactedCount: number;
}
