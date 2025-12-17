import { useState, useEffect } from 'preact/hooks';

// Mock asset data for development when no contract is available
export interface AssetData {
  symbol: string;
  name: string;
  address: string;
  reserves: number;      // Amount in asset units
  liabilities: number;   // Amount in asset units
  price: number;         // USD price
  volume24h: number;     // USD
  apy: number;           // Percentage
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

export function useLiquidityData(): UseLiquidityDataResult {
  const [pool, setPool] = useState<PoolData | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    // Simulate loading delay
    const timer = setTimeout(() => {
      // Calculate aggregate metrics
      const metrics = calculatePoolMetrics(MOCK_POOL_DATA.assets);
      setPool({
        ...MOCK_POOL_DATA,
        ...metrics,
      });
      setLoading(false);
    }, 100);

    return () => clearTimeout(timer);
  }, []);

  return {
    pool,
    loading,
    error: null,
    isMockMode: true,
  };
}

// Get asset-specific data
export function useAssetData(symbol: string): AssetData | null {
  const { pool } = useLiquidityData();
  if (!pool) return null;
  return pool.assets.find(a => a.symbol === symbol) || null;
}

// Format helpers
export function formatUsd(value: number): string {
  if (value >= 1000000) return `$${(value / 1000000).toFixed(2)}M`;
  if (value >= 1000) return `$${(value / 1000).toFixed(1)}K`;
  return `$${value.toFixed(2)}`;
}

export function formatPercent(value: number): string {
  return `${value.toFixed(1)}%`;
}

export function formatCoverage(reservesUsd: number, liabilitiesUsd: number): number {
  if (liabilitiesUsd === 0) return 100;
  return (reservesUsd / liabilitiesUsd) * 100;
}
