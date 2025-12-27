import { useState, useEffect, useCallback, useMemo } from 'preact/hooks';
import { SwapForm } from '@components/features/swap';
import { useWallet } from '@lib/wallet';
import { useRouter } from '@lib/router';
import { useSettings } from '@lib/settings';
import { PageContainer } from '@components/layout/PageContainer';
import { CHAINS, getAllTokensForChain } from '@sdk/eth';
import { PriceChartLazy } from '@components/features/chart';
import { SwapStore } from '@/lib/swap/SwapStore';

// Helper to get canonical pair ordering
function getCanonicalPairOrder(token1: string, token2: string): { base: string; quote: string } {
  const priority: Record<string, number> = { USDC: 0, USDT: 1, ETH: 2, WETH: 3 };
  const t1Priority = priority[token1] ?? 100;
  const t2Priority = priority[token2] ?? 100;
  return t1Priority < t2Priority ? { base: token1, quote: token2 } : { base: token2, quote: token1 };
}

export function SwapPage() {
  const { isConnected, connect, chainId: walletChainId } = useWallet();
  const { queryParams } = useRouter();
  const { settings, updateSettings } = useSettings();

  // Current chain (defaults to Ethereum if wallet not connected)
  const [chainId, setChainId] = useState(walletChainId || 1);

  // Sync chainId with wallet when it changes
  useEffect(() => {
    if (walletChainId) {
      setChainId(walletChainId);
    }
  }, [walletChainId]);

  // Get available tokens for current chain
  const availableTokens = Object.keys(getAllTokensForChain(chainId));

  // Read token from URL params (e.g., /swap?token=ETH)
  const urlToken = queryParams?.get('token')?.toUpperCase();

  // Default tokens - priority: URL param > saved settings > defaults
  const initialTokenIn = useMemo(() => {
    if (urlToken && availableTokens.includes(urlToken)) return urlToken;
    if (settings.swapTokenIn && availableTokens.includes(settings.swapTokenIn)) return settings.swapTokenIn;
    return availableTokens.includes('USDC') ? 'USDC' : availableTokens[0];
  }, [urlToken, availableTokens, settings.swapTokenIn]);

  const initialTokenOut = useMemo(() => {
    if (urlToken && availableTokens.includes(urlToken)) {
      if (urlToken === 'USDC' || urlToken === 'USDT') {
        const eth = availableTokens.find((t: string) => t === 'ETH' || t === 'WETH');
        return eth || availableTokens.find((t: string) => t !== urlToken);
      }
      return availableTokens.includes('USDC') ? 'USDC' : availableTokens.find((t: string) => t !== urlToken);
    }
    if (settings.swapTokenOut && availableTokens.includes(settings.swapTokenOut)) return settings.swapTokenOut;
    const eth = availableTokens.find((t: string) => t === 'ETH' || t === 'WETH');
    return eth || availableTokens.find((t: string) => t !== initialTokenIn);
  }, [urlToken, availableTokens, settings.swapTokenOut, initialTokenIn]);

  // Use SwapStore - it will be shared or passed down
  const store = useMemo(() => new SwapStore(initialTokenIn, initialTokenOut || 'USDC'), [initialTokenIn, initialTokenOut]);

  // Track explicit chart pair when user selects from PairSelector (null = use canonical)
  const [explicitChartPair, setExplicitChartPair] = useState<{ base: string; quote: string } | null>(null);

  // Compute chart base/quote - use explicit selection or derive from tokens
  const chartPair = useMemo(() => {
    const tokenIn = store.primaryTokens.value[0]?.symbol;
    const tokenOut = store.secondaryTokens.value[0]?.symbol;
    // If user explicitly selected a pair, use it as-is
    if (explicitChartPair) return explicitChartPair;
    // Otherwise derive from swap tokens using canonical ordering
    if (!tokenIn || !tokenOut) return { base: tokenIn || 'ETH', quote: tokenOut || 'USDC' };
    return getCanonicalPairOrder(tokenIn, tokenOut);
  }, [store.primaryTokens, store.secondaryTokens, explicitChartPair]);

  // Handle pair change from chart PairSelector (user explicitly picks pair)
  const handlePairChange = useCallback((base: string, quote: string) => {
    // User explicitly selected this pair - use exact order, don't canonicalize
    setExplicitChartPair({ base, quote });
    // Also update swap tokens to match
    store.setTokenSymbol('1', base, 'primary');
    store.setTokenSymbol('1', quote, 'secondary');
    updateSettings({ swapTokenIn: base, swapTokenOut: quote });
  }, [updateSettings, store]);

  // Handle pair inversion (flip base/quote)
  const handleInvertPair = useCallback(() => {
    // Invert the current chart pair explicitly
    setExplicitChartPair({ base: chartPair.quote, quote: chartPair.base });
  }, [chartPair]);

  // Handle token change from SwapForm (auto-change, use canonical ordering)
  const handleTokenChange = useCallback((primary: string, secondary: string) => {
    // Clear explicit pair - let canonical ordering take over
    setExplicitChartPair(null);
    // Persist to settings
    updateSettings({ swapTokenIn: primary, swapTokenOut: secondary });
  }, [updateSettings]);

  const chainConfig = CHAINS[chainId] || { name: 'Unknown', icon: '/networks/ethereum.svg' };
  const chainInfo = { name: chainConfig.name, icon: chainConfig.icon || `/networks/${chainConfig.name.toLowerCase()}.svg` };

  const handleSwap = () => {
    console.log('Swap initiated');
  };

  return (
    <PageContainer title="Swap">
      {/* Full width container - stacked on mobile, side-by-side on desktop */}
      <div className="flex flex-col lg:flex-row gap-4 w-full">
        {/* Price Chart - 2/3 width on desktop, full width on mobile, shown first on mobile */}
        <div className="w-full lg:w-2/3 order-2 lg:order-1 h-[520px]">
          {store.secondaryTokens.value[0]?.symbol ? (
            <PriceChartLazy
              key={`${chartPair.base}-${chartPair.quote}`}
              base={chartPair.base}
              quote={chartPair.quote}
              height={520}
              className="overflow-hidden border border-border rounded-lg"
              onChangePair={handlePairChange}
              onInvertPair={handleInvertPair}
            />
          ) : (
            <div className="h-full flex items-center justify-center text-muted-foreground text-sm bg-bg-1 border border-border rounded-lg">
              Select tokens to view chart
            </div>
          )}
        </div>

        {/* Swap Form - 1/3 width on desktop, full width on mobile, shown first on mobile */}
        <div className="w-full lg:w-1/3 order-1 lg:order-2">
          <SwapForm
            bordered={true}
            chainInfo={chainInfo}
            chainId={chainId}
            isConnected={isConnected}
            onConnect={connect}
            onSwap={handleSwap}
            initialPrimaryToken={store.primaryTokens.value[0]?.symbol}
            initialSecondaryToken={store.secondaryTokens.value[0]?.symbol}
            onTokenChange={handleTokenChange}
            store={store}
          />
        </div>
      </div>
    </PageContainer>
  );
}
