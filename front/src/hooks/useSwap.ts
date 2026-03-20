import { useCallback, useEffect } from 'preact/hooks';
import { withContext } from '@/lib/logger';
import { useWallet } from '@/lib/wallet';
import { formatUnits, parseUnits, type Address, ERC20_ABI, MOCK_PRICES, getTokenAddress, encodeFn, decodeFn } from '@sdk';
import { swap as sdkSwap } from '@sdk/pool';
import { getSwapQuote as apiGetSwapQuote } from './usePoolsAPI';
import { usePoolsAPI } from './usePoolsAPI';
import { quoteStore, type SwapQuote } from '@/lib/swap/QuoteStore';

const log = withContext('useSwap');

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
  const { pools } = usePoolsAPI();

  // Get pool address from API data
  const poolAddress = pools.length > 0 ? pools[0].address as Address : undefined;
  const tokenIn = chainId ? getTokenAddress(tokenInSymbol, chainId) : undefined;
  const tokenOut = chainId ? getTokenAddress(tokenOutSymbol, chainId) : undefined;

  // Check if we should use mock mode (no pool data from API)
  const useMockMode = pools.length === 0;

    // Fetch quote when inputs change
    useEffect(() => {
    if (!tokenIn || !tokenOut) {
      quoteStore.setQuoteError('Unknown token');
      return;
    }
    if (!amountIn || parseFloat(amountIn) <= 0) {
      quoteStore.clearQuote();
      return;
    }

    // Use mock quotes when no pool is available from backend
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

      quoteStore.setQuoteSuccess({
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
      return;
    }

    if (!poolAddress) {
      quoteStore.setQuoteError('No pool address');
      return;
    }

    const fetchQuote = async () => {
      quoteStore.startQuoteLoading();

      try {
        // Parse amount (assume 18 decimals for now)
        const amountInWei = parseUnits(amountIn, 18);

        // Fetch quote from backend API
        const apiQuote = await apiGetSwapQuote(
          poolAddress,
          tokenIn,
          tokenOut,
          amountInWei.toString()
        );

        // Convert API response to SwapQuote format - use batched update
        quoteStore.setQuoteSuccess({
          amountOut: BigInt(apiQuote.amountOut),
          amountIn: BigInt(apiQuote.amountIn),
          spreadBps: apiQuote.spreadBps,
          protoFee: BigInt(apiQuote.protoFee),
          lpFee: BigInt(apiQuote.lpFee),
          skewIn: apiQuote.skewIn,
          skewOut: apiQuote.skewOut,
          routeHops: apiQuote.routeHops as Address[],
          hopAmounts: apiQuote.hopAmounts.map((a) => BigInt(a)),
        });
      } catch (err: unknown) {
        log.error('Quote error:', err);
        let errorMessage = 'Failed to get quote';
        if (typeof err === 'object' && err !== null && 'message' in err && typeof (err as Record<string, unknown>).message === 'string') {
          errorMessage = (err as Record<string, unknown>).message as string;
        }
        quoteStore.setQuoteError(errorMessage);
      }
    };

    const debounceTimer = setTimeout(fetchQuote, 300);
    return () => clearTimeout(debounceTimer);
  }, [poolAddress, tokenIn, tokenOut, amountIn, useMockMode, tokenInSymbol, tokenOutSymbol]);

  // Check allowance when quote changes (skip in mock mode)
  useEffect(() => {
    if (useMockMode) {
      quoteStore.setNeedsApproval(false);
      return;
    }
    const quote = quoteStore.quote.value;
    if (!quote || !address || !provider || !tokenIn || !poolAddress) {
      quoteStore.setNeedsApproval(false);
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

        quoteStore.setNeedsApproval(allowance < quote.amountIn);
      } catch (err) {
        log.error('Allowance check error:', err);
      }
    };

    checkAllowance();
  }, [quoteStore.quote.value, address, provider, tokenIn, poolAddress, useMockMode]);

  const approve = useCallback(async () => {
    if (useMockMode) {
      log.debug('[MOCK] Approval simulated');
      return;
    }
    const quote = quoteStore.quote.value;
    if (!provider || !tokenIn || !poolAddress || !quote) return;

    quoteStore.startApproval();
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

      quoteStore.completeApproval(true);
    } catch (err: unknown) {
      log.error('Approve error:', err);
      quoteStore.completeApproval(false);
      throw err;
    }
  }, [provider, tokenIn, poolAddress, address, useMockMode]);

  const executeSwap = useCallback(async (): Promise<string> => {
    if (useMockMode) {
      log.debug('[MOCK] Swap simulated:', { tokenInSymbol, tokenOutSymbol, amountIn });
      // Return a fake tx hash for mock mode
      return '0x' + '0'.repeat(64);
    }

    const quote = quoteStore.quote.value;
    if (!provider || !poolAddress || !quote || !address || !tokenIn || !tokenOut) {
      throw new Error('Missing required params');
    }

    quoteStore.startSwapExecution();

    try {
      // Calculate minAmountOut with slippage
      const minAmountOut = (quote.amountOut * BigInt(10000 - slippageBps)) / 10000n;

      // Use SDK swap function
      const txHash = await sdkSwap(provider, poolAddress, {
        tokenIn: tokenIn as Address,
        tokenOut: tokenOut as Address,
        amountIn: quote.amountIn,
        minAmountOut,
        recipient: address as Address,
      });

      quoteStore.completeSwapExecution();
      return txHash;
    } catch (err: unknown) {
      log.error('Swap error:', err);
      let errorMessage = 'Swap failed';
      if (typeof err === 'object' && err !== null && 'message' in err && typeof (err as Record<string, unknown>).message === 'string') {
        errorMessage = (err as Record<string, unknown>).message as string;
      }
      quoteStore.setSwapError(errorMessage);
      throw err;
    }
  }, [provider, poolAddress, address, tokenIn, tokenOut, slippageBps, useMockMode, tokenInSymbol, tokenOutSymbol, amountIn]);

  return {
    quote: quoteStore.quote.value,
    quoteLoading: quoteStore.quoteLoading.value,
    quoteError: quoteStore.quoteError.value,
    executeSwap,
    swapLoading: quoteStore.swapLoading.value,
    swapError: quoteStore.swapError.value,
    needsApproval: quoteStore.needsApproval.value,
    approve,
    approveLoading: quoteStore.approveLoading.value,
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
