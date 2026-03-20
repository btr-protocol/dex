import { useState, useEffect, useMemo } from 'preact/hooks';
import { withContext } from '@/lib/logger';

const log = withContext('usePriceFeed');
import { getCandleStore } from '@/lib/price/CandleStore';
import type { OHLC, PriceData } from '@/types/market';

// Re-export for backward compatibility
export type { OHLC, PriceData };

// Candle type for backend collector compatibility (different from OHLC)
export interface Candle {
  timestamp: number;
  open: number;
  high: number;
  low: number;
  close: number;
}

const API_URL = import.meta.env.VITE_COLLECTOR_API || 'http://localhost:3001';
const WS_URL = import.meta.env.VITE_COLLECTOR_WS || 'ws://localhost:3001/ws';

// Quote priority: higher index = higher priority as quote currency
const QUOTE_PRIORITY = ['ETH', 'BTC', 'USD1', 'RLUSD', 'PYUSD', 'DAI', 'USDS', 'USDE', 'USDT', 'USDC'];
const QUOTE_PRIORITY_MAP = new Map(QUOTE_PRIORITY.map((q, i) => [q, i]));

// Get canonical pair ordering (base/quote) based on priority
export function getCanonicalPair(a: string, b: string): { base: string; quote: string } {
  const prioA = QUOTE_PRIORITY_MAP.get(a) ?? -1;
  const prioB = QUOTE_PRIORITY_MAP.get(b) ?? -1;
  // Higher priority becomes quote
  return prioB > prioA ? { base: a, quote: b } : { base: b, quote: a };
}

// Check if a pair needs to be inverted (user wants non-canonical direction)
export function isInvertedPair(requestedBase: string, requestedQuote: string): boolean {
  const canonical = getCanonicalPair(requestedBase, requestedQuote);
  return canonical.base !== requestedBase || canonical.quote !== requestedQuote;
}

// Invert OHLC data (swap high/low, invert all prices)
export function invertOHLC(ohlc: OHLC): OHLC {
  return {
    time: ohlc.time,
    open: 1 / ohlc.open,
    high: 1 / ohlc.low,  // Inverted: original low becomes new high
    low: 1 / ohlc.high,  // Inverted: original high becomes new low
    close: 1 / ohlc.close,
  };
}

// Invert price data
export function invertPriceData(data: PriceData): PriceData {
  return {
    mid: 1 / data.mid,
    bid: 1 / data.ask,  // Inverted: original ask becomes new bid
    ask: 1 / data.bid,  // Inverted: original bid becomes new ask
  };
}

// ─────────────────────────────────────────────────────────────
// WebSocket Manager (Singleton, Throttled)
// ─────────────────────────────────────────────────────────────

const listeners = new Map<string, Set<(p: PriceData) => void>>();
const candleListeners = new Map<string, Set<(c: Candle) => void>>();
const prices = new Map<string, PriceData>();
let ws: WebSocket | null = null;
let reconnectTimer: ReturnType<typeof setTimeout> | null = null;
let throttleTimer: ReturnType<typeof setTimeout> | null = null;
const pendingUpdates = new Map<string, PriceData>();
const THROTTLE_MS = 333; // Max 3 updates/second

function flushUpdates() {
  pendingUpdates.forEach((priceData, symbol) => {
    listeners.get(symbol)?.forEach(cb => cb(priceData));
  });
  pendingUpdates.clear();
}

function queueUpdate(symbol: string, priceData: PriceData) {
  prices.set(symbol, priceData);
  pendingUpdates.set(symbol, priceData);

  if (!throttleTimer) {
    throttleTimer = setTimeout(() => {
      flushUpdates();
      throttleTimer = null;
    }, THROTTLE_MS);
  }
}

function connect() {
  if (ws?.readyState === WebSocket.OPEN || ws?.readyState === WebSocket.CONNECTING) return;

  ws = new WebSocket(WS_URL);

  ws.onopen = () => {
    const symbols = Array.from(listeners.keys());
    ws?.send(JSON.stringify({ type: 'subscribe', symbols: symbols.length ? symbols : ['*'] }));
  };

  ws.onmessage = (e) => {
    try {
      const d = JSON.parse(e.data);
      if (d.type === 'price') {
        // Legacy single price update
        const priceData: PriceData = { mid: d.price, bid: d.bid || d.price, ask: d.ask || d.price };
        queueUpdate(d.symbol, priceData);
        if (d.pair) queueUpdate(d.pair, priceData);
      } else if (d.type === 'price_batch') {
        // Batched price updates (new format)
        for (const u of d.updates || []) {
          const priceData: PriceData = { mid: u.price, bid: u.bid || u.price, ask: u.ask || u.price };
          queueUpdate(u.symbol, priceData);
          if (u.pair) queueUpdate(u.pair, priceData);
        }
      } else if (d.type === 'candle') {
        // Completed candle - notify candle listeners
        const key = `${d.pair}:${d.timeframe}`;
        candleListeners.get(key)?.forEach(cb => cb(d.candle));
      }
    } catch {}
  };

  ws.onclose = () => {
    ws = null;
    if (reconnectTimer) clearTimeout(reconnectTimer);
    reconnectTimer = setTimeout(connect, 2000);
  };

  ws.onerror = () => ws?.close();
}

function subscribe(sym: string, cb: (p: PriceData) => void) {
  if (!listeners.has(sym)) {
    listeners.set(sym, new Set());
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'subscribe', symbols: [sym] }));
    }
  }
  listeners.get(sym)!.add(cb);

  // Send cached price immediately
  const cached = prices.get(sym);
  if (cached) cb(cached);

  connect();

  return () => {
    const s = listeners.get(sym);
    s?.delete(cb);
    if (s?.size === 0) {
      listeners.delete(sym);
      if (ws?.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'unsubscribe', symbols: [sym] }));
      }
    }
  };
}

function subscribeCandles(pair: string, timeframe: number, cb: (c: Candle) => void) {
  const key = `${pair}:${timeframe}`;

  if (!candleListeners.has(key)) {
    candleListeners.set(key, new Set());
    if (ws?.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify({ type: 'subscribe_candles', symbols: [pair] }));
    }
  }
  candleListeners.get(key)!.add(cb);

  connect();

  return () => {
    const s = candleListeners.get(key);
    s?.delete(cb);
    if (s?.size === 0) {
      candleListeners.delete(key);
      if (ws?.readyState === WebSocket.OPEN) {
        ws.send(JSON.stringify({ type: 'unsubscribe_candles', symbols: [pair] }));
      }
    }
  };
}

// ─────────────────────────────────────────────────────────────
  // Hooks
  // ─────────────────────────────────────────────────────────────

  export function usePriceStream(symbol: string): PriceData | null {
  const [priceData, setPriceData] = useState<PriceData | null>(null);
  useEffect(() => {
    // Reset stale price from previous symbol immediately
    setPriceData(null);
    if (!symbol) return;
    return subscribe(symbol, setPriceData);
  }, [symbol]);
  return priceData;
}

export function useCandles(symbol: string, tf = 60, limit = 200) {
  // Use signal-based CandleStore instead of 3 useState calls
  const store = useMemo(() => getCandleStore(symbol, tf), [symbol, tf]);

  // Fetch candles when symbol or timeframe changes
  useEffect(() => {
    if (!symbol) return; // Skip if no symbol yet
    let active = true;
    store.startLoading();

    fetch(`${API_URL}/api/candles?symbol=${symbol}&timeframe=${tf}&limit=${limit}`)
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then((j: { candles?: Candle[] }) => {
        if (!active) return;
        // API returns DESC (newest first), reverse to chronological order (oldest first)
        const candles = (j.candles || []).reverse().map((c: Candle) => ({
          ...c,
          time: c.timestamp / 1000
        }));
        store.setCandles(candles);
      })
      .catch(e => {
        if (!active) return;
        // Only log in production or if it's not an HTML response (API not available)
        if (!e?.message?.includes('Unexpected token')) {
          log.error('[useCandles] Fetch error:', e);
        }
        store.setError(e?.message || 'Failed to load candles');
      });

    return () => { active = false; };
  }, [symbol, tf, limit, store]);

  // Listen to candle completion events (primary update mechanism)
  useEffect(() => {
    if (!symbol || !store.candles.value.length) return;

    return subscribeCandles(symbol, tf, (candle: Candle) => {
      const newCandle: OHLC = {
        time: candle.timestamp / 1000,
        open: candle.open,
        high: candle.high,
        low: candle.low,
        close: candle.close
      };

      store.updateCandle(newCandle, limit);
    });
  }, [symbol, tf, limit, store, store.candles.value.length > 0]);

  // Live tick updates for current candle (fallback between candle completions)
  useEffect(() => {
    if (!store.candles.value.length) return;

    return subscribe(`agg:spot:${symbol}`, (priceData) => {
      const price = priceData.mid; // Use mid price for OHLC
      store.updateLiveTick(price, tf, limit);
    });
  }, [store.candles.value.length > 0, symbol, tf, limit, store]);

  return {
    candles: store.candles.value,
    loading: store.loading.value,
    error: store.error.value,
  };
}

// Fetch available tickers
export const fetchAvailableTickers = () =>
  fetch(`${API_URL}/api/tickers`).then(r => r.json()).then(d => d.tickers || []).catch(() => []);

// Unwrap wrapped tokens to their canonical form for feed lookup
const WRAPPER_MAP: Record<string, string> = {
  WETH: 'ETH',
  WBTC: 'BTC',
  CBBTC: 'BTC',
  TBTC: 'BTC',
};

function unwrap(symbol: string): string {
  return WRAPPER_MAP[symbol] || symbol;
}

// Get feed info for a pair (triangulation if needed)
export function getPairFeedInfo(base: string, quote: string, feeds: string[]) {
  // Unwrap wrapped tokens (WETH -> ETH, WBTC -> BTC, etc.)
  const unwrappedBase = unwrap(base);
  const unwrappedQuote = unwrap(quote);

  // Convert to Set for O(1) lookups
  const feedSet = new Set(feeds);

  // Try direct feed first
  const direct = `agg:spot:${unwrappedBase}${unwrappedQuote}`;
  if (feedSet.has(direct)) return { isSynthetic: false, feed: direct, symbol: `${unwrappedBase}${unwrappedQuote}` };

  // Try USDT/USDC variants for stablecoin quotes or bases
  const stables = ['USDC', 'USDT'];
  if (stables.includes(unwrappedQuote)) {
    for (const s of stables) {
      const f = `agg:spot:${unwrappedBase}${s}`;
      if (feedSet.has(f)) return { isSynthetic: false, feed: f, symbol: `${unwrappedBase}${s}` };
    }
  }

  // Also check if base is a stablecoin (e.g., USDC/USDT)
  if (stables.includes(unwrappedBase)) {
    for (const s of stables) {
      const f = `agg:spot:${unwrappedBase}${s}`;
      if (feedSet.has(f)) return { isSynthetic: false, feed: f, symbol: `${unwrappedBase}${s}` };
    }
  }

  // Triangulation: base/USDC / quote/USDC (prefer USDC over USDT)
  const baseFeed = feeds.find(f => f.includes(`${unwrappedBase}USDC`) || f.includes(`${unwrappedBase}USDT`));
  const quoteFeed = feeds.find(f => f.includes(`${unwrappedQuote}USDC`) || f.includes(`${unwrappedQuote}USDT`));

  if (baseFeed && quoteFeed) {
    return {
      isSynthetic: true,
      baseFeed,
      quoteFeed,
      baseSymbol: baseFeed.replace('agg:spot:', ''),
      quoteSymbol: quoteFeed.replace('agg:spot:', ''),
    };
  }

  return { isSynthetic: false, feed: direct, symbol: `${unwrappedBase}${unwrappedQuote}` };
}

