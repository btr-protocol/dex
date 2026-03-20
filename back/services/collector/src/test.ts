#!/usr/bin/env bun

/**
 * Test script for market data collector
 */

import { MarketCollector } from './collector';
import { getStorage } from './storage';
import { MarketDataServer } from './server';
import { config } from './config';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('test');

async function testCollector() {
  log.info('=== Market Data Collector Test ===\n');

  const collector = new MarketCollector(config.tickers);

  try {
    // Start collector
    log.info('1. Starting collector...');
    await collector.start();

    // Wait for initial data
    log.info('2. Waiting 3 seconds for data collection...');
    await new Promise(resolve => setTimeout(resolve, 3000));

    // Test price retrieval
    log.info('3. Testing price retrieval:');
    for (const symbol of Object.keys(config.tickers)) {
      const price = collector.getLatestPrice(symbol as any);
      log.info(`   ${symbol}: ${price ? price.toFixed(2) : 'N/A'}`);
    }

    // Start HTTP server
    log.info('\n4. Starting HTTP server...');
    const server = new MarketDataServer(collector, 3000);
    await server.start();

    // Test API endpoints
    log.info('\n5. Testing API endpoints...');

    // Test price endpoint
    log.info('   Testing /api/prices...');
    const priceRes = await fetch('http://localhost:3000/api/prices?symbol=agg:spot:ETHUSDT');
    const priceData = await priceRes.json();
    log.info(`   ✓ Price response:`, priceData);

    // Test candles endpoint
    log.info('\n   Testing /api/candles...');
    const candlesRes = await fetch('http://localhost:3000/api/candles?symbol=ETHUSDT&timeframe=60&limit=10');
    const candlesData = await candlesRes.json() as any;
    log.info(`   ✓ Candles response:`, {
      symbol: candlesData.symbol,
      timeframe: candlesData.timeframe,
      count: candlesData.count,
      sample: candlesData.candles.slice(0, 2)
    });

    log.info('\n✓ Tests passed!');
    log.info('\nServer running. Press Ctrl+C to stop.');

    // Keep server running
    process.on('SIGINT', async () => {
      log.info('\nShutting down...');
      await server.stop();
      await collector.stop();
      process.exit(0);
    });

  } catch (error: any) {
    log.error('❌ Test failed:', error.message);
    log.error(error.stack);
    await collector.stop();
    process.exit(1);
  }
}

testCollector();
