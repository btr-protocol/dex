# BTR's Archivist - Technical Specification

**Minimal AI Knowledge Agent with Hybrid RAG + Context Management**

---

## 1. Overview

BTR's Archivist is a lightweight AI agent designed to leverage project knowledge from documentation (`./docs`) and codebases (`./contracts/src`, `./sdk/src`) through hybrid RAG search (vector embeddings + fuzzy grep search). The agent maintains per-user conversation sessions with intelligent context compaction and uses local Ollama embeddings with ZAI GLM-4.7 for reasoning.

### Key Characteristics

- **Minimal dependencies**: Only essential packages for embeddings, vector DB, and LLM communication
- **Generic foundation**: Designed to support multiple agents, not just Archivist
- **Hybrid search**: Combines vector RAG with real-time fuzzy grep
- **Smart context**: Automatic conversation compaction with age-based aggressiveness
- **Persistent memories**: Agent memories never compacted, always in context
- **Modular design**: Each agent has system prompt, knowledge folder, memories, config

---

## 2. Architecture

### 2.1 Directory Structure

```
back/
└── agents/
    ├── archivist/           # Archivist agent implementation
    │   ├── agent.md        # System prompt and configuration
    │   ├── memories.md     # Persistent memories (never compacted)
    │   ├── config.json     # Agent-specific configuration
    │   └── knowledge/     # Files to be RAG indexed
    ├── core/              # Generic agent foundation
    │   ├── server.ts       # Bun HTTP/WebSocket server
    │   ├── router.ts       # Agent routing and dispatch
    │   ├── models.ts       # LLM/embedding abstractions
    │   ├── context.ts      # Session and context management
    │   ├── storage.ts      # LanceDB + SQLite persistence
    │   └── types.ts       # Shared TypeScript types
    └── search/            # Hybrid search implementation
        ├── vector.ts       # LanceDB vector search
        ├── fuzzy.ts       # Real-time grep-based search
        └── hybrid.ts      # RAG+fuzzy result fusion
```

### 2.2 Technology Stack

| Component | Technology | Reason |
|-----------|------------|---------|
| Runtime | Bun | Fast, TypeScript-native, minimal overhead |
| Vector DB | LanceDB | Used in moa, efficient, no separate server |
| Embeddings | Ollama (embeddinggemma:latest) | Google's 768D model (307MB), ~3x faster than qwen-embedding:0.6b; optimized for 4 chars/token approximation |
| LLM | ZAI GLM-4.5-air (OpenAI-compatible) | Primary reasoning model |
| Persistence | SQLite | Session history, agent config, metadata |
| Frontend | Preact + Tailwind | Matches existing stack, minimal |

### 2.3 Minimal Dependencies

```json
{
  "dependencies": {
    "@lancedb/lancedb": "^0.22.3",
    "better-sqlite3": "^11.8.1",
    "openai": "^5.11.0",
    "preact": "^10.22.0",
    "@preact/signals": "^2.5.1",
    "lucide-preact": "^0.468.0"
  },
  "devDependencies": {
    "@types/bun": "latest",
    "typescript": "^5.9.3",
    "tailwindcss": "^3.4.1"
  }
}
```

---

## 3. Core Components

### 3.1 Generic Agent Server (`back/agents/core/server.ts`)

**Purpose**: Lightweight HTTP/WebSocket server for all agents

**Endpoints**:

```
GET  /agents                           # List available agents
POST /agents/{id}/chat               # Chat with agent (streaming)
GET  /agents/{id}/sessions/{uid}     # Get session history
POST /agents/{id}/sessions/{uid}/reset # Reset/clear session
GET  /agents/{id}/status             # Agent health and config
POST /agents/{id}/reindex            # Trigger knowledge reindex
```

**WebSocket**:
```
WS   /agents/{id}/ws                 # Real-time streaming chat
```

**Implementation**:
- Bun native HTTP server (no Express/Fastify)
- WebSocket support for streaming responses
- JSON request/response with SSE fallback
- Simple rate limiting per session ID

### 3.2 Model Abstraction (`back/agents/core/models.ts`)

**Purpose**: OpenAI-compatible client abstraction supporting multiple providers

**Interfaces**:

```typescript
interface EmbeddingProvider {
  generateEmbeddings(texts: string[]): Promise<number[][]>;
  getDimensions(): number;
  isAvailable(): Promise<boolean>;
}

interface ChatProvider {
  chatCompletion(messages: ChatMessage[], options?: ChatOptions): Promise<AsyncGenerator<string>>;
  countTokens(text: string): number;
}

interface ChatMessage {
  role: 'system' | 'user' | 'assistant';
  content: string;
}
```

**Providers**:

1. **ZAIEmbeddingProvider** (via Ollama)
   - Model: `embeddinggemma:latest`
   - Dimensions: 768 (Google's optimized size)
   - URL: `http://localhost:11434`
   - Batch size: 10 embeddings per request (parallelized)

2. **ZAIChatProvider**
   - Model: `glm-4.7-flashx`
   - Base URL: `https://api.z.ai/api/coding/paas/v4`
   - OpenAI-compatible API

**Implementation**:
- OpenAI SDK with custom base URL for ZAI
- Fallback chain: Ollama → ZAI
- Connection pooling for embeddings (batch of 64)

### 3.3 Context Management (`back/agents/core/context.ts`)

**Purpose**: Intelligent conversation compaction with age-based prioritization

**Key Concepts**:

```typescript
interface ConversationMessage {
  id: string;
  role: 'user' | 'assistant';
  content: string;
  timestamp: number;
  tokens: number;
  importance: number;  // 0-1, higher = less aggressive compaction
}

interface RetrievalContext {
  sourceType: 'rag' | 'fuzzy';
  sourceRef: string;  // file path, line numbers, or section title
  content: string;
  relevance: number;
  protected: boolean;  // Retrieval contexts compaction-resistent
}

interface SessionContext {
  sessionId: string;
  userId?: string;
  agentId: string;
  messages: ConversationMessage[];
  retrievalContexts: RetrievalContext[];
  totalTokens: number;
  lastCompacted: number;
}
```

**Compaction Algorithm**:

1. **Trigger**: When `totalTokens > maxContextTokens * 0.8`
2. **Strategy**: Compaction-resistant messages prioritized
3. **Protection**:
   - Latest 20% of messages always kept
   - Retrieval contexts with `protected: true`
   - Messages with `importance > 0.8`
4. **Compaction**:
   - Target size: `maxContextTokens * 0.3` (8k chars default)
   - Older messages compressed more aggressively
   - Recent messages preserved with higher detail
5. **Preservation**:
   - Never compact agent memories
   - Always keep last 3 exchanges
   - Maintain conversation flow

**Configuration**:

```json
{
  "context": {
    "maxContextTokens": 30000,        // ~30k characters
    "compactThreshold": 0.8,            // Trigger at 80%
    "compactTargetTokens": 8000,         // Target after compaction
    "minRecentMessages": 6,              // Keep last 3 exchanges
    "ageDecayFactor": 0.95              // Older = more aggressive
  },
  "retrieval": {
    "maxContextTokens": 8000,            // Summarize to max 8k chars
    "ragWeight": 0.6,                   // RAG vs fuzzy weighting
    "maxResults": 15
  }
}
```

### 3.4 Storage (`back/agents/core/storage.ts`)

**Purpose**: LanceDB (vectors) + SQLite (metadata/sessions)

**Schema (SQLite)**:

```sql
-- Agent configurations
CREATE TABLE agents (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  config_json TEXT NOT NULL,
  created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

-- User sessions
CREATE TABLE sessions (
  session_id TEXT PRIMARY KEY,
  user_id TEXT,
  agent_id TEXT NOT NULL,
  created_at TEXT NOT NULL,
  last_active TEXT NOT NULL,
  total_tokens INTEGER DEFAULT 0,
  FOREIGN KEY (agent_id) REFERENCES agents(id)
);

-- Conversation messages
CREATE TABLE messages (
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
);

-- Retrieval contexts (protected from compaction)
CREATE TABLE retrieval_contexts (
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
);

-- Indexes for performance
CREATE INDEX idx_messages_session ON messages(session_id, timestamp DESC);
CREATE INDEX idx_messages_protected ON messages(protected, timestamp DESC);
CREATE INDEX idx_retrieval_session ON retrieval_contexts(session_id, timestamp DESC);
```

**LanceDB Schema**:

```typescript
interface KnowledgeChunk {
  id: number;
  vector: number[];  // 768D from embeddinggemma:latest
  text: string;
  sourceType: 'code' | 'doc' | 'markdown';
  sourceRef: string;  // file path
  metadata: {
    language?: string;
    section?: string;
    function?: string;
    contract?: string;
    lineRange?: [number, number];
  };
  indexedAt: string;
}
```

**Operations**:
- Batch embedding generation (10 texts per batch)
- Vector search with KNN
- Source-based updates (re-index on file change)
- Hybrid query results with metadata

### 3.5 Hybrid Search (`back/agents/search/`)

**Purpose**: Combine vector RAG + fuzzy grep for comprehensive retrieval

#### 3.5.1 Vector Search (`vector.ts`)

```typescript
async function vectorSearch(
  query: string,
  options: {
    k?: number;              // Default: 10
    sourceTypes?: string[];   // Filter by 'code', 'doc', 'markdown'
    sourceRefs?: string[];    // Filter by file paths
  }
): Promise<SearchResult[]>
```

**Process**:
1. Generate embedding for query via Ollama
2. LanceDB KNN search with K=10
3. Return top results with distance scores

**SearchResult**:
```typescript
{
  content: string;
  sourceType: 'code' | 'doc' | 'markdown';
  sourceRef: string;
  metadata: {
    language?: string;
    section?: string;
    function?: string;
    contract?: string;
    lineRange?: [number, number];
  };
  score: number;  // 0-1, higher = better match
}
```

#### 3.5.2 Fuzzy Search (`fuzzy.ts`)

**Purpose**: Real-time grep-based search in knowledge folder

**Constraint**: Only search within `knowledge/` folder, NO arbitrary system commands

```typescript
async function fuzzySearch(
  query: string,
  options: {
    caseSensitive?: boolean;
    filePatterns?: string[];  // Default: ['**/*.ts', '**/*.sol', '**/*.md']
    maxResults?: number;       // Default: 20
    contextLines?: number;      // Default: 3
  }
): Promise<SearchResult[]>
```

**Process**:
1. Glob for files matching patterns in `knowledge/`
2. Read file contents
3. Use Bun's native text search (no exec)
4. Extract matches with context lines
5. Score based on term frequency and proximity

**Implementation**:
```typescript
function extractMatchesWithContext(
  content: string,
  query: string,
  contextLines: number
): SearchResult[] {
  const lines = content.split('\n');
  const matches: SearchResult[] = [];

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.toLowerCase().includes(query.toLowerCase())) {
      const start = Math.max(0, i - contextLines);
      const end = Math.min(lines.length, i + contextLines + 1);
      const context = lines.slice(start, end).join('\n');

      matches.push({
        content: context,
        sourceType: inferSourceType(path),
        sourceRef: `${filePath}:${i + 1}`,
        metadata: {
          language: inferLanguage(filePath),
          lineRange: [start + 1, end]
        },
        score: calculateScore(line, query)
      });
    }
  }

  return matches;
}
```

#### 3.5.3 Hybrid Fusion (`hybrid.ts`)

```typescript
async function hybridSearch(
  query: string,
  options: {
    ragWeight?: number;         // Default: 0.6
    fuzzyWeight?: number;       // Default: 0.4
    maxResults?: number;        // Default: 15
  }
): Promise<SearchResult[]>
```

**Fusion Algorithm**:
1. Execute vector search → `ragResults`
2. Execute fuzzy search → `fuzzyResults`
3. Score fusion: `finalScore = (ragScore * ragWeight) + (fuzzyScore * fuzzyWeight)`
4. Deduplicate by `sourceRef` + line range
5. Sort by `finalScore`
6. Return top `maxResults`

**Deduplication**:
```typescript
function deduplicateResults(
  results: SearchResult[]
): SearchResult[] {
  const seen = new Set<string>();
  const deduped: SearchResult[] = [];

  for (const result of results) {
    const key = `${result.sourceRef}:${result.metadata.lineRange?.join('-')}`;
    if (!seen.has(key)) {
      seen.add(key);
      deduped.push(result);
    }
  }

  return deduped;
}
```

### 3.6 Retrieval Summarization

**Purpose**: Compress search results to max 8k chars with relevance emphasis

**Prompt**:

```text
You are a knowledge summarizer. Your task is to condense the following search results into a concise summary that:
1. Maximizes relevance to the user's query: {query}
2. Discards any content that does NOT directly answer the question
3. Preserves source references (files, line numbers, function names)
4. Maintains the technical accuracy of the original content
5. Fits within {maxChars} characters total

Format your response as:
- Brief summary (2-3 sentences)
- Key findings with source references
- Technical details only if directly relevant

SEARCH RESULTS:
{results}

COMPACT SUMMARY:
```

**Implementation**:
```typescript
async function summarizeRetrieval(
  results: SearchResult[],
  query: string,
  maxChars: number
): Promise<string> {
  const prompt = buildSummarizationPrompt(results, query, maxChars);
  const summary = await chatProvider.chatCompletion([
    { role: 'system', content: SUMMARIZATION_SYSTEM_PROMPT },
    { role: 'user', content: prompt }
  ]);

  return summary;
}
```

---

## 4. Agent Configuration

### 4.1 Archivist Agent Definition (`back/agents/archivist/agent.md`)

```markdown
---
name: archivist
title: BTR Knowledge Archivist
icon: 📚
description: |
  Intelligent knowledge agent with hybrid RAG+fuzzy search.
  Manages project documentation and codebase comprehension.
model: glm-4.7-flashx
capabilities:
  - read_files
  - search_rag
  - search_fuzzy
  - chat
  - manage_context
knowledge_path: ./back/agents/archivist/knowledge
memories_path: ./back/agents/archivist/memories.md
config_path: ./back/agents/archivist/config.json
---

# Archivist - BTR Knowledge Archivist

You are **Archivist**, the guardian and indexer of BTR's collective knowledge.

## Your Role

You are an intelligent knowledge assistant that:
- **Learns** from BTR's documentation and codebase
- **Retrieves** relevant information through hybrid search (RAG + fuzzy)
- **Comprehends** complex DeFi and smart contract concepts
- **Guides** users through project understanding

## Core Capabilities

1. **Hybrid Search**:
   - Vector search for semantic understanding
   - Fuzzy grep for precise code/docs matches
   - Fused results with relevance scoring

2. **Context Management**:
   - Per-user session tracking
   - Intelligent conversation compaction
   - Persistent memories (never lost)

3. **Knowledge Indexing**:
   - Automatically indexes code and docs
   - Updates on file changes
   - LanceDB vector storage

## Search Behavior

When users ask about BTR:
1. Use hybrid search first (RAG + fuzzy)
2. Summarize results to max 8k chars
3. Prioritize relevant information
4. Always include source references
5. Offer follow-up queries

## Conversation Policy

- Keep conversations focused and productive
- When context grows, compact intelligently
- Never lose important information
- Protect retrieval contexts from compaction
- Maintain conversation flow

## Knowledge Domain

Your knowledge covers:
- **Smart Contracts**: `./contracts/src` (Solidity)
- **SDK/Tooling**: `./sdk/src` (TypeScript)
- **Documentation**: `./docs` (Markdown)

Be accurate, cite sources, and admit when you don't know.
```

### 4.2 Configuration (`back/agents/archivist/config.ts`)

#### Rationale for Chunking Strategy

**Based on Google's Gemini Embedding best practices** (`gemini-embedding-001`):
- Hard limit: **2,048 tokens** (~8,192 characters) per embedding
- Anything beyond this won't contribute to the embedding
- Approximation: **4 characters per token** for Gemini models

**Our Chosen Values**:

| Parameter | Value | Token Equivalent | Rationale |
|-----------|-------|------------------|------------|
| `chunkSize` | 4,000 chars | ~1,000 tokens | Middle of 800–1,200 token recommendation for prose; ensures "one topic per chunk" while staying under the 8,192 char hard limit |
| `overlap` | 500 chars | ~125 tokens | Middle of 128–256 token overlap recommendation; prevents "boundary misses" where answers span multiple chunks |
| `minChunkSize` | 500 chars | ~125 tokens | Prevents tiny fragments; ensures minimum semantic coherence |

**Content-Specific Tuning Guidelines** (for future refinement):

| Content Type | Chunk Size | Overlap | Reason |
|-------------|------------|---------|---------|
| Prose/manuals | 3,000–4,000 chars | 300–500 chars | One topic per chunk; ideal for documentation |
| API/Technical docs | 1,600–2,400 chars | 200–400 chars | Precise identifier matching; smaller chunks for exact parameter/flag queries |
| Code | 800–1,500 chars | 100–200 chars | Function-level units; retrieval lands on exact implementation rather than whole file's "average meaning" |

**Expected Corpus Size**:
- With ~20,000 characters per document average, expect **~5–7 chunks per doc** with 4,000-char chunks
- Total estimated chunks: **~600–800** for the entire corpus (docs + contracts + SDK)
- Manageable scale for vector search with good precision

**Batching**:
- Embeddings generated in batches of **10** chunks per request
- Keeps under Ollama's request limits
- Parallelized for faster processing

#### Current Configuration

```typescript
{
  agentId: 'archivist',
  name: 'BTR Knowledge Archivist',
  model: 'glm-4.7-flashx',
  embeddingModel: 'embeddinggemma:latest',
  embeddingProvider: 'ollama',
  ollamaUrl: 'http://localhost:11434',
  zaiBaseUrl: 'https://api.z.ai/api/coding/paas/v4',
  embeddingDimensions: 768,  // embeddinggemma outputs 768D vectors

  context: {
    maxContextTokens: 30000,
    compactThreshold: 0.8,
    compactTargetTokens: 8000,
    minRecentMessages: 6,
    ageDecayFactor: 0.95
  },

  retrieval: {
    maxContextTokens: 8000,
    ragWeight: 0.6,
    fuzzyWeight: 0.4,
    maxResults: 15
  },

  chunking: {
    chunkSize: 840,
    overlap: 160,
    minChunkSize: 200,
  },

  knowledge: {
    include: [
      '../../docs/**/*.md',
      '../../contracts/src/**/*.sol',
      '../../sdk/src/**/*.ts',
    ],
    exclude: [
      '**/node_modules/**',
      '**/.next/**',
      '**/dist/**',
      '**/build/**',
      '**/test*.ts',
      '**/*.test.ts',
    ]
  },

  server: {
    port: 4001,
    corsEnabled: true,
    rateLimitPerSession: 60
  }
}
```

### 4.3 Persistent Memories (`back/agents/archivist/memories.md`)

```markdown
# Archivist Persistent Memories

These memories are **never compacted** and always included in context.

## Project Structure

BTR is a decentralized exchange with:
- Smart contracts (Solidity) in `./contracts/src`
- TypeScript SDK in `./sdk/src`
- Documentation in `./docs`

## Key Concepts

- Uses Foundry for contract development
- Solidity 0.8.33 exact version required
- SDK provides TypeScript bindings
- DeFi-focused DEX protocol

## Search Strategy

Always use hybrid search: vector RAG for semantic understanding, fuzzy grep for precise matches.

## User Preferences

- Default: concise answers with source citations
- Ask follow-up questions if unclear
- Admit knowledge gaps honestly
```

---

## 5. Frontend Interface

### 5.1 Minimal Chat UI (`front/archivist.html`)

**Single-file Preact + Tailwind application**

**Features**:
- Chat-GPT style interface (minimal)
- Streaming responses
- Session management (localStorage)
- Context indicator (tokens used, compaction status)
- Source reference rendering

**HTML Structure**:

```html
<!DOCTYPE html>
<html lang="en">
<head>
  <title>BTR Archivist</title>
  <script type="module" src="./archivist.tsx"></script>
  <style>
    /* Tailwind via CDN for standalone */
    @import "tailwindcss";
  </style>
</head>
<body>
  <div id="root"></div>
</body>
</html>
```

**Component Structure**:

```typescript
function App() {
  const messages = useSignal<Message[]>([]);
  const input = useSignal('');
  const contextInfo = useSignal<ContextInfo | null>(null);

  // Chat handlers
  const sendMessage = async () => {
    const userMsg = { role: 'user', content: input.value };
    messages.value = [...messages.value, userMsg];

    // Stream response
    const stream = await fetch('/agents/archivist/chat', {
      method: 'POST',
      body: JSON.stringify({
        message: userMsg,
        sessionId: getSessionId()
      })
    });

    const reader = stream.body.getReader();
    const assistantMsg = { role: 'assistant', content: '' };
    messages.value = [...messages.value, assistantMsg];

    // Append chunks
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      assistantMsg.content += new TextDecoder().decode(value);
      messages.value = [...messages.value];  // Trigger re-render
    }
  };

  return html`
    <div class="flex flex-col h-screen bg-gray-900 text-gray-100">
      <header class="p-4 border-b border-gray-700">
        <h1 class="text-xl font-bold">📚 BTR Archivist</h1>
        <span class="text-sm text-gray-400">
          ${contextInfo.value?.tokensUsed || 0} tokens
          ${contextInfo.value?.compacted ? ' • Compacted' : ''}
        </span>
      </header>

      <div class="flex-1 overflow-y-auto p-4">
        ${messages.value.map(msg => html`
          <div class="mb-4">
            <div class="font-bold text-sm ${msg.role === 'user' ? 'text-blue-400' : 'text-green-400'}">
              ${msg.role === 'user' ? 'You' : 'Archivist'}
            </div>
            <div class="p-2 rounded ${msg.role === 'user' ? 'bg-blue-900/30' : 'bg-green-900/30'}">
              ${renderMarkdown(msg.content)}
            </div>
          </div>
        `)}
      </div>

      <footer class="p-4 border-t border-gray-700">
        <textarea
          value=${input.value}
          oninput=${(e: any) => input.value = e.target.value}
          class="w-full bg-gray-800 border border-gray-600 rounded p-2 resize-none"
          rows="3"
          placeholder="Ask about BTR..."
        />
        <button onclick=${sendMessage} class="mt-2 w-full bg-blue-600 hover:bg-blue-700 text-white py-2 rounded">
          Send
        </button>
      </footer>
    </div>
  `;
}
```

**Deployment**:
- Serve from `bun serve` or Vite dev server
- No build step required for testing
- Production: `bun build` for optimization

---

## 6. Implementation Phases

### Phase 1: Foundation (Core)

**Tasks**:
1. Set up Bun + TypeScript project structure
2. Implement `core/models.ts` (Ollama + ZAI)
3. Implement `core/storage.ts` (LanceDB + SQLite)
4. Create `core/server.ts` (HTTP/WebSocket)
5. Basic chat endpoint (no RAG yet)

**Deliverable**:
- Running server at `http://localhost:4001`
- `POST /agents/archivist/chat` returns response
- SQLite session storage working

### Phase 2: Search Engine

**Tasks**:
1. Implement `search/vector.ts` (LanceDB integration)
2. Implement `search/fuzzy.ts` (glob + text search)
3. Implement `search/hybrid.ts` (fusion algorithm)
4. Chunking + indexing pipeline
5. Retrieval summarization

**Deliverable**:
- Vector search functional with Ollama
- Fuzzy search restricted to knowledge folder
- Hybrid search with deduplication
- Knowledge indexing from docs/contracts/sdk

### Phase 3: Context Management

**Tasks**:
1. Implement `core/context.ts` (compaction algorithm)
2. Session persistence in SQLite
3. Token counting and tracking
4. Retrieval context protection
5. Agent memories integration

**Deliverable**:
- Automatic compaction at 80% threshold
- Age-based aggressive compaction
- Protected retrieval contexts
- Persistent agent memories

### Phase 4: Frontend & Integration

**Tasks**:
1. Create minimal Preact chat UI
2. WebSocket streaming integration
3. Session management (localStorage)
4. Context indicator display
5. Source reference rendering

**Deliverable**:
- Working chat interface at `front/archivist.html`
- Real-time streaming responses
- Session persistence across refreshes

### Phase 5: Testing & Polish

**Tasks**:
1. Unit tests for search algorithms
2. Integration tests for compaction
3. Load testing with concurrent sessions
4. Performance optimization
5. Documentation (README.md)

**Deliverable**:
- Test suite with >80% coverage
- Performance benchmarks
- User documentation
- Production-ready deployment

---

## 7. Configuration Management

### 7.1 Environment Variables

```bash
# ZAI Configuration
ZAI_API_KEY=your_zai_api_key_here
ZAI_BASE_URL=https://api.z.ai/api/coding/paas/v4

# Server Configuration
PORT=4001
CORS_ENABLED=true
RATE_LIMIT_PER_SESSION=60

# Storage Paths
AGENTS_DIR=./back/agents
DATA_DIR=./back/agents/.data
```

### 7.2 Configuration Files

**Global** (`back/agents/config.json`):
```json
{
  "defaultAgent": "archivist",
  "server": {
    "port": 4001,
    "corsEnabled": true
  }
}
```

**Per-Agent** (`back/agents/{agent}/config.json`):
```json
{
  "agentId": "archivist",
  "model": "glm-4.7-flashx",
  "context": { ... },
  "retrieval": { ... }
}
```

---

## 8. Security Considerations

### 8.1 Input Validation

- **No arbitrary file access**: Fuzzy search restricted to `knowledge/` folder
- **Path traversal protection**: Strip `../`, `/`, etc. from inputs
- **SQL injection prevention**: Use parameterized queries
- **Size limits**: Max 100k characters per message

### 8.2 Rate Limiting

- Per-session rate limit (default: 60 req/min)
- Global rate limit (default: 600 req/min)
- Exponential backoff for violations

### 8.3 API Keys

- Never log or expose API keys
- Environment variables only (no hardcoded values)
- Support key rotation without restart

### 8.4 File System

- Read-only access to knowledge files
- Write access restricted to `./back/agents/.data`
- No execution of arbitrary commands

---

## 9. Performance Targets

| Metric | Target | Notes |
|---------|---------|--------|
| Embedding batch latency (10x) | <1500ms | embeddinggemma optimized for speed |
| Single embedding latency | <150ms | Per text, after warmup |
| Vector search | <50ms | K=10 queries |
| Fuzzy search | <200ms | Full knowledge scan |
| Hybrid fusion | <300ms | Total retrieval time |
| Chat response time | <2s | First token |
| Compaction time | <500ms | For 30k token context |
| Indexing full corpus | <3 min | ~600-800 chunks with parallelized embedding |
| Concurrent sessions | 100+ | With proper rate limiting |

---

## 10. Future Extensibility

### 10.1 Multi-Agent Support

The foundation supports adding new agents by:

1. Creating `back/agents/{new-agent}/` directory
2. Adding `agent.md`, `memories.md`, `config.json`
3. Optional: Custom tools in `tools/` subdirectory

### 10.2 Additional Embedding Providers

Easy to add new providers by implementing `EmbeddingProvider`:

```typescript
class CustomEmbeddingProvider implements EmbeddingProvider {
  async generateEmbeddings(texts: string[]): Promise<number[][]> {
    // Custom implementation
  }
}
```

### 10.3 Additional Chat Models

Same pattern for chat providers:

```typescript
class CustomChatProvider implements ChatProvider {
  async chatCompletion(messages: ChatMessage[]): Promise<AsyncGenerator<string>> {
    // Custom streaming implementation
  }
}
```

---

## 11. Delegation Plan

### Phase 1: Foundation (han - delivery)
- Implement generic server and model abstractions
- Set up project structure
- Basic HTTP endpoints

### Phase 2: Storage & Search (scotty - backend)
- LanceDB integration
- Hybrid search algorithm
- Indexing pipeline

### Phase 3: Context Management (trinity - systems)
- Session compaction algorithm
- Token tracking
- Agent memories

### Phase 4: Frontend (edna - UX)
- Minimal Preact chat UI
- WebSocket streaming
- Session management

### Phase 5: Integration (neo - frontend)
- Polish and optimization
- Testing suite
- Documentation

---

**Version**: 1.0.0
**Last Updated**: 2025-01-16
**Status**: Draft Specification
