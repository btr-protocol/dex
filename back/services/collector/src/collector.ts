/**
 * Market Data Collector
 * USDC-denominated price feeds using WebSocket streams
 * M1 OHLC construction, higher timeframes reconstructed on-demand
 */

import ccxt from 'ccxt';
import type { PairSymbol, AggregatedTicker, TickerConfig, OHLCCandle } from './types';
import { getStorage, OHLCStorage } from './storage';
import { STORAGE_CONFIG } from './config';
import { logger } from '@btr/sdk/utils';

const log = logger.withContext('collector');
// M1 candle state per symbol
interface CandleState {
  current: OHLCCandle | null;
}

interface PriceListener {
  (symbol: PairSymbol, price: number, priceUsdc: number, bid: number, ask: number): void;
}

// Candle completion listener
interface CandleListener {
  (pair: string, timeframe: number, candle: OHLCCandle): void;
}

// Reference USDCUSDT sources for denomination conversion
const USDC_SOURCES = {
  'binance:spot:USDCUSDT': { weight: 0.4 },
  'bybit:spot:USDCUSDT': { weight: 0.25 },
  'okx:spot:USDC-USDT': { weight: 0.2 },
  'mexc:spot:USDCUSDT': { weight: 0.15 }
};

// Per-exchange WebSocket connection tracking
interface ExchangeConnection {
  exchange: any;
  subscriptions: Map<string, { // tickerSymbol -> subscription info
    aggSymbol: PairSymbol;
    weight: number;
  }>;
  stopSignal: { stop: boolean };
  isRunning: boolean;
}

export class MarketCollector {
  private connections = new Map<string, ExchangeConnection>();
  private priceCache = new Map<PairSymbol, AggregatedTicker>();
  private latestPrices = new Map<string, { price: number; bid: number; ask: number; weight: number; timestamp: number }>();
  private m1States = new Map<PairSymbol, CandleState>(); // M1 candle state only
  private running = false;
  private ready = false;
  private priceListeners = new Set<PriceListener>();
  private candleListeners = new Set<CandleListener>();
  private usdcPrice = 1.0;

  constructor(private tickerConfigs: Record<PairSymbol, TickerConfig>) {}

  async start(): Promise<void> {
    this.running = true;
    log.info('Market Collector starting...');

    const storage = getStorage();
    await storage.initialize();

    // Build pairs list for M1 gap filling
    const pairs = Object.entries(this.tickerConfigs).map(([symbol, config]) => ({
      pair: this.getPairFromSymbol(symbol),
      sources: config.sources
    }));

    // Fill M1 gaps from exchanges
    log.info('Filling M1 gaps...');
    try {
      await OHLCStorage.fillAll(pairs, storage);
    } catch (e) {
      log.error('Gap fill error: ' + e);
    }

    this.ready = true;
    await this.startWebSocketStreams();
  }

  private async startWebSocketStreams(): Promise<void> {
    // Group sources by exchange
    const exchangeGroups = new Map<string, Array<{
      aggSymbol: PairSymbol;
      tickerSymbol: string;
      sourceKey: string;
      weight: number;
    }>>();

    for (const [aggSymbol, config] of Object.entries(this.tickerConfigs)) {
      for (const [sourceKey, sourceConfig] of Object.entries(config.sources)) {
        const [exchangeId, _type, pair] = sourceKey.split(':');
        const tickerSymbol = this.convertToCCXTSymbol(pair, exchangeId);

        if (!exchangeGroups.has(exchangeId)) {
          exchangeGroups.set(exchangeId, []);
        }
        exchangeGroups.get(exchangeId)!.push({
          aggSymbol: aggSymbol as PairSymbol,
          tickerSymbol,
          sourceKey,
          weight: sourceConfig.weight
        });
      }
    }

    // Also add USDC sources for denomination
    for (const [sourceKey, sourceConfig] of Object.entries(USDC_SOURCES)) {
      const [exchangeId, _type, pair] = sourceKey.split(':');
      const tickerSymbol = this.convertToCCXTSymbol(pair, exchangeId);

      if (!exchangeGroups.has(exchangeId)) {
        exchangeGroups.set(exchangeId, []);
      }
      exchangeGroups.get(exchangeId)!.push({
        aggSymbol: 'agg:spot:USDCUSDT' as PairSymbol,
        tickerSymbol,
        sourceKey,
        weight: sourceConfig.weight
      });
    }

    // Start WebSocket stream for each exchange
    log.info(`Starting WebSocket streams for ${exchangeGroups.size} exchanges...`);

    for (const [exchangeId, subscriptions] of exchangeGroups) {
      this.startExchangeStream(exchangeId, subscriptions).catch(err => {
        log.error(`[${exchangeId}] Stream error: ${err.message}`);
      });
    }
  }

  private async startExchangeStream(
    exchangeId: string,
    subscriptions: Array<{
      aggSymbol: PairSymbol;
      tickerSymbol: string;
      sourceKey: string;
      weight: number;
    }>
  ): Promise<void> {
    // Get exchange with WebSocket support (ccxt.pro)
    const ctor = (ccxt as any).pro?.[exchangeId] || (ccxt as any)[exchangeId];
    if (!ctor) {
      log.error(`[${exchangeId}] Exchange not found`);
      return;
    }

    const exchange = new ctor({
      enableRateLimit: true,
      rateLimit: exchangeId === 'bitget' ? 1200 : 1000
    });

    try {
      await exchange.loadMarkets();
    } catch (err: any) {
      log.error(`[${exchangeId}] Failed to load markets: ${err.message}`);
      return;
    }

    const connection: ExchangeConnection = {
      exchange,
      subscriptions: new Map(),
      stopSignal: { stop: false },
      isRunning: false
    };

    // Register subscriptions
    for (const sub of subscriptions) {
      connection.subscriptions.set(sub.tickerSymbol, {
        aggSymbol: sub.aggSymbol,
        weight: sub.weight
      });
      // Also track by sourceKey for price aggregation
      this.latestPrices.set(sub.sourceKey, { price: 0, bid: 0, ask: 0, weight: sub.weight, timestamp: 0 });
    }

    this.connections.set(exchangeId, connection);

    // Start the WebSocket monitoring loop
    this.runExchangeLoop(exchangeId, connection, subscriptions);
  }

  private async runExchangeLoop(
    exchangeId: string,
    connection: ExchangeConnection,
    subscriptions: Array<{
      aggSymbol: PairSymbol;
      tickerSymbol: string;
      sourceKey: string;
      weight: number;
    }>
  ): Promise<void> {
    connection.isRunning = true;
    const symbols = subscriptions.map(s => s.tickerSymbol);
    const sourceKeyMap = new Map(subscriptions.map(s => [s.tickerSymbol, s.sourceKey]));
    const subscriptionMap = new Map(subscriptions.map(s => [s.sourceKey, s]));

    log.info(`[${exchangeId}] Streaming ${symbols.length} symbols...`);

    // Exchange-specific: bybit has max 10 symbols per watchTickers call
    const batchSize = exchangeId === 'bybit' ? 10 : symbols.length;
    // Exchange-specific: mexc spot doesn't support watchTickers, use individual watchTicker
    const useIndividualWatch = exchangeId === 'mexc';

    while (!connection.stopSignal.stop && this.running) {
      try {
        // Use watchTickers for batch WebSocket updates (unless exchange doesn't support it)
        if (!useIndividualWatch && connection.exchange.has?.watchTickers) {
          // For bybit, batch symbols into groups of 10
          if (batchSize < symbols.length) {
            // Watch all batches in parallel
            const batches: string[][] = [];
            for (let i = 0; i < symbols.length; i += batchSize) {
              batches.push(symbols.slice(i, i + batchSize));
            }

            const results = await Promise.all(
              batches.map(batch => connection.exchange.watchTickers(batch).catch(() => ({})))
            );

            for (const tickers of results) {
              this.processTickerUpdates(tickers, sourceKeyMap, subscriptionMap);
            }
          } else {
            const tickers = await connection.exchange.watchTickers(symbols);
            this.processTickerUpdates(tickers, sourceKeyMap, subscriptionMap);
          }
        } else if (connection.exchange.has?.watchTicker) {
          // Watch individual tickers in parallel (for mexc and fallback)
          const results = await Promise.all(
            symbols.map(symbol =>
              connection.exchange.watchTicker(symbol)
                .then((ticker: any) => ({ symbol, ticker }))
                .catch(() => null)
            )
          );

          for (const result of results) {
            if (!result || !result.ticker?.last) continue;

            const sourceKey = sourceKeyMap.get(result.symbol);
            if (!sourceKey) continue;

            const existing = this.latestPrices.get(sourceKey);
            if (existing) {
              existing.price = result.ticker.last;
              existing.timestamp = result.ticker.timestamp || Date.now();
            }

            if (sourceKey.includes('USDCUSDT') || sourceKey.includes('USDC-USDT')) {
              this.updateUsdcFromSource(sourceKey, result.ticker.last);
            } else {
              const sub = subscriptionMap.get(sourceKey);
              if (sub) {
                this.updateAggregatedPrice(sub.aggSymbol);
              }
            }
          }
        } else {
          // No WebSocket support, fall back to REST polling
          log.warn(`[${exchangeId}] No WebSocket support, using REST polling`);
          await this.pollExchangeREST(exchangeId, connection, subscriptions);
          await new Promise(r => setTimeout(r, 1000));
        }
      } catch (err: any) {
        log.error(`[${exchangeId}] WebSocket error: ${err.message}`);
        await new Promise(r => setTimeout(r, 5000)); // Reconnect delay
      }
    }

    connection.isRunning = false;
  }

  private processTickerUpdates(
    tickers: Record<string, any>,
    sourceKeyMap: Map<string, string>,
    subscriptionMap: Map<string, { aggSymbol: PairSymbol; tickerSymbol: string; sourceKey: string; weight: number }>
  ): void {
    for (const [symbol, ticker] of Object.entries(tickers)) {
      if (!ticker || !ticker.last) continue;

      const sourceKey = sourceKeyMap.get(symbol);
      if (!sourceKey) continue;

      const price = ticker.last;
      const bid = ticker.bid || price;
      const ask = ticker.ask || price;
      const timestamp = ticker.timestamp || Date.now();

      // Update latest price for this source
      const existing = this.latestPrices.get(sourceKey);
      if (existing) {
        existing.price = price;
        existing.bid = bid;
        existing.ask = ask;
        existing.timestamp = timestamp;
      }

      // Check if this is a USDC source
      if (sourceKey.includes('USDCUSDT') || sourceKey.includes('USDC-USDT')) {
        this.updateUsdcFromSource(sourceKey, price);
      } else {
        // Trigger aggregated price update for the relevant symbol
        const sub = subscriptionMap.get(sourceKey);
        if (sub) {
          this.updateAggregatedPrice(sub.aggSymbol);
        }
      }
    }
  }

  private async pollExchangeREST(
    exchangeId: string,
    connection: ExchangeConnection,
    subscriptions: Array<{
      aggSymbol: PairSymbol;
      tickerSymbol: string;
      sourceKey: string;
      weight: number;
    }>
  ): Promise<void> {
    const symbols = subscriptions.map(s => s.tickerSymbol);
    const sourceKeyMap = new Map(subscriptions.map(s => [s.tickerSymbol, s.sourceKey]));
    const subscriptionMap = new Map(subscriptions.map(s => [s.sourceKey, s]));

    try {
      let tickers: Record<string, any> = {};

      if (connection.exchange.has?.fetchTickers) {
        tickers = await connection.exchange.fetchTickers(symbols);
      } else {
        // Fetch individually
        for (const symbol of symbols) {
          try {
            const ticker = await connection.exchange.fetchTicker(symbol);
            if (ticker) tickers[symbol] = ticker;
          } catch {}
        }
      }

      for (const [symbol, ticker] of Object.entries(tickers)) {
        if (!ticker?.last) continue;

        const sourceKey = sourceKeyMap.get(symbol);
        if (!sourceKey) continue;

        const existing = this.latestPrices.get(sourceKey);
        if (existing) {
          existing.price = ticker.last;
          existing.timestamp = ticker.timestamp || Date.now();
        }

        if (sourceKey.includes('USDCUSDT') || sourceKey.includes('USDC-USDT')) {
          this.updateUsdcFromSource(sourceKey, ticker.last);
        } else {
          const sub = subscriptionMap.get(sourceKey);
          if (sub) {
            this.updateAggregatedPrice(sub.aggSymbol);
          }
        }
      }
    } catch (err: any) {
      log.error(`[${exchangeId}] REST poll error: ${err.message}`);
    }
  }

  private updateUsdcFromSource(sourceKey: string, price: number): void {
    // Calculate weighted USDC price from all sources
    let totalWeight = 0;
    let weightedPrice = 0;

    for (const [key, config] of Object.entries(USDC_SOURCES)) {
      const latest = this.latestPrices.get(key);
      if (latest && latest.price > 0.9 && latest.price < 1.1) {
        totalWeight += config.weight;
        weightedPrice += latest.price * config.weight;
      }
    }

    if (totalWeight > 0) {
      this.usdcPrice = weightedPrice / totalWeight;
    }
  }

  private updateAggregatedPrice(aggSymbol: PairSymbol): void {
    const config = this.tickerConfigs[aggSymbol];
    if (!config) return;

    let totalWeight = 0;
    let weightedPrice = 0;
    let weightedBid = 0;
    let weightedAsk = 0;

    for (const [sourceKey, sourceConfig] of Object.entries(config.sources)) {
      const latest = this.latestPrices.get(sourceKey);
      if (latest && latest.price > 0 && Date.now() - latest.timestamp < 60000) { // 1 min staleness
        totalWeight += sourceConfig.weight;
        weightedPrice += latest.price * sourceConfig.weight;
        weightedBid += (latest.bid || latest.price) * sourceConfig.weight;
        weightedAsk += (latest.ask || latest.price) * sourceConfig.weight;
      }
    }

    if (totalWeight === 0) return;

    const priceUsdt = weightedPrice / totalWeight;
    const bidUsdt = weightedBid / totalWeight;
    const askUsdt = weightedAsk / totalWeight;
    const priceUsdc = priceUsdt / this.usdcPrice;
    const bidUsdc = bidUsdt / this.usdcPrice;
    const askUsdc = askUsdt / this.usdcPrice;

    // Update cache
    const aggregated: AggregatedTicker = {
      symbol: aggSymbol,
      last: {
        bid: bidUsdc,
        ask: askUsdc,
        mid: priceUsdc,
        last: priceUsdc,
        volume: 0,
        timestamp: Date.now()
      },
      sources: {}
    };
    this.priceCache.set(aggSymbol, aggregated);

    // Notify listeners with bid/ask
    for (const listener of this.priceListeners) {
      listener(aggSymbol, priceUsdt, priceUsdc, bidUsdc, askUsdc);
    }

    // Update M1 OHLC (use mid price)
    this.updateOHLC(aggSymbol, priceUsdc);
  }

  getUsdcPrice(): number {
    return this.usdcPrice;
  }

  isReady(): boolean {
    return this.ready;
  }

  onPrice(listener: PriceListener): () => void {
    this.priceListeners.add(listener);
    return () => this.priceListeners.delete(listener);
  }

  onCandle(listener: CandleListener): () => void {
    this.candleListeners.add(listener);
    return () => this.candleListeners.delete(listener);
  }

  private updateOHLC(symbol: PairSymbol, price: number): void {
    const pair = this.getPairFromSymbol(symbol);
    const now = Date.now();
    const candleStart = Math.floor(now / 60_000) * 60_000; // M1 bucket

    if (!this.m1States.has(symbol)) {
      this.m1States.set(symbol, { current: null });
    }

    const state = this.m1States.get(symbol)!;

    if (!state.current || state.current.timestamp !== candleStart) {
      // Save completed candle to storage
      if (state.current) {
        getStorage().saveCandle(pair, state.current);
        // Notify listeners
        for (const listener of this.candleListeners) {
          listener(pair, 60, state.current);
        }
      }
      // Start new candle
      state.current = { timestamp: candleStart, open: price, high: price, low: price, close: price, volume: 0 };
    } else {
      // Update current candle
      state.current.high = Math.max(state.current.high, price);
      state.current.low = Math.min(state.current.low, price);
      state.current.close = price;
    }
  }

  private convertToCCXTSymbol(pair: string, exchangeId: string): string {
    if (pair.includes('/')) return pair;
    if (pair.includes('-')) return pair.replace('-', '/');
    if (pair.includes('_')) return pair.replace('_', '/');

    const match = pair.match(/^(.+?)(USDT|USDC|USDE|DAI|BTC|ETH)$/);
    if (match) {
      return `${match[1]}/${match[2]}`;
    }

    return pair;
  }

  private getPairFromSymbol(symbol: PairSymbol): string {
    const parts = symbol.split(':');
    return parts[parts.length - 1];
  }

  getLatestPrice(symbol: PairSymbol): number | null {
    return this.priceCache.get(symbol)?.last?.mid || null;
  }

  async stop(): Promise<void> {
    log.info('Stopping Market Collector...');
    this.running = false;
    this.ready = false;

    // Flush pending M1 candles
    const storage = getStorage();
    for (const [symbol, state] of this.m1States) {
      if (state.current) {
        storage.saveCandle(this.getPairFromSymbol(symbol), state.current);
      }
    }

    // Close all WebSocket connections
    for (const [, connection] of this.connections) {
      connection.stopSignal.stop = true;
      try { await connection.exchange.close(); } catch {}
    }
    this.connections.clear();

    await storage.close();
    log.info('Market Collector stopped');
  }
}
