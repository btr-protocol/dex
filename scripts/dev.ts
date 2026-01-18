#!/usr/bin/env bun
import { spawn, execSync, type ChildProcess } from "child_process";
import { resolve } from "path";
import { existsSync, mkdirSync } from "fs";
import { config } from "dotenv";

// Load .env for DEPLOYER address
const ROOT = resolve(import.meta.dir, "..");
const CONTRACTS = resolve(ROOT, "contracts");
const ANVIL_STATE_DIR = resolve(ROOT, ".anvil");
const ANVIL_STATE_FILE = resolve(ANVIL_STATE_DIR, "state.json");
const DEPLOYMENT_INFO = resolve(ROOT, "front/public/deployment.json");

// Precompile docs on every dev server start
const precompileDocs = () => {
  console.log("\n[docs] Precompiling markdown files...");
  try {
    execSync("bun run scripts/precompile-markdown.ts", {
      encoding: "utf-8",
      stdio: "pipe",
      cwd: ROOT,
    });
    console.log("[docs] ✓ Docs precompiled successfully\n");
  } catch (e: any) {
    console.error("[docs] ✗ Failed to precompile docs:", e.message);
    // Don't exit - allow dev server to start even if doc compilation fails
  }
};

// Load .env and get DEPLOYER from environment or use default
config({ path: resolve(ROOT, ".env") });
const DEPLOYER = process.env.DEPLOYER || "0x0a37aEc263CbA0aaBC09Bac56A0F2074a22E69A3";

// BSC RPC for forking
const BSC_RPC = "https://bsc-dataseed1.binance.org";

// Parse CLI flags
const RESET = process.argv.includes("--reset") || process.argv.includes("--init");

type Service = { name: string; cwd: string; port: number; isAnvil?: boolean };

const SERVICES: Service[] = [
  { name: "anvil", cwd: "contracts", port: 8545, isAnvil: true },
  { name: "front", cwd: "front", port: 3000 },
  { name: "back:collector", cwd: "back/collector", port: 3001 },
  { name: "back:agents", cwd: "back/agents", port: 4001 },
];

// Kill process on port
const killPort = (port: number, name: string) => {
  try {
    const pid = execSync(`lsof -ti:${port} 2>/dev/null`, { encoding: "utf-8" }).trim();
    if (pid) {
      execSync(`kill -9 ${pid} 2>/dev/null`);
      console.log(`✓ Killed ${name} on port ${port}`);
    }
  } catch (e) {
    // Port likely free
  }
};

// Wait for anvil to be ready
const waitForAnvil = async (port: number, maxAttempts = 30): Promise<boolean> => {
  for (let i = 0; i < maxAttempts; i++) {
    try {
      const response = await fetch(`http://localhost:${port}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ jsonrpc: "2.0", method: "eth_chainId", params: [], id: 1 }),
      });
      if (response.ok) return true;
    } catch {
      // Not ready yet
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
};

// Wait for archivist to be ready
const waitForArchivist = async (port: number, maxAttempts = 30): Promise<boolean> => {
  for (let i = 0; i < maxAttempts; i++) {
    try {
      const response = await fetch(`http://localhost:${port}/health`);
      if (response.ok) return true;
    } catch {
      // Not ready yet
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
};

// Note: Indexing is now automatic on server startup (incremental, file-digest based)

// Fund DEPLOYER account on fork (required for CREATE3 deployments)
const fundDeployer = async (port: number) => {
  try {
    // Fund from Anvil's first pre-funded account
    const fromAccount = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
    const fundAmount = 1000; // 1000 ETH

    const response = await fetch(`http://localhost:${port}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        jsonrpc: "2.0",
        method: "anvil_setBalance",
        params: [DEPLOYER, `0x${BigInt(fundAmount * 1e18).toString(16)}`],
        id: 1,
      }),
    });

    if (response.ok) {
      console.log(`[anvil] ✓ Funded DEPLOYER (${DEPLOYER}) with ${fundAmount} ETH`);
    }
  } catch (e) {
    console.error("[anvil] ✗ Failed to fund DEPLOYER:", e);
  }
};

// Deploy contracts to anvil
const deployContracts = async () => {
  // Check if deployment exists and we're not resetting
  if (!RESET && existsSync(DEPLOYMENT_INFO)) {
    try {
      const info = await Bun.file(DEPLOYMENT_INFO).json();
      if (info.pools?.poolZero && info.pools?.poolStable) {
        console.log("[deploy] ✓ Using existing deployment");
        console.log(`[deploy]   Pool Zero:   ${info.pools.poolZero}`);
        console.log(`[deploy]   Pool Stable: ${info.pools.poolStable}\n`);
        return true; // Deployment exists
      }
    } catch {
      // Invalid deployment file, proceed with deployment
    }
  }

  console.log("\n[deploy] Deploying contracts to local Anvil fork...\n");

  try {
    // Run the deployment script (DEPLOYER_PK should be set via environment variable)
    const result = execSync(
      `cd ${CONTRACTS} && forge script script/DeployBSCFork.s.sol --rpc-url http://localhost:8545 --broadcast --code-size-limit 100000`,
      { encoding: "utf-8", stdio: "pipe", env: { ...process.env } }
    );

    // Extract deployed addresses from output
    const lines = result.split("\n");
    const poolZeroMatch = lines.find(l => l.includes("Pool Zero Proxy:"));
    const poolStableMatch = lines.find(l => l.includes("Pool Stable Proxy:"));

    if (poolZeroMatch && poolStableMatch) {
      const poolZeroAddr = poolZeroMatch.match(/0x[a-fA-F0-9]{40}/)?.[0];
      const poolStableAddr = poolStableMatch.match(/0x[a-fA-F0-9]{40}/)?.[0];

      if (poolZeroAddr && poolStableAddr) {
        // Save deployment info to public directory for frontend access
        const deployInfo = {
          chainId: 31337,
          timestamp: Date.now(),
          pools: {
            poolZero: poolZeroAddr,
            poolStable: poolStableAddr,
          },
        };

        await Bun.write(DEPLOYMENT_INFO, JSON.stringify(deployInfo, null, 2));

        console.log("[deploy] ✓ Deployment successful!");
        console.log(`[deploy]   Pool Zero:   ${poolZeroAddr}`);
        console.log(`[deploy]   Pool Stable: ${poolStableAddr}`);
        console.log(`[deploy]   Saved to: ${DEPLOYMENT_INFO}\n`);
        return true; // New deployment
      }
    } else {
      console.log("[deploy] ✓ Deployment completed (check logs for details)\n");
      return true;
    }
  } catch (e: any) {
    console.error("[deploy] ✗ Deployment failed:");
    console.error(e.message);
    console.log("\n[deploy] You can run deployment manually:");
    console.log("[deploy]   cd contracts && forge script script/DeployBSCFork.s.sol --rpc-url http://localhost:8545 --broadcast --code-size-limit 100000\n");
    return false;
  }
};

// Prefix each line with fixed-width tag
const maxTagLen = Math.max(...SERVICES.map((s) => s.name.length));
const prefix = (tag: string, data: Buffer) => {
  const padded = tag.padEnd(maxTagLen);
  return data
    .toString()
    .split("\n")
    .filter(Boolean)
    .map((line) => `[${padded}] ${line}`)
    .join("\n") + "\n";
};

// Precompile docs on every dev server start
precompileDocs();

// Handle reset flag
if (RESET) {
  console.log("🔄 --reset flag detected: clearing state and redeploying...\n");
  try {
    if (existsSync(ANVIL_STATE_FILE)) {
      execSync(`rm ${ANVIL_STATE_FILE}`);
      console.log("✓ Cleared Anvil state");
    }
    if (existsSync(DEPLOYMENT_INFO)) {
      execSync(`rm ${DEPLOYMENT_INFO}`);
      console.log("✓ Cleared deployment info");
    }
  } catch (e) {
    // Ignore
  }
  console.log();
}

// Create state directory if needed
if (!existsSync(ANVIL_STATE_DIR)) {
  mkdirSync(ANVIL_STATE_DIR, { recursive: true });
}

// Clear ports
console.log("Clearing ports...");
SERVICES.forEach((s) => killPort(s.port, s.name));

// Spawn all services
const children: ChildProcess[] = [];

// First spawn anvil
const anvilService = SERVICES.find((s) => s.isAnvil);
if (anvilService) {
  const hasState = existsSync(ANVIL_STATE_FILE);
  console.log(`\nStarting anvil (BSC fork on port ${anvilService.port})${hasState ? " [resuming state]" : ""}...`);

  const anvilArgs = [
    "--fork-url", BSC_RPC,
    "--port", String(anvilService.port),
    "--chain-id", "31337",
    "--block-time", "2",
    "--accounts", "10",
    "--balance", "10000",
    "--code-size-limit", "100000",
    "--silent",
  ];

  // Load and save state (--state does both)
  if (hasState) {
    anvilArgs.push("--state", ANVIL_STATE_FILE);
  }

  const anvilChild = spawn("anvil", anvilArgs, {
    cwd: resolve(ROOT, anvilService.cwd),
    stdio: ["ignore", "pipe", "pipe"],
  });

  // Only log errors from anvil
  anvilChild.stderr?.on("data", (d) => process.stderr.write(prefix(anvilService.name, d)));
  children.push(anvilChild);

  // Wait for anvil and deploy
  waitForAnvil(anvilService.port).then(async (ready) => {
    if (ready) {
      console.log("[anvil] ✓ Anvil ready\n");

      await fundDeployer(anvilService.port);
      await deployContracts();

      console.log("\n" + "=".repeat(60));
      console.log("DEV ENVIRONMENT READY");
      console.log("=".repeat(60));
      console.log(`\n  Anvil RPC:   http://localhost:${anvilService.port} (chainId: 31337)`);
      console.log(`  State:       ${hasState ? "Resumed" : "Fresh fork"}`);
      console.log(`  Frontend:    http://localhost:3000`);
      console.log(`  Collector:   http://localhost:3001`);
      console.log(`  Archivist:   http://localhost:4001`);
      console.log(`\n  Admin/Owner Account (controls pools):`);
      console.log(`  Address:     0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`);
      console.log(`  Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`);
      console.log(`  Funded with: 10000 ETH + mock tokens (mUSDC, mUSDT, mWETH, etc.)`);
      console.log(`\n  Mock Tokens: Prefixed with 'm' (e.g., mUSDC = Mock USD Coin)`);
      console.log(`              All have public mint() function for testing`);
      console.log(`\n  Reset state: bun scripts/dev.ts --reset`);
      console.log("\n" + "=".repeat(60) + "\n");
    } else {
      console.log("[anvil] ✗ Failed to start anvil");
    }
  });
}

// Then spawn front and back
SERVICES.filter((s) => !s.isAnvil).forEach((svc) => {
  const child = spawn("bun", ["run", "dev"], {
    cwd: resolve(ROOT, svc.cwd),
    env: { ...process.env, PORT: String(svc.port) },
    stdio: ["ignore", "pipe", "pipe"],
  });

  child.stdout?.on("data", (d) => process.stdout.write(prefix(svc.name, d)));
  child.stderr?.on("data", (d) => process.stderr.write(prefix(svc.name, d)));
  children.push(child);

  // Just wait for archivist to be ready
  if (svc.name === "back:agents") {
    waitForArchivist(svc.port).then((ready) => {
      if (ready) {
        console.log("[archivist] ✓ Archivist ready (auto-indexing in background)\n");
      } else {
        console.log("[archivist] ✗ Failed to start archivist");
      }
    });
  }
});

// Exit all on any exit
const exit = (code = 0) => {
  children.forEach((c) => c.kill());
  process.exit(code);
};

process.on("SIGINT", () => exit(0));
process.on("SIGTERM", () => exit(0));
children.forEach((c) => c.on("exit", (code) => exit(code ?? 1)));
