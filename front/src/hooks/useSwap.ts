import { useState, useCallback, useEffect } from 'preact/hooks';
import { useWallet } from '@/lib/wallet';
import { formatUnits, parseUnits, type Address, POOL_ABI, ERC20_ABI, MOCK_PRICES, getTokenAddress, encodeFn, decodeFn } from '@sdk/eth';

/**
 * Pool addresses by chain ID
 * For Anvil BSC fork: deploy with `forge test --match-test "test_swap" --fork-url http://localhost:8545`
 */
const POOL_ADDRESSES: Record<number, Address> = {
  // Anvil (BSC fork) - address from forge test deployment
  31337: (import.meta.env.VITE_POOL_ADDRESS as Address) || '0x0000000000000000000000000000000000000000',
  // BSC mainnet - not deployed yet
  56: '0x0000000000000000000000000000000000000000',
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
  const tokenIn = chainId ? getTokenAddress(tokenInSymbol, chainId) : undefined;
  const tokenOut = chainId ? getTokenAddress(tokenOutSymbol, chainId) : undefined;

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
        const callData = encodeFn({
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
        const decoded = decodeFn({
          abi: POOL_ABI,
          functionName: 'getSwapQuote',
          data: result as `0x${string}`,
        }) as SwapQuote;

        setQuote(decoded);
      } catch (err: unknown) {
        console.error('Quote error:', err);
        let errorMessage = 'Failed to get quote';
        if (typeof err === 'object' && err !== null && 'message' in err && typeof (err as Record<string, unknown>).message === 'string') {
          errorMessage = (err as Record<string, unknown>).message as string;
        }
        setQuoteError(errorMessage);
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
        const callData = encodeFn({
          abi: ERC20_ABI,
          functionName: 'allowance',
          args: [address, poolAddress],
        });

        const result = await provider.request({
          method: 'eth_call',
          params: [{ to: tokenIn, data: callData }, 'latest'],
        });

        const allowance = decodeFn({
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
      const callData = encodeFn({
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
    } catch (err: unknown) {
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

      const callData = encodeFn({
        abi: POOL_ABI,
        functionName: 'swap',
        args: [tokenIn, tokenOut, quote.amountIn, minAmountOut, address],
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
    } catch (err: unknown) {
      console.error('Swap error:', err);
      let errorMessage = 'Swap failed';
      if (typeof err === 'object' && err !== null && 'message' in err && typeof (err as Record<string, unknown>).message === 'string') {
        errorMessage = (err as Record<string, unknown>).message as string;
      }
      setSwapError(errorMessage);
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

// Re-export from SDK for backward compatibility
export { getTokenAddress } from '@sdk/eth';
