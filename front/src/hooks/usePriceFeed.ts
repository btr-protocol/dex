import { useState, useEffect } from 'preact/hooks';

const API_URL = import.meta.env.VITE_COLLECTOR_URL || 'http://localhost:3001';
const WS_URL = import.meta.env.VITE_COLLECTOR_WS || 'ws://localhost:3001/ws';

export interface OHLC { time: number; open: number; high: number; low: number; close: number; }

// Quote priority: higher index = higher priority as quote currency
const QUOTE_PRIORITY = ['ETH', 'BTC', 'USD1', 'RLUSD', 'PYUSD', 'DAI', 'USDS', 'USDE', 'USDT', 'USDC'];

// Get canonical pair ordering (base/quote) based on priority
export function getCanonicalPair(a: string, b: string): { base: string; quote: string } {
  const prioA = QUOTE_PRIORITY.indexOf(a);
  const prioB = QUOTE_PRIORITY.indexOf(b);
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

interface PriceData { mid: number; bid: number; ask: number; }
const listeners = new Map<string, Set<(p: PriceData) => void>>();
const candleListeners = new Map<string, Set<(c: any) => void>>();
const prices = new Map<string, PriceData>();
let ws: WebSocket | null = null;
let reconnectTimer: any = null;
let throttleTimer: any = null;
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

function subscribeCandles(pair: string, timeframe: number, cb: (c: any) => void) {
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

export { type PriceData };

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
  const [data, setData] = useState<OHLC[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  // Fetch candles when symbol or timeframe changes
  useEffect(() => {
    if (!symbol) return; // Skip if no symbol yet
    let active = true;
    setData([]); // Clear old data immediately on change
    setLoading(true);
    setError(null);

    fetch(`${API_URL}/api/candles?symbol=${symbol}&timeframe=${tf}&limit=${limit}`)
      .then(r => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        return r.json();
      })
      .then(j => {
        if (!active) return;
        // API returns DESC (newest first), reverse to chronological order (oldest first)
        const candles = (j.candles || []).reverse().map((c: any) => ({
          ...c,
          time: c.timestamp / 1000
        }));
        setData(candles);
        setLoading(false);
      })
      .catch(e => {
        if (!active) return;
        console.error('[useCandles] Fetch error:', e);
        setError(e?.message || 'Failed to load candles');
        setLoading(false);
      });

    return () => { active = false; };
  }, [symbol, tf, limit]);

  // Listen to candle completion events (primary update mechanism)
  useEffect(() => {
    if (!symbol || !data.length) return;

    return subscribeCandles(symbol, tf, (candle: any) => {
      setData(prev => {
        if (!prev.length) return prev;

        const newCandle: OHLC = {
          time: candle.timestamp / 1000,
          open: candle.open,
          high: candle.high,
          low: candle.low,
          close: candle.close
        };

        // Find where this candle belongs (it's a completed candle, may not be the latest)
        const idx = prev.findIndex(c => c.time === newCandle.time);
        if (idx >= 0) {
          // Replace existing candle at this time
          const updated = [...prev];
          updated[idx] = newCandle;
          return updated;
        }

        // Insert in correct position to maintain ascending order
        const last = prev[prev.length - 1];
        if (newCandle.time > last.time) {
          // Append (most common case - new candle)
          return [...prev.slice(-(limit - 1)), newCandle];
        }

        // Candle is older than last - insert in sorted position
        const insertIdx = prev.findIndex(c => c.time > newCandle.time);
        if (insertIdx === -1) return prev; // Shouldn't happen
        const result = [...prev.slice(0, insertIdx), newCandle, ...prev.slice(insertIdx)];
        return result.slice(-limit);
      });
    });
  }, [symbol, tf, limit, data.length > 0]);

  // Live tick updates for current candle (fallback between candle completions)
  useEffect(() => {
    if (!data.length) return;
    return subscribe(`agg:spot:${symbol}`, (priceData) => {
      const price = priceData.mid; // Use mid price for OHLC
      setData(prev => {
        if (!prev.length) return prev;
        const last = prev[prev.length - 1];
        const bucket = Math.floor(Date.now() / 1000 / tf) * tf;

        if (bucket === last.time) {
          // Update current candle
          return [...prev.slice(0, -1), { ...last, close: price, high: Math.max(last.high, price), low: Math.min(last.low, price) }];
        }
        if (bucket > last.time) {
          // Start new candle (will be replaced by candle completion event)
          return [...prev.slice(-(limit - 1)), { time: bucket, open: price, high: price, low: price, close: price }];
        }
        return prev;
      });
    });
  }, [data.length > 0, symbol, tf, limit]);

  return { candles: data, loading, error };
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

  // Try direct feed first
  const direct = `agg:spot:${unwrappedBase}${unwrappedQuote}`;
  if (feeds.includes(direct)) return { isSynthetic: false, feed: direct, symbol: `${unwrappedBase}${unwrappedQuote}` };

  // Try USDT/USDC variants for stablecoin quotes or bases
  const stables = ['USDC', 'USDT'];
  if (stables.includes(unwrappedQuote)) {
    for (const s of stables) {
      const f = `agg:spot:${unwrappedBase}${s}`;
      if (feeds.includes(f)) return { isSynthetic: false, feed: f, symbol: `${unwrappedBase}${s}` };
    }
  }

  // Also check if base is a stablecoin (e.g., USDC/USDT)
  if (stables.includes(unwrappedBase)) {
    for (const s of stables) {
      const f = `agg:spot:${unwrappedBase}${s}`;
      if (feeds.includes(f)) return { isSynthetic: false, feed: f, symbol: `${unwrappedBase}${s}` };
    }
  }

  // Triangulation: base/USDC / quote/USDC (prefer USDC over USDT)
  const baseFeed = feeds.find(f => f.includes(`${unwrappedBase}USDC`)) || feeds.find(f => f.includes(`${unwrappedBase}USDT`));
  const quoteFeed = feeds.find(f => f.includes(`${unwrappedQuote}USDC`)) || feeds.find(f => f.includes(`${unwrappedQuote}USDT`));

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

