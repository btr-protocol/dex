import { spawn, execSync } from 'node:child_process';
import { embeddingConfig } from './config.js';
import { logger } from '@btr/sdk/utils';
import { resolve } from 'path';
import { setupQ4Model } from './semantic/q4-setup.js';

const log = logger.withContext('tei');

const MODEL_ID = process.env.TEI_MODEL || 'onnx-community/embeddinggemma-300m-ONNX';
const HF_TOKEN = process.env.HF_TOKEN || '';
const PORT = parseInt(process.env.TEI_PORT || '8080', 10);
const USE_GPU = process.env.TEI_GPU === 'true';
const CONTAINER_NAME = 'tei-embeddings';
const HEALTH_URL = `http://localhost:${PORT}/health`;

/**
 * Check if TEI container is running and healthy
 */
export async function isTEIRunning(): Promise<boolean> {
  try {
    const response = await fetch(HEALTH_URL, {
      signal: AbortSignal.timeout(2000)
    });
    return response.ok;
  } catch {
    return false;
  }
}

/**
 * Check if the TEI Docker container exists (running or stopped)
 */
function containerExists(): boolean {
  try {
    const result = execSync(`docker ps -a --filter name=^${CONTAINER_NAME}$ --format '{{.Names}}'`, {
      encoding: 'utf8',
      stdio: 'pipe'
    });
    return result.trim() === CONTAINER_NAME;
  } catch {
    return false;
  }
}

/**
 * Check if the TEI container is stopped (exists but not running)
 */
function containerStopped(): boolean {
  try {
    const result = execSync(`docker ps --filter name=^${CONTAINER_NAME}$ --format '{{.Names}}'`, {
      encoding: 'utf8',
      stdio: 'pipe'
    });
    return result.trim() !== CONTAINER_NAME && containerExists();
  } catch {
    return false;
  }
}

/**
 * Start the TEI Docker container
 */
async function startTEIContainer(): Promise<void> {
  log.info('🐳 Starting TEI Docker container...');
  log.info(`   Model: ${MODEL_ID}`);
  log.info(`   Port: ${PORT}`);
  log.info(`   GPU: ${USE_GPU ? 'enabled' : 'disabled (CPU mode)'}`);
  log.info(`   HF Token: ${HF_TOKEN ? 'set' : 'NOT SET (may be required for gated models)'}`);

  // If container exists but is stopped, just restart it (preserves any state)
  if (containerStopped()) {
    try {
      execSync(`docker start ${CONTAINER_NAME}`, { stdio: 'pipe' });
      log.info('   ✓ Restarted existing container');
      return;
    } catch (error) {
      log.info(`   ⚠️  Failed to restart container: ${error}`);
      // Fall through to create new container
    }
  }

  // If container is running, nothing to do
  if (await isTEIRunning()) {
    log.info('   ✅ Container already running');
    return;
  }

  // Ensure Q4 quantized model is configured (6x smaller, ~188MB vs 1.1GB)
  try {
    const q4Result = await setupQ4Model(resolve(process.cwd(), 'back/agents/search/semantic/.data'));
    if (q4Result.configured) {
      log.info(`   ✅ ${q4Result.message}`);
    }
  } catch (error) {
    log.info(`   ⚠️  Q4 setup skipped: ${error}`);
  }

  // Stop and remove existing container if present (but not running)
  if (containerExists()) {
    try {
      execSync(`docker rm ${CONTAINER_NAME} 2>/dev/null || true`, { stdio: 'pipe' });
      log.info('   ✓ Removed old container');
    } catch {
      // Ignore errors
    }
  }

  // Build docker run arguments
  const dockerArgs = [
    'run', '-d',
    '--name', CONTAINER_NAME,
    '-p', `${PORT}:80`,
    '-v', `${resolve(process.cwd(), 'back/agents/search/semantic/.data')}:/data`,
  ];

  // Add HF_TOKEN if available (required for gated models like EmbeddingGemma)
  if (HF_TOKEN) {
    dockerArgs.push('-e', `HF_TOKEN=${HF_TOKEN}`);
  }

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

  // Start the container
  return new Promise<void>((resolve, reject) => {
    const docker = spawn('docker', dockerArgs);

    let stderrOutput = '';

    docker.stderr.on('data', (data) => {
      const msg = data.toString().trim();
      if (msg) stderrOutput += msg + '\n';
    });

    docker.on('close', async (code) => {
      if (code !== 0) {
        log.info(`   ❌ Docker failed with code ${code}`);
        if (stderrOutput) log.info(`   stderr: ${stderrOutput}`);
        reject(new Error(`Docker failed to start TEI container. Check if Docker is running.`));
        return;
      }
      resolve();
    });

    docker.on('error', (err) => {
      reject(new Error(`Failed to spawn docker: ${err.message}`));
    });
  });
}

/**
 * Wait for TEI to become healthy
 */
async function waitForTEI(maxWaitMs = 300000): Promise<void> {
  const pollInterval = 2000;
  const start = Date.now();
  let dotsPrinted = 0;

  log.info('   Waiting for TEI to become healthy...');

  while (Date.now() - start < maxWaitMs) {
    try {
      const response = await fetch(HEALTH_URL, {
        signal: AbortSignal.timeout(2000)
      });
      if (response.ok) {
        // Clear the dots line
        if (dotsPrinted > 0) {
          process.stdout.write('\r' + ' '.repeat(dotsPrinted + 50) + '\r');
        }
        log.info(`   ✅ TEI ready at ${HEALTH_URL.replace('/health', '/embed')}`);
        return;
      }
    } catch {
      // Server not ready yet
    }
    await Bun.sleep(pollInterval);
    process.stdout.write('.');
    dotsPrinted++;
  }

  throw new Error(`TEI health check timed out after ${maxWaitMs / 1000}s. Check logs: docker logs ${CONTAINER_NAME}`);
}

/**
 * Ensure TEI is running. Starts it via Docker if not running.
 */
export async function ensureTEIRunning(): Promise<void> {
  log.info('═══════════════════════════════════════════════════════════════');
  log.info('  TEI (Text Embeddings Inference) CHECK');
  log.info('═══════════════════════════════════════════════════════════════');

  const running = await isTEIRunning();

  if (running) {
    log.info(`   ✅ TEI already running at ${HEALTH_URL.replace('/health', '/embed')}`);
    log.info('');
    return;
  }

  log.info(`   ⚠️  TEI not running. Starting Docker container...`);

  try {
    await startTEIContainer();
    await waitForTEI();
    log.info('');
  } catch (error) {
    log.info(`   ❌ Failed to start TEI: ${error}`);
    log.info('');
    throw error;
  }
}

/**
 * Stop the TEI Docker container (for cleanup/shutdown)
 * NB: Does not remove the container, allowing quick restart later
 */
export async function stopTEI(): Promise<void> {
  if (!containerExists()) {
    return;
  }

  try {
    execSync(`docker stop ${CONTAINER_NAME} 2>/dev/null || true`, { stdio: 'pipe' });
    log.info('   ✅ TEI container stopped (preserved for restart)');
  } catch {
    // Ignore errors
  }
}

/**
 * Completely remove the TEI container (for full reset)
 */
export async function removeTEI(): Promise<void> {
  if (!containerExists()) {
    return;
  }

  try {
    execSync(`docker stop ${CONTAINER_NAME} 2>/dev/null || true`, { stdio: 'pipe' });
    execSync(`docker rm ${CONTAINER_NAME} 2>/dev/null || true`, { stdio: 'pipe' });
    log.info('   ✅ TEI container stopped and removed');
  } catch {
    // Ignore errors
  }
}
