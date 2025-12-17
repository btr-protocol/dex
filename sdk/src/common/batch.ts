/**
 * Batch swap encoding utilities for CoreV1
 * @module @btr/dex-sdk/common/batch
 */

import { type Address, type Hex, concat, pad, toHex } from 'viem';

// ─────────────────────────────────────────────────────────────
// B64 Encoding (52/5/7 format)
// ─────────────────────────────────────────────────────────────

const B64_MANTISSA_BITS = 52n;
const B64_MAX_MANTISSA = (1n << B64_MANTISSA_BITS) - 1n;
const EXPONENT_BIAS = 64n;

/**
 * Encode amount to B64 format (52-bit mantissa, 5-bit decimals, 7-bit exponent)
 * @param amount - Raw token amount as bigint
 * @param decimals - Token decimals (0-31)
 * @returns B64 encoded value as bigint (fits in uint64)
 */
export function encodeB64(amount: bigint, decimals: number): bigint {
  if (amount === 0n) throw new Error('Cannot encode zero');
  if (decimals > 31) throw new Error('Decimals must be <= 31');

  let mant = amount;
  let exponent = 0n;

  // Normalize mantissa to fit in 52 bits
  while (mant > B64_MAX_MANTISSA) {
    mant = (mant + 5n) / 10n; // Round
    exponent++;
  }

  // Scale up if too small
  const minMantissa = B64_MAX_MANTISSA / 10n;
  while (mant < minMantissa && exponent > -64n) {
    mant *= 10n;
    exponent--;
  }

  if (exponent < -64n || exponent > 63n) throw new Error('Exponent overflow');

  // Pack: mantissa(52) | decimals(5) | biasedExp(7)
  const biasedExp = exponent + EXPONENT_BIAS;
  return (mant << 12n) | (BigInt(decimals) << 7n) | biasedExp;
}

/**
 * Decode B64 to raw amount
 * @param packed - B64 encoded value
 * @param targetDecimals - Target decimal precision
 * @returns Decoded amount as bigint
 */
export function decodeB64(packed: bigint, targetDecimals: number): bigint {
  if (packed === 0n) throw new Error('Cannot decode zero');

  const mant = packed >> 12n;
  const storedDecimals = Number((packed >> 7n) & 0x1fn);
  const exponent = (packed & 0x7fn) - EXPONENT_BIAS;

  const totalShift = exponent + BigInt(targetDecimals - storedDecimals);

  if (totalShift >= 0n) {
    return mant * 10n ** totalShift;
  } else {
    return mant / 10n ** -totalShift;
  }
}

// ─────────────────────────────────────────────────────────────
// Batch Input Encoding (shared by quote and swap)
// ─────────────────────────────────────────────────────────────

export interface BatchInput {
  token: Address;
  amount: bigint;
  decimals: number;
}

/**
 * Encode batch inputs for quoteBatchSwap/batchSwap
 * Format: 32 bytes each = [address(20) | uint64 amountB64(8) | uint32 reserved(4)]
 */
export function encodeBatchInputs(inputs: BatchInput[]): Hex {
  if (inputs.length === 0 || inputs.length > 8) {
    throw new Error('Inputs must be 1-8 tokens');
  }

  const encoded = inputs.map((input) => {
    const amountB64 = encodeB64(input.amount, input.decimals);
    // Pack: address (20 bytes) | amountB64 (8 bytes) | reserved (4 bytes)
    const addressHex = input.token.toLowerCase() as Hex;
    const amountHex = pad(toHex(amountB64), { size: 8 });
    const reservedHex = '0x00000000' as Hex;
    return concat([addressHex, amountHex, reservedHex]);
  });

  return concat(encoded);
}

// ─────────────────────────────────────────────────────────────
// Quote Output Encoding (for quoteBatchSwap)
// ─────────────────────────────────────────────────────────────

export interface QuoteOutput {
  token: Address;
  weightBps: number; // 0-10000 (100% = 10000)
  slippageBps?: number; // Default 50 (0.5%)
}

/**
 * Encode batch outputs for quoteBatchSwap
 * Format: 32 bytes each = [address(20) | uint16 weightBps(2) | uint16 slippageBps(2) | uint64 reserved(8)]
 */
export function encodeBatchQuoteOutputs(outputs: QuoteOutput[]): Hex {
  if (outputs.length === 0 || outputs.length > 8) {
    throw new Error('Outputs must be 1-8 tokens');
  }

  // Validate weights sum to 10000
  const weightSum = outputs.reduce((sum, o) => sum + o.weightBps, 0);
  if (weightSum !== 10000) {
    throw new Error(`Weights must sum to 10000, got ${weightSum}`);
  }

  const encoded = outputs.map((output) => {
    const slippage = output.slippageBps ?? 50; // Default 0.5%
    // Pack: address (20 bytes) | weightBps (2 bytes) | slippageBps (2 bytes) | reserved (8 bytes)
    const addressHex = output.token.toLowerCase() as Hex;
    const weightHex = pad(toHex(output.weightBps), { size: 2 });
    const slippageHex = pad(toHex(slippage), { size: 2 });
    const reservedHex = '0x0000000000000000' as Hex;
    return concat([addressHex, weightHex, slippageHex, reservedHex]);
  });

  return concat(encoded);
}

// ─────────────────────────────────────────────────────────────
// Swap Output Encoding (for batchSwap)
// ─────────────────────────────────────────────────────────────

export interface SwapOutput {
  token: Address;
  weightBps: number; // 0-10000 (100% = 10000)
  minAmountOut: bigint; // Minimum output (from quote)
  decimals: number;
}

/**
 * Encode batch outputs for batchSwap
 * Format: 32 bytes each = [address(20) | uint16 weightBps(2) | uint16 reserved(2) | uint64 minOutB64(8)]
 */
export function encodeBatchSwapOutputs(outputs: SwapOutput[]): Hex {
  if (outputs.length === 0 || outputs.length > 8) {
    throw new Error('Outputs must be 1-8 tokens');
  }

  // Validate weights sum to 10000
  const weightSum = outputs.reduce((sum, o) => sum + o.weightBps, 0);
  if (weightSum !== 10000) {
    throw new Error(`Weights must sum to 10000, got ${weightSum}`);
  }

  const encoded = outputs.map((output) => {
    const minOutB64 = encodeB64(output.minAmountOut, output.decimals);
    // Pack: address (20 bytes) | weightBps (2 bytes) | reserved (2 bytes) | minOutB64 (8 bytes)
    const addressHex = output.token.toLowerCase() as Hex;
    const weightHex = pad(toHex(output.weightBps), { size: 2 });
    const reservedHex = '0x0000' as Hex;
    const minOutHex = pad(toHex(minOutB64), { size: 8 });
    return concat([addressHex, weightHex, reservedHex, minOutHex]);
  });

  return concat(encoded);
}

// ─────────────────────────────────────────────────────────────
// Result Types (matching LibBatchPricing.BatchQuote)
// ─────────────────────────────────────────────────────────────

export interface BatchQuote {
  totalValueIn: bigint;      // Total input value in base terms (1e18)
  amountsOut: bigint[];      // Expected output per token (after impact)
  minAmountsOut: bigint[];   // With slippage applied
  avgSpreadBps: bigint;      // Value-weighted average spread
}

// ─────────────────────────────────────────────────────────────
// Helper Functions
// ─────────────────────────────────────────────────────────────

/**
 * Helper to build equal-weight quote outputs
 */
export function equalWeightQuoteOutputs(tokens: Address[]): QuoteOutput[] {
  const weight = Math.floor(10000 / tokens.length);
  const remainder = 10000 - weight * tokens.length;

  return tokens.map((token, i) => ({
    token,
    weightBps: i === 0 ? weight + remainder : weight,
  }));
}

/**
 * Convert quote results to swap outputs
 * @param quoteOutputs - The quote output config
 * @param minAmountsOut - Minimum amounts from quoteBatchSwap
 * @param decimals - Token decimals for each output
 */
export function quoteToSwapOutputs(
  quoteOutputs: QuoteOutput[],
  minAmountsOut: bigint[],
  decimals: number[],
): SwapOutput[] {
  if (quoteOutputs.length !== minAmountsOut.length || quoteOutputs.length !== decimals.length) {
    throw new Error('Array length mismatch');
  }

  return quoteOutputs.map((q, i) => ({
    token: q.token,
    weightBps: q.weightBps,
    minAmountOut: minAmountsOut[i],
    decimals: decimals[i],
  }));
}

/**
 * Helper to build proportional quote outputs from target amounts
 */
export function proportionalQuoteOutputs(
  targets: { token: Address; targetAmount: bigint; price: bigint }[],
): QuoteOutput[] {
  // Calculate values
  const values = targets.map((t) => (t.targetAmount * t.price) / 10n ** 18n);
  const totalValue = values.reduce((a, b) => a + b, 0n);

  if (totalValue === 0n) throw new Error('Total value is zero');

  // Convert to weights (ensure sum = 10000)
  let weightSum = 0;
  const weights = values.map((v) => {
    const w = Number((v * 10000n) / totalValue);
    weightSum += w;
    return w;
  });

  // Adjust first weight for rounding
  weights[0] += 10000 - weightSum;

  return targets.map((t, i) => ({
    token: t.token,
    weightBps: weights[i],
  }));
}

