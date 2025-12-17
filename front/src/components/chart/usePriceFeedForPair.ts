/**
 * Hook for fetching price feed data for a trading pair
 */
import { useState, useEffect } from 'preact/hooks';
import {
  useCandles,
  usePriceStream,
  fetchAvailableTickers,
  getPairFeedInfo,
  getCanonicalPair,
} from '@/hooks/usePriceFeed';

export function usePriceFeedForPair(base: string, quote: string, timeframe: number) {
  const canonical = getCanonicalPair(base, quote);
  const [pairInfo, setPairInfo] = useState<ReturnType<typeof getPairFeedInfo>>({
    isSynthetic: false,
    feed: '',
    symbol: '',
  });

  useEffect(() => {
    fetchAvailableTickers().then((feeds) => {
      setPairInfo(getPairFeedInfo(canonical.base, canonical.quote, feeds));
    });
  }, [canonical.base, canonical.quote]);

  const feedSymbol = pairInfo.symbol || `${canonical.base}USDT`;
  const { candles, loading, error } = useCandles(feedSymbol, timeframe, 200);

  const livePrice = usePriceStream(
    pairInfo.isSynthetic ? pairInfo.baseFeed! : pairInfo.feed || `agg:spot:${feedSymbol}`
  );
  const quotePrice = usePriceStream(pairInfo.isSynthetic ? pairInfo.quoteFeed! : '');

  return {
    canonical,
    pairInfo,
    candles,
    livePrice,
    quotePrice,
    loading,
    error,
  };
}
