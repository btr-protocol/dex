import { useReadContract, useReadContracts } from './useContract';
import type { Address } from '@sdk/eth';
import { getAddresses } from '@/contracts/addresses';
import BAMM_ABI from '@/contracts/abis/BAMM.json';

export interface AssetState {
  reserves: bigint;
  liabilities: bigint;
  segmentCount: number;
  minFeeBps: number;
  maxFeeBps: number;
  flashFeeBps: number;
}

export interface PoolAsset {
  address: Address;
  symbol: string;
  decimals: number;
  reserves: bigint;
  liabilities: bigint;
  coverageRatio: bigint;
  price: bigint;
}

/**
 * Read asset state from pool
 */
export function useAssetState(token: Address | undefined) {
  const addresses = getAddresses();

  return useReadContract({
    address: addresses?.pool as Address | undefined,
    abi: BAMM_ABI,
    functionName: 'getAsset',
    args: token ? [token] : undefined,
    query: {
      enabled: !!addresses?.pool && !!token,
    },
  });
}

/**
 * Read oracle price for token
 */
export function useOraclePrice(token: Address | undefined) {
  const addresses = getAddresses();

  return useReadContract({
    address: addresses?.pool as Address | undefined,
    abi: BAMM_ABI,
    functionName: 'getOraclePrice',
    args: token ? [token] : undefined,
    query: {
      enabled: !!addresses?.pool && !!token,
    },
  });
}

/**
 * Read coverage ratio for token
 */
export function useCoverageRatio(token: Address | undefined) {
  const addresses = getAddresses();

  return useReadContract({
    address: addresses?.pool as Address | undefined,
    abi: BAMM_ABI,
    functionName: 'coverageRatio',
    args: token ? [token] : undefined,
    query: {
      enabled: !!addresses?.pool && !!token,
    },
  });
}

/**
 * Quote a swap
 */
export function useSwapQuote(
  tokenIn: Address | undefined,
  tokenOut: Address | undefined,
  amountIn: bigint | undefined
) {
  const addresses = getAddresses();

  return useReadContract({
    address: addresses?.pool as Address | undefined,
    abi: BAMM_ABI,
    functionName: 'quote',
    args: tokenIn && tokenOut && amountIn ? [tokenIn, tokenOut, amountIn] : undefined,
    query: {
      enabled: !!addresses?.pool && !!tokenIn && !!tokenOut && !!amountIn && amountIn > 0n,
    },
  });
}

/**
 * Get all registered assets in the pool
 */
export function useRegisteredAssets() {
  const addresses = getAddresses();

  return useReadContract({
    address: addresses?.pool as Address | undefined,
    abi: BAMM_ABI,
    functionName: 'registeredAssets',
    query: {
      enabled: !!addresses?.pool,
    },
  });
}

/**
 * Get complete state for all pool assets
 */
export function usePoolAssets() {
  const { data: assetAddresses } = useRegisteredAssets();
  const addresses = getAddresses();

  const contracts = assetAddresses?.map((token: Address) => [
    {
      address: addresses?.pool as Address,
      abi: BAMM_ABI,
      functionName: 'getAsset',
      args: [token],
    },
    {
      address: addresses?.pool as Address,
      abi: BAMM_ABI,
      functionName: 'getOraclePrice',
      args: [token],
    },
    {
      address: addresses?.pool as Address,
      abi: BAMM_ABI,
      functionName: 'coverageRatio',
      args: [token],
    },
  ]).flat();

  const { data, loading: isLoading, error } = useReadContracts({
    contracts: contracts || [],
    query: {
      enabled: !!assetAddresses && assetAddresses.length > 0,
    },
  });

  // Transform data into structured format
  const assets: PoolAsset[] = [];
  if (data && assetAddresses) {
    for (let i = 0; i < assetAddresses.length; i++) {
      const assetData = data[i * 3]?.result as AssetState | undefined;
      const price = data[i * 3 + 1]?.result as bigint | undefined;
      const coverageRatio = data[i * 3 + 2]?.result as bigint | undefined;

      if (assetData && price && coverageRatio) {
        assets.push({
          address: assetAddresses[i],
          symbol: 'UNKNOWN', // Will be populated from token contract
          decimals: 18, // Will be populated from token contract
          reserves: assetData.reserves,
          liabilities: assetData.liabilities,
          coverageRatio,
          price,
        });
      }
    }
  }

  return {
    assets,
    isLoading,
    error,
  };
}
