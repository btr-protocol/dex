#!/usr/bin/env bun

/**
 * Market Data Collector with HTTP Server
 */

import { MarketCollector } from './collector';
import { MarketDataServer } from './server';
import { config } from './config';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('collector-main');

// Port resolution: COLLECTOR_PORT > PORT > 3001
const port = parseInt(process.env.COLLECTOR_PORT || process.env.PORT || '3001');
const rpcUrl = process.env.RPC_URL || process.env.ANVIL_RPC_URL || 'http://localhost:8545';

const collector = new MarketCollector(config.tickers);
const server = new MarketDataServer(collector, port, rpcUrl);

process.on('SIGINT', async () => {
  log.info('\nShutting down...');
  await server.stop();
  await collector.stop();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  log.info('\nShutting down...');
  await server.stop();
  await collector.stop();
  process.exit(0);
});

log.info('Starting market data collector with HTTP server...');
await collector.start();
await server.start();
