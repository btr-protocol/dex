/**
 * Common constants and types used across the SDK
 */

import type { Address } from '../eth/index.js';

// ─────────────────────────────────────────────────────────────
// Constants
// ─────────────────────────────────────────────────────────────

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

// ─────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────

export type TokenAddress = Address;
export type PoolAddress = Address;

export interface TokenInfo {
  address: TokenAddress;
  symbol: string;
  name: string;
  decimals: number;
}

export interface PoolAsset {
  reserves: bigint;
  fastTWAP: bigint;
  slowTWAP: bigint;
  fastVolatility: number;
  slowVolatility: number;
  targetAllocation: number;
  segments: number;
  isActive: boolean;
  isPaused: boolean;
  isFrozen: boolean;
  hooks: Address;
  lastOracleUpdate: number;
}

export interface SwapQuote {
  tokenIn: TokenAddress;
  tokenOut: TokenAddress;
  amountIn: bigint;
  amountOut: bigint;
  priceImpact: number;
  fee: bigint;
}

export interface OraclePrice {
  price: bigint;
  timestamp: number;
  symbol: string;
}

export interface CircuitBreakerConfig {
  maxDivergence: number; // in basis points
  checkInterval: number; // in milliseconds
  cooldownPeriod: number; // in seconds
}

export interface GuardianConfig extends CircuitBreakerConfig {
  poolAddress: PoolAddress;
  assets: TokenAddress[];
  referenceOracle: string; // e.g., 'binance', 'chainlink'
}

/**
 * Contract addresses for a BTR DEX deployment
 * These should be injected at build time and remain consistent across all environments
 */
export interface ContractAddresses {
  factory: Address; // Factory contract for creating pools
  pool: Address; // Main AIMM pool contract
  usdc: Address; // USDC token contract
  wbtc: Address; // WBTC token contract
  eth: Address; // ETH/WETH token contract
  deployer: Address; // Deployer/admin address
}
