# Installation Guide for BTR Agents

## Prerequisites

### 1. Install Ollama

```bash
curl -fsSL https://ollama.ai/install.sh | sh
```

### 2. Pull Google's EmbeddingGemma Model

**Important**: We use Google's `embeddinggemma:latest` (768 dimensions)

```bash
ollama pull embeddinggemma:latest
```

Verify installation:
```bash
ollama list
```

Expected output:
```
NAME                       ID              SIZE      MODIFIED
embeddinggemma:latest      abc123...    271MB    ...
```

### 3. Start Ollama Service

```bash
ollama serve
```

### 4. Get ZAI API Key

1. Visit: https://open.bigmodel.cn/
2. Sign up / Login
3. Get your API key
4. Set environment variable:

```bash
export ZAI_API_KEY=your_zai_api_key_here
```

## Quick Start

```bash
cd back/agents
bun install
cp .env.example .env
# Edit .env with your ZAI_API_KEY
bun run dev
```

Server starts at: `http://localhost:4001`

## Dependencies

- **Bun**: Native SQLite client (no better-sqlite3 needed)
- **LanceDB**: Vector database for embeddings
- **Ollama**: Local embeddings (Google's embeddinggemma, 768D)
- **ZAI GLM-4.7**: Primary reasoning model

## Configuration

See `.env.example` for all environment variables.

## Verify Setup

Test embeddings:
```bash
curl http://localhost:11434/api/embeddings -d '{
  "model": "embeddinggemma:latest",
  "prompt": "Hello world"
}' | jq '.embedding | length'
```

Expected: `768`
