# Docker Deployment Guide

## Quick Start

### 1. Configure environment

```bash
# Copy environment template
cp back/.env.example back/.env

# Edit configuration
vim back/.env
```

Set required variables:
- `HF_TOKEN` - HuggingFace token (required for EmbeddingGemma model access)
- `ZAI_API_KEY` - ZAI API key (required for chat)
- `JWT_SECRET` - Secret for JWT signing

### 2. Build and run agents + collector (without TEI)

```bash
docker compose up -d
```

This starts:
- Agents service on port 4001 (lexical search only)
- Collector service on port 3001

### 3. Full stack with TEI (semantic search enabled)

Start the full stack:

```bash
docker compose --profile tei up -d
```

This starts:
- TEI service on port 8080 (downloads EmbeddingGemma-300M on first run)
- Agents service on port 4001 (with semantic search)
- Collector service on port 3001

### 4. Check service health

```bash
# Check all services
docker compose ps

# Test health endpoints
curl http://localhost:4001/health  # Agents
curl http://localhost:3001/health  # Collector
curl http://localhost:8080/health  # TEI (if running)
```

### 5. Test TEI embeddings (optional)

```bash
# Generate an embedding vector
curl http://localhost:8080/embed \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"inputs":"hello from the BTR DEX"}'

# Should return a 768-dimensional vector
```

## Services

### Agents Service

**Port**: 4001
**Image**: btr-agents:latest
**Purpose**: RAG-based chat with hybrid search (lexical + semantic)

**Endpoints**:
- `GET /health` - Health check
- `POST /api/chat` - Chat interface
- `WebSocket /ws` - Real-time chat

**Environment Variables**:
```bash
ZAI_API_KEY=         # Required for AI responses
ZAI_BASE_URL=        # Default: https://api.z.ai/api/coding/paas/v4
JWT_SECRET=          # Required for auth
TEI_URL=             # Default: http://tei:80/embed
TEI_EXTERNAL=true    # Set to false when TEI is available
```

### Collector Service

**Port**: 3001
**Image**: btr-collector:latest
**Purpose**: Market data collection and streaming

**Endpoints**:
- `GET /health` - Health check
- `GET /api/price?symbol=agg:spot:ETHUSDT` - Price data
- `GET /api/candles?symbol=ETHUSDT&timeframe=60&limit=100` - OHLCV data
- `WebSocket /ws` - Real-time price streaming

**Environment Variables**:
```bash
RPC_URL=             # Blockchain RPC endpoint
POOL_ZERO_ADDRESS=   # Pool contract address
POOL_STABLE_ADDRESS= # Pool contract address
```

### TEI Service

**Port**: 8080
**Image**: ghcr.io/huggingface/text-embeddings-inference:cpu-1.5
**Purpose**: Text embeddings for semantic search
**Model**: onnx-community/embeddinggemma-300m-ONNX (768D, SOTA quality, quantized for CPU)

**Setup Options**:

1. **Automatic download** (default): TEI downloads the model on first start
   - Set `HF_TOKEN` in `back/.env`
   - Model downloads to Docker volume (~500MB, takes 2-5 minutes)

2. **Pre-clone with git lfs** (recommended for reliability):
   ```bash
   git lfs install
   git clone https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX \
     back/services/agents/src/search/semantic/.data/embeddinggemma-300m-ONNX
   ```
   This ensures all ONNX artifacts (including `model.onnx_data` sidecar) are downloaded correctly.

**Alternative Models** (set `TEI_MODEL` in `back/.env`):
- `onnx-community/embeddinggemma-300m-ONNX` - 768D, SOTA, quantized (default)
- `BAAI/bge-base-en-v1.5` - 768D, good quality, no token required
- `sentence-transformers/all-MiniLM-L6-v2` - 384D, faster, smaller

**Required flags**: `--pooling mean` (EmbeddingGemma uses mean pooling)

**Manual Setup** (if you want to run TEI standalone for testing):

```bash
# Clone the ONNX model
git lfs install
git clone https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX ./models/embeddinggemma-300m-ONNX

# Run TEI pointing to local directory
export HF_TOKEN=your_token_here
docker run --rm -p 8080:80 \
  -v $PWD/models:/data \
  -e HF_TOKEN=$HF_TOKEN \
  ghcr.io/huggingface/text-embeddings-inference:cpu-1.5 \
  --model-id /data/embeddinggemma-300m-ONNX \
  --pooling mean

# Test the embedding API
curl http://localhost:8080/embed \
  -X POST \
  -H 'Content-Type: application/json' \
  -d '{"inputs":"test embedding"}'
```

## Building Images

### Build specific service

```bash
# Build agents
docker build -f Dockerfile.back --target agents-runner -t btr-agents:latest .

# Build collector
docker build -f Dockerfile.back --target collector-runner -t btr-collector:latest .
```

### Rebuild all services

```bash
docker compose build
```

## Troubleshooting

### TEI fails to start with "tokenizer.json not found"

This happens when ONNX models download incomplete files (LFS pointer files instead of actual artifacts). Solutions:

1. **Pre-clone with git lfs** (most reliable):
   ```bash
   git lfs install
   git clone https://huggingface.co/onnx-community/embeddinggemma-300m-ONNX \
     back/services/agents/src/search/semantic/.data/embeddinggemma-300m-ONNX
   docker compose down && docker compose --profile tei up -d
   ```

2. **Alternative models**: Try `TEI_MODEL=BAAI/bge-base-en-v1.5` (no token or git lfs needed)

3. **Check for missing files**: Ensure `model.onnx_data` sidecar file is present alongside `model.onnx`

**Note**: The dev script (`bun run dev`) automatically attempts to clone the model with git lfs if not present.

### Agents service starts but semantic search doesn't work

Check if TEI is running and healthy:
```bash
docker compose ps
docker logs dex-tei-1
curl http://localhost:8080/health
```

If TEI is not running, agents will use lexical search only (still functional).

### Collector shows "No pool addresses configured"

Set the pool addresses in your `.env` file:
```bash
POOL_ZERO_ADDRESS=0x...
POOL_STABLE_ADDRESS=0x...
RPC_URL=http://...
```

## Production Deployment

### Using pre-built images

```bash
# Tag and push to registry
docker tag btr-agents:latest your-registry.com/btr-agents:v1.0.0
docker push your-registry.com/btr-agents:v1.0.0

# Update docker-compose.yml to use registry images
```

### Environment variables

Create a `back/.env` file (do not commit):
```bash
# Copy from example
cp back/.env.example back/.env

# Edit with your values
vim back/.env
```

Required variables:
- `HF_TOKEN` - For EmbeddingGemma model access (TEI semantic search)
- `ZAI_API_KEY` - For AI chat responses
- `JWT_SECRET` - For authentication
- `RPC_URL` - For blockchain data

### Resource requirements

**Minimum**:
- CPU: 2 cores
- RAM: 4GB
- Disk: 10GB

**Recommended** (with TEI):
- CPU: 4 cores
- RAM: 8GB
- Disk: 20GB

**With GPU** (for TEI):
Use `ghcr.io/huggingface/text-embeddings-inference:latest` and add GPU support to docker-compose.

## Monitoring

### View logs

```bash
# All services
docker compose logs -f

# Specific service
docker compose logs -f agents
docker compose logs -f collector
docker compose logs -f tei
```

### Container stats

```bash
docker stats dex-agents-1 dex-collector-1 dex-tei-1
```

## Cleanup

```bash
# Stop services
docker compose down

# Stop and remove volumes
docker compose down --volumes

# Remove images
docker rmi btr-agents:latest btr-collector:latest
```
