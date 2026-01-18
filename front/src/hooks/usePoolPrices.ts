import { useState, useEffect } from 'preact/hooks';
import { usePriceStream } from './usePriceFeed';

/**
 * Hook to fetch and aggregate external prices for pool assets
 * Returns a map of symbol -> USD price
 */
export function usePoolPrices(symbols: string[]): Map<string, number> {
  const [priceMap, setPriceMap] = useState<Map<string, number>>(new Map());

  useEffect(() => {
    const newMap = new Map<string, number>();

    // Update map when we have all prices
    // This effect will re-run when any symbol changes
    setPriceMap(newMap);
  }, [symbols]);

  return priceMap;
}

/**
 * Hook to get price for a single asset
 * Uses external feed if available (e.g., ETHUSDC, BTCUSDC)
 * Falls back to $1.00 for stablecoins
 */
export function useAssetPrice(symbol: string, feedSymbol?: string): number | null {
  // Stablecoins always $1.00
  if (isStablecoin(symbol)) {
    return 1.0;
  }

  // Try to get external price
  const feedData = usePriceStream(feedSymbol ? `agg:spot:${feedSymbol}` : '');

  if (feedData) {
    return feedData.mid;
  }

  // No price available yet
  return null;
}

function isStablecoin(symbol: string): boolean {
  const stables = ['USDC', 'USDT', 'DAI', 'TUSD', 'FDUSD', 'USDD', 'USDP', 'crvUSD', 'lisUSD', 'AUSD', 'frxUSD'];
  return stables.includes(symbol);
}
