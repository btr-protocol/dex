/**
 * Market data types shared across collector and frontend
 */

/**
 * OHLC Candle Data
 * Used by: usePriceFeed, useCandles, collector, chart components
 */
export interface OHLC {
  time: number;      // Unix timestamp (seconds)
  open: number;      // Open price
  high: number;      // High price
  low: number;       // Low price
  close: number;     // Close price
}

/**
 * Price data (bid/ask/mid)
 * Used by: usePriceFeed, collector, chart components
 */
export interface PriceData {
  mid: number;
  bid: number;
  ask: number;
}

/**
 * Timeframe constants
 * Used by: chart components, useCandles
 */
export enum Timeframe {
  M1 = 60,      // 1 minute
  M5 = 300,     // 5 minutes
  M15 = 900,    // 15 minutes
  M30 = 1800,   // 30 minutes
  H1 = 3600,    // 1 hour
  H4 = 14400,   // 4 hours
  H12 = 43200,  // 12 hours
  D1 = 86400,   // 1 day
}
