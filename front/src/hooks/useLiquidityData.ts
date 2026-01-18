import { useState, useEffect } from 'preact/hooks';
import { usePoolsAPI } from './usePoolsAPI';

// Asset data for display
export interface AssetData {
  symbol: string;
  name: string;
  address: string;
  reserves: number;      // Amount in asset units
  liabilities: number;   // Amount in asset units
  price: number;         // USD price
  volume24h: number;     // USD (mocked for now)
  apy: number;           // Percentage (mocked for now)
}

export interface PoolData {
  name: string;
  assets: AssetData[];
  tvl: number;           // Total USD value locked
  volume24h: number;     // Total 24h volume USD
  utilization: number;   // Weighted average %
  coverage: number;      // Weighted average %
}

// Mock prices
const MOCK_PRICES: Record<string, number> = {
  WETH: 3500,
  ETH: 3500,
  WBTC: 100000,
  BTC: 100000,
  USDC: 1,
  USDT: 1,
  DAI: 1,
  WBNB: 600,
  BNB: 600,
  SOL: 200,
  PAXG: 2650,
};

// Mock pool data simulating a healthy AMM
const MOCK_POOL_DATA: PoolData = {
  name: 'Genesis',
  assets: [
    {
      symbol: 'WETH',
      name: 'Wrapped Ether',
      address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
      reserves: 150,
      liabilities: 120,
      price: MOCK_PRICES.WETH,
      volume24h: 125000,
      apy: 8.5,
    },
    {
      symbol: 'USDC',
      name: 'USD Coin',
      address: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48',
      reserves: 500000,
      liabilities: 400000,
      price: MOCK_PRICES.USDC,
      volume24h: 250000,
      apy: 5.2,
    },
    {
      symbol: 'WBTC',
      name: 'Wrapped Bitcoin',
      address: '0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599',
      reserves: 5,
      liabilities: 4,
      price: MOCK_PRICES.WBTC,
      volume24h: 75000,
      apy: 4.8,
    },
  ],
  tvl: 0, // Will be calculated
  volume24h: 0, // Will be calculated
  utilization: 0, // Will be calculated
  coverage: 0, // Will be calculated
};

// Calculate aggregate metrics
function calculatePoolMetrics(assets: AssetData[]): Pick<PoolData, 'tvl' | 'volume24h' | 'utilization' | 'coverage'> {
  let totalReservesUsd = 0;
  let totalLiabilitiesUsd = 0;
  let totalVolume = 0;

  for (const asset of assets) {
    const reservesUsd = asset.reserves * asset.price;
    const liabilitiesUsd = asset.liabilities * asset.price;
    totalReservesUsd += reservesUsd;
    totalLiabilitiesUsd += liabilitiesUsd;
    totalVolume += asset.volume24h;
  }

  return {
    tvl: totalReservesUsd,
    volume24h: totalVolume,
    utilization: totalLiabilitiesUsd > 0 ? (totalLiabilitiesUsd / totalReservesUsd) * 100 : 0,
    coverage: totalLiabilitiesUsd > 0 ? (totalReservesUsd / totalLiabilitiesUsd) * 100 : 100,
  };
}

export interface UseLiquidityDataResult {
  pool: PoolData | null;
  loading: boolean;
  error: string | null;
  isMockMode: boolean;
}

/**
 * Hook to get real-time liquidity pool data
 * Fetches from backend API (single source of truth)
 */
export function useLiquidityData(): UseLiquidityDataResult {
  const { pools, loading: apiLoading, error: apiError } = usePoolsAPI();
  const [pool, setPool] = useState<PoolData | null>(null);

  // Use backend API data if available, otherwise fall back to mock
  const isMockMode = pools.length === 0 && !apiLoading;

  useEffect(() => {
    if (isMockMode && !apiLoading) {
      // Use mock data when backend not available
      const metrics = calculatePoolMetrics(MOCK_POOL_DATA.assets);
      setPool({
        ...MOCK_POOL_DATA,
        ...metrics,
      });
      return;
    }

    if (pools.length === 0) {
      return;
    }

    // Use the first pool (Pool Zero) for now
    // TODO: Add pool selection UI
    const poolData = pools[0];

    // Convert API data to UI format
    const assets: AssetData[] = poolData.assets.map((asset) => {
      const reserves = Number(asset.reserves) / 10 ** asset.decimals;
      const liabilities = Number(asset.liabilities) / 10 ** asset.decimals;

      // Use mock prices for now (will be enriched with external feeds from collector)
      const price = MOCK_PRICES[asset.symbol] ?? 1;

      return {
        symbol: asset.symbol,
        name: asset.name,
        address: asset.token,
        reserves,
        liabilities,
        price,
        volume24h: 0, // TODO: Calculate from on-chain events
        apy: 0, // TODO: Calculate from fees and utilization
      };
    });

    // Calculate aggregate metrics
    const metrics = calculatePoolMetrics(assets);

    setPool({
      name: poolData.name,
      assets,
      ...metrics,
    });
  }, [pools, apiLoading, isMockMode]);

  return {
    pool,
    loading: apiLoading,
    error: apiError,
    isMockMode,
  };
}

// Get asset-specific data
export function useAssetData(symbol: string): AssetData | null {
  const { pool } = useLiquidityData();
  if (!pool) return null;
  return pool.assets.find(a => a.symbol === symbol) || null;
}
