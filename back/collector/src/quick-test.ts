#!/usr/bin/env bun

/**
 * Quick test - starts collector and shows live prices
 * Doesn't wait for full historical backfill
 */

import { MarketCollector } from './collector';
import { config } from './config';

async function runQuickTest() {
  console.log('=== Quick Collector Test ===\n');
  console.log(`Testing with ${Object.keys(config.tickers).length} tickers:\n`);
  console.log(Object.keys(config.tickers).map((t, i) => `  ${i + 1}. ${t}`).join('\n'));

  const collector = new MarketCollector(config.tickers);
  const priceUpdates: Record<string, number> = {};

  try {
    // Subscribe to price updates
    collector.onPrice((symbol: any, price: number) => {
      priceUpdates[symbol] = price;
      console.log(`✓ ${symbol}: $${price.toFixed(2)}`);
    });

    // Start collector
    console.log('\nStarting collector...');
    await collector.start();

    // Wait for prices
    console.log('Collecting live prices for 8 seconds...\n');
    await new Promise(resolve => setTimeout(resolve, 8000));

    // Show summary
    console.log('\n=== Results ===');
    console.log(`Received prices from ${Object.keys(priceUpdates).length} tickers:\n`);

    Object.entries(priceUpdates)
      .sort(([a], [b]) => a.localeCompare(b))
      .forEach(([symbol, price]) => {
        console.log(`  ${symbol.padEnd(25)} $${price.toFixed(2)}`);
      });

    console.log('\n✅ Collector working with all tickers!');

  } catch (error: any) {
    console.error('❌ Test failed:', error.message);
  } finally {
    await collector.stop();
  }
}

runQuickTest();
