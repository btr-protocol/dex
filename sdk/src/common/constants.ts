/**
 * Common constants used across the SDK
 */

export const BPS_PRECISION = 10_000n;
export const PRECISION_1E18 = 10n ** 18n;
export const PRECISION_1E8 = 10n ** 8n;

// Default gas limits
export const DEFAULT_GAS_LIMIT = 500_000n;
export const SWAP_GAS_LIMIT = 300_000n;
export const DEPOSIT_GAS_LIMIT = 250_000n;
export const WITHDRAW_GAS_LIMIT = 250_000n;

// Time constants
export const ONE_MINUTE = 60;
export const FIVE_MINUTES = 300;
export const ONE_HOUR = 3600;
export const ONE_DAY = 86400;

// Oracle constants
export const DEFAULT_ORACLE_STALENESS = ONE_DAY; // 24 hours
export const DEFAULT_PRICE_DIVERGENCE_BPS = 500; // 5%

// Circuit breaker constants
export const DEFAULT_CB_CHECK_INTERVAL = FIVE_MINUTES * 1000; // 5 minutes in ms
export const DEFAULT_CB_COOLDOWN = ONE_HOUR; // 1 hour

// Supported chains (example)
export const SUPPORTED_CHAINS = {
  ETHEREUM: 1,
  ARBITRUM: 42161,
  OPTIMISM: 10,
  BASE: 8453,
} as const;

export type SupportedChainId = typeof SUPPORTED_CHAINS[keyof typeof SUPPORTED_CHAINS];
