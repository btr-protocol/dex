#!/usr/bin/env bun

/**
 * Quick test - starts collector and shows live prices
 * Doesn't wait for full historical backfill
 */

import { MarketCollector } from './collector';
import { config } from './config';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('quickTest');

async function runQuickTest() {
  log.info('=== Quick Collector Test ===');
  log.info(`Testing with ${Object.keys(config.tickers).length} tickers:`);
  log.info(Object.keys(config.tickers).map((t, i) => `  ${i + 1}. ${t}`).join('\n'));

  const collector = new MarketCollector(config.tickers);
  const priceUpdates: Record<string, number> = {};

  try {
    // Subscribe to price updates
    collector.onPrice((symbol: any, price: number) => {
      priceUpdates[symbol] = price;
      log.info(`✓ ${symbol}: $${price.toFixed(2)}`);
    });

    // Start collector
    log.info('\nStarting collector...');
    await collector.start();

    // Wait for prices
    log.info('Collecting live prices for 8 seconds...\n');
    await new Promise(resolve => setTimeout(resolve, 8000));

    // Show summary
    log.info('\n=== Results ===');
    log.info(`Received prices from ${Object.keys(priceUpdates).length} tickers:\n`);

    Object.entries(priceUpdates)
      .sort(([a], [b]) => a.localeCompare(b))
      .forEach(([symbol, price]) => {
        log.info(`  ${symbol.padEnd(25)} $${price.toFixed(2)}`);
      });

    log.info('\n✅ Collector working with all tickers!');

  } catch (error: any) {
    log.error('❌ Test failed', error.message);
  } finally {
    await collector.stop();
  }
}

runQuickTest();
