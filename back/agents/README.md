# BTR Agents - AI Agent Framework

Lightweight framework for AI agents with hybrid RAG search and intelligent context management.

## Architecture

```
back/agents/
├── archivist/           # Archivist agent implementation
│   ├── agent.md        # System prompt and capabilities
│   ├── memories.md     # Persistent memories (never compacted)
│   ├── config.json     # Agent-specific configuration
│   └── knowledge/     # Files to be RAG indexed
├── core/              # Generic agent foundation
│   ├── config.ts       # Environment configuration
│   ├── models.ts       # LLM/embedding abstractions
│   ├── context.ts      # Session and context management
│   ├── storage.ts      # LanceDB + Bun SQLite persistence
│   └── types.ts       # Shared TypeScript types
└── search/            # Hybrid search implementation
    ├── vector.ts       # LanceDB vector search
    ├── fuzzy.ts       # Real-time grep-based search
    └── hybrid.ts      # RAG+fuzzy result fusion
```

## Quick Start

### Prerequisites

1. **Ollama** for local embeddings:
   ```bash
   curl -fsSL https://ollama.ai/install.sh | sh
   ollama pull embeddinggemma:latest
   ollama serve
   ```

2. **ZAI API Key** for GLM-4.7:
   ```bash
   export ZAI_API_KEY=your_zai_key_here
   ```

### Install & Run

```bash
cd back/agents
bun install
bun run dev
```

Server starts at: `http://localhost:4001`

## Agents

### Archivist (BTR Knowledge Archivist)

First agent: intelligent knowledge assistant for BTR project.

**Features**:
- Hybrid RAG+fuzzy search
- Per-user session management
- Intelligent context compaction
- Persistent agent memories

**Endpoints**:
- `POST /agents/archivist/chat` - Chat with Archivist
- `GET  /agents/archivist/sessions/{uid}` - Get session history
- `POST /agents/archivist/reindex` - Trigger knowledge reindex

## Development

### Project Structure

Each agent has:
- `agent.md` - System prompt, capabilities, tools
- `memories.md` - Persistent context (never compacted)
- `config.json` - Model, context, retrieval settings
- `knowledge/` - Files for RAG indexing

### Core Components

**Generic Foundation** (`core/`):
- **Server**: Bun HTTP/WebSocket server with routing
- **Models**: OpenAI-compatible abstractions (Ollama + ZAI)
- **Context**: Age-based conversation compaction
- **Storage**: LanceDB (vectors) + SQLite (sessions)

**Search Engine** (`search/`):
- **Vector**: LanceDB KNN search with metadata
- **Fuzzy**: Glob + text search in knowledge folder
- **Hybrid**: Fusion with deduplication

## Configuration

### Environment Variables

```bash
ZAI_API_KEY=your_zai_key_here
ZAI_BASE_URL=https://open.bigmodel.cn/api/paas/v4
OLLAMA_URL=http://localhost:11434
PORT=4001
```

### Agent Config

See `archivist/config.json` for all settings:
- Context limits and compaction thresholds
- Retrieval weights (RAG vs fuzzy)
- Chunking parameters
- Knowledge paths and filters

## Adding New Agents

1. Create directory: `back/agents/{new-agent}/`
2. Add `agent.md` with system prompt
3. Add `memories.md` with persistent knowledge
4. Add `config.json` with settings
5. (Optional) Add custom tools in `tools/` subdirectory

Server auto-registers agents from directory structure.

## Tech Stack

- **Runtime**: Bun (TypeScript-native, native SQLite)
- **Vector DB**: LanceDB
- **Embeddings**: Ollama (Google's embeddinggemma, 768D)
- **LLM**: ZAI GLM-4.7

## Performance Targets

| Metric | Target |
|---------|---------|
| Embedding latency | <100ms |
| Vector search | <50ms |
| Fuzzy search | <200ms |
| Hybrid fusion | <300ms |
| Chat response | <2s (first token) |

## License

MIT
