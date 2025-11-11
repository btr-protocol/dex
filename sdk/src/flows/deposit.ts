/**
 * Deposit flow for BAMM pools
 * @module @btr/dex-sdk/flows
 */

import type { Address, PublicClient, WalletClient, Hash } from 'viem';
import { erc20Abi, parseUnits } from 'viem';
import { applySlippage } from '../common/utils.js';

export interface DepositParams {
  poolAddress: Address;
  token: Address;
  amount: bigint;
  minLpTokens?: bigint;
  slippageBps?: number; // Optional - will calculate minLpTokens if not provided
  deadline?: bigint;
}

export interface DepositResult {
  hash: Hash;
  lpTokensReceived?: bigint;
}

/**
 * Execute a deposit into a BAMM pool
 */
export async function deposit(
  publicClient: PublicClient,
  walletClient: WalletClient,
  poolAbi: any,
  params: DepositParams,
): Promise<DepositResult> {
  const account = walletClient.account;
  if (!account) {
    throw new Error('No account configured on wallet client');
  }

  // 1. Check token allowance
  const allowance = await publicClient.readContract({
    address: params.token,
    abi: erc20Abi,
    functionName: 'allowance',
    args: [account.address, params.poolAddress],
  }) as bigint;

  // 2. Approve if needed
  if (allowance < params.amount) {
    console.log('Approving token...');
    const { request: approveRequest } = await publicClient.simulateContract({
      account,
      address: params.token,
      abi: erc20Abi,
      functionName: 'approve',
      args: [params.poolAddress, params.amount],
    });

    const approveHash = await walletClient.writeContract(approveRequest);
    await publicClient.waitForTransactionReceipt({ hash: approveHash });
    console.log('Approval confirmed');
  }

  // 3. Calculate minLpTokens if not provided
  let minLpTokens = params.minLpTokens;
  if (!minLpTokens && params.slippageBps) {
    // Estimate LP tokens from current reserves (simplified)
    // In production, you'd want to calculate this more accurately
    const assetData = await publicClient.readContract({
      address: params.poolAddress,
      abi: poolAbi,
      functionName: 'assets',
      args: [params.token],
    }) as any;

    const totalSupply = await publicClient.readContract({
      address: params.poolAddress,
      abi: poolAbi,
      functionName: 'totalSupply',
      args: [],
    }) as bigint;

    // LP tokens ≈ (amount / reserves) * totalSupply
    const expectedLp = (params.amount * totalSupply) / assetData.reserves;
    minLpTokens = applySlippage(expectedLp, params.slippageBps, true);
  } else if (!minLpTokens) {
    minLpTokens = 0n;
  }

  // 4. Execute deposit
  const { request } = await publicClient.simulateContract({
    account,
    address: params.poolAddress,
    abi: poolAbi,
    functionName: 'deposit',
    args: [params.token, params.amount, minLpTokens],
  });

  const hash = await walletClient.writeContract(request);
  console.log(`Deposit transaction: ${hash}`);

  // Wait for confirmation and extract LP tokens received
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  console.log(`Deposit confirmed. Gas used: ${receipt.gasUsed}`);

  // TODO: Parse logs to extract actual LP tokens received
  return { hash };
}

/**
 * Get quote for a deposit (how many LP tokens will be received)
 */
export async function getDepositQuote(
  publicClient: PublicClient,
  poolAddress: Address,
  poolAbi: any,
  token: Address,
  amount: bigint,
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

  // Calculate expected LP tokens
  // This is simplified - actual calculation may differ based on pool mechanics
  if (totalSupply === 0n) {
    return amount; // First deposit
  }

  return (amount * totalSupply) / assetData.reserves;
}
