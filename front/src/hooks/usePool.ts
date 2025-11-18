import { useReadContract, useBlockNumber } from 'wagmi'
import { formatUnits } from 'viem'

// BAMM ABI subset - add full ABI when ready
const BAMM_ABI = [
  {
    name: 'getAsset',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'reserves', type: 'uint128' },
          { name: 'liabilities', type: 'uint128' },
          { name: 'depositFeeBps', type: 'uint16' },
          { name: 'withdrawalFeeBps', type: 'uint16' },
          { name: 'protocolFeeBps', type: 'uint16' },
          { name: 'flashFeeBps', type: 'uint16' },
          { name: 'decimals', type: 'uint8' },
          { name: 'segmentCount', type: 'uint8' },
          { name: 'mainOracle', type: 'address' },
          { name: 'fallbackOracle', type: 'address' }
        ]
      }
    ]
  },
  {
    name: 'registeredAssets',
    type: 'function',
    stateMutability: 'view',
    inputs: [{ name: 'index', type: 'uint256' }],
    outputs: [{ name: 'token', type: 'address' }]
  },
  {
    name: 'baseToken',
    type: 'function',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'address' }]
  }
] as const

export interface Asset {
  reserves: bigint
  liabilities: bigint
  depositFeeBps: number
  withdrawalFeeBps: number
  protocolFeeBps: number
  flashFeeBps: number
  decimals: number
  segmentCount: number
  mainOracle: string
  fallbackOracle: string
}

export interface PoolMetrics {
  totalValueLocked: string
  totalLiabilities: string
  coverageRatio: number
  utilization: number
}

/**
 * Hook to read pool state from BAMM contract
 * @param poolAddress BAMM pool contract address
 * @param tokenAddress Asset token address
 */
export function usePoolAsset(poolAddress?: `0x${string}`, tokenAddress?: `0x${string}`) {
  const { data: asset, isLoading, error, refetch } = useReadContract({
    address: poolAddress,
    abi: BAMM_ABI,
    functionName: 'getAsset',
    args: tokenAddress ? [tokenAddress] : undefined,
    query: {
      enabled: !!poolAddress && !!tokenAddress,
      refetchInterval: 12_000 // Refetch every block (~12s)
    }
  })

  const formatAsset = (raw: any): Asset | null => {
    if (!raw) return null
    return {
      reserves: raw.reserves,
      liabilities: raw.liabilities,
      depositFeeBps: Number(raw.depositFeeBps),
      withdrawalFeeBps: Number(raw.withdrawalFeeBps),
      protocolFeeBps: Number(raw.protocolFeeBps),
      flashFeeBps: Number(raw.flashFeeBps),
      decimals: Number(raw.decimals),
      segmentCount: Number(raw.segmentCount),
      mainOracle: raw.mainOracle,
      fallbackOracle: raw.fallbackOracle
    }
  }

  const formattedAsset = formatAsset(asset)

  // Calculate metrics
  const metrics: PoolMetrics | null = formattedAsset ? {
    totalValueLocked: formatUnits(formattedAsset.reserves, formattedAsset.decimals),
    totalLiabilities: formatUnits(formattedAsset.liabilities, formattedAsset.decimals),
    coverageRatio: formattedAsset.liabilities > 0n
      ? Number((formattedAsset.reserves * 10000n) / formattedAsset.liabilities) / 100
      : 100,
    utilization: formattedAsset.reserves > 0n
      ? Number((formattedAsset.liabilities * 10000n) / formattedAsset.reserves) / 100
      : 0
  } : null

  return {
    asset: formattedAsset,
    metrics,
    isLoading,
    error,
    refetch
  }
}

/**
 * Hook to get base token address
 * @param poolAddress BAMM pool contract address
 */
export function useBaseToken(poolAddress?: `0x${string}`) {
  const { data: baseToken } = useReadContract({
    address: poolAddress,
    abi: BAMM_ABI,
    functionName: 'baseToken',
    query: {
      enabled: !!poolAddress
    }
  })

  return baseToken as `0x${string}` | undefined
}

/**
 * Hook to watch for new blocks
 */
export function useBlockWatcher() {
  const { data: blockNumber } = useBlockNumber({ watch: true })
  return blockNumber
}
