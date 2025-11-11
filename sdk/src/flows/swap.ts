/**
 * Swap flow for BAMM pools
 * @module @btr/dex-sdk/flows
 */

import type { Address, PublicClient, WalletClient, Hash } from 'viem';
import { erc20Abi } from 'viem';
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
  hash: Hash;
  amountOut?: bigint;
}

/**
 * Execute a swap in a BAMM pool
 */
export async function swap(
  publicClient: PublicClient,
  walletClient: WalletClient,
  poolAbi: any,
  params: SwapParams,
): Promise<SwapResult> {
  const account = walletClient.account;
  if (!account) {
    throw new Error('No account configured on wallet client');
  }

  // 1. Get quote
  const quote = await getSwapQuote(
    publicClient,
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
  const allowance = await publicClient.readContract({
    address: params.tokenIn,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [account.address, params.poolAddress],
  }) as bigint;

  // 4. Approve if needed
  if (allowance < params.amountIn) {
    console.log('Approving token...');
    const { request: approveRequest } = await publicClient.simulateContract({
      account,
      address: params.tokenIn,
      abi: erc20Abi,
      functionName: 'approve',
      args: [params.poolAddress, params.amountIn],
    });

    const approveHash = await walletClient.writeContract(approveRequest);
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
    console.log('Approval confirmed');
  }

  // 5. Execute swap
  const swapArgs = params.data
    ? [params.tokenIn, params.tokenOut, params.amountIn, minAmountOut, params.data]
    : [params.tokenIn, params.tokenOut, params.amountIn, minAmountOut];

  const { request } = await publicClient.simulateContract({
    account,
    address: params.poolAddress,
    abi: poolAbi,
    functionName: 'swap',
    args: swapArgs,
  });

  const hash = await walletClient.writeContract(request);
  console.log(`Swap transaction: ${hash}`);

  // Wait for confirmation
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`Swap confirmed. Gas used: ${receipt.gasUsed}`);

  // TODO: Parse logs to extract actual amountOut
  return { hash };
}

/**
 * Get quote for a swap
 */
export async function getSwapQuote(
  publicClient: PublicClient,
  poolAddress: Address,
  poolAbi: any,
  tokenIn: Address,
  tokenOut: Address,
  amountIn: bigint,
): Promise<SwapQuote> {
  // Read asset data for both tokens
  const [assetIn, assetOut] = await Promise.all([
    publicClient.readContract({
      address: poolAddress,
      abi: poolAbi,
      functionName: 'assets',
      args: [tokenIn],
    }) as Promise<any>,
    publicClient.readContract({
      address: poolAddress,
      abi: poolAbi,
      functionName: 'assets',
      args: [tokenOut],
    }) as Promise<any>,
  ]);

  // Simple constant product calculation (adjust based on actual BAMM mechanics)
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
