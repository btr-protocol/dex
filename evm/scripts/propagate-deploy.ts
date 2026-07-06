#!/usr/bin/env bun
/**
 * Read dex/evm/deployments/<chainId>.deploy.json and emit env + front token patch hints.
 * Usage: bun scripts/propagate-deploy.ts [chainId=97]
 */
import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { resolve } from 'node:path';

const chainId = Number(process.argv[2] ?? 97);
const root = resolve(import.meta.dir, '..');
const deployPath = resolve(root, 'deployments', `${chainId}.deploy.json`);

if (!existsSync(deployPath)) {
  console.error(`missing ${deployPath}`);
  process.exit(1);
}

const d = JSON.parse(readFileSync(deployPath, 'utf8')) as Record<string, string>;

const envLines = [
  `BTR_ROUTER_ADDRESS=${d.routerProxy}`,
  `BTR_POOL_FACTORY_ADDRESS=${d.poolFactory}`,
  `BTR_ADMIN_ADDRESS=${d.admin}`,
  `BTR_ACCESS_CONTROL_ADDRESS=${d.ac}`,
  `BTR_ORACLE_ADDRESS=${d.oracle}`,
  `BTR_FAUCET_ADDRESS=${d.faucet}`,
  `VITE_ROUTER_ADDRESS=${d.routerProxy}`,
  `VITE_POOL_FACTORY_ADDRESS=${d.poolFactory}`,
  `VITE_ADMIN_ADDRESS=${d.admin}`,
  `VITE_ACCESS_CONTROL_ADDRESS=${d.ac}`,
  `VITE_ORACLE_ADDRESS=${d.oracle}`,
  `VITE_FAUCET_ADDRESS=${d.faucet}`,
];

const outEnv = resolve(root, 'deployments', `${chainId}.env`);
writeFileSync(outEnv, envLines.join('\n') + '\n');
console.log(`wrote ${outEnv}`);

const tokenSymbols = ['usdc', 'usdt', 'usd1', 'usde', 'usds', 'fdusd', 'btcb', 'eth', 'wbnb', 'cake', 'xaut'] as const;
const tokenMap = Object.fromEntries(
  tokenSymbols.filter((s) => d[s]).map((s) => [s.toUpperCase(), d[s]]),
);

const genPath = resolve(root, 'deployments', `${chainId}.tokens.json`);
writeFileSync(genPath, JSON.stringify({ chainId, pools: { stable: d.stablePool, volatile: d.volatilePool }, tokens: tokenMap, feeds: { usdcFeedId: d.usdcFeedId } }, null, 2) + '\n');
console.log(`wrote ${genPath}`);
