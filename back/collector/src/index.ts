#!/usr/bin/env bun

/**
 * Market Data Collector Entry Point
 */

import { MarketCollector } from './collector';
import { config } from './config';

// ─────────────────────────────────────────────────────────────
// Utility: Timestamp logging
// ─────────────────────────────────────────────────────────────

function timestamp(): string {
  return new Date().toISOString().substring(11, 23); // HH:MM:SS.mmm
}

function log(msg: string) {
  console.log(`[${timestamp()}] ${msg}`);
}

// ─────────────────────────────────────────────────────────────

const collector = new MarketCollector(config.tickers);

process.on('SIGINT', async () => {
  log('\nShutting down...');
  await collector.stop();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  log('\nShutting down...');
  await collector.stop();
  process.exit(0);
});

log('Starting market data collector...');
await collector.start();

log('Collector running. Press Ctrl+C to stop.');
