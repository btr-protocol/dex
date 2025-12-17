/**
 * Example: Frontend integration for swapping tokens
 * This demonstrates the light bundle usage - only imports what's needed
 */

import { swap, getSwapQuote } from '../src/flows/swap.js';
import { AIMM_ABI } from '../src/abis/AIMM.js';
import { formatTokenAmount, parseTokenAmount } from '../src/common/utils.js';
import { createPublicClient, createWalletClient, http } from 'viem';
import { mainnet } from 'viem/chains';
import { privateKeyToAccount } from 'viem/accounts';

async function main() {
  // Setup viem clients
  const publicClient = createPublicClient({
    chain: mainnet,
    transport: http(process.env.RPC_URL || 'https://eth.llamarpc.com'),
  });

  const account = privateKeyToAccount(process.env.PRIVATE_KEY as `0x${string}`);
  const walletClient = createWalletClient({
    account,
    chain: mainnet,
    transport: http(process.env.RPC_URL || 'https://eth.llamarpc.com'),
  });

  // Pool and token addresses
  const poolAddress = '0x...'; // Your AIMM pool
  const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
  const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';

  // User wants to swap 1000 USDC for WETH
  const amountIn = parseTokenAmount('1000', 6); // 1000 USDC (6 decimals)

  console.log('Getting swap quote...');
  const quote = await getSwapQuote(
    publicClient,
    poolAddress,
    AIMM_ABI,
    USDC,
    WETH,
    amountIn
  );

  console.log(`Quote:`);
  console.log(`  Input: ${formatTokenAmount(quote.amountIn, 6)} USDC`);
  console.log(`  Output: ${formatTokenAmount(quote.amountOut, 18)} WETH`);
  console.log(`  Price impact: ${quote.priceImpact.toFixed(2)}%`);
  console.log(`  Fee: ${formatTokenAmount(quote.fee, 6)} USDC`);

  // Execute swap with 0.5% slippage tolerance
  console.log('\nExecuting swap...');
  const result = await swap(publicClient, walletClient, AIMM_ABI, {
    poolAddress,
    tokenIn: USDC,
    tokenOut: WETH,
    amountIn,
    slippageBps: 50, // 0.5%
  });

  console.log(`✅ Swap executed!`);
  console.log(`   Transaction: ${result.hash}`);
  console.log(`   View on Etherscan: https://etherscan.io/tx/${result.hash}`);
}

main().catch(console.error);
