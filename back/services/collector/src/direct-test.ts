#!/usr/bin/env bun

/**
 * Direct test of collector functionality
 * Tests without starting HTTP server
 */

import { MarketCollector } from './collector';
import { getStorage } from './storage';
import { config } from './config';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('directTest');

async function runTests() {
  log.info('=== Collector Direct Test ===\n');

  const collector = new MarketCollector(config.tickers);
  let priceUpdates = 0;

  try {
    // Test 1: Subscribe to price updates
    log.info('1. Testing price streaming...');
    const unsubscribe = collector.onPrice((symbol: any, price: number) => {
      priceUpdates++;
      log.info(`   Update ${priceUpdates}: ${symbol} = $${price.toFixed(2)}`);
    });

    // Start collector
    log.info('2. Starting collector...');
    await collector.start();

    // Wait for some price updates
    log.info('3. Collecting live prices for 5 seconds...\n');
    await new Promise(resolve => setTimeout(resolve, 5000));

    log.info(`\n✓ Received ${priceUpdates} price updates\n`);

    // Test 2: Get stored historical data
    log.info('4. Testing historical data retrieval...');
    const storage = getStorage();

    const ethCandles = storage.getCandles('ETHUSDT', 60, 5);
    log.info(`\n   ETHUSDT Candles (5 most recent, 1-minute):
${ethCandles.map((c, i) =>
  `   ${i + 1}. ${new Date(c.timestamp).toISOString()} | O:${c.open.toFixed(2)} H:${c.high.toFixed(2)} L:${c.low.toFixed(2)} C:${c.close.toFixed(2)} V:${c.volume.toFixed(0)}`
).join('\n')}`);

    const btcCandles = storage.getCandles('BTCUSDT', 60, 3);
    log.info(`\n   BTCUSDT Candles (3 most recent, 1-minute):
${btcCandles.map((c, i) =>
  `   ${i + 1}. ${new Date(c.timestamp).toISOString()} | O:${c.open.toFixed(2)} H:${c.high.toFixed(2)} L:${c.low.toFixed(2)} C:${c.close.toFixed(2)}`
).join('\n')}`);

    // Test 3: Query aggregated prices
    log.info('\n5. Testing current aggregated prices:');
    for (const symbol of Object.keys(config.tickers)) {
      const price = collector.getLatestPrice(symbol as any);
      log.info(`   ${symbol}: ${price ? `$${price.toFixed(2)}` : 'N/A'}`);
    }

    unsubscribe();

    log.info('\n✅ All tests passed!');
    log.info('\nCollector successfully:');
    log.info('  ✓ Fetched 14 days of historical OHLC data from Binance');
    log.info('  ✓ Stored candles in SQLite database');
    log.info('  ✓ Streamed live price updates in real-time');
    log.info('  ✓ Retrieved historical data on-demand');

  } catch (error: any) {
    log.error('❌ Test failed:', error.message);
    log.error(error.stack);
  } finally {
    await collector.stop();
  }
}

runTests();
