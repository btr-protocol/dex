/**
 * Swap flow for AIMM pools
 * @module @btr/dex-sdk/flows
 */

import type { Address, Hex, Eip1193Provider, Abi } from '../eth/index.js';
import { Contract, ERC20_ABI, waitForTransaction } from '../eth/index.js';
import { type SwapQuote } from '../common/types.js';
import { applySlippage, calculatePriceImpact } from '../common/utils.js';

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

  console.log(`Swap quote: ${quote.amountOut} ${params.tokenOut}`);
  console.log(`Price impact: ${quote.priceImpact.toFixed(2)}%`);

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
  });

  const allowance = await tokenContract.read('allowance', [account, params.poolAddress]) as bigint;

  // 4. Approve if needed
  if (allowance < params.amountIn) {
    console.log('Approving token...');
    const approveHash = await tokenContract.write('approve', [params.poolAddress, params.amountIn], { from: account });
    await waitForTransaction(provider, approveHash);
    console.log('Approval confirmed');
  }

  // 5. Execute swap
  const swapArgs = params.data
    ? [params.tokenIn, params.tokenOut, params.amountIn, minAmountOut, params.data]
    : [params.tokenIn, params.tokenOut, params.amountIn, minAmountOut];

  const hash = await poolContract.write('swap', swapArgs, { from: account });
  console.log(`Swap transaction: ${hash}`);

  // Wait for confirmation
  const receipt = await waitForTransaction(provider, hash);
  console.log(`Swap confirmed. Gas used: ${receipt.gasUsed}`);

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
