/**
 * Example: Frontend integration for swapping tokens
 * This demonstrates the light bundle usage - only imports what's needed
 */

import { swap, getSwapQuote } from '../src/flows/swap.js';
import { AIMM_ABI } from '../src/abis/AIMM.js';
import { formatTokenAmount, parseTokenAmount } from '../src/utils/business.js';
import type { Eip1193Provider } from '../src/eth/types.js';
import { logger } from '../src/utils/logger.js';

const log = logger.withContext('frontendSwap');

async function main() {
  // Setup EIP-1193 provider (works with MetaMask, WalletConnect, Anvil, etc.)
  const rpcUrl = process.env.RPC_URL || 'https://eth.llamarpc.com';
  const provider: Eip1193Provider = {
    request: async (args: { method: string; params: any[] }) => {
      const response = await fetch(rpcUrl, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          jsonrpc: '2.0',
          method: args.method,
          params: args.params,
          id: 1,
        }),
      });
      const data = await response.json();
      if (data.error) throw new Error(data.error.message);
      return data.result;
    },
  };

  // Pool and token addresses
  const poolAddress = '0x...'; // Your AIMM pool
  const USDC = '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
  const WETH = '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
  const userAddress = process.env.ADDRESS || '0x...'; // Your address

  // User wants to swap 1000 USDC for WETH
  const amountIn = parseTokenAmount('1000', 6); // 1000 USDC (6 decimals)

  log.info('Getting swap quote...');
  const quote = await getSwapQuote(
    provider,
    poolAddress,
    AIMM_ABI,
    USDC,
    WETH,
    amountIn
  );

  log.info(`Quote:`);
  log.info(`  Input: ${formatTokenAmount(quote.amountIn, 6)} USDC`);
  log.info(`  Output: ${formatTokenAmount(quote.amountOut, 18)} WETH`);
  log.info(`  Price impact: ${quote.priceImpact.toFixed(2)}%`);
  log.info(`  Fee: ${formatTokenAmount(quote.fee, 6)} USDC`);

  // Execute swap with 0.5% slippage tolerance
  log.info('\nExecuting swap...');
  const result = await swap(provider, AIMM_ABI, {
    poolAddress,
    tokenIn: USDC,
    tokenOut: WETH,
    amountIn,
    slippageBps: 50, // 0.5%
    userAddress,
  });

  log.info(`✅ Swap executed!`);
  log.info(`   Transaction: ${result}`);
}

main().catch(console.error);
