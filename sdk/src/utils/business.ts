/**
 * Business logic utilities - DeFi operations, pricing, slippage
 */

import { formatUnits, parseUnits } from './format.js';
import { BPS_PRECISION, PRECISION_1E18 } from './constants.js';

// ─────────────────────────────────────────────────────────────
// Divergence & Price Impact
// ─────────────────────────────────────────────────────────────

/**
 * Calculate percentage change in basis points
 */
export function calculateDivergenceBps(current: bigint, reference: bigint): number {
  if (reference === 0n) return 0;
  const diff = current > reference ? current - reference : reference - current;
  return Number((diff * BPS_PRECISION) / reference);
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

// ─────────────────────────────────────────────────────────────
// Slippage
// ─────────────────────────────────────────────────────────────

/**
 * Calculate slippage-adjusted amount
 */
export function applySlippage(amount: bigint, slippageBps: number, isMin: boolean): bigint {
  const adjustment = (amount * BigInt(slippageBps)) / BPS_PRECISION;
  return isMin ? amount - adjustment : amount + adjustment;
}

// ─────────────────────────────────────────────────────────────
// Token Operations
// ─────────────────────────────────────────────────────────────

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
