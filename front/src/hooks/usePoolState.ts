import { useReadContract, useReadContracts } from './useContract';
import type { Address } from '@sdk/eth';
import { AIMM_ABI, getContractAddress } from '@sdk/eth';

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
 * @param chainId - Chain ID (required to get pool address from SDK)
 */
export function useAssetState(token: Address | undefined, chainId?: number) {
  const poolAddress = chainId ? getContractAddress(chainId, 'AIMM_POOL') : undefined;

  return useReadContract({
    address: poolAddress as Address | undefined,
    abi: AIMM_ABI,
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
export function useOraclePrice(token: Address | undefined, chainId?: number) {
  const poolAddress = chainId ? getContractAddress(chainId, 'AIMM_POOL') : undefined;

  return useReadContract({
    address: poolAddress as Address | undefined,
    abi: AIMM_ABI,
    functionName: 'getOraclePrice',
    args: token ? [token] : undefined,
    query: {
      enabled: !!poolAddress && !!token,
    },
  });
}

/**
 * Read coverage ratio for token
 */
export function useCoverageRatio(token: Address | undefined, chainId?: number) {
  const poolAddress = chainId ? getContractAddress(chainId, 'AIMM_POOL') : undefined;

  return useReadContract({
    address: poolAddress as Address | undefined,
    abi: AIMM_ABI,
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
  chainId?: number
) {
  const poolAddress = chainId ? getContractAddress(chainId, 'AIMM_POOL') : undefined;

  return useReadContract({
    address: poolAddress as Address | undefined,
    abi: AIMM_ABI,
    functionName: 'quote',
    args: tokenIn && tokenOut && amountIn ? ([tokenIn, tokenOut, amountIn] as const) : undefined,
    query: {
      enabled: !!poolAddress && !!tokenIn && !!tokenOut && !!amountIn && amountIn > 0n,
    },
  });
}

/**
 * Get all registered assets in the pool
 */
export function useRegisteredAssets(chainId?: number) {
  const poolAddress = chainId ? getContractAddress(chainId, 'AIMM_POOL') : undefined;

  return useReadContract({
    address: poolAddress as Address | undefined,
    abi: AIMM_ABI,
    functionName: 'registeredAssets',
    query: {
      enabled: !!poolAddress,
    },
  });
}

/**
 * Get complete state for all pool assets
 */
export function usePoolAssets(chainId?: number) {
  const { data: assetAddressesData } = useRegisteredAssets(chainId);
  const assetAddresses = Array.isArray(assetAddressesData) ? (assetAddressesData as Address[]) : undefined;
  const poolAddress = chainId ? getContractAddress(chainId, 'AIMM_POOL') : undefined;

  const contracts = assetAddresses?.map((token: Address) => [
    {
      address: poolAddress as Address,
      abi: AIMM_ABI,
      functionName: 'getAsset',
      args: [token],
    },
    {
      address: poolAddress as Address,
      abi: AIMM_ABI,
      functionName: 'getOraclePrice',
      args: [token],
    },
    {
      address: poolAddress as Address,
      abi: AIMM_ABI,
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
