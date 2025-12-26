import { type OHLC } from '@/hooks/usePriceFeed';

/**
 * Derives synthetic candles using variance-addition: var(ln X) = var(ln A) + var(ln B) - 2·ρ·σ_A·σ_B
 */
export function generateSyntheticCandles(
  baseCandles: OHLC[],
  quoteCandles: OHLC[]
): OHLC[] {
  if (!baseCandles.length || !quoteCandles.length) return [];

  // Index quote candles by time for O(1) lookup
  const quoteByTime = new Map(quoteCandles.map(c => [c.time, c]));

  // Estimate rolling correlation from log returns (use ~20 bar window)
  const CORR_WINDOW = 20;
  const baseReturns: number[] = [];
  const quoteReturns: number[] = [];

  for (let i = 1; i < baseCandles.length && i < CORR_WINDOW + 1; i++) {
    const q = quoteByTime.get(baseCandles[i].time);
    const qPrev = quoteByTime.get(baseCandles[i - 1].time);
    if (!q || !qPrev || q.close <= 0 || qPrev.close <= 0) continue;
    if (baseCandles[i].close <= 0 || baseCandles[i - 1].close <= 0) continue;

    baseReturns.push(Math.log(baseCandles[i].close / baseCandles[i - 1].close));
    quoteReturns.push(Math.log(q.close / qPrev.close));
  }

  // Calculate correlation coefficient
  let rho = 0.85; // Default assumption for crypto pairs
  if (baseReturns.length >= 5) {
    const n = baseReturns.length;
    const meanB = baseReturns.reduce((a, b) => a + b, 0) / n;
    const meanQ = quoteReturns.reduce((a, b) => a + b, 0) / n;

    let covBQ = 0, varB = 0, varQ = 0;
    for (let i = 0; i < n; i++) {
      const db = baseReturns[i] - meanB;
      const dq = quoteReturns[i] - meanQ;
      covBQ += db * dq;
      varB += db * db;
      varQ += dq * dq;
    }

    if (varB > 0 && varQ > 0) {
      rho = Math.max(0, Math.min(0.99, covBQ / Math.sqrt(varB * varQ)));
    }
  }

  return baseCandles
    .map(b => {
      const q = quoteByTime.get(b.time);
      if (!q || q.close === 0 || q.open === 0 || q.high === 0 || q.low === 0) return null;

      // Exact open/close for synthetic ratio
      const open = b.open / q.open;
      const close = b.close / q.close;

      // Use variance-addition formula for synthetic range
      // Log-range of each asset (approximates intrabar volatility)
      const rangeB = Math.log(b.high / b.low);
      const rangeQ = Math.log(q.high / q.low);

      // Synthetic variance: σ² = σ_B² + σ_Q² - 2·ρ·σ_B·σ_Q
      const synthVar = rangeB * rangeB + rangeQ * rangeQ - 2 * rho * rangeB * rangeQ;
      const synthRange = Math.sqrt(Math.max(0, synthVar));

      // Apply synthetic range centered on the close price
      const halfRange = synthRange / 2;
      const high = close * Math.exp(halfRange);
      const low = close * Math.exp(-halfRange);

      // Ensure OHLC consistency
      const finalHigh = Math.max(high, open, close);
      const finalLow = Math.min(low, open, close);

      return { time: b.time, open, high: finalHigh, low: finalLow, close };
    })
    .filter((c): c is OHLC => c !== null);
}
