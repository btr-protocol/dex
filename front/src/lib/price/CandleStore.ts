/**
 * CandleStore - Signal-based candle data management
 * Replaces 3 useState calls in useCandles hook (data, loading, error)
 * Optimizes live tick updates and candle completion events with batching
 */
import { signal, batch } from '@preact/signals';
import type { OHLC } from '@/types/market';

export class CandleStore {
  // Candle data signals
  public candles = signal<OHLC[]>([]);
  public loading = signal(true);
  public error = signal<string | null>(null);

  // Store identity for cleanup
  private symbol: string;
  private timeframe: number;

  constructor(symbol: string, timeframe: number) {
    this.symbol = symbol;
    this.timeframe = timeframe;
  }

  /**
   * Set candles data with batched loading/error updates
   */
  public setCandles(candles: OHLC[]) {
    batch(() => {
      this.candles.value = candles;
      this.loading.value = false;
      this.error.value = null;
    });
  }

  /**
   * Set error state
   */
  public setError(error: string) {
    batch(() => {
      this.error.value = error;
      this.loading.value = false;
    });
  }

  /**
   * Start loading
   */
  public startLoading() {
    batch(() => {
      this.candles.value = [];
      this.loading.value = true;
      this.error.value = null;
    });
  }

  /**
   * Update existing candle or insert new one (maintains sorted order)
   * Used for candle completion events
   */
  public updateCandle(candle: OHLC, limit: number) {
    const prev = this.candles.value;
    if (!prev.length) return;

    // Find where this candle belongs
    const idx = prev.findIndex(c => c.time === candle.time);

    if (idx >= 0) {
      // Replace existing candle at this time
      const updated = [...prev];
      updated[idx] = candle;
      this.candles.value = updated;
      return;
    }

    // Insert in correct position to maintain ascending order
    const last = prev[prev.length - 1];

    if (candle.time > last.time) {
      // Append (most common case - new candle)
      this.candles.value = [...prev.slice(-(limit - 1)), candle];
      return;
    }

    // Candle is older than last - insert in sorted position
    const insertIdx = prev.findIndex(c => c.time > candle.time);
    if (insertIdx === -1) return; // Shouldn't happen

    const result = [...prev.slice(0, insertIdx), candle, ...prev.slice(insertIdx)];
    this.candles.value = result.slice(-limit);
  }

  /**
   * Update current candle with live tick
   * Updates high/low/close of the last candle
   */
  public updateLiveTick(price: number, timeframe: number, limit: number) {
    const prev = this.candles.value;
    if (!prev.length) return;

    const last = prev[prev.length - 1];
    const bucket = Math.floor(Date.now() / 1000 / timeframe) * timeframe;

    if (bucket === last.time) {
      // Update current candle (in-place optimization)
      this.candles.value = [
        ...prev.slice(0, -1),
        {
          ...last,
          close: price,
          high: Math.max(last.high, price),
          low: Math.min(last.low, price),
        },
      ];
    } else if (bucket > last.time) {
      // Start new candle (will be replaced by candle completion event)
      this.candles.value = [
        ...prev.slice(-(limit - 1)),
        {
          time: bucket,
          open: price,
          high: price,
          low: price,
          close: price,
        },
      ];
    }
  }

  /**
   * Reset all state
   */
  public reset() {
    batch(() => {
      this.candles.value = [];
      this.loading.value = true;
      this.error.value = null;
    });
  }

  /**
   * Get store identity
   */
  public getKey(): string {
    return `${this.symbol}:${this.timeframe}`;
  }
}

/**
 * Global CandleStore registry
 * Reuses stores for same symbol+timeframe to prevent duplicate subscriptions
 */
const candleStores = new Map<string, CandleStore>();

export function getCandleStore(symbol: string, timeframe: number): CandleStore {
  const key = `${symbol}:${timeframe}`;

  let store = candleStores.get(key);
  if (!store) {
    store = new CandleStore(symbol, timeframe);
    candleStores.set(key, store);
  }

  return store;
}

export function clearCandleStore(symbol: string, timeframe: number) {
  const key = `${symbol}:${timeframe}`;
  candleStores.delete(key);
}
