/**
 * Contract addresses by chain ID
 *
 * Update these addresses after deployment
 */

export const CONTRACTS = {
  // Localhost (Anvil)
  31337: {
    BAMM_FACTORY: '0x0000000000000000000000000000000000000000' as `0x${string}`,
    BAMM_POOL: '0x0000000000000000000000000000000000000000' as `0x${string}`,
    WETH: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' as `0x${string}`,
    USDC: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48' as `0x${string}`,
  },

  // Ethereum Mainnet
  1: {
    BAMM_FACTORY: '0x0000000000000000000000000000000000000000' as `0x${string}`,
    BAMM_POOL: '0x0000000000000000000000000000000000000000' as `0x${string}`,
    WETH: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2' as `0x${string}`,
    USDC: '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48' as `0x${string}`,
  }
} as const

export type SupportedChainId = keyof typeof CONTRACTS

/**
 * Get contract address for current chain
 * @param chainId Chain ID
 * @param contractName Contract name
 */
export function getContractAddress(
  chainId: number,
  contractName: keyof typeof CONTRACTS[SupportedChainId]
): `0x${string}` | undefined {
  const chain = chainId as SupportedChainId
  return CONTRACTS[chain]?.[contractName]
}

/**
 * Common token addresses
 */
export const TOKENS = {
  WETH: {
    symbol: 'WETH',
    name: 'Wrapped Ether',
    decimals: 18
  },
  USDC: {
    symbol: 'USDC',
    name: 'USD Coin',
    decimals: 6
  },
  USDT: {
    symbol: 'USDT',
    name: 'Tether USD',
    decimals: 6
  },
  DAI: {
    symbol: 'DAI',
    name: 'Dai Stablecoin',
    decimals: 18
  }
} as const

export type TokenSymbol = keyof typeof TOKENS
