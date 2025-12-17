/**
 * HTTP/WebSocket server for streaming market data
 * Single WebSocket connection supports multiple symbol subscriptions
 * Broadcasts both price ticks and completed candles
 */

import { MarketCollector } from './collector';
import { getStorage } from './storage';
import { resolveAlias } from './config';
import type { PairSymbol, OHLCCandle } from './types';

interface WSClient {
  send(data: any): void;
  close(): void;
  subs: Set<string>; // Subscribed symbols ('*' = all)
  candleSubs: Set<string>; // Symbols subscribed for candle events
}

export class MarketDataServer {
  private server: any = null;
  private collector: MarketCollector;
  private port: number;
  private wsClients: Set<WSClient> = new Set();

  constructor(collector: MarketCollector, port: number = 3000) {
    this.collector = collector;
    this.port = port;
  }

  async start(): Promise<void> {
    const collector = this.collector;
    const wsClients = this.wsClients;

    // Notify clients when service becomes ready
    let wasReady = collector.isReady();
    setInterval(() => {
      const nowReady = collector.isReady();
      if (!wasReady && nowReady) {
        // Service just became ready - notify all connected clients
        for (const ws of wsClients) {
          try {
            ws.send(JSON.stringify({
              type: 'status',
              ready: true,
              message: 'Service ready - historical data validated'
            }));
          } catch (e) {
            wsClients.delete(ws);
          }
        }
      }
      wasReady = nowReady;
    }, 1000); // Check every second

    // Batch updates - strictly limited to 3 messages per second (333ms interval)
    const priceUpdates = new Map<string, { symbol: string; pair: string; priceUsdt: number; priceUsdc: number; bid: number; ask: number }>();

    const flushPriceUpdates = () => {
      if (priceUpdates.size === 0) return;

      // Don't send price updates if collector not ready
      if (!collector.isReady()) {
        priceUpdates.clear();
        return;
      }

      const updates = Array.from(priceUpdates.values());
      const usdcRate = collector.getUsdcPrice();

      for (const ws of wsClients) {
        try {
          // Filter to only subscribed symbols
          const subscribedUpdates = updates.filter(u =>
            ws.subs.has('*') || ws.subs.has(u.symbol) || ws.subs.has(u.pair)
          );

          if (subscribedUpdates.length > 0) {
            ws.send(JSON.stringify({
              type: 'price_batch',
              updates: subscribedUpdates.map(u => ({
                symbol: u.symbol,
                pair: u.pair,
                price: u.priceUsdc,  // mid price
                bid: u.bid,
                ask: u.ask,
                priceUsdt: u.priceUsdt,
                priceUsdc: u.priceUsdc,
              })),
              usdcRate,
              timestamp: Date.now()
            }));
          }
        } catch (e) {
          wsClients.delete(ws);
        }
      }

      priceUpdates.clear();
    };

    // Fixed interval flush - exactly 3 times per second (333ms)
    setInterval(flushPriceUpdates, 333);

    // Subscribe to price updates - just accumulate, interval handles flushing
    collector.onPrice((symbol: PairSymbol, priceUsdt: number, priceUsdc: number, bid: number, ask: number) => {
      const pair = symbol.split(':').pop() || symbol;
      priceUpdates.set(symbol, { symbol, pair, priceUsdt, priceUsdc, bid, ask });
    });

    // Subscribe to candle completion events - broadcast completed candles
    collector.onCandle((pair: string, timeframe: number, candle: OHLCCandle) => {
      // Don't broadcast candles if collector not ready
      if (!collector.isReady()) return;

      const message = JSON.stringify({
        type: 'candle',
        pair,
        timeframe,
        candle: {
          timestamp: candle.timestamp,
          open: candle.open,
          high: candle.high,
          low: candle.low,
          close: candle.close,
          volume: candle.volume
        }
      });

      for (const ws of wsClients) {
        try {
          // Check if client is subscribed to this pair's candles
          if (!ws.candleSubs.has('*') && !ws.candleSubs.has(pair) && !ws.candleSubs.has(`agg:spot:${pair}`)) {
            continue;
          }
          ws.send(message);
        } catch (e) {
          wsClients.delete(ws);
        }
      }
    });

    this.server = Bun.serve({
      port: this.port,
      hostname: 'localhost',
      websocket: {
        message: async (ws: WSClient, message: string | Buffer) => {
          try {
            const data = JSON.parse(message.toString());

            if (data.type === 'subscribe') {
              // Support subscribing to multiple symbols for price updates
              const symbols = Array.isArray(data.symbols) ? data.symbols : [data.symbol || '*'];
              for (const sym of symbols) {
                // Resolve aliases and subscribe to both requested and resolved
                const resolved = resolveAlias(sym);
                ws.subs.add(sym); // Keep original for client's reference
                if (resolved !== sym) {
                  ws.subs.add(resolved); // Also subscribe to resolved
                }
              }
              ws.send(JSON.stringify({ type: 'subscribed', symbols: Array.from(ws.subs) }));
            } else if (data.type === 'subscribe_candles') {
              // Subscribe to candle completion events
              const symbols = Array.isArray(data.symbols) ? data.symbols : [data.symbol || '*'];
              for (const sym of symbols) {
                // Resolve aliases and subscribe to both requested and resolved
                const resolved = resolveAlias(sym);
                ws.candleSubs.add(sym); // Keep original for client's reference
                if (resolved !== sym) {
                  ws.candleSubs.add(resolved); // Also subscribe to resolved
                }
              }
              ws.send(JSON.stringify({ type: 'subscribed_candles', symbols: Array.from(ws.candleSubs) }));
            } else if (data.type === 'unsubscribe') {
              const symbols = Array.isArray(data.symbols) ? data.symbols : [data.symbol];
              for (const sym of symbols) {
                ws.subs.delete(sym);
              }
              ws.send(JSON.stringify({ type: 'unsubscribed', symbols: Array.from(ws.subs) }));
            } else if (data.type === 'unsubscribe_candles') {
              const symbols = Array.isArray(data.symbols) ? data.symbols : [data.symbol];
              for (const sym of symbols) {
                ws.candleSubs.delete(sym);
              }
              ws.send(JSON.stringify({ type: 'unsubscribed_candles', symbols: Array.from(ws.candleSubs) }));
            } else if (data.type === 'get_candles') {
              const requestedSymbol = data.symbol;
              const resolvedSymbol = resolveAlias(requestedSymbol);
              const storage = getStorage();
              const candles = storage.getCandles(
                resolvedSymbol,
                data.timeframe || 60,
                data.limit || 100
              );

              ws.send(JSON.stringify({
                type: 'candles',
                symbol: requestedSymbol, // Return original requested symbol
                resolvedSymbol, // Show what it resolved to
                timeframe: data.timeframe || 60,
                count: candles.length,
                candles
              }));
            }
          } catch (e) {
            ws.send(JSON.stringify({ type: 'error', error: (e as any).message }));
          }
        },
        open: (ws: WSClient) => {
          ws.subs = new Set();
          ws.candleSubs = new Set();
          wsClients.add(ws);

          // Notify client if service not ready yet
          if (!collector.isReady()) {
            ws.send(JSON.stringify({
              type: 'status',
              ready: false,
              message: 'Service warming up - validating historical data'
            }));
          } else {
            ws.send(JSON.stringify({
              type: 'status',
              ready: true,
              message: 'Service ready'
            }));
          }
        },
        close: (ws: WSClient) => {
          wsClients.delete(ws);
        }
      },
      async fetch(req: Request, bunServer: any) {
        const url = new URL(req.url);

        // CORS headers
        const corsHeaders = {
          'Access-Control-Allow-Origin': '*',
          'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
          'Access-Control-Allow-Headers': 'Content-Type',
        };

        // Handle CORS preflight
        if (req.method === 'OPTIONS') {
          return new Response(null, { headers: corsHeaders });
        }

        // WebSocket upgrade
        if (url.pathname === '/ws') {
          return bunServer.upgrade(req);
        }

        // REST API - Get current price (USDC-denominated)
        if (url.pathname === '/api/price') {
          // Check if collector is ready
          if (!collector.isReady()) {
            return new Response(
              JSON.stringify({
                error: 'Service warming up - historical data being validated',
                ready: false
              }),
              { status: 503, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }

          const requestedSymbol = url.searchParams.get('symbol') || 'agg:spot:ETHUSDT';
          const resolvedSymbol = resolveAlias(requestedSymbol) as PairSymbol;
          const price = collector.getLatestPrice(resolvedSymbol);
          const usdcRate = collector.getUsdcPrice();

          return new Response(
            JSON.stringify({
              symbol: requestedSymbol, // Return original requested symbol
              resolvedSymbol, // Show what it resolved to
              price,           // USDC-denominated
              priceUsdt: price ? price * usdcRate : null,
              usdcRate,
              denomination: 'USDC',
              timestamp: Date.now(),
              ready: true
            }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // REST API - Get historical candles (USDC-denominated)
        if (url.pathname === '/api/candles') {
          // Check if collector is ready
          if (!collector.isReady()) {
            return new Response(
              JSON.stringify({
                error: 'Service warming up - historical data being validated',
                ready: false
              }),
              { status: 503, headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }

          const requestedSymbol = url.searchParams.get('symbol') || 'ETHUSDT';
          const resolvedSymbol = resolveAlias(requestedSymbol);
          const timeframe = parseInt(url.searchParams.get('timeframe') || '60');
          const limit = parseInt(url.searchParams.get('limit') || '100');

          const storage = getStorage();
          const candles = storage.getCandles(resolvedSymbol, timeframe, limit);

          return new Response(
            JSON.stringify({
              symbol: requestedSymbol,
              resolvedSymbol,
              timeframe,
              denomination: 'USDC',
              count: candles.length,
              candles,
              ready: true
            }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Health check - enhanced with ready state
        if (url.pathname === '/health') {
          const ready = collector.isReady();
          const status = ready ? 'ready' : 'warming_up';
          const statusCode = ready ? 200 : 503;

          return new Response(
            JSON.stringify({
              status,
              ready,
              message: ready ? 'Service ready' : 'Service warming up - validating historical data',
              timestamp: Date.now()
            }),
            {
              status: statusCode,
              headers: { ...corsHeaders, 'Content-Type': 'application/json' }
            }
          );
        }

        // Info
        if (url.pathname === '/' || url.pathname === '/info') {
          return new Response(
            JSON.stringify({
              server: 'Market Data Collector',
              denomination: 'USDC',
              usdcRate: collector.getUsdcPrice(),
              endpoints: {
                rest: {
                  '/api/price': 'Get current USDC-denominated price',
                  '/api/candles': 'Get historical OHLC candles (USDC-denominated)',
                  '/api/tickers': 'List all available tickers'
                },
                websocket: {
                  '/ws': 'Real-time price stream. Send: {type:"subscribe",symbols:["*"]} or {type:"subscribe",symbols:["ETHUSDT","BTCUSDT"]}'
                }
              },
              parameters: {
                symbol: 'Trading pair (e.g., ETHUSDT, agg:spot:ETHUSDT)',
                symbols: 'Array of symbols, or "*" for all',
                timeframe: 'Candle timeframe in seconds (60, 300, 900, 1800, 3600)',
                limit: 'Max candles to return (default 100)'
              }
            }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // List tickers
        if (url.pathname === '/api/tickers') {
          const tickers = Object.keys(collector['tickerConfigs'] || {});
          return new Response(
            JSON.stringify({ tickers, count: tickers.length }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        // Data freshness check - returns oldest/newest timestamps per symbol
        if (url.pathname === '/api/freshness') {
          const storage = getStorage();
          const requestedSymbol = url.searchParams.get('symbol');
          const timeframe = parseInt(url.searchParams.get('timeframe') || '60');

          if (requestedSymbol) {
            const resolvedSymbol = resolveAlias(requestedSymbol);
            const candles = storage.getCandles(resolvedSymbol, timeframe);
            return new Response(
              JSON.stringify({
                symbol: requestedSymbol,
                resolvedSymbol,
                timeframe,
                count: candles.length,
                oldest: candles[candles.length - 1]?.timestamp || null,
                newest: candles[0]?.timestamp || null
              }),
              { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
            );
          }

          // Return freshness for all tickers
          const tickers = Object.keys(collector['tickerConfigs'] || {});
          const freshness: Record<string, any> = {};
          for (const ticker of tickers) {
            const pair = ticker.split(':').pop() || ticker;
            const candles = storage.getCandles(pair, timeframe);
            freshness[pair] = {
              count: candles.length,
              newest: candles[0]?.timestamp || null,
              oldest: candles[candles.length - 1]?.timestamp || null
            };
          }
          return new Response(
            JSON.stringify({ timeframe, freshness }),
            { headers: { ...corsHeaders, 'Content-Type': 'application/json' } }
          );
        }

        return new Response('Not found', { headers: corsHeaders, status: 404 });
      }
    });

    console.log(`\nMarket data server listening on http://localhost:${this.port}`);
    console.log('\nEndpoints:');
    console.log(`  REST:      http://localhost:${this.port}/api/price?symbol=agg:spot:ETHUSDT`);
    console.log(`  REST:      http://localhost:${this.port}/api/candles?symbol=ETHUSDT&timeframe=60&limit=100`);
    console.log(`  WebSocket: ws://localhost:${this.port}/ws (single connection, multiple subscriptions)`);
    console.log(`  Info:      http://localhost:${this.port}/info`);
  }

  async stop(): Promise<void> {
    for (const ws of this.wsClients) {
      ws.close();
    }
    this.wsClients.clear();

    if (this.server) {
      this.server.stop();
    }
  }
}
