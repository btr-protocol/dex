/**
 * Frontend configuration for supported chains and tokens
 * These are filtered lists from the SDK - the single source of truth
 */

// Supported chains (ordered by preference)
// Includes both mainnet and testnet chains
export const SUPPORTED_CHAINS_CONFIG = [
  // Local / Dev
  31337,     // Anvil (local dev)

  // Mainnets
  1,         // Ethereum (L1)
  56,        // BNB Chain
  8453,      // Base
  42161,     // Arbitrum
  // 999,    // HyperEVM (uncomment when live)

  // Testnets
  11155111,  // Ethereum Sepolia
  97,        // BNB Chain Testnet
  84532,     // Base Sepolia
  421614,    // Arbitrum Sepolia
  // 998,       // HyperEVM Testnet
] as const;

// Supported tokens (ordered by preference)
// Includes both canonical tokens (ETH, BTC) and their wrapped versions
export const SUPPORTED_TOKENS_CONFIG = [
  'ETH',
  'BTC',
  'WETH',
  'WBTC',
  'TBTC',
  'CBBTC',
  'USDC',
  'USDT',
  'USDE',
  'PAXG',
  'XAUT',
  'AAVE',
  'PENDLE',
  'ENA',
  'UNI',
  'CAKE',
  'CRV',
  'LINK',
  'ZRO',
] as const;

export type SupportedChainId = typeof SUPPORTED_CHAINS_CONFIG[number];
export type SupportedToken = typeof SUPPORTED_TOKENS_CONFIG[number];

// Helper to check if a chain is supported
export function isChainSupported(chainId: number): chainId is SupportedChainId {
  return SUPPORTED_CHAINS_CONFIG.includes(chainId as SupportedChainId);
}

// Helper to check if a token is supported
export function isTokenSupported(symbol: string): symbol is SupportedToken {
  return SUPPORTED_TOKENS_CONFIG.includes(symbol as SupportedToken);
}

// Get filtered tokens for a specific chain
export function getSupportedTokensForChain(chainId: number): SupportedToken[] {
  if (!isChainSupported(chainId)) return [];

  // In the future, this could be more granular (e.g., different tokens per chain)
  // For now, return all supported tokens that are available on the chain
  return SUPPORTED_TOKENS_CONFIG.filter(() => {
    // Token availability on chain is determined by SDK's TOKEN_ADDRESSES
    // This filter will be applied at component level using SDK data
    return true;
  });
}
