import { useState, useCallback, useEffect } from 'preact/hooks';
import { useWallet } from '@/lib/wallet';
import { formatUnits, parseUnits, type Address } from '@sdk/eth';

// Pool ABI - only the functions we need for swaps
const POOL_ABI = [
  {
    type: 'function',
    name: 'getSwapQuote',
    stateMutability: 'view',
    inputs: [
      { name: 'tokenIn', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'amountIn', type: 'uint256' },
    ],
    outputs: [
      {
        type: 'tuple',
        components: [
          { name: 'amountOut', type: 'uint256' },
          { name: 'amountIn', type: 'uint256' },
          { name: 'spreadBps', type: 'uint16' },
          { name: 'protoFee', type: 'uint256' },
          { name: 'lpFee', type: 'uint256' },
          { name: 'skewIn', type: 'int8' },
          { name: 'skewOut', type: 'int8' },
          { name: 'routeHops', type: 'address[]' },
          { name: 'hopAmounts', type: 'uint256[]' },
        ],
      },
    ],
  },
  {
    type: 'function',
    name: 'swap',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'tokenIn', type: 'address' },
      { name: 'tokenOut', type: 'address' },
      { name: 'amountIn', type: 'uint256' },
      { name: 'minAmountOut', type: 'uint256' },
      { name: 'recipient', type: 'address' },
    ],
    outputs: [{ name: 'amountOut', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'getMidPrice',
    stateMutability: 'nonpayable',
    inputs: [{ name: 'token', type: 'address' }],
    outputs: [{ name: 'midPrice', type: 'uint256' }],
  },
] as const;

const ERC20_ABI = [
  {
    type: 'function',
    name: 'approve',
    stateMutability: 'nonpayable',
    inputs: [
      { name: 'spender', type: 'address' },
      { name: 'amount', type: 'uint256' },
    ],
    outputs: [{ name: '', type: 'bool' }],
  },
  {
    type: 'function',
    name: 'allowance',
    stateMutability: 'view',
    inputs: [
      { name: 'owner', type: 'address' },
      { name: 'spender', type: 'address' },
    ],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'balanceOf',
    stateMutability: 'view',
    inputs: [{ name: 'account', type: 'address' }],
    outputs: [{ name: '', type: 'uint256' }],
  },
  {
    type: 'function',
    name: 'decimals',
    stateMutability: 'view',
    inputs: [],
    outputs: [{ name: '', type: 'uint8' }],
  },
] as const;

// BSC token addresses (from BSC fork)
const BSC_TOKENS: Record<string, Address> = {
  USDC: '0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d',
  USDT: '0x55d398326f99059fF775485246999027B3197955',
  WETH: '0x2170Ed0880ac9A755fd29B2688956BD959F933F8',
  ETH: '0x2170Ed0880ac9A755fd29B2688956BD959F933F8', // Alias
  WBTC: '0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c',
  BTC: '0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c', // Alias
  WBNB: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c',
  BNB: '0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c', // Alias
  SOL: '0x570A5D26f7765Ecb712C0924E4De545B89fD43dF',
  DAI: '0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3',
  PAXG: '0x7950865a9140cB519342433146Ed5b40c6F210f7',
};

// Pool addresses - these would come from deployment in production
// For Anvil BSC fork: deploy with `forge test --match-test "test_swap" --fork-url http://localhost:8545`
// The test deployment uses deterministic addresses based on CREATE2
const POOL_ADDRESSES: Record<number, Address> = {
  // Anvil (BSC fork) - address from forge test deployment
  // Deploy contracts first: cd contracts && forge test --match-path "test/integration/BSCForkTest.t.sol" --fork-url http://localhost:8545
  31337: (import.meta.env.VITE_POOL_ADDRESS as Address) || '0x0000000000000000000000000000000000000000',
  56: '0x0000000000000000000000000000000000000000', // BSC mainnet - not deployed yet
};

// Mock prices for development when no contract is available
const MOCK_PRICES: Record<string, number> = {
  ETH: 3500,
  WETH: 3500,
  BTC: 100000,
  WBTC: 100000,
  BNB: 600,
  WBNB: 600,
  SOL: 200,
  USDC: 1,
  USDT: 1,
  DAI: 1,
  PAXG: 2650,
};

export interface SwapQuote {
  amountOut: bigint;
  amountIn: bigint;
  spreadBps: number;
  protoFee: bigint;
  lpFee: bigint;
  skewIn: number;
  skewOut: number;
  routeHops: Address[];
  hopAmounts: bigint[];
}

export interface UseSwapResult {
  quote: SwapQuote | null;
  quoteLoading: boolean;
  quoteError: string | null;
  executeSwap: () => Promise<string>;
  swapLoading: boolean;
  swapError: string | null;
  needsApproval: boolean;
  approve: () => Promise<void>;
  approveLoading: boolean;
  isMockMode: boolean;
}

export function useSwap(
  tokenInSymbol: string,
  tokenOutSymbol: string,
  amountIn: string,
  slippageBps: number = 50 // 0.5% default
): UseSwapResult {
  const { address, chainId, provider } = useWallet();

  const [quote, setQuote] = useState<SwapQuote | null>(null);
  const [quoteLoading, setQuoteLoading] = useState(false);
  const [quoteError, setQuoteError] = useState<string | null>(null);

  const [swapLoading, setSwapLoading] = useState(false);
  const [swapError, setSwapError] = useState<string | null>(null);

  const [needsApproval, setNeedsApproval] = useState(false);
  const [approveLoading, setApproveLoading] = useState(false);

  const poolAddress = chainId ? POOL_ADDRESSES[chainId] : undefined;
  const tokenIn = BSC_TOKENS[tokenInSymbol];
  const tokenOut = BSC_TOKENS[tokenOutSymbol];

  // Check if we should use mock mode (no deployed contract)
  const useMockMode = !poolAddress || poolAddress === '0x0000000000000000000000000000000000000000';

  // Fetch quote when inputs change
  useEffect(() => {
    if (!tokenIn || !tokenOut) {
      setQuoteError('Unknown token');
      return;
    }
    if (!amountIn || parseFloat(amountIn) <= 0) {
      setQuote(null);
      setQuoteError(null);
      return;
    }

    // Use mock quotes when no pool is deployed
    if (useMockMode) {
      const priceIn = MOCK_PRICES[tokenInSymbol.toUpperCase()] || 1;
      const priceOut = MOCK_PRICES[tokenOutSymbol.toUpperCase()] || 1;
      const amountInNum = parseFloat(amountIn);
      const valueIn = amountInNum * priceIn;
      const spreadBps = 30; // 0.30% spread
      const valueOut = valueIn * (1 - spreadBps / 10000);
      const amountOutNum = valueOut / priceOut;
      const amountInWei = parseUnits(amountIn, 18);
      const amountOutWei = parseUnits(amountOutNum.toFixed(18), 18);
      const feeWei = parseUnits((amountOutNum * 0.001).toFixed(18), 18); // 0.1% total fees

      setQuote({
        amountOut: amountOutWei,
        amountIn: amountInWei,
        spreadBps,
        protoFee: feeWei / 2n,
        lpFee: feeWei / 2n,
        skewIn: 0,
        skewOut: 0,
        routeHops: [],
        hopAmounts: [],
      });
      setQuoteError(null);
      setQuoteLoading(false);
      return;
    }

    if (!provider) {
      setQuoteError('No provider');
      return;
    }

    const fetchQuote = async () => {
      setQuoteLoading(true);
      setQuoteError(null);

      try {
        // Parse amount (assume 18 decimals for now)
        const amountInWei = parseUnits(amountIn, 18);

        // Encode call data for getSwapQuote
        const { encodeFunctionData, decodeFunctionResult } = await import('viem');
        const callData = encodeFunctionData({
          abi: POOL_ABI,
          functionName: 'getSwapQuote',
          args: [tokenIn, tokenOut, amountInWei],
        });

        // Make eth_call
        const result = await provider.request({
          method: 'eth_call',
          params: [{ to: poolAddress, data: callData }, 'latest'],
        });

        // Decode result
        const decoded = decodeFunctionResult({
          abi: POOL_ABI,
          functionName: 'getSwapQuote',
          data: result as `0x${string}`,
        }) as SwapQuote;

        setQuote(decoded);
      } catch (err: any) {
        console.error('Quote error:', err);
        setQuoteError(err.message || 'Failed to get quote');
        setQuote(null);
      } finally {
        setQuoteLoading(false);
      }
    };

    const debounceTimer = setTimeout(fetchQuote, 300);
    return () => clearTimeout(debounceTimer);
  }, [poolAddress, tokenIn, tokenOut, amountIn, provider, useMockMode, tokenInSymbol, tokenOutSymbol]);

  // Check allowance when quote changes (skip in mock mode)
  useEffect(() => {
    if (useMockMode) {
      setNeedsApproval(false);
      return;
    }
    if (!quote || !address || !provider || !tokenIn || !poolAddress) {
      setNeedsApproval(false);
      return;
    }

    const checkAllowance = async () => {
      try {
        const { encodeFunctionData, decodeFunctionResult } = await import('viem');
        const callData = encodeFunctionData({
          abi: ERC20_ABI,
          functionName: 'allowance',
          args: [address as Address, poolAddress],
        });

        const result = await provider.request({
          method: 'eth_call',
          params: [{ to: tokenIn, data: callData }, 'latest'],
        });

        const allowance = decodeFunctionResult({
          abi: ERC20_ABI,
          functionName: 'allowance',
          data: result as `0x${string}`,
        }) as bigint;

        setNeedsApproval(allowance < quote.amountIn);
      } catch (err) {
        console.error('Allowance check error:', err);
      }
    };

    checkAllowance();
  }, [quote, address, provider, tokenIn, poolAddress, useMockMode]);

  const approve = useCallback(async () => {
    if (useMockMode) {
      console.log('[MOCK] Approval simulated');
      return;
    }
    if (!provider || !tokenIn || !poolAddress || !quote) return;

    setApproveLoading(true);
    try {
      const { encodeFunctionData } = await import('viem');
      const callData = encodeFunctionData({
        abi: ERC20_ABI,
        functionName: 'approve',
        args: [poolAddress, quote.amountIn],
      });

      const txHash = await provider.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address,
          to: tokenIn,
          data: callData,
        }],
      });

      // Wait for confirmation
      await provider.request({
        method: 'eth_getTransactionReceipt',
        params: [txHash],
      });

      setNeedsApproval(false);
    } catch (err: any) {
      console.error('Approve error:', err);
      throw err;
    } finally {
      setApproveLoading(false);
    }
  }, [provider, tokenIn, poolAddress, quote, address, useMockMode]);

  const executeSwap = useCallback(async (): Promise<string> => {
    if (useMockMode) {
      console.log('[MOCK] Swap simulated:', { tokenInSymbol, tokenOutSymbol, amountIn });
      // Return a fake tx hash for mock mode
      return '0x' + '0'.repeat(64);
    }

    if (!provider || !poolAddress || !quote || !address || !tokenIn || !tokenOut) {
      throw new Error('Missing required params');
    }

    setSwapLoading(true);
    setSwapError(null);

    try {
      // Calculate minAmountOut with slippage
      const minAmountOut = (quote.amountOut * BigInt(10000 - slippageBps)) / 10000n;

      const { encodeFunctionData } = await import('viem');
      const callData = encodeFunctionData({
        abi: POOL_ABI,
        functionName: 'swap',
        args: [tokenIn, tokenOut, quote.amountIn, minAmountOut, address as Address],
      });

      const txHash = await provider.request({
        method: 'eth_sendTransaction',
        params: [{
          from: address,
          to: poolAddress,
          data: callData,
        }],
      });

      return txHash as string;
    } catch (err: any) {
      console.error('Swap error:', err);
      setSwapError(err.message || 'Swap failed');
      throw err;
    } finally {
      setSwapLoading(false);
    }
  }, [provider, poolAddress, quote, address, tokenIn, tokenOut, slippageBps, useMockMode, tokenInSymbol, tokenOutSymbol, amountIn]);

  return {
    quote,
    quoteLoading,
    quoteError,
    executeSwap,
    swapLoading,
    swapError,
    needsApproval,
    approve,
    approveLoading,
    isMockMode: useMockMode,
  };
}

// Helper to format quote for display
export function formatQuote(quote: SwapQuote | null, decimals: number = 18) {
  if (!quote) return null;

  // Price impact is approximated from spread for display
  // Real price impact would come from the contract comparing effective vs mid price
  const priceImpactBps = quote.spreadBps * 0.1; // ~10% of spread as price impact estimate

  return {
    amountOut: formatUnits(quote.amountOut, decimals),
    spreadPercent: (quote.spreadBps / 100).toFixed(2),
    totalFee: formatUnits(quote.protoFee + quote.lpFee, decimals),
    priceImpact: (priceImpactBps / 100).toFixed(2),
  };
}

// Get token address by symbol
export function getTokenAddress(symbol: string): Address | undefined {
  return BSC_TOKENS[symbol.toUpperCase()];
}
