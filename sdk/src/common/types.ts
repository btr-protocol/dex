/**
 * Common types used across the SDK
 */

import type { Address } from '../eth/index.js';

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
  pool: Address; // Main BAMM pool contract
  usdc: Address; // USDC token contract
  wbtc: Address; // WBTC token contract
  eth: Address; // ETH/WETH token contract
  deployer: Address; // Deployer/admin address
}
