/**
 * Indicator Configuration - Single source of truth for all chart indicators
 */
import {
  calculateEMATrend,
  calculateEMACD,
  calculateRSIMA,
  calculateRSIMACD,
  calculateADXMA,
  calculateADXMACD,
  calculateSDEVMA,
  calculateSDEVMACD,
  ANALYSIS_PRESETS,
  type IndicatorParams,
} from '@utils/indicators';
import type { OHLC } from '@/hooks/usePriceFeed';

export type IndicatorKey =
  | 'ema-trend'
  | 'emacd' | 'rsima' | 'rsimacd'
  | 'adxma' | 'adxmacd'
  | 'sdevma' | 'sdevmacd';

export type ChartType = 'candles' | 'bars' | 'line';

export interface IndicatorDef {
  key: IndicatorKey;
  paneType: 'overlay' | 'sub';
  isDivergence: boolean;
  calc: (candles: OHLC[], params: IndicatorParams) => any[];
  series1Field: string;
  series2Field: string;
  label1: string;
  label2: string;
}

export const DEFAULT_PARAMS: IndicatorParams = { fast: 10, slow: 20, signal: 14 };

export const INDICATORS: Record<IndicatorKey, IndicatorDef> = {
  'ema-trend': {
    key: 'ema-trend',
    paneType: 'overlay',
    isDivergence: false,
    calc: calculateEMATrend,
    series1Field: 'emaFast',
    series2Field: 'emaSlow',
    label1: 'Fast',
    label2: 'Slow',
  },
  emacd: {
    key: 'emacd',
    paneType: 'sub',
    isDivergence: true,
    calc: calculateEMACD,
    series1Field: 'divergence',
    series2Field: 'zero',
    label1: 'EMACD',
    label2: '',
  },
  rsima: {
    key: 'rsima',
    paneType: 'sub',
    isDivergence: false,
    calc: calculateRSIMA,
    series1Field: 'rsi',
    series2Field: 'rsiMA',
    label1: 'RSIMA',
    label2: 'MA',
  },
  rsimacd: {
    key: 'rsimacd',
    paneType: 'sub',
    isDivergence: true,
    calc: calculateRSIMACD,
    series1Field: 'divergence',
    series2Field: 'zero',
    label1: 'RSIMACD',
    label2: '',
  },
  adxma: {
    key: 'adxma',
    paneType: 'sub',
    isDivergence: false,
    calc: calculateADXMA,
    series1Field: 'adx',
    series2Field: 'adxMA',
    label1: 'ADXMA',
    label2: 'MA',
  },
  adxmacd: {
    key: 'adxmacd',
    paneType: 'sub',
    isDivergence: true,
    calc: calculateADXMACD,
    series1Field: 'divergence',
    series2Field: 'zero',
    label1: 'ADXMACD',
    label2: '',
  },
  sdevma: {
    key: 'sdevma',
    paneType: 'sub',
    isDivergence: false,
    calc: calculateSDEVMA,
    series1Field: 'sdev',
    series2Field: 'sdevMA',
    label1: 'SDEVMA',
    label2: 'MA',
  },
  sdevmacd: {
    key: 'sdevmacd',
    paneType: 'sub',
    isDivergence: true,
    calc: calculateSDEVMACD,
    series1Field: 'divergence',
    series2Field: 'zero',
    label1: 'SDEVMACD',
    label2: '',
  },
};

export const SUB_PANE_KEYS: IndicatorKey[] = [
  'emacd', 'rsima', 'rsimacd', 'adxma', 'adxmacd', 'sdevma', 'sdevmacd'
];

export function getIndicatorBaseName(key: IndicatorKey): string {
  const presetInfo = ANALYSIS_PRESETS.find(p => p.id === key);
  return presetInfo?.name ?? key.toUpperCase();
}

export function formatIndicatorWithParams(name: string, params: IndicatorParams): string {
  return `${name}(${params.fast},${params.slow},${params.signal})`;
}

/**
 * Format a series label with its specific relevant parameters
 */
export function formatSeriesWithParams(label: string, params: IndicatorParams): string {
  // Handle multi-word labels that use specific parameters
  if (label === 'Fast') return `Fast(${params.fast})`;
  if (label === 'Slow') return `Slow(${params.slow})`;
  if (label === 'MA') return `MA(${params.signal})`;

  // For main indicators (RSIMA, ADXMA, SDEVMA), show with fast+slow params
  if (label === 'RSIMA' || label === 'ADXMA' || label === 'SDEVMA') {
    return `${label}(${params.fast},${params.slow})`;
  }

  // For divergence indicators, just show the name
  if (label === 'EMACD' || label === 'RSIMACD' || label === 'ADXMACD' || label === 'SDEVMACD') {
    return label;
  }

  // Fallback
  return label;
}

export function formatChartPrice(price: number, decimals: number): string {
  if (!isFinite(price)) return '0';
  const absPrice = Math.abs(price);
  // Use scientific notation for prices under 0.001
  if (absPrice > 0 && absPrice < 0.001) {
    return price.toExponential(4);
  }
  return price.toLocaleString('en-US', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  });
}

export function formatIndicatorValue(value: number): string {
  if (!isFinite(value)) return '—';

  const absVal = Math.abs(value);

  // Very large values: compact notation
  if (absVal >= 1_000_000) return `${value < 0 ? '-' : ''}${(absVal / 1_000_000).toFixed(2)}M`;
  if (absVal >= 10_000) return Math.round(value).toLocaleString('en-US');

  // Standard values
  if (absVal >= 100) return value.toFixed(1);
  if (absVal >= 10) return value.toFixed(2);
  if (absVal >= 1) return value.toFixed(3);
  if (absVal >= 0.01) return value.toFixed(4);
  if (absVal >= 0.0001) return value.toFixed(6);

  // Very small values: scientific notation
  if (absVal > 0) return value.toExponential(2);

  return '0';
}

export const TIMEFRAME_OPTIONS = [
  { value: 60, label: '1m' },
  { value: 300, label: '5m' },
  { value: 900, label: '15m' },
  { value: 3600, label: '1h' },
  { value: 14400, label: '4h' },
  { value: 86400, label: '1D' },
] as const;

export const CHART_TYPE_OPTIONS = [
  { value: 'candles' as const, label: 'Candles' },
  { value: 'bars' as const, label: 'Bars' },
  { value: 'line' as const, label: 'Line' },
] as const;
