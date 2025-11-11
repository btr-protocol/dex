/**
 * Withdraw flow for BAMM pools
 * @module @btr/dex-sdk/flows
 */

import type { Address, PublicClient, WalletClient, Hash } from 'viem';
import { applySlippage } from '../common/utils.js';

export interface WithdrawParams {
  poolAddress: Address;
  token: Address;
  lpTokens: bigint;
  minAmount?: bigint;
  slippageBps?: number; // Optional - will calculate minAmount if not provided
  deadline?: bigint;
}

export interface WithdrawResult {
  hash: Hash;
  amountReceived?: bigint;
}

/**
 * Execute a withdrawal from a BAMM pool
 */
export async function withdraw(
  publicClient: PublicClient,
  walletClient: WalletClient,
  poolAbi: any,
  params: WithdrawParams,
): Promise<WithdrawResult> {
  const account = walletClient.account;
  if (!account) {
    throw new Error('No account configured on wallet client');
  }

  // 1. Get quote for withdrawal
  const expectedAmount = await getWithdrawQuote(
    publicClient,
    params.poolAddress,
    poolAbi,
    params.token,
    params.lpTokens,
  );

  console.log(`Withdraw quote: ${expectedAmount} ${params.token}`);

  // 2. Calculate minAmount if not provided
  let minAmount = params.minAmount;
  if (!minAmount && params.slippageBps) {
    minAmount = applySlippage(expectedAmount, params.slippageBps, true);
  } else if (!minAmount) {
    minAmount = 0n;
  }

  // 3. Check LP token balance
  const lpBalance = await publicClient.readContract({
    address: params.poolAddress,
    abi: poolAbi,
    functionName: 'balanceOf',
    args: [account.address],
  }) as bigint;

  if (lpBalance < params.lpTokens) {
    throw new Error(`Insufficient LP tokens. Have ${lpBalance}, need ${params.lpTokens}`);
  }

  // 4. Execute withdrawal
  const { request } = await publicClient.simulateContract({
    account,
    address: params.poolAddress,
    abi: poolAbi,
    functionName: 'withdraw',
    args: [params.token, params.lpTokens, minAmount],
  });

  const hash = await walletClient.writeContract(request);
  console.log(`Withdraw transaction: ${hash}`);

  // Wait for confirmation
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`Withdraw confirmed. Gas used: ${receipt.gasUsed}`);

  // TODO: Parse logs to extract actual amount received
  return { hash };
}

/**
 * Get quote for a withdrawal (how many tokens will be received)
 */
export async function getWithdrawQuote(
  publicClient: PublicClient,
  poolAddress: Address,
  poolAbi: any,
  token: Address,
  lpTokens: bigint,
): Promise<bigint> {
  // Read current state
  const [assetData, totalSupply] = await Promise.all([
    publicClient.readContract({
      address: poolAddress,
      abi: poolAbi,
      functionName: 'assets',
      args: [token],
    }) as Promise<any>,
    publicClient.readContract({
      address: poolAddress,
      abi: poolAbi,
      functionName: 'totalSupply',
      args: [],
    }) as Promise<bigint>,
  ]);

  // Calculate expected amount: (lpTokens / totalSupply) * reserves
  return (lpTokens * assetData.reserves) / totalSupply;
}

/**
 * Get user's LP token balance for a specific pool
 */
export async function getLpBalance(
  publicClient: PublicClient,
  poolAddress: Address,
  poolAbi: any,
  userAddress: Address,
): Promise<bigint> {
  return await publicClient.readContract({
    address: poolAddress,
    abi: poolAbi,
    functionName: 'balanceOf',
    args: [userAddress],
  }) as bigint;
}
