/**
 * Technical Indicators for chart analysis
 * Multi-timeframe (MTF) approach: averages fast (10) and slow (20) period indicators
 * for smoother signals with better memory
 */
import { EMA, RSI, ADX } from 'technicalindicators';

export interface OHLC {
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
}

// Configurable periods
export interface IndicatorParams {
  fast: number;
  slow: number;
  signal: number;  // EMA period for signal/baseline
}

const DEFAULT_PARAMS: IndicatorParams = { fast: 10, slow: 20, signal: 14 };

// ─────────────────────────────────────────────────────────────────────────────
// Result types
// ─────────────────────────────────────────────────────────────────────────────

// EMA Trend: Dual EMA overlay on main chart
export interface EMATrendResult {
  time: number;
  emaFast: number;
  emaSlow: number;
}

// EMACD: EMA divergence (MTF EMA - its MA)
export interface EMACDResult {
  time: number;
  divergence: number;
  zero: number; // Always 0, for reference line
}

// RSIMA: MTF RSI vs its MA
export interface RSIMAResult {
  time: number;
  rsi: number;      // Multi-timeframe RSI average
  rsiMA: number;    // MA of the RSI
}

// RSIMACD: RSI divergence (MTF RSI - its MA)
export interface RSIMACDResult {
  time: number;
  divergence: number;
  zero: number;
}

// ADXMA: MTF ADX vs its MA
export interface ADXMAResult {
  time: number;
  adx: number;      // Multi-timeframe ADX average
  adxMA: number;    // MA of the ADX
}

// ADXMACD: ADX divergence (MTF ADX - its MA)
export interface ADXMACDResult {
  time: number;
  divergence: number;
  zero: number;
}

// SDEVMA: MTF StdDev vs its MA
export interface SDEVMAResult {
  time: number;
  sdev: number;     // Multi-timeframe StdDev average
  sdevMA: number;   // MA of the StdDev
}

// SDEVMACD: StdDev divergence (MTF SDEV - its MA)
export interface SDEVMACDResult {
  time: number;
  divergence: number;
  zero: number;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper functions
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Calculate standard deviation over a rolling window
 */
function rollingStdDev(values: number[], period: number): number[] {
  const result: number[] = [];
  for (let i = 0; i < values.length; i++) {
    if (i < period - 1) {
      result.push(NaN);
    } else {
      const slice = values.slice(i - period + 1, i + 1);
      const mean = slice.reduce((a, b) => a + b, 0) / slice.length;
      const variance = slice.reduce((a, b) => a + (b - mean) ** 2, 0) / slice.length;
      result.push(Math.sqrt(variance));
    }
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// EMA Trend (overlay on main chart)
// ─────────────────────────────────────────────────────────────────────────────

/**
 * EMA Trend: Dual EMA (fast vs slow) - overlay indicator
 */
export function calculateEMATrend(ohlc: OHLC[], params = DEFAULT_PARAMS): EMATrendResult[] {
  if (ohlc.length < params.slow) return [];

  const closes = ohlc.map(d => d.close);
  const emaFast = EMA.calculate({ values: closes, period: params.fast });
  const emaSlow = EMA.calculate({ values: closes, period: params.slow });

  const results: EMATrendResult[] = [];
  const offset = params.slow - 1;

  for (let i = 0; i < emaSlow.length; i++) {
    const fastIdx = i + (params.slow - params.fast);
    if (fastIdx >= 0 && fastIdx < emaFast.length) {
      results.push({
        time: ohlc[offset + i].time,
        emaFast: emaFast[fastIdx],
        emaSlow: emaSlow[i],
      });
    }
  }
  return results;
}

/**
 * EMACD: MTF EMA divergence (MTF EMA - its MA)
 */
export function calculateEMACD(ohlc: OHLC[], params = DEFAULT_PARAMS): EMACDResult[] {
  if (ohlc.length < params.slow + params.signal) return [];

  const closes = ohlc.map(d => d.close);

  // Calculate MTF EMA: average of fast and slow EMAs
  const emaFast = EMA.calculate({ values: closes, period: params.fast });
  const emaSlow = EMA.calculate({ values: closes, period: params.slow });

  // Align and average for MTF signal
  const offset = params.slow - params.fast;
  const mtfEMA: number[] = [];

  for (let i = 0; i < emaSlow.length; i++) {
    const fastIdx = i + offset;
    if (fastIdx >= 0 && fastIdx < emaFast.length) {
      mtfEMA.push((emaFast[fastIdx] + emaSlow[i]) / 2);
    }
  }

  // Calculate MA of MTF EMA
  const mtfMA = EMA.calculate({ values: mtfEMA, period: params.signal });

  const results: EMACDResult[] = [];
  const dataOffset = params.slow - 1 + params.signal - 1;

  for (let i = 0; i < mtfMA.length; i++) {
    const mtfIdx = i + params.signal - 1;
    if (mtfIdx < mtfEMA.length) {
      results.push({
        time: ohlc[dataOffset + i].time,
        divergence: mtfEMA[mtfIdx] - mtfMA[i],
        zero: 0,
      });
    }
  }
  return results;
}

// ─────────────────────────────────────────────────────────────────────────────
// RSI Indicators
// ─────────────────────────────────────────────────────────────────────────────

/**
 * RSIMA: Multi-timeframe RSI vs its MA
 */
export function calculateRSIMA(ohlc: OHLC[], params = DEFAULT_PARAMS): RSIMAResult[] {
  const minLen = params.slow + params.signal;
  if (ohlc.length < minLen) return [];

  const closes = ohlc.map(d => d.close);

  // Calculate RSI for both periods
  const rsiFast = RSI.calculate({ values: closes, period: params.fast });
  const rsiSlow = RSI.calculate({ values: closes, period: params.slow });

  // Align arrays - slow RSI starts later
  const offset = params.slow - params.fast;
  const mtfRSI: number[] = [];

  for (let i = 0; i < rsiSlow.length; i++) {
    const fastIdx = i + offset;
    if (fastIdx < rsiFast.length) {
      // Average of fast and slow RSI (multi-timeframe)
      mtfRSI.push((rsiFast[fastIdx] + rsiSlow[i]) / 2);
    }
  }

  // Calculate MA of MTF RSI
  const rsiMA = EMA.calculate({ values: mtfRSI, period: params.signal });

  const results: RSIMAResult[] = [];
  const dataOffset = params.slow - 1 + params.signal - 1;

  for (let i = 0; i < rsiMA.length; i++) {
    const mtfIdx = i + params.signal - 1;
    if (mtfIdx < mtfRSI.length) {
      results.push({
        time: ohlc[dataOffset + i].time,
        rsi: mtfRSI[mtfIdx],
        rsiMA: rsiMA[i],
      });
    }
  }
  return results;
}

/**
 * RSIMACD: RSI divergence (MTF RSI - its MA)
 */
export function calculateRSIMACD(ohlc: OHLC[], params = DEFAULT_PARAMS): RSIMACDResult[] {
  const rsima = calculateRSIMA(ohlc, params);
  return rsima.map(r => ({
    time: r.time,
    divergence: r.rsi - r.rsiMA,
    zero: 0,
  }));
}

// ─────────────────────────────────────────────────────────────────────────────
// ADX Indicators
// ─────────────────────────────────────────────────────────────────────────────

/**
 * ADXMA: Multi-timeframe ADX vs its MA
 */
export function calculateADXMA(ohlc: OHLC[], params = DEFAULT_PARAMS): ADXMAResult[] {
  const minLen = params.slow * 2 + params.signal;
  if (ohlc.length < minLen) return [];

  const highs = ohlc.map(d => d.high);
  const lows = ohlc.map(d => d.low);
  const closes = ohlc.map(d => d.close);

  // Calculate ADX for both periods
  const adxFast = ADX.calculate({ high: highs, low: lows, close: closes, period: params.fast });
  const adxSlow = ADX.calculate({ high: highs, low: lows, close: closes, period: params.slow });

  if (adxFast.length === 0 || adxSlow.length === 0) return [];

  // Extract ADX values
  const adxFastVals = adxFast.map((r: any) => r.adx);
  const adxSlowVals = adxSlow.map((r: any) => r.adx);

  // Align and average for MTF
  const offset = adxFastVals.length - adxSlowVals.length;
  const mtfADX: number[] = [];

  for (let i = 0; i < adxSlowVals.length; i++) {
    const fastIdx = i + offset;
    if (fastIdx >= 0 && fastIdx < adxFastVals.length) {
      mtfADX.push((adxFastVals[fastIdx] + adxSlowVals[i]) / 2);
    }
  }

  // Calculate MA of MTF ADX
  const adxMA = EMA.calculate({ values: mtfADX, period: params.signal });

  const results: ADXMAResult[] = [];
  const dataOffset = ohlc.length - adxSlowVals.length - params.signal + 1;

  for (let i = 0; i < adxMA.length; i++) {
    const mtfIdx = i + params.signal - 1;
    if (mtfIdx < mtfADX.length && dataOffset + i + params.signal - 1 < ohlc.length) {
      results.push({
        time: ohlc[dataOffset + i + params.signal - 1].time,
        adx: mtfADX[mtfIdx],
        adxMA: adxMA[i],
      });
    }
  }
  return results;
}

/**
 * ADXMACD: ADX divergence (MTF ADX - its MA)
 */
export function calculateADXMACD(ohlc: OHLC[], params = DEFAULT_PARAMS): ADXMACDResult[] {
  const adxma = calculateADXMA(ohlc, params);
  return adxma.map(r => ({
    time: r.time,
    divergence: r.adx - r.adxMA,
    zero: 0,
  }));
}

// ─────────────────────────────────────────────────────────────────────────────
// SDEV (Standard Deviation) Indicators
// ─────────────────────────────────────────────────────────────────────────────

/**
 * SDEVMA: Multi-timeframe StdDev vs its MA
 */
export function calculateSDEVMA(ohlc: OHLC[], params = DEFAULT_PARAMS): SDEVMAResult[] {
  if (ohlc.length < params.slow + params.signal) return [];

  const closes = ohlc.map(d => d.close);

  // Calculate StdDev for both periods
  const sdevFast = rollingStdDev(closes, params.fast);
  const sdevSlow = rollingStdDev(closes, params.slow);

  // Align and average for MTF
  const mtfSDEV: number[] = [];
  const times: number[] = [];

  for (let i = params.slow - 1; i < ohlc.length; i++) {
    const fastVal = sdevFast[i];
    const slowVal = sdevSlow[i];
    if (!isNaN(fastVal) && !isNaN(slowVal)) {
      mtfSDEV.push((fastVal + slowVal) / 2);
      times.push(ohlc[i].time);
    }
  }

  // Calculate MA of MTF SDEV
  const sdevMA = EMA.calculate({ values: mtfSDEV, period: params.signal });

  const results: SDEVMAResult[] = [];
  for (let i = 0; i < sdevMA.length; i++) {
    const mtfIdx = i + params.signal - 1;
    if (mtfIdx < mtfSDEV.length && mtfIdx < times.length) {
      results.push({
        time: times[mtfIdx],
        sdev: mtfSDEV[mtfIdx],
        sdevMA: sdevMA[i],
      });
    }
  }
  return results;
}

/**
 * SDEVMACD: StdDev divergence (MTF SDEV - its MA)
 */
export function calculateSDEVMACD(ohlc: OHLC[], params = DEFAULT_PARAMS): SDEVMACDResult[] {
  const sdevma = calculateSDEVMA(ohlc, params);
  return sdevma.map(r => ({
    time: r.time,
    divergence: r.sdev - r.sdevMA,
    zero: 0,
  }));
}

// ─────────────────────────────────────────────────────────────────────────────
// Analysis Presets
// ─────────────────────────────────────────────────────────────────────────────

export type AnalysisPreset =
  | 'none'
  | 'ema-trend'    // Overlay: EMA fast vs slow
  | 'emacd'        // Sub-pane: EMA divergence
  | 'rsima'        // Sub-pane: RSI vs MA
  | 'rsimacd'      // Sub-pane: RSI divergence
  | 'adxma'        // Sub-pane: ADX vs MA
  | 'adxmacd'      // Sub-pane: ADX divergence
  | 'sdevma'       // Sub-pane: SDEV vs MA
  | 'sdevmacd';    // Sub-pane: SDEV divergence

export const ANALYSIS_PRESETS: { id: AnalysisPreset; name: string; desc: string; isOverlay: boolean }[] = [
  { id: 'none', name: 'None', desc: 'No indicators', isOverlay: false },
  { id: 'ema-trend', name: 'EMA', desc: 'MTF EMA 10/20', isOverlay: true },
  { id: 'emacd', name: 'EMACD', desc: 'EMA Divergence', isOverlay: false },
  { id: 'rsima', name: 'RSIMA', desc: 'MTF RSI vs MA', isOverlay: false },
  { id: 'rsimacd', name: 'RSIMACD', desc: 'RSI Divergence', isOverlay: false },
  { id: 'adxma', name: 'ADXMA', desc: 'MTF ADX vs MA', isOverlay: false },
  { id: 'adxmacd', name: 'ADXMACD', desc: 'ADX Divergence', isOverlay: false },
  { id: 'sdevma', name: 'SDEVMA', desc: 'MTF SDEV vs MA', isOverlay: false },
  { id: 'sdevmacd', name: 'SDEVMACD', desc: 'SDEV Divergence', isOverlay: false },
];

// Helper to check if preset is overlay type
export const isOverlayPreset = (preset: AnalysisPreset): boolean =>
  ANALYSIS_PRESETS.find(p => p.id === preset)?.isOverlay ?? false;

// Helper to check if preset is divergence type (shows histogram around zero)
export const isDivergencePreset = (preset: AnalysisPreset): boolean =>
  preset.endsWith('cd'); // emacd, rsimacd, adxmacd, sdevmacd
