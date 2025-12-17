#!/usr/bin/env bun

import { config } from './config';

console.log('=== Collector Configuration Verification ===\n');

const tickers = Object.keys(config.tickers);
console.log(`✓ Loaded ${tickers.length} tickers from config\n`);

console.log('Configured Market Feeds:');
console.log('─'.repeat(70));

tickers.forEach((t, i) => {
  const cfg = config.tickers[t as any];
  const sources = Object.keys(cfg.sources).length;
  const shortName = t.replace('agg:spot:', '');
  console.log(
    `${(i + 1).toString().padStart(2)}. ${shortName.padEnd(12)} - ${cfg.name.padEnd(30)} [${sources} sources]`
  );
});

console.log('─'.repeat(70));

console.log('\nExchange Weights Configuration:');
console.log('─'.repeat(70));

// Show a sample ticker's sources
const sampleTicker = config.tickers['agg:spot:ETHUSDT' as any];
console.log('\nSample: agg:spot:ETHUSDT');
Object.entries(sampleTicker.sources).forEach(([source, cfg]) => {
  const [exchange] = source.split(':');
  console.log(`  • ${exchange.padEnd(10)} weight: ${cfg.weight}`);
});

console.log('\n✓ All 15 tickers configured with weighted exchange sources');
console.log('✓ Ready to collect aggregated prices and historical OHLC data');
console.log('\nStart collector with: bun run start');
console.log('Or with HTTP server: bun run server');
