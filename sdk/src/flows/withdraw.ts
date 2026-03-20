/**
 * Withdraw flow for AIMM pools
 * @module @btr/sdk/flows
 */

import type { Address, Hex, Eip1193Provider, Abi } from '../eth/index.js';
import { Contract, waitForTransaction } from '../eth/index.js';
import { applySlippage } from '../utils/business.js';
import { logger } from '../utils/logger.js';

const log = logger.withContext('withdraw');

export interface WithdrawParams {
  poolAddress: Address;
  token: Address;
  lpTokens: bigint;
  minAmount?: bigint;
  slippageBps?: number; // Optional - will calculate minAmount if not provided
  deadline?: bigint;
}

export interface WithdrawResult {
  hash: Hex;
  amountReceived?: bigint;
}

/**
 * Execute a withdrawal from a AIMM pool
 */
export async function withdraw(
  provider: Eip1193Provider,
  account: Address,
  poolAbi: Abi,
  params: WithdrawParams,
): Promise<WithdrawResult> {
  if (!account) {
    throw new Error('No account provided');
  }

  const poolContract = new Contract({
    address: params.poolAddress,
    abi: poolAbi,
    provider,
    account,
  });

  // 1. Get quote for withdrawal
  const expectedAmount = await getWithdrawQuote(
    provider,
    params.poolAddress,
    poolAbi,
    params.token,
    params.lpTokens,
  );

  log.info(`Withdraw quote: ${expectedAmount} ${params.token}`);

  // 2. Calculate minAmount if not provided
  let minAmount = params.minAmount;
  if (!minAmount && params.slippageBps) {
    minAmount = applySlippage(expectedAmount, params.slippageBps, true);
  } else if (!minAmount) {
    minAmount = 0n;
  }

  // 3. Check LP token balance
  const lpBalance = await poolContract.read('balanceOf', [account]) as bigint;

  if (lpBalance < params.lpTokens) {
    throw new Error(`Insufficient LP tokens. Have ${lpBalance}, need ${params.lpTokens}`);
  }

  // 4. Execute withdrawal
  const hash = await poolContract.write('withdraw', [params.token, params.lpTokens, minAmount]);
  log.info(`Withdraw transaction: ${hash}`);

  // Wait for confirmation
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const receipt = await waitForTransaction(provider, hash) as any;
  log.info(`Withdraw confirmed. Gas used: ${receipt.gasUsed}`);

  // TODO: Parse logs to extract actual amount received
  return { hash };
}

/**
 * Get quote for a withdrawal (how many tokens will be received)
 */
export async function getWithdrawQuote(
  provider: Eip1193Provider,
  poolAddress: Address,
  poolAbi: Abi,
  token: Address,
  lpTokens: bigint,
): Promise<bigint> {
  const poolContract = new Contract({
    address: poolAddress,
    abi: poolAbi,
    provider,
  });

  // Read current state
  const [assetData, totalSupply] = await Promise.all([
    poolContract.read('assets', [token]) as Promise<any>,
    poolContract.read('totalSupply', []) as Promise<bigint>,
  ]);

  // Calculate expected amount: (lpTokens / totalSupply) * reserves
  return (lpTokens * assetData.reserves) / totalSupply;
}

/**
 * Get user's LP token balance for a specific pool
 */
export async function getLpBalance(
  provider: Eip1193Provider,
  poolAddress: Address,
  poolAbi: Abi,
  userAddress: Address,
): Promise<bigint> {
  const poolContract = new Contract({
    address: poolAddress,
    abi: poolAbi,
    provider,
  });

  return await poolContract.read('balanceOf', [userAddress]) as bigint;
}
