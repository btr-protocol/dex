/**
 * Hook to fetch pool data from backend API
 * Backend is the single source of truth for pool data
 */

import { useEffect } from 'preact/hooks';
import { poolsStore, type Pool, type PoolAssetAPI } from '@/lib/pool/PoolsStore';

export type { Pool, PoolAssetAPI };

const API_URL = import.meta.env.VITE_COLLECTOR_API || 'http://localhost:3001';

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
 * Fetch pool data from backend using signal-based PoolsStore
 * Uses singleton store for shared state across components
 */
export function usePoolsAPI() {
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
          // Use updatePools for background refresh (doesn't set loading)
          if (poolsStore.hasPools.value) {
            poolsStore.updatePools(data.pools);
          } else {
            poolsStore.setPools(data.pools);
          }
        }
      } catch (err) {
        if (active) {
          poolsStore.setError(err instanceof Error ? err.message : 'Failed to fetch pools');
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

  return {
    pools: poolsStore.pools.value,
    loading: poolsStore.loading.value,
    error: poolsStore.error.value,
  };
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
