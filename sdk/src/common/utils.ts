/**
 * Common utility functions
 */

import { type Address, type PublicClient, formatUnits, parseUnits } from 'viem';
import { BPS_PRECISION, PRECISION_1E18 } from './constants.js';

/**
 * Calculate percentage change in basis points
 */
export function calculateDivergenceBps(current: bigint, reference: bigint): number {
  if (reference === 0n) return 0;
  const diff = current > reference ? current - reference : reference - current;
  return Number((diff * BPS_PRECISION) / reference);
}

/**
 * Format token amount with decimals
 */
export function formatTokenAmount(amount: bigint, decimals: number): string {
  return formatUnits(amount, decimals);
}

/**
 * Parse token amount with decimals
 */
export function parseTokenAmount(amount: string, decimals: number): bigint {
  return parseUnits(amount, decimals);
}

/**
 * Calculate price impact in basis points
 */
export function calculatePriceImpact(
  amountIn: bigint,
  amountOut: bigint,
  spotPrice: bigint,
): number {
  // spotPrice is in 1e18
  const expectedOut = (amountIn * spotPrice) / PRECISION_1E18;
  if (expectedOut === 0n) return 0;

  const impact = expectedOut > amountOut ? expectedOut - amountOut : amountOut - expectedOut;
  return Number((impact * BPS_PRECISION) / expectedOut);
}

/**
 * Sleep utility
 */
export function sleep(ms: number): Promise<void> {
  return new Promise(resolve => setTimeout(resolve, ms));
}

/**
 * Retry with exponential backoff
 */
export async function retryWithBackoff<T>(
  fn: () => Promise<T>,
  maxRetries: number = 3,
  baseDelay: number = 1000,
): Promise<T> {
  let lastError: Error | undefined;

  for (let i = 0; i < maxRetries; i++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error as Error;
      if (i < maxRetries - 1) {
        const delay = baseDelay * Math.pow(2, i);
        await sleep(delay);
      }
    }
  }

  throw lastError;
}

/**
 * Check if address has code (is contract)
 */
export async function isContract(
  client: PublicClient,
  address: Address,
): Promise<boolean> {
  const code = await client.getCode({ address });
  return code !== undefined && code !== '0x';
}

/**
 * Validate address format
 */
export function isValidAddress(address: string): boolean {
  return /^0x[a-fA-F0-9]{40}$/.test(address);
}

/**
 * Calculate slippage-adjusted amount
 */
export function applySlippage(amount: bigint, slippageBps: number, isMin: boolean): bigint {
  const adjustment = (amount * BigInt(slippageBps)) / BPS_PRECISION;
  return isMin ? amount - adjustment : amount + adjustment;
}
