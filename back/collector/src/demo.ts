#!/usr/bin/env bun

/**
 * Demo - Show live prices from all tickers
 */

import ccxt from 'ccxt';
import { config } from './config';

async function demo() {
  console.log('=== Collector Demo: Live Prices ===\n');

  const tickers = Object.keys(config.tickers);
  console.log(`Collecting prices from ${tickers.length} tickers...\n`);

  const exchanges: Record<string, any> = {};

  async function getOrCreateExchange(id: string) {
    if (exchanges[id]) return exchanges[id];
    const ExchangeClass = (ccxt as any)[id];
    if (!ExchangeClass) throw new Error(`Exchange ${id} not supported`);
    const ex = new ExchangeClass({ enableRateLimit: true, rateLimit: 200 });
    await ex.loadMarkets();
    exchanges[id] = ex;
    return ex;
  }

  function convertSymbol(pair: string, exchangeId: string): string {
    if (pair.includes('-')) return pair.replace('-', '/');
    if (pair.includes('_')) return pair.replace('_', '/');
    const match = pair.match(/^(.+?)(USDT|USDC|USDE|DAI|BTC|ETH)$/);
    if (match) return `${match[1]}/${match[2]}`;
    return pair;
  }

  const prices: Record<string, number> = {};

  // Fetch from multiple exchanges and average
  for (const tickerSymbol of tickers) {
    const tickerConfig = config.tickers[tickerSymbol as any];
    const sources = tickerConfig.sources;

    let totalWeighted = 0;
    let totalWeight = 0;

    for (const [sourceKey, sourceConfig] of Object.entries(sources)) {
      const [exchangeId, , pair] = sourceKey.split(':');

      try {
        const exchange = await getOrCreateExchange(exchangeId);
        const ccxtSymbol = convertSymbol(pair, exchangeId);
        const ticker = await exchange.fetchTicker(ccxtSymbol);
        const price = ticker.last || ticker.close;

        if (price) {
          totalWeighted += price * sourceConfig.weight;
          totalWeight += sourceConfig.weight;
        }
      } catch (error) {
        // Skip failed exchanges
      }
    }

    if (totalWeight > 0) {
      prices[tickerSymbol] = totalWeighted / totalWeight;
    }
  }

  // Close exchanges
  for (const [id, ex] of Object.entries(exchanges)) {
    try {
      await ex.close();
    } catch (e) {}
  }

  // Display results
  console.log('Live Aggregated Prices (weighted average):');
  console.log('─'.repeat(50));

  Object.entries(prices)
    .sort(([a], [b]) => a.localeCompare(b))
    .forEach(([symbol, price]) => {
      const shortName = symbol.replace('agg:spot:', '');
      const name = config.tickers[symbol as any]?.name || shortName;
      console.log(`${name.padEnd(30)} $${price.toFixed(2)}`);
    });

  console.log('─'.repeat(50));
  console.log(`\n✅ Collected ${Object.keys(prices).length}/${tickers.length} prices`);
  console.log('\nCollector is streaming prices from:');
  console.log('  • Binance, Bybit, OKX, Gate, Mexc');
  console.log('  • HTX, Bitget (for select pairs)');
  console.log('\nHistorical data cached in: ./data/collector.db');
}

try {
  await demo();
} catch (error: any) {
  console.error('❌ Error:', error.message);
  process.exit(1);
}
