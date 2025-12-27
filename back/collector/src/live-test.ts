#!/usr/bin/env bun

/**
 * Live test - skip historical backfill, just collect prices
 */

import { MarketCollector } from './collector';
import { getStorage } from './storage';
import { config } from './config';

async function runLiveTest() {
  console.log('=== Live Price Collection Test ===\n');

  const collector = new MarketCollector(config.tickers);
  const priceUpdates: Record<string, number> = {};
  const storage = getStorage();
  let priceCount = 0;

  try {
    // Initialize storage without historical fetch
    await storage.initialize();

    console.log(`Starting with ${Object.keys(config.tickers).length} tickers\n`);

    // Subscribe to price updates
    collector.onPrice((symbol: any, price: number) => {
      priceUpdates[symbol] = price;
      priceCount++;

      const shortSymbol = symbol.replace('agg:spot:', '');
      process.stdout.write(`\r✓ Collected ${priceCount} prices from ${Object.keys(priceUpdates).length} tickers`);
    });

    // Start collector normally - start() handles historical fetch but it's needed for consistency
    console.log('Starting collector...\n');
    await collector.start();

    // Run for 10 seconds
    await new Promise(resolve => setTimeout(resolve, 10000));

    // Results
    console.log('\n\n=== Live Prices Collected ===\n');

    const sorted = Object.entries(priceUpdates)
      .map(([sym, price]) => ({
        symbol: sym.replace('agg:spot:', ''),
        price
      }))
      .sort((a, b) => a.symbol.localeCompare(b.symbol));

    if (sorted.length > 0) {
      console.log('Ticker                Price');
      console.log('─'.repeat(30));
      sorted.forEach(({ symbol, price }) => {
        console.log(`${symbol.padEnd(20)} $${price.toFixed(2)}`);
      });
      console.log('\n✅ Successfully collected prices from', sorted.length, 'tickers');
    } else {
      console.log('⚠️  No prices collected yet, collectors may still be initializing');
    }

  } catch (error: any) {
    console.error('\n❌ Error:', error.message);
  } finally {
    await collector.stop();
    await storage.close();
  }
}

runLiveTest();
