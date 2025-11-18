/**
 * Multi-chain RPC endpoints with fallbacks
 * Format: Primary RPC followed by fallbacks
 */

export const RPC_ENDPOINTS = {
  // Ethereum Mainnet (1)
  1: [
    'https://rpc.ankr.com/eth',
    'https://eth.llamarpc.com',
    'https://eth-mainnet.public.blastapi.io',
    'https://endpoints.omniatech.io/v1/eth/mainnet/public',
    'https://1rpc.io/eth',
    'https://cloudflare-eth.com',
    'https://ethereum.blockpi.network/v1/rpc/public',
    'https://eth.drpc.org'
  ],

  // Optimism (10)
  10: [
    'https://mainnet.optimism.io',
    'https://rpc.ankr.com/optimism',
    'https://optimism.llamarpc.com',
    'https://optimism-mainnet.public.blastapi.io',
    'https://1rpc.io/op',
    'https://endpoints.omniatech.io/v1/op/mainnet/public'
  ],

  // BNB Chain (56)
  56: [
    'https://bsc-dataseed.bnbchain.org',
    'https://rpc.ankr.com/bsc',
    'https://binance.llamarpc.com',
    'https://endpoints.omniatech.io/v1/bsc/mainnet/public',
    'https://bsc-mainnet.public.blastapi.io'
  ],

  // Gnosis (100)
  100: [
    'https://rpc.gnosischain.com',
    'https://rpc.ankr.com/gnosis',
    'https://gnosis-mainnet.public.blastapi.io',
    'https://endpoints.omniatech.io/v1/gnosis/mainnet/public',
    'https://1rpc.io/gnosis'
  ],

  // Polygon (137)
  137: [
    'https://rpc-mainnet.matic.network',
    'https://rpc.ankr.com/polygon',
    'https://endpoints.omniatech.io/v1/matic/mainnet/public',
    'https://polygon-mainnet.public.blastapi.io',
    'https://1rpc.io/matic'
  ],

  // Sonic (146)
  146: [
    'https://rpc.soniclabs.com',
    'https://rpc.ankr.com/sonic_mainnet',
    'https://sonic.drpc.org'
  ],

  // Blast (238)
  238: [
    'https://rpc.ankr.com/blast',
    'https://blastl2-mainnet.public.blastapi.io',
    'https://rpc.blastblockchain.com',
    'https://blast.drpc.org'
  ],

  // Fantom (250)
  250: [
    'https://rpc.fantom.network',
    'https://rpc.ankr.com/fantom',
    'https://fantom-mainnet.public.blastapi.io',
    'https://1rpc.io/ftm',
    'https://endpoints.omniatech.io/v1/fantom/mainnet/public'
  ],

  // Moonbeam (1284)
  1284: [
    'https://rpc.api.moonbeam.network',
    'https://rpc.ankr.com/moonbeam',
    'https://moonbeam.public.blastapi.io',
    'https://endpoints.omniatech.io/v1/moonbeam/mainnet/public'
  ],

  // Mantle (5000)
  5000: [
    'https://rpc.mantle.xyz',
    'https://rpc.ankr.com/mantle',
    'https://mantle-mainnet.public.blastapi.io',
    'https://1rpc.io/mantle'
  ],

  // Base (8453)
  8453: [
    'https://mainnet.base.org',
    'https://base.llamarpc.com',
    'https://1rpc.io/base',
    'https://base-mainnet.public.blastapi.io',
    'https://endpoints.omniatech.io/v1/base/mainnet/public'
  ],

  // Arbitrum (42161)
  42161: [
    'https://arb1.arbitrum.io/rpc',
    'https://arbitrum.llamarpc.com',
    'https://rpc.ankr.com/arbitrum',
    'https://arbitrum-one.public.blastapi.io',
    'https://endpoints.omniatech.io/v1/arbitrum/one/public'
  ],

  // Avalanche (43114)
  43114: [
    'https://api.avax.network/ext/bc/C/rpc',
    'https://rpc.ankr.com/avalanche',
    'https://ava-mainnet.public.blastapi.io/ext/bc/C/rpc',
    'https://1rpc.io/avax/c',
    'https://endpoints.omniatech.io/v1/avax/mainnet/public'
  ],

  // Linea (59144)
  59144: [
    'https://rpc.linea.build',
    'https://1rpc.io/linea',
    'https://linea.drpc.org',
    'https://linea.blockpi.network/v1/rpc/public'
  ],

  // Scroll (534352)
  534352: [
    'https://rpc.scroll.io',
    'https://rpc.ankr.com/scroll',
    'https://scroll-mainnet.public.blastapi.io',
    'https://1rpc.io/scroll'
  ],

  // XRPL EVM Sidechain (1440002)
  1440002: [
    'https://rpc-evm-sidechain.xrpl.org'
  ],

  // Local Anvil (default for development)
  31337: [
    'http://localhost:8545'
  ]
} as const

export type SupportedChainId = keyof typeof RPC_ENDPOINTS

/**
 * Get RPC URL for a chain with automatic fallback
 * @param chainId Chain ID
 * @param index Fallback index (0 = primary)
 * @returns RPC URL
 */
export function getRpcUrl(chainId: SupportedChainId, index = 0): string {
  const rpcs = RPC_ENDPOINTS[chainId]
  return rpcs[index] || rpcs[0]
}

/**
 * Get all RPC URLs for a chain
 * @param chainId Chain ID
 * @returns Array of RPC URLs
 */
export function getAllRpcs(chainId: SupportedChainId): readonly string[] {
  return RPC_ENDPOINTS[chainId] || []
}

/**
 * Test RPC endpoint health
 * @param url RPC URL
 * @returns true if healthy
 */
export async function testRpc(url: string): Promise<boolean> {
  try {
    const response = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        method: 'eth_blockNumber',
        params: [],
        id: 1
      })
    })
    return response.ok
  } catch {
    return false
  }
}

/**
 * Find first healthy RPC for a chain
 * @param chainId Chain ID
 * @returns Healthy RPC URL
 */
export async function getHealthyRpc(chainId: SupportedChainId): Promise<string> {
  const rpcs = getAllRpcs(chainId)

  for (const rpc of rpcs) {
    if (await testRpc(rpc)) {
      return rpc
    }
  }

  // Fallback to first RPC if none are healthy
  return rpcs[0]
}
