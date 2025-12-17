import { useState, useEffect, useCallback, useMemo } from 'preact/hooks';
import { SwapForm } from '@components/SwapForm';
import { useWallet } from '@lib/wallet';
import { useRouter } from '@lib/router';
import { useSettings } from '@lib/settings';
import PageContainer from '@components/layout/PageContainer';
import { CHAINS, getAllTokensForChain } from '@sdk/eth';
import { PriceChart } from '@components/PriceChartLazy';

// Helper to get token symbols for a chain
function getTokensForChain(chainId: number): string[] {
  return Object.keys(getAllTokensForChain(chainId));
}

// Stablecoins that should be quoted against (never base unless both are stables)
const STABLECOINS = ['USDC', 'USDT', 'USDE', 'DAI', 'FRAX', 'TUSD', 'BUSD', 'GUSD', 'USDP'];

// Determine which token should be base (more expensive) and which should be quote
// Rule: Non-stablecoin is always base, stablecoin is always quote
function getCanonicalPairOrder(tokenA: string, tokenB: string): { base: string; quote: string } {
  const aIsStable = STABLECOINS.includes(tokenA.toUpperCase());
  const bIsStable = STABLECOINS.includes(tokenB.toUpperCase());

  // If only one is a stablecoin, the other is base
  if (aIsStable && !bIsStable) return { base: tokenB, quote: tokenA };
  if (bIsStable && !aIsStable) return { base: tokenA, quote: tokenB };

  // Both stablecoins or neither - alphabetical order (arbitrary but consistent)
  return tokenA < tokenB ? { base: tokenA, quote: tokenB } : { base: tokenB, quote: tokenA };
}

export default function SwapPage() {
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
  const availableTokens = getTokensForChain(chainId);

  // Read token from URL params (e.g., /swap?token=ETH)
  const urlToken = queryParams?.get('token')?.toUpperCase();

  // Default tokens - priority: URL param > saved settings > defaults
  const [tokenIn, setTokenIn] = useState(() => {
    if (urlToken && availableTokens.includes(urlToken)) return urlToken;
    if (settings.swapTokenIn && availableTokens.includes(settings.swapTokenIn)) return settings.swapTokenIn;
    return availableTokens.includes('USDC') ? 'USDC' : availableTokens[0];
  });
  const [tokenOut, setTokenOut] = useState<string | undefined>(() => {
    if (urlToken && availableTokens.includes(urlToken)) {
      if (urlToken === 'USDC' || urlToken === 'USDT') {
        const eth = availableTokens.find(t => t === 'ETH' || t === 'WETH');
        return eth || availableTokens.find(t => t !== urlToken);
      }
      return availableTokens.includes('USDC') ? 'USDC' : availableTokens.find(t => t !== urlToken);
    }
    if (settings.swapTokenOut && availableTokens.includes(settings.swapTokenOut)) return settings.swapTokenOut;
    const eth = availableTokens.find(t => t === 'ETH' || t === 'WETH');
    return eth || availableTokens.find(t => t !== tokenIn);
  });

  // Track explicit chart pair when user selects from PairSelector (null = use canonical)
  const [explicitChartPair, setExplicitChartPair] = useState<{ base: string; quote: string } | null>(null);

  // Compute chart base/quote - use explicit selection or derive from tokens
  const chartPair = useMemo(() => {
    // If user explicitly selected a pair, use it as-is
    if (explicitChartPair) return explicitChartPair;
    // Otherwise derive from swap tokens using canonical ordering
    if (!tokenIn || !tokenOut) return { base: tokenIn || 'ETH', quote: tokenOut || 'USDC' };
    return getCanonicalPairOrder(tokenIn, tokenOut);
  }, [tokenIn, tokenOut, explicitChartPair]);

  // Handle pair change from chart PairSelector (user explicitly picks pair)
  const handlePairChange = useCallback((base: string, quote: string) => {
    // User explicitly selected this pair - use exact order, don't canonicalize
    setExplicitChartPair({ base, quote });
    // Also update swap tokens to match
    setTokenIn(base);
    setTokenOut(quote);
    updateSettings({ swapTokenIn: base, swapTokenOut: quote });
  }, [updateSettings]);

  // Handle pair inversion (flip base/quote)
  const handleInvertPair = useCallback(() => {
    // Invert the current chart pair explicitly
    setExplicitChartPair({ base: chartPair.quote, quote: chartPair.base });
  }, [chartPair]);

  // Handle token change from SwapForm (auto-change, use canonical ordering)
  const handleTokenChange = useCallback((primary: string, secondary: string) => {
    // Clear explicit pair - let canonical ordering take over
    setExplicitChartPair(null);
    // SwapForm: primary = what user has (tokenIn), secondary = what user wants (tokenOut)
    setTokenIn(primary);
    setTokenOut(secondary);
    // Persist to settings
    updateSettings({ swapTokenIn: primary, swapTokenOut: secondary });
  }, [updateSettings]);

  const chainInfo = CHAINS[chainId] || { name: 'Unknown', icon: '/networks/ethereum.svg' };

  const handleSwap = () => {
    console.log('Swap initiated');
  };

  return (
    <PageContainer title="Swap">
      {/* Full width container - stacked on mobile, side-by-side on desktop */}
      <div className="flex flex-col lg:flex-row gap-4 w-full">
        {/* Price Chart - 2/3 width on desktop, full width on mobile, shown first on mobile */}
        <div className="w-full lg:w-2/3 order-2 lg:order-1 h-[520px]">
          {tokenOut ? (
            <PriceChart
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
            initialPrimaryToken={tokenIn}
            initialSecondaryToken={tokenOut}
            onTokenChange={handleTokenChange}
          />
        </div>
      </div>
    </PageContainer>
  );
}
