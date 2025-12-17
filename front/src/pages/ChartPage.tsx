/**
 * Standalone Chart Page - Ultra-lightweight route for popup/sharing
 * URL format: /chart?pair=ETHUSDC&tf=60&type=candles&ta=ema-trend(10,20,14)&ta=rsima(10,20,14)
 */
import { useEffect, useState } from 'preact/hooks';
import { useRouter } from '@lib/router';
import { useSettings } from '@lib/settings';
import { PriceChart } from '@components/PriceChart';
import PairSelector from '@components/PairSelector';
import type { IndicatorParams } from '@utils/indicators';
import type { IndicatorKey, InitialIndicator } from '@components/chart';

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

export default function ChartPage() {
  const { queryParams, navigate } = useRouter();
  const { settings, updateSettings } = useSettings();
  const [ready, setReady] = useState(false);
  const [pairSelectorOpen, setPairSelectorOpen] = useState(false);

  // Parse URL params - priority: URL > saved settings > defaults
  const urlPair = queryParams.get('pair');
  const savedPair = settings.chartBase && settings.chartQuote
    ? `${settings.chartBase}${settings.chartQuote}`
    : null;
  const pair = urlPair || savedPair || 'ETHUSDC';
  const tf = parseInt(queryParams.get('tf') || '60', 10);
  const type = (queryParams.get('type') || 'candles') as 'candles' | 'bars' | 'line';

  // Parse all ta params
  const taParams = queryParams.getAll('ta');
  const indicators: InitialIndicator[] = [];
  taParams.forEach((ta: string) => {
    const parsed = parseIndicator(ta);
    if (parsed) indicators.push(parsed);
  });

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
    // Persist to settings
    updateSettings({ chartBase: newBase, chartQuote: newQuote });

    // Preserve other params while updating pair (use clean URL)
    const params = new URLSearchParams(window.location.search);
    const parts: string[] = [`pair=${newBase}${newQuote}`];

    // Keep existing tf, type, and ta params
    const tfParam = params.get('tf');
    const typeParam = params.get('type');
    const taParams = params.getAll('ta');

    if (tfParam) parts.push(`tf=${tfParam}`);
    if (typeParam) parts.push(`type=${typeParam}`);
    taParams.forEach(ta => parts.push(`ta=${ta}`));

    navigate(`/chart?${parts.join('&')}`, { replace: true });
  };

  // Handle pair inversion (swap base/quote)
  const handleInvertPair = () => {
    handleChangePair(quote, base);
  };

  // Set document title and persist pair to settings
  useEffect(() => {
    document.title = `${base}/${quote} Chart`;
    // Persist current pair (whether from URL or saved settings)
    if (base && quote) {
      updateSettings({ chartBase: base, chartQuote: quote });
    }
    setReady(true);
  }, [base, quote, updateSettings]);

  // Keyboard shortcut: Cmd+K to open pair selector
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key === 'k') {
        e.preventDefault();
        setPairSelectorOpen(true);
      }
    };

    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, []);

  if (!ready) return null;

  // Toolbar height is 32px (h-8), account for it in chart height
  const TOOLBAR_HEIGHT = 32;

  return (
    <div className="w-screen h-screen bg-bg-0 overflow-hidden">
      <PriceChart
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
      />
      <PairSelector
        isOpen={pairSelectorOpen}
        onClose={() => setPairSelectorOpen(false)}
        onSelect={handleChangePair}
        currentBase={base}
        currentQuote={quote}
      />
    </div>
  );
}
