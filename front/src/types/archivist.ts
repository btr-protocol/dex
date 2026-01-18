export interface ArchivistMessage {
  role: 'user' | 'assistant';
  content: string;
  html?: string;
  timestamp: number;
}

export interface ArchivistSource {
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
  preview: string;
}

export interface QueryEnhancement {
  originalQuery: string;
  rephrasedQuery: string;
  synonyms: string[];
  relatedTerms: string[];
  durationMs: number;
}

export interface ArchivistResponse {
  response: string;
  rawResponse: string;
  enhancement: QueryEnhancement;
  sources: ArchivistSource[];
  metrics: {
    totalDurationMs: number;
    queryOptimizationMs: number;
    lexicalSearchMs: number;
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

export interface ArchivistSession {
  sessionId: string;
  name?: string;
  lastMessage?: string;
  createdAt: number;
  lastActive: number;
  messageCount: number;
}
