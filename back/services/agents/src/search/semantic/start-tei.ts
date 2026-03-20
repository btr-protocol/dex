#!/usr/bin/env bun

import { spawn, execSync } from 'node:child_process';
import { embeddingConfig } from '../config.js';
import { logger } from '@btr/sdk/utils';
import { setupQ4Model } from './q4-setup.js';

const log = logger.withContext('start-tei');

// Use the model from shared config (defaults to onnx-community/embeddinggemma-300m-ONNX)
// This is a high-quality 768D embedding model optimized for TEI
const MODEL_ID = process.env.TEI_MODEL || embeddingConfig.model;
const PORT = parseInt(process.env.TEI_PORT || '8080', 10);
const USE_GPU = process.env.TEI_GPU === 'true';

log.info('═══════════════════════════════════════════════════════════════');
log.info('  Starting Text Embeddings Inference (TEI) Server');
log.info('═══════════════════════════════════════════════════════════════');
log.info(`  Model: ${MODEL_ID}`);
log.info(`  Port: ${PORT}`);
log.info(`  GPU: ${USE_GPU ? 'enabled' : 'disabled (CPU mode)'}`);
log.info('');

// Ensure Q4 quantized model is configured (6x smaller, ~188MB vs 1.1GB)
log.info('  Checking Q4 quantized model setup...');
try {
  const q4Result = await setupQ4Model();
  if (q4Result.configured) {
    log.info(`  ✅ ${q4Result.message}`);
  } else {
    log.info(`  ℹ️  ${q4Result.message}`);
  }
} catch (error) {
  log.info(`  ⚠️  Q4 setup skipped: ${error}`);
}
log.info('');

// Stop any existing container
try {
  execSync('docker stop tei-embeddings 2>/dev/null || true', { stdio: 'pipe' });
  execSync('docker rm tei-embeddings 2>/dev/null || true', { stdio: 'pipe' });
  log.info('  ✓ Cleaned up existing container');
} catch {
  // Ignore errors if container doesn't exist
}

const dockerArgs = [
  'run', '-d',
  '--name', 'tei-embeddings',
  '-p', `${PORT}:80`,
  '-v', `${process.cwd()}/back/agents/search/semantic/.data:/data`,
];

// Add GPU support if enabled
if (USE_GPU) {
  dockerArgs.push('--gpus', 'all');
  dockerArgs.push('ghcr.io/huggingface/text-embeddings-inference:latest');
} else {
  dockerArgs.push('ghcr.io/huggingface/text-embeddings-inference:cpu-latest');
}

// Add model configuration
// EmbeddingGemma uses 'mean' pooling with ONNX runtime (no fp16 support)
dockerArgs.push(
  '--model-id', MODEL_ID,
  '--pooling', 'mean',  // Required for EmbeddingGemma
  '--dtype', 'float32',  // EmbeddingGemma doesn't support fp16, must use float32
  '--max-batch-tokens', '32768',
  '--max-concurrent-requests', '128',
  '--auto-truncate'
);

log.info(`  Running: docker ${dockerArgs.join(' ')}`);
log.info('');

const docker = spawn('docker', dockerArgs);

let containerId = '';

docker.stdout.on('data', (data) => {
  containerId = data.toString().trim();
  log.info(`  Container ID: ${containerId.slice(0, 12)}`);
});

docker.stderr.on('data', (data) => {
  const msg = data.toString().trim();
  if (msg) log.error(`  ⚠️  ${msg}`);
});

docker.on('close', async (code) => {
  if (code !== 0) {
    log.error(`\n  ❌ Docker failed with code ${code}`);
    log.error('  Check if Docker is running and the image is available.');
    process.exit(1);
  }

  log.info('');
  log.info('  Waiting for TEI to become healthy...');

  // Wait for health check with timeout
  const maxWait = 300000; // 5 minutes (model download + loading)
  const pollInterval = 2000;
  const start = Date.now();

  while (Date.now() - start < maxWait) {
    try {
      const res = await fetch(`http://localhost:${PORT}/health`);
      if (res.ok) {
        log.info('');
        log.info('═══════════════════════════════════════════════════════════════');
        log.info(`  ✅ TEI ready at http://localhost:${PORT}`);
        log.info('     Embed endpoint: http://localhost:' + PORT + '/embed');
        log.info('═══════════════════════════════════════════════════════════════');
        process.exit(0);
      }
    } catch {
      // Server not ready yet
    }
    await Bun.sleep(pollInterval);
    process.stdout.write('.');
  }

  log.error('\n  ❌ TEI health check timed out after 2 minutes');
  log.error('  Check container logs: docker logs tei-embeddings');
  process.exit(1);
});
