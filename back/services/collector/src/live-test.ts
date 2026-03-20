#!/usr/bin/env bun

/**
 * Live test - skip historical backfill, just collect prices
 */

import { MarketCollector } from './collector';
import { getStorage } from './storage';
import { config } from './config';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('liveTest');

async function runLiveTest() {
  log.info('=== Live Price Collection Test ===\n');

  const collector = new MarketCollector(config.tickers);
  const priceUpdates: Record<string, number> = {};
  const storage = getStorage();
  let priceCount = 0;

  try {
    // Initialize storage without historical fetch
    await storage.initialize();

    log.info(`Starting with ${Object.keys(config.tickers).length} tickers\n`);

    // Subscribe to price updates
    collector.onPrice((symbol: any, price: number) => {
      priceUpdates[symbol] = price;
      priceCount++;

      const shortSymbol = symbol.replace('agg:spot:', '');
      process.stdout.write(`\r✓ Collected ${priceCount} prices from ${Object.keys(priceUpdates).length} tickers`);
    });

    // Start collector normally - start() handles historical fetch but it's needed for consistency
    log.info('Starting collector...\n');
    await collector.start();

    // Run for 10 seconds
    await new Promise(resolve => setTimeout(resolve, 10000));

    // Results
    log.info('\n\n=== Live Prices Collected ===\n');

    const sorted = Object.entries(priceUpdates)
      .map(([sym, price]) => ({
        symbol: sym.replace('agg:spot:', ''),
        price
      }))
      .sort((a, b) => a.symbol.localeCompare(b.symbol));

    if (sorted.length > 0) {
      log.info('Ticker                Price');
      log.info('─'.repeat(30));
      sorted.forEach(({ symbol, price }) => {
        log.info(`${symbol.padEnd(20)} $${price.toFixed(2)}`);
      });
      log.info('\n✅ Successfully collected prices from', { count: sorted.length });
    } else {
      log.info('⚠️  No prices collected yet, collectors may still be initializing');
    }

  } catch (error: any) {
    log.error('\n❌ Error', error.message);
  } finally {
    await collector.stop();
    await storage.close();
  }
}

runLiveTest();
