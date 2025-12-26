import { useMemo } from 'preact/hooks';
import { useCandles } from '@/hooks/usePriceFeed';
import { generateSyntheticCandles } from '@/lib/chart/math/synthetic';

export function useChartData(
  _base: string,
  _quote: string,
  timeframe: number,
  isSynthetic: boolean,
  baseSymbol: string,
  quoteSymbol: string,
  needsInversion: boolean
) {
  const { candles: baseC, loading: l1, error: e1 } = useCandles(baseSymbol, timeframe, 200);
  const { candles: quoteC, loading: l2 } = useCandles(quoteSymbol, timeframe, 200);

  const rawCandles = useMemo(() => {
    if (!isSynthetic) return baseC;
    return generateSyntheticCandles(baseC, quoteC);
  }, [isSynthetic, baseC, quoteC]);

  const candles = useMemo(() => {
    if (!needsInversion) return rawCandles;
    return rawCandles.map(c => ({
      ...c,
      open: 1 / c.open,
      high: 1 / c.low,
      low: 1 / c.high,
      close: 1 / c.close,
    }));
  }, [rawCandles, needsInversion]);

  return {
    candles,
    loading: l1 || (isSynthetic && l2),
    error: e1
  };
}
