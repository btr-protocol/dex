import { useReadContract, useReadContracts } from './useContract';
import type { Address } from '@sdk/eth';
import { POOL_ABI, getContractAddress } from '@sdk/eth';

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
 * @param token - Token address to query
 * @param poolAddress - Pool address (POOL_ZERO or POOL_STABLE)
 */
export function useAssetState(token: Address | undefined, poolAddress?: Address) {
  return useReadContract({
    address: poolAddress,
    abi: POOL_ABI,
    functionName: 'getAsset',
    args: token ? [token] : undefined,
    query: {
      enabled: !!poolAddress && !!token,
    },
  });
}

/**
 * Read oracle price for token
 */
export function useOraclePrice(token: Address | undefined, poolAddress?: Address) {
  return useReadContract({
    address: poolAddress,
    abi: POOL_ABI,
    functionName: 'getMidPrice',
    args: token ? [token] : undefined,
    query: {
      enabled: !!poolAddress && !!token,
    },
  });
}

/**
 * Read coverage ratio for token
 */
export function useCoverageRatio(token: Address | undefined, poolAddress?: Address) {
  return useReadContract({
    address: poolAddress,
    abi: POOL_ABI,
    functionName: 'coverageRatio',
    args: token ? [token] : undefined,
    query: {
      enabled: !!poolAddress && !!token,
    },
  });
}

/**
 * Quote a swap
 */
export function useSwapQuote(
  tokenIn: Address | undefined,
  tokenOut: Address | undefined,
  amountIn: bigint | undefined,
  poolAddress?: Address
) {
  return useReadContract({
    address: poolAddress,
    abi: POOL_ABI,
    functionName: 'getSwapQuote',
    args: tokenIn && tokenOut && amountIn ? ([tokenIn, tokenOut, amountIn] as const) : undefined,
    query: {
      enabled: !!poolAddress && !!tokenIn && !!tokenOut && !!amountIn && amountIn > 0n,
    },
  });
}

/**
 * Get all registered assets in pool
 */
export function useRegisteredAssets(poolAddress?: Address) {
  return useReadContract({
    address: poolAddress,
    abi: POOL_ABI,
    functionName: 'registeredAssets',
    query: {
      enabled: !!poolAddress,
    },
  });
}

/**
 * Get complete state for all pool assets
 */
export function usePoolAssets(poolAddress?: Address) {
  const { data: assetAddressesData } = useRegisteredAssets(poolAddress);
  const assetAddresses = Array.isArray(assetAddressesData) ? (assetAddressesData as Address[]) : undefined;

  const contracts = assetAddresses?.map((token: Address) => [
    {
      address: poolAddress,
      abi: POOL_ABI,
      functionName: 'getAsset',
      args: [token],
    },
    {
      address: poolAddress,
      abi: POOL_ABI,
      functionName: 'getMidPrice',
      args: [token],
    },
    {
      address: poolAddress,
      abi: POOL_ABI,
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
