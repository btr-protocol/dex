#!/usr/bin/env bun
import { spawn, execSync, type ChildProcess } from "child_process";
import { resolve } from "path";
import { config } from "dotenv";
import { logger } from "../sdk/src/utils/logger.js";
import { setupQ4Model } from "../back/services/agents/src/search/semantic/q4-setup.js";

const log = logger.withContext('dev');

const ROOT = resolve(import.meta.dir, "..");

// Load environment variables from back/.env
config({ path: resolve(ROOT, "back/.env") });

// Read ports from environment
const FRONTEND_PORT = parseInt(process.env.FRONTEND_PORT || '3000', 10);
const COLLECTOR_PORT = parseInt(process.env.COLLECTOR_PORT || '3001', 10);
const AGENTS_PORT = parseInt(process.env.AGENTS_PORT || '4001', 10);
const TEI_PORT = parseInt(process.env.TEI_PORT || '8080', 10);

// ============ PORT CLEANUP ============

interface PortInfo {
  service: string;
  port: number;
  pids: string[];
}

/**
 * Find processes on a given port
 */
function checkPort(port: number): string[] {
  try {
    return execSync(`lsof -ti:${port}`, { encoding: 'utf8', stdio: 'pipe' })
      .trim()
      .split('\n')
      .filter(Boolean);
  } catch {
    return [];
  }
}

/**
 * Kill all processes on a given port, returns info about what was done
 */
function killPort(service: string, port: number): PortInfo {
  const pids = checkPort(port);

  if (pids.length > 0) {
    execSync(`kill -9 ${pids.join(' ')}`, { stdio: 'pipe' });
  }

  return { service, port, pids };
}

/**
 * Clean up all ports before starting
 */
function cleanupPorts(): void {
  log.info('Checking ports...\n');

  const ports: PortInfo[] = [
    killPort('Frontend', FRONTEND_PORT),
    killPort('Collector', COLLECTOR_PORT),
    killPort('Agents', AGENTS_PORT),
    killPort('TEI', TEI_PORT),
  ];

  // Display results in a table format
  const serviceColWidth = 12;
  const portColWidth = 8;
  const statusColWidth = 20;

  console.log(`  ${'Service'.padEnd(serviceColWidth)} ${'Port'.padEnd(portColWidth)} ${'Status'.padEnd(statusColWidth)}`);
  console.log(`  ${'─'.repeat(serviceColWidth)} ${'─'.repeat(portColWidth)} ${'─'.repeat(statusColWidth)}`);

  for (const { service, port, pids } of ports) {
    const status = pids.length > 0
      ? `Killed ${pids.length} process${pids.length > 1 ? 'es' : ''} (PID${pids.length > 1 ? 's' : ''}: ${pids.join(', ')})`
      : 'Free';
    console.log(`  ${(service + ':').padEnd(serviceColWidth)} ${String(port).padEnd(portColWidth)} ${status.padEnd(statusColWidth)}`);
  }

  // Also stop any existing TEI docker container
  try {
    const containerExists = execSync('docker ps -a -q -f name=tei-embeddings', { encoding: 'utf8', stdio: 'pipe' }).trim();
    if (containerExists) {
      execSync('docker stop tei-embeddings 2>/dev/null', { stdio: 'pipe' });
      execSync('docker rm tei-embeddings 2>/dev/null', { stdio: 'pipe' });
      console.log(`  ${('Docker:').padEnd(serviceColWidth)} ${String(TEI_PORT).padEnd(portColWidth)} ${'Removed container'.padEnd(statusColWidth)}`);
    }
  } catch {
    // Container doesn't exist - that's fine
  }

  console.log('');
}

// ============ PARALLEL TASKS ============

type TaskResult = { name: string; success: boolean; message: string };
interface ServiceInfo { name: string; port: number; process: ChildProcess }

async function runTask(name: string, fn: () => Promise<void>): Promise<TaskResult> {
  try {
    await fn();
    return { name, success: true, message: '' };
  } catch (e: any) {
    return { name, success: false, message: e.message };
  }
}

// Task 1: TEI Setup (Docker container)
async function taskTEI(): Promise<void> {
  const TEI_CONTAINER = 'tei-embeddings';
  const HF_TOKEN = process.env.HF_TOKEN || '';

  const isTEIRunning = async (): Promise<boolean> => {
    try {
      const response = await fetch(`http://localhost:${TEI_PORT}/health`, {
        signal: AbortSignal.timeout(2000)
      });
      return response.ok;
    } catch {
      return false;
    }
  };

  log.info('Starting TEI (Text Embeddings Inference)...');

  const running = await isTEIRunning();
  if (running) {
    log.info(`  → Already running at http://localhost:${TEI_PORT}/embed`);
    return;
  }

  // Model directory with q4 quantized files
  // Must use cpu-latest (not cpu-1.5) due to hf-hub crate bug in older versions
  const modelsSrcDir = resolve(ROOT, 'back/services/agents/src/search/semantic/.data/models--onnx-community--embeddinggemma-300m-ONNX/snapshots/*/onnx');
  const teiModelDir = resolve(ROOT, 'back/services/agents/src/search/semantic/.tei-model');

  // Prepare TEI model directory with q4 files and symlinks
  try {
    // Create TEI model directory
    execSync(`rm -rf "${teiModelDir}" && mkdir -p "${teiModelDir}"`, { stdio: 'pipe' });

    // Copy required config files
    const snapshotDir = resolve(modelsSrcDir, '..');
    execSync(`cp "${snapshotDir}/config.json" "${teiModelDir}/"`, { stdio: 'pipe' });
    execSync(`cp "${snapshotDir}/tokenizer.json" "${teiModelDir}/"`, { stdio: 'pipe' });
    execSync(`cp "${snapshotDir}/tokenizer_config.json" "${teiModelDir}/"`, { stdio: 'pipe' });

    // Copy q4 model files and create symlinks for TEI compatibility
    execSync(`cp "${modelsSrcDir}/model_q4.onnx" "${teiModelDir}/"`, { stdio: 'pipe' });
    execSync(`cp "${modelsSrcDir}/model_q4.onnx_data" "${teiModelDir}/"`, { stdio: 'pipe' });
    execSync(`cd "${teiModelDir}" && ln -sf model_q4.onnx model.onnx`, { stdio: 'pipe' });
    execSync(`cd "${teiModelDir}" && ln -sf model_q4.onnx_data model.onnx_data`, { stdio: 'pipe' });

    log.info(`  → Q4 model prepared at ${teiModelDir}`);
  } catch (error) {
    log.error(`  → Failed to prepare model: ${error}`);
    throw new Error('TEI model preparation failed');
  }

  const dockerArgs = [
    'run', '-d',
    '--name', TEI_CONTAINER,
    '-p', `${TEI_PORT}:80`,
    // Mount TEI model directory to /data in container
    '-v', `${teiModelDir}:/data`,
  ];

  // Note: HF_TOKEN not needed for local model, but kept for future use
  if (HF_TOKEN) {
    dockerArgs.push('-e', `HF_TOKEN=${HF_TOKEN}`);
  }

  // Use cpu-latest (has newer hf-hub crate that fixes URL construction bug)
  dockerArgs.push(
    'ghcr.io/huggingface/text-embeddings-inference:cpu-latest',
    '--model-id', '/data',
    '--pooling', 'mean'
  );

  return new Promise<void>((resolve, reject) => {
    const docker = spawn('docker', dockerArgs);

    let stderrOutput = '';
    docker.stderr.on('data', (d) => {
      stderrOutput += d.toString();
    });

    docker.on('close', async (code) => {
      if (code !== 0) {
        log.error(`Docker failed with code ${code}`);
        if (stderrOutput) log.error(`stderr: ${stderrOutput}`);
        reject(new Error('Docker failed to start TEI'));
        return;
      }

      log.info('Waiting for TEI health check...');
      const maxWait = 300000;
      const pollInterval = 2000;
      const start = Date.now();

      while (Date.now() - start < maxWait) {
        try {
          const response = await fetch(`http://localhost:${TEI_PORT}/health`, {
            signal: AbortSignal.timeout(2000)
          });
          if (response.ok) {
            log.info(`TEI ready at http://localhost:${TEI_PORT}/embed`);
            resolve();
            return;
          }
        } catch {
        }
        await new Promise(r => setTimeout(r, pollInterval));
        process.stdout.write('.');
      }

      reject(new Error('TEI health check timed out'));
    });

    docker.on('error', (err) => {
      reject(new Error(`Failed to spawn docker: ${err.message}`));
    });
  });
}

// Task 2: Precompile Docs
async function taskPrecompileDocs(): Promise<void> {
  log.info('Precompiling docs...');

  execSync("bun run scripts/precompile-markdown.ts", {
    encoding: "utf-8",
    stdio: "pipe",
    cwd: ROOT,
  });

  log.info('→ Docs precompiled');
}

// Start service (spawn process, don't wait)
function startService(name: string, cwd: string, port: number, env: Record<string, string> = {}): ServiceInfo {
  const child = spawn("bun", ["run", "dev"], {
    cwd: resolve(ROOT, cwd),
    env: { ...process.env, PORT: port.toString(), ...env, SKIP_PREBUILD: '1' },
    stdio: ["ignore", "pipe", "pipe"],
  });

  const prefixLine = (data: Buffer, tag: string) => {
    return data
      .toString()
      .split("\n")
      .filter(Boolean)
      .map((line) => `[${tag}] ${line}`)
      .join("\n") + "\n";
  };

  child.stdout?.on("data", (d) => process.stdout.write(prefixLine(d, name)));
  child.stderr?.on("data", (d) => process.stderr.write(prefixLine(d, name)));

  return { name, port, process: child };
}

// ============ MAIN EXECUTION ============

/**
 * Print services table with PIDs
 */
function printServicesTable(services: ServiceInfo[], teiPort: number): void {
  const serviceColWidth = 12;
  const portColWidth = 8;
  const pidColWidth = 10;

  console.log('\n  Service      Port     PID');
  console.log(`  ${'─'.repeat(serviceColWidth)} ${'─'.repeat(portColWidth)} ${'─'.repeat(pidColWidth)}`);

  for (const { name, port, process } of services) {
    console.log(`  ${(name + ':').padEnd(serviceColWidth)} ${String(port).padEnd(portColWidth)} ${String(process.pid).padEnd(pidColWidth)}`);
  }

  // TEI runs in Docker, so we show the Docker container info instead
  try {
    const containerId = execSync('docker ps -q -f name=tei-embeddings', { encoding: 'utf8', stdio: 'pipe' }).trim();
    if (containerId) {
      console.log(`  ${('TEI:').padEnd(serviceColWidth)} ${String(teiPort).padEnd(portColWidth)} ${containerId.slice(0, 8).padEnd(pidColWidth)} (docker)`);
    }
  } catch {
    // TEI not running in Docker
  }

  console.log('');
}

async function main() {
  console.log('\n▸ Starting dev environment...\n');

  // Step 1: Clean up ports
  cleanupPorts();

  const children: ServiceInfo[] = [];

  try {
    // Step 2: Start TEI and precompile docs in parallel
    const [teiResult, docsResult] = await Promise.allSettled([
      runTask('TEI', taskTEI),
      runTask('Precompile Docs', taskPrecompileDocs),
    ]);

    if (teiResult.status === 'rejected') {
      log.warn(`TEI failed: ${teiResult.reason}`);
      log.warn('Continuing without TEI - lexical search only');
    }

    if (docsResult.status === 'rejected') {
      log.warn(`Docs precompilation failed: ${docsResult.reason}`);
    }

    // Step 3: Start all services
    log.info('Starting services...');

    children.push(
      startService('collector', 'back/services/collector', COLLECTOR_PORT),
      startService('agents', 'back/services/agents', AGENTS_PORT),
      startService('front', 'front', FRONTEND_PORT)
    );

    // Wait a moment for services to start
    await new Promise(r => setTimeout(r, 2000));

    // Print services table with PIDs
    printServicesTable(children, TEI_PORT);

    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('  ✅ Dev environment ready\n');
    console.log(`  Frontend:  http://localhost:${FRONTEND_PORT}`);
    console.log(`  Collector: http://localhost:${COLLECTOR_PORT}`);
    console.log(`  Agents:    http://localhost:${AGENTS_PORT}`);
    console.log(`  TEI:       http://localhost:${TEI_PORT}/embed`);
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n');

    // Cleanup handler
    const exit = (code = 0) => {
      log.info('Shutting down...');
      try {
        execSync(`docker stop tei-embeddings 2>/dev/null || true`, { stdio: 'pipe' });
        execSync(`docker rm tei-embeddings 2>/dev/null || true`, { stdio: 'pipe' });
      } catch {
      }
      children.forEach((c) => c.process.kill());
      process.exit(code);
    };

    process.on("SIGINT", () => exit(0));
    process.on("SIGTERM", () => exit(0));
    children.forEach((c) => c.process.on("exit", (code) => {
      if (code !== 0) {
        log.error(`Service exited with code ${code}`);
        exit(code ?? 1);
      }
    }));

  } catch (e: any) {
    console.error(`\nFailed to start: ${e.message}`);
    children.forEach((c) => c.process.kill());
    process.exit(1);
  }
}

main();
