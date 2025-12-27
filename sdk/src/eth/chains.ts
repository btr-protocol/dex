/**
 * Chain Configuration - Canonical Source of Truth
 *
 * This file is the single source of truth for chain metadata.
 * The frontend imports from here - do not duplicate in front/.
 */

import type { Address } from './types';

export type { Address } from './types';

// ─────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────

export const MULTICALL3_ADDRESS: Address = '0xcA11bde05977b3631167028862bE2a173976CA11';

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export interface ChainConfig {
  id: number;
  name: string;
  icon?: string;      // Optional override. Default: /networks/{name-slugged}.svg
  rpcUrls: readonly string[];
  nativeCurrency: {
    name: string;
    symbol: string;
    decimals: number;
  };
  blockExplorerUrls?: readonly string[];
  wrappedNative?: Address;
  multicall3?: Address;
  testnet?: boolean;
}

/**
 * Get chain icon path (auto-computed from name or overridden)
 */
export function getChainIcon(chainId: number): string {
  const chain = CHAINS[chainId];
  if (!chain) return '/networks/unknown.svg';

  // Use override if specified
  if (chain.icon) return chain.icon;

  // Auto-compute from name: "BNB Chain" → "/networks/bnb-chain.svg"
  const slug = chain.name.toLowerCase().replace(/\s+/g, '-');
  return `/networks/${slug}.svg`;
}

// ─────────────────────────────────────────────────────────────
// Chain Configurations
// ─────────────────────────────────────────────────────────────

export const CHAINS: Record<number, ChainConfig> = {
  // ═══════════════════════════════════════════════════════════
  // Layer 1s
  // ═══════════════════════════════════════════════════════════

  1: {
    id: 1,
    name: 'Ethereum',
    rpcUrls: [
      'https://eth.llamarpc.com',
      'https://rpc.ankr.com/eth',
      'https://eth-mainnet.public.blastapi.io',
      'https://1rpc.io/eth',
      'https://cloudflare-eth.com',
      'https://eth.drpc.org',
    ],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://etherscan.io'],
    wrappedNative: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
    multicall3: MULTICALL3_ADDRESS,
  },

  56: {
    id: 56,
    name: 'BNB Chain',
    rpcUrls: [
      'https://bsc-dataseed.binance.org',
      'https://rpc.ankr.com/bsc',
      'https://binance.llamarpc.com',
      'https://bsc-mainnet.public.blastapi.io',
    ],
    nativeCurrency: { name: 'Build N Build', symbol: 'BNB', decimals: 18 },
    blockExplorerUrls: ['https://bscscan.com'],
    wrappedNative: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
    multicall3: MULTICALL3_ADDRESS,
  },

  100: {
    id: 100,
    name: 'Gnosis',
    rpcUrls: [
      'https://rpc.gnosischain.com',
      'https://rpc.ankr.com/gnosis',
      'https://gnosis-mainnet.public.blastapi.io',
      'https://1rpc.io/gnosis',
    ],
    nativeCurrency: { name: 'xDai', symbol: 'XDAI', decimals: 18 },
    blockExplorerUrls: ['https://gnosisscan.io'],
    wrappedNative: '0xe91D153E0b41518A2Ce8Dd3D7944Fa863463a97d',
    multicall3: MULTICALL3_ADDRESS,
  },

  137: {
    id: 137,
    name: 'Polygon',
    rpcUrls: [
      'https://polygon-rpc.com',
      'https://rpc.ankr.com/polygon',
      'https://polygon-mainnet.public.blastapi.io',
      'https://1rpc.io/matic',
    ],
    nativeCurrency: { name: 'Polygon', symbol: 'POL', decimals: 18 },
    blockExplorerUrls: ['https://polygonscan.com'],
    wrappedNative: '0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270',
    multicall3: MULTICALL3_ADDRESS,
  },

  43114: {
    id: 43114,
    name: 'Avalanche C-Chain',
    icon: '/networks/avalanche.svg',
    rpcUrls: [
      'https://api.avax.network/ext/bc/C/rpc',
      'https://rpc.ankr.com/avalanche',
      'https://ava-mainnet.public.blastapi.io/ext/bc/C/rpc',
      'https://1rpc.io/avax/c',
    ],
    nativeCurrency: { name: 'Avalanche', symbol: 'AVAX', decimals: 18 },
    blockExplorerUrls: ['https://snowtrace.io'],
    wrappedNative: '0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7',
    multicall3: MULTICALL3_ADDRESS,
  },

  // ═══════════════════════════════════════════════════════════
  // Layer 2s / Rollups
  // ═══════════════════════════════════════════════════════════

  10: {
    id: 10,
    name: 'Optimism',
    rpcUrls: [
      'https://mainnet.optimism.io',
      'https://rpc.ankr.com/optimism',
      'https://optimism.llamarpc.com',
      'https://1rpc.io/op',
    ],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://optimistic.etherscan.io'],
    wrappedNative: '0x4200000000000000000000000000000000000006',
    multicall3: MULTICALL3_ADDRESS,
  },

  42161: {
    id: 42161,
    name: 'Arbitrum One',
    icon: '/networks/arbitrum.svg',
    rpcUrls: [
      'https://arb1.arbitrum.io/rpc',
      'https://arbitrum.llamarpc.com',
      'https://rpc.ankr.com/arbitrum',
      'https://arbitrum-one.public.blastapi.io',
    ],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://arbiscan.io'],
    wrappedNative: '0x82aF49447d8a07e3bd95bd0d56f35241523fbab1',
    multicall3: MULTICALL3_ADDRESS,
  },

  8453: {
    id: 8453,
    name: 'Base',
    rpcUrls: [
      'https://mainnet.base.org',
      'https://base.llamarpc.com',
      'https://1rpc.io/base',
      'https://base-mainnet.public.blastapi.io',
    ],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://basescan.org'],
    wrappedNative: '0x4200000000000000000000000000000000000006',
    multicall3: MULTICALL3_ADDRESS,
  },

  59144: {
    id: 59144,
    name: 'Linea',
    rpcUrls: [
      'https://rpc.linea.build',
      'https://1rpc.io/linea',
      'https://linea.drpc.org',
    ],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://lineascan.build'],
    wrappedNative: '0xe5d7c2a44ffddf6b295a15c148167daaaf5cf34f',
    multicall3: MULTICALL3_ADDRESS,
  },

  5000: {
    id: 5000,
    name: 'Mantle',
    rpcUrls: [
      'https://rpc.mantle.xyz',
      'https://rpc.ankr.com/mantle',
      'https://mantle-mainnet.public.blastapi.io',
      'https://1rpc.io/mantle',
    ],
    nativeCurrency: { name: 'Mantle', symbol: 'MNT', decimals: 18 },
    blockExplorerUrls: ['https://mantlescan.xyz'],
    wrappedNative: '0xdeaddeaddeaddeaddeaddeaddeaddeaddead1111',
    multicall3: MULTICALL3_ADDRESS,
  },

  534352: {
    id: 534352,
    name: 'Scroll',
    rpcUrls: [
      'https://rpc.scroll.io',
      'https://rpc.ankr.com/scroll',
      'https://scroll-mainnet.public.blastapi.io',
      'https://1rpc.io/scroll',
    ],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://scrollscan.com'],
    wrappedNative: '0x5300000000000000000000000000000000000004',
    multicall3: MULTICALL3_ADDRESS,
  },

  324: {
    id: 324,
    name: 'zkSync Era',
    icon: '/networks/zksync.svg',
    rpcUrls: [
      'https://mainnet.era.zksync.io',
      'https://zksync.drpc.org',
    ],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://explorer.zksync.io'],
    wrappedNative: '0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91',
    multicall3: MULTICALL3_ADDRESS,
  },

  // ═══════════════════════════════════════════════════════════
  // Alt L1s / Emerging Chains
  // ═══════════════════════════════════════════════════════════

  14: {
    id: 14,
    name: 'Flare',
    rpcUrls: ['https://flare-api.flare.network/ext/C/rpc'],
    nativeCurrency: { name: 'Flare', symbol: 'FLR', decimals: 18 },
    blockExplorerUrls: ['https://flare-explorer.flare.network'],
    wrappedNative: '0x1D80c49BbBCd1C0911346656B529DF9E5C2F783d',
    multicall3: MULTICALL3_ADDRESS,
  },

  130: {
    id: 130,
    name: 'Unichain',
    rpcUrls: ['https://mainnet.unichain.org'],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://uniscan.xyz'],
    wrappedNative: '0x4200000000000000000000000000000000000006',
    multicall3: MULTICALL3_ADDRESS,
  },

  143: {
    id: 143,
    name: 'Monad',
    rpcUrls: ['https://rpc.monad.xyz'],
    nativeCurrency: { name: 'Monad', symbol: 'MON', decimals: 18 },
    blockExplorerUrls: ['https://monadvision.com'],
    wrappedNative: '0x760AfE86e5de5fa0Ee542fc7B7B713e1c5425701',
    multicall3: MULTICALL3_ADDRESS,
  },

  146: {
    id: 146,
    name: 'Sonic',
    rpcUrls: [
      'https://rpc.soniclabs.com',
      'https://rpc.ankr.com/sonic_mainnet',
      'https://sonic.drpc.org',
    ],
    nativeCurrency: { name: 'Sonic', symbol: 'S', decimals: 18 },
    blockExplorerUrls: ['https://sonicscan.org'],
    wrappedNative: '0x039e2fB66102314Ce7b64Ce5Ce3E5183bc94aD38',
    multicall3: MULTICALL3_ADDRESS,
  },

  480: {
    id: 480,
    name: 'World Chain',
    icon: '/networks/worldchain.svg',
    rpcUrls: ['https://worldchain-mainnet.g.alchemy.com/public'],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://worldscan.org'],
    wrappedNative: '0x4200000000000000000000000000000000000006',
    multicall3: MULTICALL3_ADDRESS,
  },

  999: {
    id: 999,
    name: 'HyperEVM',
    rpcUrls: ['https://rpc.hyperliquid.xyz/evm'],
    nativeCurrency: { name: 'Hyperliquid', symbol: 'HYPE', decimals: 18 },
    blockExplorerUrls: ['https://hyperevmscan.io'],
    wrappedNative: '0x5555555555555555555555555555555555555555',
    multicall3: MULTICALL3_ADDRESS,
  },

  1329: {
    id: 1329,
    name: 'Sei',
    rpcUrls: ['https://evm-rpc.sei-apis.com'],
    nativeCurrency: { name: 'Sei', symbol: 'SEI', decimals: 18 },
    blockExplorerUrls: ['https://seiscan.io'],
    wrappedNative: '0xE30feDd158A2e3b13e9badaeABaFc5516e95e8C7',
    multicall3: MULTICALL3_ADDRESS,
  },

  2741: {
    id: 2741,
    name: 'Abstract',
    rpcUrls: ['https://api.mainnet.abs.xyz'],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://abscan.org'],
    wrappedNative: '0x3439153eb7af838ad19d56e1571fbd09333c2809',
    multicall3: MULTICALL3_ADDRESS,
  },

  9745: {
    id: 9745,
    name: 'Plasma',
    icon: '/networks/plasma.svg',
    rpcUrls: ['https://rpc.plasma.to'],
    nativeCurrency: { name: 'Plasma', symbol: 'XPL', decimals: 18 },
    blockExplorerUrls: ['https://plasmascan.to'],
    wrappedNative: '0x6100E367285b01F48D07953803A2d8dCA5D19873',
    multicall3: MULTICALL3_ADDRESS,
  },

  42220: {
    id: 42220,
    name: 'Celo',
    icon: '/networks/celo.svg',
    rpcUrls: ['https://forno.celo.org'],
    nativeCurrency: { name: 'Celo', symbol: 'CELO', decimals: 18 },
    blockExplorerUrls: ['https://celoscan.io'],
    wrappedNative: '0x471EcE3750Da237f93B8E339c536989b8978a438',
    multicall3: MULTICALL3_ADDRESS,
  },

  747474: {
    id: 747474,
    name: 'Katana',
    icon: '/networks/katana.svg',
    rpcUrls: ['https://rpc.katana.network'],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://katanascan.com'],
    wrappedNative: '0xee7d8bcfb72bc1880d0cf19822eb0a2e6577ab62',
    multicall3: MULTICALL3_ADDRESS,
  },

  // ═══════════════════════════════════════════════════════════
  // Testnets / Dev
  // ═══════════════════════════════════════════════════════════

  31337: {
    id: 31337,
    name: 'Anvil',
    icon: '/networks/anvil.svg',
    rpcUrls: ['http://localhost:8545'],
    nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
    testnet: true,
  },

  11155111: {
    id: 11155111,
    name: 'Ethereum Sepolia Testnet',
    rpcUrls: [
      'https://sepolia.gateway.tenderly.co',
      'https://rpc.ankr.com/eth_sepolia',
      'https://ethereum-sepolia.publicnode.com',
    ],
    nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://sepolia.etherscan.io'],
    wrappedNative: '0x7b79995e5f793A07Bc00c21412e50Ecae098E7f9',
    multicall3: MULTICALL3_ADDRESS,
    testnet: true,
  },

  97: {
    id: 97,
    name: 'BNB Chain Testnet',
    rpcUrls: [
      'https://data-seed-prebsc-1-s1.binance.org:8545',
      'https://rpc.ankr.com/bsc_testnet_chapel',
    ],
    nativeCurrency: { name: 'Test BNB', symbol: 'tBNB', decimals: 18 },
    blockExplorerUrls: ['https://testnet.bscscan.com'],
    wrappedNative: '0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd',
    multicall3: MULTICALL3_ADDRESS,
    testnet: true,
  },

  84532: {
    id: 84532,
    name: 'Base Sepolia Testnet',
    rpcUrls: [
      'https://sepolia.base.org',
      'https://base-sepolia.public.blastapi.io',
    ],
    nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://sepolia.basescan.org'],
    wrappedNative: '0x4200000000000000000000000000000000000006',
    multicall3: MULTICALL3_ADDRESS,
    testnet: true,
  },

  421614: {
    id: 421614,
    name: 'Arbitrum Sepolia Testnet',
    rpcUrls: [
      'https://sepolia-rollup.arbitrum.io/rpc',
      'https://arbitrum-sepolia.public.blastapi.io',
    ],
    nativeCurrency: { name: 'Sepolia Ether', symbol: 'ETH', decimals: 18 },
    blockExplorerUrls: ['https://sepolia.arbiscan.io'],
    wrappedNative: '0x980B62Da83eFf3D4576C647993b0c1D7faf17c73',
    multicall3: MULTICALL3_ADDRESS,
    testnet: true,
  },

  998: {
    id: 998,
    name: 'HyperEVM Testnet',
    rpcUrls: ['https://rpc.hyperliquid-testnet.xyz/evm'],
    nativeCurrency: { name: 'Test Hyperliquid', symbol: 'HYPE', decimals: 18 },
    blockExplorerUrls: ['https://testnet.hyperevmscan.io'],
    wrappedNative: '0x5555555555555555555555555555555555555555',
    multicall3: MULTICALL3_ADDRESS,
    testnet: true,
  },

  80002: {
    id: 80002,
    name: 'Polygon Amoy Testnet',
    rpcUrls: [
      'https://rpc-amoy.polygon.technology',
      'https://polygon-amoy.public.blastapi.io',
    ],
    nativeCurrency: { name: 'Test POL', symbol: 'POL', decimals: 18 },
    blockExplorerUrls: ['https://amoy.polygonscan.com'],
    wrappedNative: '0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889',
    multicall3: MULTICALL3_ADDRESS,
    testnet: true,
  },

  43113: {
    id: 43113,
    name: 'Avalanche Fuji Testnet',
    icon: '/networks/avalanche.svg',
    rpcUrls: [
      'https://api.avax-test.network/ext/bc/C/rpc',
      'https://rpc.ankr.com/avalanche_fuji',
    ],
    nativeCurrency: { name: 'Test Avalanche', symbol: 'AVAX', decimals: 18 },
    blockExplorerUrls: ['https://testnet.snowtrace.io'],
    wrappedNative: '0xd00ae08403B9bbb9124bB305C09058E32C39A48c',
    multicall3: MULTICALL3_ADDRESS,
    testnet: true,
  },
};

// ─────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────

export type ChainId = keyof typeof CHAINS;

/**
 * Get chain config by ID
 */
export function getChain(id: number): ChainConfig | undefined {
  return CHAINS[id];
}

/**
 * Get RPC URL for chain (primary)
 */
export function getRpcUrl(chainId: number, index = 0): string | undefined {
  const chain = CHAINS[chainId];
  return chain?.rpcUrls[index] ?? chain?.rpcUrls[0];
}

/**
 * Get all RPC URLs for chain
 */
export function getAllRpcs(chainId: number): readonly string[] {
  return CHAINS[chainId]?.rpcUrls ?? [];
}

/**
 * Get block explorer URL for chain
 */
export function getExplorerUrl(chainId: number): string | undefined {
  return CHAINS[chainId]?.blockExplorerUrls?.[0];
}

/**
 * Get wrapped native token address
 */
export function getWrappedNative(chainId: number): Address | undefined {
  return CHAINS[chainId]?.wrappedNative;
}

/**
 * Get multicall3 address for chain
 */
export function getMulticall3(chainId: number): Address {
  return CHAINS[chainId]?.multicall3 ?? MULTICALL3_ADDRESS;
}

/**
 * Test RPC endpoint health
 */
export async function testRpc(url: string): Promise<boolean> {
  try {
    const res = await fetch(url, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', method: 'eth_blockNumber', params: [], id: 1 }),
    });
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Find first healthy RPC for chain
 */
export async function getHealthyRpc(chainId: number): Promise<string | undefined> {
  const rpcs = getAllRpcs(chainId);
  for (const rpc of rpcs) {
    if (await testRpc(rpc)) return rpc;
  }
  return rpcs[0];
}

/**
 * List all supported chain IDs
 */
export function getSupportedChainIds(): number[] {
  return Object.keys(CHAINS).map(Number);
}

/**
 * List all mainnet chain IDs (excluding testnets)
 */
export function getMainnetChainIds(): number[] {
  return Object.entries(CHAINS)
    .filter(([, c]) => !c.testnet)
    .map(([id]) => Number(id));
}

/**
 * Check if a chain is a testnet or local development network
 */
export function isTestOrLocalChain(chainId: number): boolean {
  const chain = CHAINS[chainId];
  if (!chain) return false;

  // Check testnet flag
  if (chain.testnet) return true;

  // Check name patterns for local dev networks
  const nameLower = chain.name.toLowerCase();
  const localPatterns = ['local', 'anvil', 'ganache', 'hardhat', 'truffle'];
  if (localPatterns.some(pattern => nameLower.includes(pattern))) return true;

  // Check for testnet in name
  if (chain.name.includes('Testnet')) return true;

  return false;
}

/**
 * Detect forked chain ID from Anvil RPC
 * Anvil can be queried for the forked chain ID via eth_chainId on the fork
 */
export async function detectAnvilFork(rpcUrl: string = 'http://localhost:8545'): Promise<number | null> {
  try {
    const response = await fetch(rpcUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        method: 'anvil_metadata',
        params: [],
        id: 1,
      }),
    });

    if (response.ok) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const data: any = await response.json();
      // Anvil metadata returns fork info
      return data.result?.forkChainId ? Number(data.result.forkChainId) : null;
    }

    // Fallback: try to get chain ID directly
    const chainIdResponse = await fetch(rpcUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0',
        method: 'eth_chainId',
        params: [],
        id: 1,
      }),
    });

    if (chainIdResponse.ok) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const chainIdData: any = await chainIdResponse.json();
      const chainId = parseInt(chainIdData.result, 16);
      // If it's not 31337, it might be a fork
      return chainId !== 31337 ? chainId : null;
    }

    return null;
  } catch {
    return null;
  }
}

/**
 * Get chain config for Anvil, with fork detection
 * If Anvil is forking a chain, returns the forked chain's metadata
 */
export async function getAnvilChainConfig(rpcUrl: string = 'http://localhost:8545'): Promise<ChainConfig> {
  const forkedChainId = await detectAnvilFork(rpcUrl);

  if (forkedChainId && CHAINS[forkedChainId]) {
    // Return forked chain config but with Anvil's RPC URL and ID
    const forkedChain = CHAINS[forkedChainId];
    return {
      ...forkedChain,
      id: 31337,
      name: `Anvil (${forkedChain.name} Fork)`,
      rpcUrls: [rpcUrl],
      testnet: true,
    };
  }

  // Return default Anvil config
  return CHAINS[31337];
}

// ─────────────────────────────────────────────────────────────
// Simplified Chain Info (for UI components)
// ─────────────────────────────────────────────────────────────

export interface ChainInfo {
  id: number;
  name: string;
  icon: string;
  nativeSymbol: string;
}

/**
 * Get simplified chain info for UI display
 */
export function getChainInfo(chainId: number): ChainInfo | undefined {
  const chain = CHAINS[chainId];
  if (!chain) return undefined;
  return {
    id: chain.id,
    name: chain.name,
    icon: chain.icon || getChainIcon(chainId),
    nativeSymbol: chain.nativeCurrency.symbol,
  };
}

/**
 * Get all chains as simplified info objects
 */
export function getAllChainInfo(): Record<number, ChainInfo> {
  const result: Record<number, ChainInfo> = {};
  for (const [id, chain] of Object.entries(CHAINS)) {
    result[Number(id)] = {
      id: chain.id,
      name: chain.name,
      icon: chain.icon || getChainIcon(Number(id)),
      nativeSymbol: chain.nativeCurrency.symbol,
    };
  }
  return result;
}
