#!/usr/bin/env bun
import { spawn, execSync, type ChildProcess } from "child_process";
import { resolve } from "path";
import { existsSync } from "fs";

const ROOT = resolve(import.meta.dir, "..");
const CONTRACTS = resolve(ROOT, "contracts");

// BSC RPC for forking
const BSC_RPC = "https://bsc-dataseed1.binance.org";

const SERVICES = [
  { name: "anvil", cwd: "contracts", port: 8545, isAnvil: true },
  { name: "front", cwd: "front", port: 3000 },
  { name: "back:collector", cwd: "back/collector", port: 3001 },
] as const;

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

// Deploy contracts to anvil
// Note: The full deployment script uses vm.warp for timelocks, which doesn't work with broadcast.
// For now, the frontend can connect but pool operations require running forge tests separately.
const deployContracts = async () => {
  console.log("\n[deploy] Contract deployment skipped (use forge test for full deployment)\n");
  console.log("[deploy] To run integration tests with pools:");
  console.log("[deploy]   cd contracts && forge test --match-path \"test/integration/BSCForkTest.t.sol\" --fork-url http://localhost:8545 -vv\n");
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

// Clear ports
console.log("Clearing ports...");
SERVICES.forEach((s) => killPort(s.port, s.name));

// Spawn all services
const children: ChildProcess[] = [];

// First spawn anvil
const anvilService = SERVICES.find((s) => s.isAnvil);
if (anvilService) {
  console.log(`\nStarting anvil (BSC fork on port ${anvilService.port})...`);

  const anvilChild = spawn(
    "anvil",
    [
      "--fork-url", BSC_RPC,
      "--port", String(anvilService.port),
      "--chain-id", "31337",
      "--block-time", "2",
      "--accounts", "10",
      "--balance", "10000",
      "--silent",  // Suppress block mining logs
    ],
    {
      cwd: resolve(ROOT, anvilService.cwd),
      stdio: ["ignore", "pipe", "pipe"],
    }
  );

  // Only log errors from anvil
  anvilChild.stderr?.on("data", (d) => process.stderr.write(prefix(anvilService.name, d)));
  children.push(anvilChild);

  // Wait for anvil and deploy
  waitForAnvil(anvilService.port).then(async (ready) => {
    if (ready) {
      console.log("[anvil] ✓ Anvil ready\n");
      await deployContracts();
      console.log("\n" + "=".repeat(60));
      console.log("DEV ENVIRONMENT READY");
      console.log("=".repeat(60));
      console.log(`\n  Anvil RPC:   http://localhost:8545 (chainId: 31337)`);
      console.log(`  Frontend:    http://localhost:3000`);
      console.log(`  Backend:     http://localhost:3001`);
      console.log(`\n  Test Account (funded with 10000 ETH + fork tokens):`);
      console.log(`  Address:     0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266`);
      console.log(`  Private Key: 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80`);
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
});

// Exit all on any exit
const exit = (code = 0) => {
  children.forEach((c) => c.kill());
  process.exit(code);
};

process.on("SIGINT", () => exit(0));
process.on("SIGTERM", () => exit(0));
children.forEach((c) => c.on("exit", (code) => exit(code ?? 1)));
