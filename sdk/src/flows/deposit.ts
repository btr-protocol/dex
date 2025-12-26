/**
 * Deposit flow for AIMM pools
 * @module @btr/dex-sdk/flows
 */

import type { Address, Hex, Eip1193Provider, Abi } from '../eth/index.js';
import { Contract, ERC20_ABI, parseUnits, sendTransaction, waitForTransaction } from '../eth/index.js';
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
  hash: Hex;
  lpTokensReceived?: bigint;
}

/**
 * Execute a deposit into a AIMM pool
 */
export async function deposit(
  provider: Eip1193Provider,
  account: Address,
  poolAbi: Abi,
  params: DepositParams,
): Promise<DepositResult> {
  if (!account) {
    throw new Error('No account provided');
  }

  const tokenContract = new Contract({
    address: params.token,
    abi: ERC20_ABI,
    provider,
  });

  // 1. Check token allowance
  const allowance = await tokenContract.read('allowance', [account, params.poolAddress]) as bigint;

  // 2. Approve if needed
  if (allowance < params.amount) {
    console.log('Approving token...');

    const approveTx = await tokenContract.write('approve', [params.poolAddress, params.amount], { from: account });
    await waitForTransaction(provider, approveTx);
    console.log('Approval confirmed');
  }

  const poolContract = new Contract({
    address: params.poolAddress,
    abi: poolAbi,
    provider,
  });

  // 3. Calculate minLpTokens if not provided
  let minLpTokens = params.minLpTokens;
  if (!minLpTokens && params.slippageBps) {
    // Estimate LP tokens from current reserves (simplified)
    const assetData = await poolContract.read('assets', [params.token]) as any;
    const totalSupply = await poolContract.read('totalSupply', []) as bigint;

    // LP tokens ≈ (amount / reserves) * totalSupply
    const expectedLp = (params.amount * totalSupply) / assetData.reserves;
    minLpTokens = applySlippage(expectedLp, params.slippageBps, true);
  } else if (!minLpTokens) {
    minLpTokens = 0n;
  }

  // 4. Execute deposit
  const hash = await poolContract.write('deposit', [params.token, params.amount, minLpTokens], { from: account });
  console.log(`Deposit transaction: ${hash}`);

  // Wait for confirmation
  const receipt = await waitForTransaction(provider, hash);
  console.log(`Deposit confirmed. Gas used: ${receipt.gasUsed}`);

  // TODO: Parse logs to extract actual LP tokens received
  return { hash };
}

/**
 * Get quote for a deposit (how many LP tokens will be received)
 */
export async function getDepositQuote(
  provider: Eip1193Provider,
  poolAddress: Address,
  poolAbi: Abi,
  token: Address,
  amount: bigint,
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

  // Calculate expected LP tokens
  // This is simplified - actual calculation may differ based on pool mechanics
  if (totalSupply === 0n) {
    return amount; // First deposit
  }

  return (amount * totalSupply) / assetData.reserves;
}
