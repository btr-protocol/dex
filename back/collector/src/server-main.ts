#!/usr/bin/env bun

/**
 * Market Data Collector with HTTP Server
 */

import { MarketCollector } from './collector';
import { MarketDataServer } from './server';
import { config } from './config';

const port = parseInt(process.env.PORT || '3000');

const collector = new MarketCollector(config.tickers);
const server = new MarketDataServer(collector, port);

process.on('SIGINT', async () => {
  console.log('\nShutting down...');
  await server.stop();
  await collector.stop();
  process.exit(0);
});

process.on('SIGTERM', async () => {
  console.log('\nShutting down...');
  await server.stop();
  await collector.stop();
  process.exit(0);
});

console.log('Starting market data collector with HTTP server...');
await collector.start();
await server.start();
