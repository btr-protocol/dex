#!/usr/bin/env bun
/**
 * TEI Container Test Script
 *
 * Tests both dev and prod TEI container configurations.
 * Validates that HF_TOKEN is properly passed and TEI can start.
 */

import { spawn, execSync } from "child_process";
import { resolve } from "path";
import { config } from "dotenv";
import { logger } from "../sdk/src/utils/logger.js";

const log = logger.withContext('tei-test');
const ROOT = resolve(import.meta.dir, "..");

// Load environment
config({ path: resolve(ROOT, "back/.env") });

const HF_TOKEN = process.env.HF_TOKEN || "";
const TEI_PORT = parseInt(process.env.TEI_PORT || '8080');
const TEI_MODEL = process.env.TEI_MODEL || 'onnx-community/embeddinggemma-300m-ONNX';
const modelsDir = resolve(ROOT, 'back/services/agents/src/search/semantic/.data');

async function testDevTEI(): Promise<boolean> {
  log.info('\n╔═══════════════════════════════════════════════════════════════╗');
  log.info('║         TESTING DEV TEI CONTAINER (from dev.ts)             ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝\n');

  if (!HF_TOKEN) {
    log.error('❌ HF_TOKEN not set in back/.env');
    return false;
  }

  log.info(`HF_TOKEN: ${HF_TOKEN.slice(0, 10)}...`);
  log.info(`Model: ${TEI_MODEL}`);
  log.info(`Mount: ${modelsDir} -> /root/.cache/huggingface`);

  // Clean up any existing container
  try {
    execSync('docker stop tei-embeddings 2>/dev/null || true', { stdio: 'pipe' });
    execSync('docker rm tei-embeddings 2>/dev/null || true', { stdio: 'pipe' });
  } catch {}

  const dockerArgs = [
    'run', '-d',
    '--name', 'tei-embeddings',
    '-p', `${TEI_PORT}:80`,
    '-v', `${modelsDir}:/root/.cache/huggingface`,
    '-e', `HUGGING_FACE_HUB_TOKEN=${HF_TOKEN}`,
    '-e', `HF_TOKEN=${HF_TOKEN}`,
    'ghcr.io/huggingface/text-embeddings-inference:cpu-1.5',
    '--model-id', TEI_MODEL,
    '--pooling', 'mean',
    '--max-batch-tokens', '32768',
    '--max-concurrent-requests', '128',
    '--auto-truncate'
  ];

  log.info('\n🚀 Starting TEI container...');
  log.info(`Command: docker ${dockerArgs.join(' ')}`);

  try {
    execSync('docker ' + dockerArgs.join(' '), { stdio: 'pipe' });
    log.info('✅ Container started');
  } catch (e) {
    log.error(`❌ Failed to start container: ${e}`);
    return false;
  }

  // Wait for health check
  log.info('\n⏳ Waiting for TEI health check...');

  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://localhost:${TEI_PORT}/health`, {
        signal: AbortSignal.timeout(2000)
      });
      if (res.ok) {
        log.info(`✅ TEI healthy at http://localhost:${TEI_PORT}/embed`);

        // Check logs for token
        const logs = execSync('docker logs tei-embeddings 2>&1', { encoding: 'utf8' });
        log.info('\n📋 Checking logs for authentication...');

        const hasToken = logs.includes('hf_') || logs.includes('token') || logs.includes('Token');
        const hasError = logs.toLowerCase().includes('error') || logs.toLowerCase().includes('failed');

        if (hasError) {
          log.warn('⚠️  Errors found in logs:');
          const errorLines = logs.split('\n').filter((l: string) =>
            l.toLowerCase().includes('error') || l.toLowerCase().includes('failed')
          );
          log.warn(errorLines.slice(-5).join('\n'));
        }

        // Test embedding generation
        log.info('\n🧪 Testing embedding generation...');
        const embedRes = await fetch(`http://localhost:${TEI_PORT}/embed`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ inputs: ['hello world'] })
        });

        if (embedRes.ok) {
          const json = await embedRes.json();
          const embeddings = Object.values(json as Record<string, number[]>) as number[][];
          log.info(`✅ Embedding generated: ${embeddings[0].length} dimensions`);
          log.info(`   Sample: [${embeddings[0].slice(0, 5).map(v => v.toFixed(4)).join(', ')}...]`);
          return true;
        } else {
          log.error(`❌ Embed request failed: ${embedRes.status}`);
          return false;
        }
      }
    } catch {}
    process.stdout.write('.');
    await new Promise(r => setTimeout(r, 2000));
  }

  log.error('\n❌ TEI health check timed out');
  return false;
}

async function testProdTEI(): Promise<boolean> {
  log.info('\n╔═══════════════════════════════════════════════════════════════╗');
  log.info('║         TESTING PROD TEI (docker-compose)                   ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝\n');

  // Stop the dev container
  try {
    execSync('docker stop tei-embeddings 2>/dev/null || true', { stdio: 'pipe' });
    execSync('docker rm tei-embeddings 2>/dev/null || true', { stdio: 'pipe' });
  } catch {}

  log.info('🚀 Starting TEI via docker-compose...');

  try {
    execSync('docker compose --profile tei up -d tei', { stdio: 'inherit', cwd: ROOT });
  } catch (e) {
    log.error(`❌ Failed to start docker-compose: ${e}`);
    return false;
  }

  log.info('\n⏳ Waiting for TEI health check...');

  for (let i = 0; i < 60; i++) {
    try {
      const res = await fetch(`http://localhost:${TEI_PORT}/health`, {
        signal: AbortSignal.timeout(2000)
      });
      if (res.ok) {
        log.info(`✅ TEI healthy at http://localhost:${TEI_PORT}/embed`);

        // Check logs for token
        const logs = execSync('docker compose logs tei 2>&1', { encoding: 'utf8', cwd: ROOT });
        log.info('\n📋 Checking logs for authentication...');

        const hasError = logs.toLowerCase().includes('error') || logs.toLowerCase().includes('failed');

        if (hasError) {
          log.warn('⚠️  Errors found in logs:');
          const errorLines = logs.split('\n').filter((l: string) =>
            l.toLowerCase().includes('error') || l.toLowerCase().includes('failed')
          );
          log.warn(errorLines.slice(-5).join('\n'));
        }

        // Test embedding generation
        log.info('\n🧪 Testing embedding generation...');
        const embedRes = await fetch(`http://localhost:${TEI_PORT}/embed`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ inputs: ['hello world'] })
        });

        if (embedRes.ok) {
          const json = await embedRes.json();
          const embeddings = Object.values(json as Record<string, number[]>) as number[][];
          log.info(`✅ Embedding generated: ${embeddings[0].length} dimensions`);
          log.info(`   Sample: [${embeddings[0].slice(0, 5).map(v => v.toFixed(4)).join(', ')}...]`);
          return true;
        } else {
          log.error(`❌ Embed request failed: ${embedRes.status}`);
          return false;
        }
      }
    } catch {}
    process.stdout.write('.');
    await new Promise(r => setTimeout(r, 2000));
  }

  log.error('\n❌ TEI health check timed out');
  return false;
}

async function main() {
  log.info('\n╔═══════════════════════════════════════════════════════════════╗');
  log.info('║              TEI CONTAINER TEST SUITE                         ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝');

  const devPassed = await testDevTEI();

  // Clean up dev container
  try {
    execSync('docker stop tei-embeddings 2>/dev/null || true', { stdio: 'pipe' });
    execSync('docker rm tei-embeddings 2>/dev/null || true', { stdio: 'pipe' });
  } catch {}

  const prodPassed = await testProdTEI();

  log.info('\n╔═══════════════════════════════════════════════════════════════╗');
  log.info('║                    TEST RESULTS                               ║');
  log.info('╚═══════════════════════════════════════════════════════════════╝');
  log.info(`\n  Dev TEI (dev.ts):      ${devPassed ? '✅ PASS' : '❌ FAIL'}`);
  log.info(`  Prod TEI (compose):   ${prodPassed ? '✅ PASS' : '❌ FAIL'}`);

  if (devPassed && prodPassed) {
    log.info('\n✅ All tests passed!\n');
    process.exit(0);
  } else {
    log.info('\n❌ Some tests failed!\n');
    process.exit(1);
  }
}

main().catch(err => {
  log.error(`Fatal error: ${err}`);
  process.exit(1);
});
