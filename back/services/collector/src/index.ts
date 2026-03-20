#!/usr/bin/env bun

/**
 * Market Data Collector Entry Point
 */

import { MarketCollector } from './collector';
import { config } from './config';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('collector');

// ─────────────────────────────────────────────────────────────
// Utility: Timestamp logging
// ─────────────────────────────────────────────────────────────

function timestamp(): string {
  return new Date().toISOString().substring(11, 23); // HH:MM:SS.mmm
}

function logWithTimestamp(msg: string) {
  log.info(`[${timestamp()}] ${msg}`);
}

// ─────────────────────────────────────────────────────────────

const collector = new MarketCollector(config.tickers);

process.on('SIGINT', async () => {
  logWithTimestamp('\nShutting down...');
  await collector.stop();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  log.info('\nShutting down...');
  await collector.stop();
  process.exit(0);
});

log.info('Starting market data collector...');
await collector.start();

log.info('Collector running. Press Ctrl+C to stop.');
