/**
 * Swap flow for AIMM pools with batch support
 * @module @btr/sdk/flows
 */

import type { Address, Hex, Eip1193Provider, Abi } from '../eth/index.js';
import { Contract, ERC20_ABI, waitForTransaction } from '../eth/index.js';
import type { SwapQuote } from '../utils/constants.js';
import { applySlippage, calculatePriceImpact } from '../utils/business.js';
import { encodeB64, concat, pad, toHex } from '../utils/encoding.js';
import { logger } from '../utils/logger.js';

const log = logger.withContext('swap');

export interface SwapParams {
  poolAddress: Address;
  tokenIn: Address;
  tokenOut: Address;
  amountIn: bigint;
  minAmountOut?: bigint;
  slippageBps?: number; // Optional - will calculate minAmountOut if not provided
  deadline?: bigint;
  data?: `0x${string}`; // Optional hook data
}

export interface SwapResult {
  hash: Hex;
  amountOut?: bigint;
}

/**
 * Execute a swap in a AIMM pool
 */
export async function swap(
  provider: Eip1193Provider,
  account: Address,
  poolAbi: Abi,
  params: SwapParams,
): Promise<SwapResult> {
  if (!account) {
    throw new Error('No account provided');
  }

  const poolContract = new Contract({
    address: params.poolAddress,
    abi: poolAbi,
    provider,
    account,
  });

  // 1. Get quote
  const quote = await getSwapQuote(
    provider,
    params.poolAddress,
    poolAbi,
    params.tokenIn,
    params.tokenOut,
    params.amountIn,
  );

  log.info(`Swap quote: ${quote.amountOut} ${params.tokenOut}`);
  log.info(`Price impact: ${quote.priceImpact.toFixed(2)}%`);

  // 2. Calculate minAmountOut if not provided
  let minAmountOut = params.minAmountOut;
  if (!minAmountOut && params.slippageBps) {
    minAmountOut = applySlippage(quote.amountOut, params.slippageBps, true);
  } else if (!minAmountOut) {
    minAmountOut = 0n;
  }

  // 3. Check token allowance
  const tokenContract = new Contract({
    address: params.tokenIn,
    abi: ERC20_ABI,
    provider,
    account,
  });

  const allowance = await tokenContract.read('allowance', [account, params.poolAddress]) as bigint;

  // 4. Approve if needed
  if (allowance < params.amountIn) {
    log.info('Approving token...');
    const approveHash = await tokenContract.write('approve', [params.poolAddress, params.amountIn]);
    await waitForTransaction(provider, approveHash);
    log.info('Approval confirmed');
  }

  // 5. Execute swap
  const swapArgs = params.data
    ? [params.tokenIn, params.tokenOut, params.amountIn, minAmountOut, params.data]
    : [params.tokenIn, params.tokenOut, params.amountIn, minAmountOut];

  const hash = await poolContract.write('swap', swapArgs);
  log.info(`Swap transaction: ${hash}`);

  // Wait for confirmation
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const receipt = await waitForTransaction(provider, hash) as any;
  log.info(`Swap confirmed. Gas used: ${receipt.gasUsed}`);

  // TODO: Parse logs to extract actual amountOut
  return { hash };
}

/**
 * Get quote for a swap
 */
export async function getSwapQuote(
  provider: Eip1193Provider,
  poolAddress: Address,
  poolAbi: Abi,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
): Promise<SwapQuote> {
  const poolContract = new Contract({
    address: poolAddress,
    abi: poolAbi,
    provider,
  });

  // Read asset data for both tokens
  const [assetIn, assetOut] = await Promise.all([
    poolContract.read('assets', [tokenIn]) as Promise<any>,
    poolContract.read('assets', [tokenOut]) as Promise<any>,
  ]);

  // Simple constant product calculation (adjust based on actual AIMM mechanics)
  // In production, call a view function on the contract for accurate quotes
  const reserveIn: bigint = assetIn.reserves;
  const reserveOut: bigint = assetOut.reserves;

  // x * y = k
  const k: bigint = reserveIn * reserveOut;
  const newReserveIn: bigint = reserveIn + amountIn;
  const newReserveOut: bigint = k / newReserveIn;
  const amountOut: bigint = reserveOut - newReserveOut;

  // Calculate fee (example: 0.3%)
  const fee: bigint = (amountIn * 30n) / 10000n;

  // Calculate price impact
  const spotPrice: bigint = (reserveOut * 10n ** 18n) / reserveIn;
  const priceImpact: number = calculatePriceImpact(amountIn, amountOut, spotPrice);

  return {
    tokenIn,
    tokenOut,
    amountIn,
    amountOut,
    priceImpact,
    fee,
  };
}

// ─────────────────────────────────────────────────────────────
// Batch Swap Encoding (CoreV1-specific)
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
    const amountHex = pad(toHex(amountB64), 8);
    const reservedHex = '0x00000000' as Hex;
    return concat([addressHex, amountHex, reservedHex]);
  });

  return concat(encoded);
}

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
    const weightHex = pad(toHex(output.weightBps), 2);
    const slippageHex = pad(toHex(slippage), 2);
    const reservedHex = '0x0000000000000000' as Hex;
    return concat([addressHex, weightHex, slippageHex, reservedHex]);
  });

  return concat(encoded);
}

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
    const weightHex = pad(toHex(output.weightBps), 2);
    const reservedHex = '0x0000' as Hex;
    const minOutHex = pad(toHex(minOutB64), 8);
    return concat([addressHex, weightHex, reservedHex, minOutHex]);
  });

  return concat(encoded);
}

export interface BatchQuote {
  totalValueIn: bigint;      // Total input value in base terms (1e18)
  amountsOut: bigint[];      // Expected output per token (after impact)
  minAmountsOut: bigint[];   // With slippage applied
  avgSpreadBps: bigint;      // Value-weighted average spread
}

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
