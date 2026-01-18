/**
 * Hook to fetch pool data from backend API
 * Backend is the single source of truth for pool data
 */

import { useState, useEffect } from 'preact/hooks';

const API_URL = import.meta.env.VITE_COLLECTOR_API || 'http://localhost:3001';

export interface PoolAsset {
  token: string;
  symbol: string;
  name: string;
  decimals: number;
  reserves: string;
  liabilities: string;
  coverage: string;
}

export interface Pool {
  name: string;
  address: string;
  assets: PoolAsset[];
}

export interface PoolsResponse {
  pools: Pool[];
}

export interface SwapQuote {
  amountOut: string;
  amountIn: string;
  spreadBps: number;
  protoFee: string;
  lpFee: string;
  skewIn: number;
  skewOut: number;
  routeHops: string[];
  hopAmounts: string[];
}

/**
 * Fetch pool data from backend
 */
export function usePoolsAPI() {
  const [pools, setPools] = useState<Pool[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let active = true;

    const fetchPools = async () => {
      try {
        const response = await fetch(`${API_URL}/api/pools`);
        if (!response.ok) {
          throw new Error(`HTTP ${response.status}`);
        }

        const data: PoolsResponse = await response.json();

        if (active) {
          setPools(data.pools);
          setLoading(false);
        }
      } catch (err) {
        if (active) {
          setError(err instanceof Error ? err.message : 'Failed to fetch pools');
          setLoading(false);
        }
      }
    };

    fetchPools();

    // Refresh every 5 seconds
    const interval = setInterval(fetchPools, 5000);

    return () => {
      active = false;
      clearInterval(interval);
    };
  }, []);

  return { pools, loading, error };
}

/**
 * Fetch swap quote from backend
 */
export async function getSwapQuote(
  poolAddress: string,
  tokenIn: string,
  tokenOut: string,
  amountIn: string
): Promise<SwapQuote> {
  const params = new URLSearchParams({
    pool: poolAddress,
    tokenIn,
    tokenOut,
    amountIn,
  });

  const response = await fetch(`${API_URL}/api/quote?${params}`);

  if (!response.ok) {
    const error = await response.json();
    throw new Error(error.error || `HTTP ${response.status}`);
  }

  return response.json();
}
