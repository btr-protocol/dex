/**
 * Standalone Chart Page - Ultra-lightweight route for popup/sharing
 * URL format: /chart?pair=ETHUSDC&tf=60&type=candles&ta=ema-trend(10,20,14)&ta=rsima(10,20,14)
 */
import { useEffect, useMemo } from 'preact/hooks';
import { useRouter } from '@lib/router';
import { PriceChartLazy } from '@components/features/chart';
import { PairSelector } from '@components/shared/token';
import { ChartPageStore } from '@/lib/chart/ChartPageStore';
import type { IndicatorParams } from '@utils/indicators';
import type { IndicatorKey, ChartType } from '@components/features/chart/indicatorsConfig';
import type { InitialIndicator } from '@components/features/chart/useIndicatorParams';

// Parse indicator from URL format: ema-trend(10,20,14) -> { preset, params }
function parseIndicator(str: string): InitialIndicator | null {
  const match = str.match(/^([a-z-]+)(?:\((\d+),(\d+),(\d+)\))?$/);
  if (!match) return null;
  const preset = match[1] as IndicatorKey;
  const params: IndicatorParams = {
    fast: match[2] ? parseInt(match[2], 10) : 10,
    slow: match[3] ? parseInt(match[3], 10) : 20,
    signal: match[4] ? parseInt(match[4], 10) : 14,
  };
  return { preset, params };
}

// Build URL for chart with all current settings (clean URL without encoding parens/commas)
export function buildChartUrl(
  base: string,
  quote: string,
  timeframe: number,
  chartType: string,
  indicators: InitialIndicator[]
): string {
  const parts: string[] = [
    `pair=${base}${quote}`,
    `tf=${timeframe}`,
    `type=${chartType}`,
  ];

  indicators.forEach(({ preset, params: p }) => {
    parts.push(`ta=${preset}(${p.fast},${p.slow},${p.signal})`);
  });

  return `/chart?${parts.join('&')}`;
}

export function ChartPage() {
  const { queryParams, navigate } = useRouter();

  // Use signal-based ChartPageStore instead of 5 useState calls
  const store = useMemo(() => new ChartPageStore(), []);

  // Parse URL params - priority: URL > defaults
  const urlPair = queryParams.get('pair');
  const pair: string = urlPair || 'ETHUSDC';
  const tf = parseInt(queryParams.get('tf') || '60', 10);
  const type = (queryParams.get('type') || 'candles') as 'candles' | 'bars' | 'line';

  // Parse all ta params
  const taParams = queryParams.getAll('ta');
  const indicators: InitialIndicator[] = [];
  taParams.forEach((ta: string) => {
    const parsed = parseIndicator(ta);
    if (parsed) indicators.push(parsed);
  });

  // Initialize current state from URL on first load
  useEffect(() => {
    store.initializeChartState(tf, type, indicators);
  }, [tf, type, indicators, store]);

  // Extract base/quote from pair (assume last 3-4 chars are quote)
  let base = pair;
  let quote = 'USDC';
  // Include all supported tokens as potential quotes (sorted by length descending to avoid partial matches)
  const knownQuotes = ['USDC', 'USDT', 'USDE', 'WETH', 'WBTC', 'TBTC', 'CBBTC', 'PAXG', 'XAUT', 'PENDLE', 'AAVE', 'CAKE', 'LINK', 'UNI', 'CRV', 'ENA', 'ZRO', 'USD', 'ETH', 'BTC', 'DAI']
    .sort((a, b) => b.length - a.length); // Longest first to avoid partial matches (e.g., TBTC before BTC)
  for (const q of knownQuotes) {
    if (pair.endsWith(q) && pair.length > q.length) {
      base = pair.slice(0, -q.length);
      quote = q;
      break;
    }
  }

  // Handle pair change
  const handleChangePair = (newBase: string, newQuote: string) => {
    // Use current state (from chart component) instead of URL params to preserve user changes
    const parts: string[] = [`pair=${newBase}${newQuote}`];

    // Use current chart state (which may have been changed by user)
    const timeframeToUse = store.currentTimeframe.value ?? tf;
    const chartTypeToUse = store.currentChartType.value ?? type;
    const indicatorsToUse = store.currentIndicators.value ?? indicators;

    parts.push(`tf=${timeframeToUse}`);
    parts.push(`type=${chartTypeToUse}`);
    indicatorsToUse.forEach(({ preset, params: p }) => {
      parts.push(`ta=${preset}(${p.fast},${p.slow},${p.signal})`);
    });

    navigate(`/chart?${parts.join('&')}`, { replace: true });
  };

  // Handle pair inversion (swap base/quote) - preserve all chart state
  const handleInvertPair = () => {
    handleChangePair(quote, base);
  };

  // Set document title
  useEffect(() => {
    document.title = `${base}/${quote} Chart`;
    store.setReady();
  }, [base, quote, store]);

  // Keyboard shortcut: Cmd+K to open pair selector
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        store.openPairSelector();
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [store]);

  if (!store.ready.value) return null;

  // Toolbar height is 32px (h-8), account for it in chart height
  const TOOLBAR_HEIGHT = 32;

  return (
    <div className="w-full h-full bg-bg-0 overflow-hidden">
      <PriceChartLazy
        key={`${base}-${quote}`}
        base={base}
        quote={quote}
        height={window.innerHeight - TOOLBAR_HEIGHT}
        className="w-full h-full"
        initialTimeframe={tf}
        initialChartType={type}
        initialIndicators={indicators}
        standalone
        onChangePair={handleChangePair}
        onInvertPair={handleInvertPair}
        onTimeframeChange={(tf: number) => store.setTimeframe(tf)}
        onChartTypeChange={(type: ChartType) => store.setChartType(type)}
        onIndicatorsChange={(indicators: InitialIndicator[]) => store.setIndicators(indicators)}
      />
      <PairSelector
        isOpen={store.pairSelectorOpen.value}
        onClose={() => store.closePairSelector()}
        onSelect={handleChangePair}
        currentBase={base}
        currentQuote={quote}
      />
    </div>
  );
}
