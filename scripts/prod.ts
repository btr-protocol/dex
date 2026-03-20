#!/usr/bin/env bun
import { execSync } from "child_process";
import { resolve } from "path";
import { config } from "dotenv";
import { logger } from "../sdk/src/utils/logger.js";

const log = logger.withContext('prod');

const ROOT = resolve(import.meta.dir, "..");

// Load environment
config({ path: resolve(ROOT, "back/.env") });

type ServiceConfig = {
  name: string;
  image: string;
  port: number;
  envVars: string[];
  isTEI?: boolean;
};

const services: ServiceConfig[] = [
  {
    name: 'btr-collector',
    image: 'btr-collector:latest',
    port: 3001,
    envVars: ['RPC_URL', 'ANVIL_RPC_URL'],
  },
  {
    name: 'btr-agents',
    image: 'btr-agents:latest',
    port: 4001,
    envVars: [
      'JWT_SECRET',
      'HF_TOKEN',
      'OPENAI_API_KEY',
      'TEI_URL',
      'GENESIS_INVITE_CODE',
      'ADMIN_WALLETS',
      'DISCLAIMER_EXPIRY_DAYS',
    ],
  },
  {
    name: 'tei-embeddings',
    image: 'ghcr.io/huggingface/text-embeddings-inference:cpu-latest',
    port: 8080,
    envVars: ['HF_TOKEN'],
    // TEI requires special handling: model-id and local model mount
    isTEI: true,
  },
];

function dockerBuild(stage: string, image: string): void {
  log.info(`\n📦 Building ${image} from stage: ${stage}`);
  
  execSync('bun run scripts/build-docker.ts ' + stage + ' ' + image, { stdio: 'inherit', cwd: ROOT });
  
  log.info(`✅ ${image} built successfully`);
}

function dockerRun(service: ServiceConfig): void {
  log.info(`\n🚀 Starting ${service.name}...`);

  const args = ['run', '-d', '--name', service.name];

  // Add environment variables from .env
  for (const envVar of service.envVars) {
    const value = process.env[envVar];
    if (value) {
      args.push('-e', `${envVar}=${value}`);
    }
  }

  // Port mapping
  args.push('-p', `${service.port}:${service.port}`);

  // Volume for agents data (LanceDB)
  if (service.name === 'btr-agents') {
    args.push('-v', `${resolve(ROOT, 'back/agents/.data')}:/app/back/.data`);
  }

  // Volume for collector data (SQLite)
  if (service.name === 'btr-collector') {
    args.push('-v', `${resolve(ROOT, 'back/collector/.data')}:/app/data`);
  }

  // Volume for TEI local q4 model
  if (service.isTEI) {
    const teiModelDir = resolve(ROOT, 'back/services/agents/src/search/semantic/.tei-model');
    args.push('-v', `${teiModelDir}:/data`);
  }

  args.push('--restart', 'unless-stopped', service.image);

  // TEI requires model-id command
  if (service.isTEI) {
    args.push('--model-id', '/data', '--pooling', 'mean');
  }

  try {
    execSync('docker ' + args.join(' '), { stdio: 'inherit', cwd: ROOT });
    log.info(`✅ ${service.name} started on port ${service.port}`);
  } catch (e) {
    log.error(`❌ Failed to start ${service.name}`);
    throw e;
  }
}

function dockerStop(service: ServiceConfig): void {
  try {
    execSync(`docker stop ${service.name} 2>/dev/null || true`, { stdio: 'pipe' });
    execSync(`docker rm ${service.name} 2>/dev/null || true`, { stdio: 'pipe' });
    log.info(`🛑 Stopped ${service.name}`);
  } catch {
  }
}

function isContainerRunning(name: string): boolean {
  try {
    const result = execSync(`docker ps --filter name=^${name}$ --format '{{.Names}}'`, {
      encoding: 'utf8',
      stdio: 'pipe'
    });
    return result.trim() === name;
  } catch {
    return false;
  }
}

function buildFrontend(): void {
  const FRONT_DIR = resolve(ROOT, 'front');

  log.info('\n' + '═'.repeat(60));
  log.info('  BUILDING FRONTEND FOR CLOUDFLARE');
  log.info('═'.repeat(60));

  log.info('\n📚 Building search index...');
  execSync("bun run build:search-index", {
    cwd: FRONT_DIR,
    stdio: "inherit",
  });

  log.info('\n📝 Precompiling documentation...');
  execSync("bun run build:markdown", {
    cwd: FRONT_DIR,
    stdio: "inherit",
  });

  log.info('\n🏗️  Building Preact application with Vite...');
  execSync("bun run build", {
    cwd: FRONT_DIR,
    stdio: "inherit",
  });

  log.info('\n' + '═'.repeat(60));
  log.info('  FRONTEND BUILD COMPLETE');
  log.info('═'.repeat(60));
  log.info(`\n  Output directory: ${resolve(FRONT_DIR, 'dist')}`);
  log.info(`  Deploy to Cloudflare: \`wrangler pages deploy ${resolve(FRONT_DIR, 'dist')}\``);
  log.info('\n' + '═'.repeat(60) + '\n');
}

async function main() {
  const args = process.argv.slice(2);
  const command = args[0];
  
  if (command === 'build-contract') {
    log.info('\n' + '═'.repeat(60));
    log.info('  BUILDING CONTRACTS WITH FORGE');
    log.info('═'.repeat(60));

    const argsForge = ['script', 'script/DeployBSCFork.s.sol:DeployBSCFork', '--rpc-url', 'http://localhost:8545', '--broadcast', '--code-size-limit', '100000'];
    execSync('forge ' + argsForge.join(' '), { stdio: 'inherit', cwd: resolve(ROOT, 'contracts') });

    log.info('\n' + '═'.repeat(60));
    log.info('  CONTRACTS BUILT SUCCESSFULLY');
    log.info('═'.repeat(60) + '\n');

  } else if (command === 'build-back') {
    buildFrontend();

  } else if (command === 'build') {
    log.info('\n' + '═'.repeat(60));
    log.info('  BUILDING PRODUCTION IMAGES');
    log.info('═'.repeat(60));

    dockerBuild('collector-runner', 'btr-collector:latest');
    dockerBuild('agents-runner', 'btr-agents:latest');

    log.info('\n' + '═'.repeat(60));
    log.info('  ALL IMAGES BUILT SUCCESSFULLY');
    log.info('═'.repeat(60) + '\n');

  } else if (command === 'start') {
    log.info('\n' + '═'.repeat(60));
    log.info('  STARTING PRODUCTION CONTAINERS');
    log.info('═'.repeat(60));

    for (const service of services) {
      if (isContainerRunning(service.name)) {
        log.info(`⚠️  ${service.name} is already running, skipping...`);
        continue;
      }
      dockerRun(service);
    }

    log.info('\n' + '═'.repeat(60));
    log.info('  ALL CONTAINERS RUNNING');
    log.info('═'.repeat(60));
    log.info(`  Collector:   http://localhost:3001`);
    log.info(`  Agents:      http://localhost:4001`);
    log.info(`  TEI:         http://localhost:8080/embed`);
    log.info('\n' + '═'.repeat(60) + '\n');

  } else if (command === 'stop') {
    log.info('\n' + '═'.repeat(60));
    log.info('  STOPPING PRODUCTION CONTAINERS');
    log.info('═'.repeat(60) + '\n');

    for (const service of services.reverse()) {
      dockerStop(service);
    }

    log.info('\n✅ All containers stopped\n');

  } else if (command === 'restart') {
    log.info('\n' + '═'.repeat(60));
    log.info('  RESTARTING PRODUCTION CONTAINERS');
    log.info('═'.repeat(60) + '\n');

    for (const service of services.reverse()) {
      dockerStop(service);
    }

    for (const service of services) {
      dockerRun(service);
    }

    log.info('\n✅ All containers restarted\n');

  } else if (command === 'build-front') {
    buildFrontend();

  } else if (command === 'deploy') {
    log.info('\n' + '═'.repeat(60));
    log.info('  BUILDING AND DEPLOYING PRODUCTION');
    log.info('═'.repeat(60));

    dockerBuild('collector-runner', 'btr-collector:latest');
    dockerBuild('agents-runner', 'btr-agents:latest');

    for (const service of services.slice(0, 2).reverse()) {
      dockerStop(service);
    }

    for (const service of services.slice(0, 2)) {
      dockerRun(service);
    }

    log.info('\n' + '═'.repeat(60));
    log.info('  DEPLOYMENT COMPLETE');
    log.info('═'.repeat(60));
    log.info(`  Collector:   http://localhost:3001`);
    log.info(`  Agents:      http://localhost:4001`);
    log.info(`  TEI:         http://localhost:8080/embed`);
    log.info('\n' + '═'.repeat(60) + '\n');

  } else {
    log.info('\nUsage: bun scripts/prod.ts <command>');
    log.info('\nCommands:');
    log.info('  build-contract  - Build contracts with Forge');
    log.info('  build-back      - Build backend (frontend for Cloudflare)');
    log.info('  build          - Build Docker images (collector, agents)');
    log.info('  start          - Start all containers');
    log.info('  stop           - Stop all containers');
    log.info('  restart        - Restart all containers');
    log.info('  deploy         - Build and deploy all containers');
    log.info('');
  }
}

main().catch((err) => {
  log.error(`Fatal error: ${err}`);
  process.exit(1);
});
