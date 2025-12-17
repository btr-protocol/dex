import { useEffect, useState } from 'preact/hooks';
import type { Address } from '@sdk/eth';

interface HistoricalData {
  price: number;
  volume: number;
  tvl: number;
  apy: number;
  coverage: number;
  utilization: number;
  timestamp: number;
}

// Store historical data in localStorage
const STORAGE_KEY = 'asset_history_';

export function useAssetHistory(address: Address | undefined) {
  const [history, setHistory] = useState<HistoricalData | null>(null);

  useEffect(() => {
    if (!address) return;

    const key = `${STORAGE_KEY}${address}`;
    const stored = localStorage.getItem(key);
    if (stored) {
      try {
        setHistory(JSON.parse(stored));
      } catch {
        setHistory(null);
      }
    }
  }, [address]);

  const updateHistory = (data: HistoricalData) => {
    if (!address) return;
    const key = `${STORAGE_KEY}${address}`;
    localStorage.setItem(key, JSON.stringify(data));
    setHistory(data);
  };

  return { history, updateHistory };
}

export function calculatePercentageChange(current: number, previous?: number): number {
  if (!previous || previous === 0) return 0;
  return ((current - previous) / previous) * 100;
}
