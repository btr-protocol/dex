/**
 * Frontend configuration for supported chains and tokens
 * These are filtered lists from the SDK - the single source of truth
 */

// Supported chains (ordered by preference)
export const SUPPORTED_CHAINS_CONFIG = [
  31337,  // Anvil (local dev)
  1,      // Ethereum (L1)
  56,     // BNB Chain
  // 999,    // HyperEVM
  8453,   // Base
  42161,  // Arbitrum
  // 17000, // HyperEVM (uncomment when available)
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
