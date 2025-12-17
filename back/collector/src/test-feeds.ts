#!/usr/bin/env bun
/**
 * Test all configured feeds without historical data
 */

import ccxt from 'ccxt';
import { config } from './config';

const USDC_SOURCES = {
  'binance:spot:USDCUSDT': { weight: 0.4 },
  'bybit:spot:USDCUSDT': { weight: 0.25 },
  'okx:spot:USDC-USDT': { weight: 0.2 },
  'mexc:spot:USDCUSDT': { weight: 0.15 }
};

const exchanges: Map<string, any> = new Map();

async function getExchange(id: string): Promise<any> {
  if (exchanges.has(id)) return exchanges.get(id);

  const ExchangeClass = (ccxt as any)[id];
  if (!ExchangeClass) throw new Error(`Unknown exchange: ${id}`);

  const exchange = new ExchangeClass({ enableRateLimit: true });
  await exchange.loadMarkets();
  exchanges.set(id, exchange);
  return exchange;
}

function convertSymbol(pair: string, exchangeId: string): string {
  // Handle exchange-specific formats
  if (pair.includes('-')) {
    const [base, quote] = pair.split('-');
    return `${base}/${quote}`;
  }
  if (pair.includes('_')) {
    const [base, quote] = pair.split('_');
    return `${base}/${quote}`;
  }
  // Handle lowercase HTX symbols
  if (exchangeId === 'htx') {
    pair = pair.toUpperCase();
  }
  // Standard format
  const match = pair.match(/^(.+?)(USDT|USDC|BTC|ETH|DAI)$/);
  if (match) return `${match[1]}/${match[2]}`;
  return pair;
}

async function testSource(sourceKey: string): Promise<{ ok: boolean; price?: number; error?: string }> {
  const [exchangeId, _type, pair] = sourceKey.split(':');

  try {
    const exchange = await getExchange(exchangeId);
    const symbol = convertSymbol(pair, exchangeId);
    const ticker = await exchange.fetchTicker(symbol);
    const price = ticker.last || ticker.close;

    if (!price || price <= 0) {
      return { ok: false, error: 'Invalid price' };
    }

    return { ok: true, price };
  } catch (e: any) {
    return { ok: false, error: e.message?.substring(0, 50) || 'Unknown error' };
  }
}

async function main() {
  console.log('Testing all configured price feeds...\n');

  // Test USDC reference first
  console.log('=== USDC Reference ===');
  let usdcPrice = 1.0;
  const usdcPrices: number[] = [];
  const usdcWeights: number[] = [];

  for (const [source, cfg] of Object.entries(USDC_SOURCES)) {
    const result = await testSource(source);
    if (result.ok && result.price) {
      console.log(`  ✓ ${source}: $${result.price.toFixed(6)}`);
      usdcPrices.push(result.price);
      usdcWeights.push(cfg.weight);
    } else {
      console.log(`  ✗ ${source}: ${result.error}`);
    }
  }

  if (usdcPrices.length > 0) {
    const totalWeight = usdcWeights.reduce((a, b) => a + b, 0);
    usdcPrice = usdcPrices.reduce((sum, p, i) => sum + p * usdcWeights[i], 0) / totalWeight;
    console.log(`  → USDC/USDT rate: ${usdcPrice.toFixed(6)}\n`);
  }

  // Test all tickers
  console.log('=== Price Feeds ===');
  const results: { ticker: string; ok: boolean; priceUsdt?: number; priceUsdc?: number; failedSources: string[] }[] = [];

  for (const [tickerId, tickerConfig] of Object.entries(config.tickers)) {
    const prices: number[] = [];
    const weights: number[] = [];
    const failedSources: string[] = [];

    process.stdout.write(`\n${tickerId}:\n`);

    for (const [source, cfg] of Object.entries(tickerConfig.sources)) {
      const result = await testSource(source);
      if (result.ok && result.price) {
        console.log(`  ✓ ${source}: $${result.price.toFixed(4)}`);
        prices.push(result.price);
        weights.push(cfg.weight);
      } else {
        console.log(`  ✗ ${source}: ${result.error}`);
        failedSources.push(source);
      }
    }

    if (prices.length > 0) {
      const totalWeight = weights.reduce((a, b) => a + b, 0);
      const priceUsdt = prices.reduce((sum, p, i) => sum + p * weights[i], 0) / totalWeight;
      const priceUsdc = priceUsdt / usdcPrice;
      console.log(`  → Aggregate: $${priceUsdt.toFixed(4)} USDT / $${priceUsdc.toFixed(4)} USDC`);
      results.push({ ticker: tickerId, ok: true, priceUsdt, priceUsdc, failedSources });
    } else {
      console.log(`  → FAILED: No sources available`);
      results.push({ ticker: tickerId, ok: false, failedSources });
    }
  }

  // Summary
  console.log('\n=== Summary ===');
  const working = results.filter(r => r.ok);
  const failed = results.filter(r => !r.ok);

  console.log(`Working feeds: ${working.length}/${results.length}`);

  if (failed.length > 0) {
    console.log(`\nFailed feeds:`);
    for (const f of failed) {
      console.log(`  - ${f.ticker}`);
    }
  }

  const partialFailures = working.filter(r => r.failedSources.length > 0);
  if (partialFailures.length > 0) {
    console.log(`\nPartial failures (still working with remaining sources):`);
    for (const p of partialFailures) {
      console.log(`  - ${p.ticker}: ${p.failedSources.join(', ')}`);
    }
  }

  // Cleanup
  for (const [id, ex] of exchanges) {
    try { await ex.close(); } catch {}
  }

  process.exit(failed.length > 0 ? 1 : 0);
}

main().catch(console.error);
