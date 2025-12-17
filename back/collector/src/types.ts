/**
 * Type definitions for market data collector
 */

export type PairSymbol = string;

export interface OHLCCandle {
  timestamp: number;
  open: number;
  high: number;
  low: number;
  close: number;
  volume: number;
}

export enum OHLCTimeframe {
  M1 = 60,      // 1 minute
  M5 = 300,     // 5 minutes
  M15 = 900,    // 15 minutes
  M30 = 1800,   // 30 minutes
  H1 = 3600,    // 1 hour
  H4 = 14400,   // 4 hours
  H12 = 43200   // 12 hours
}

export interface TickerSource {
  weight: number;
}

export interface TickerConfig {
  id: PairSymbol;
  name: string;
  tf: number;
  lookback: number;
  sources: Record<PairSymbol, TickerSource>;
}

export interface CollectorConfig {
  pollIntervalMs: number;
  tickers: Record<PairSymbol, TickerConfig>;
}

export interface TickerData {
  bid: number;
  ask: number;
  mid: number;
  last: number;
  volume: number;
  timestamp: number;
}

export interface AggregatedTicker {
  symbol: PairSymbol;
  last: TickerData | null;
  sources: Record<string, {
    status: 'active' | 'inactive';
    last: TickerData | null;
  }>;
  history?: {
    ts: number[];
    o: number[];
    h: number[];
    l: number[];
    c: number[];
    v: number[];
  };
}
