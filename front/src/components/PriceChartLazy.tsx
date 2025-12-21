import { Suspense, lazy } from 'preact/compat';

const PriceChartComponent = lazy(() =>
  import('./PriceChart').then(m => ({ default: m.PriceChart }))
);

interface PriceChartProps {
  base: string;
  quote: string;
  height?: number;
  className?: string;
  onChangePair?: (base: string, quote: string) => void;
  onInvertPair?: () => void;
}

export function PriceChart(props: PriceChartProps) {
  return (
    <Suspense
      fallback={
        <div
          className={`relative ${props.className || ''}`}
          style={{ height: props.height || '100%', width: '100%' }}
        >
          <div className="absolute inset-0 flex items-center justify-center">
            <div className="text-muted-foreground text-sm animate-pulse">
              Loading chart...
            </div>
          </div>
        </div>
      }
    >
      <PriceChartComponent {...props} />
    </Suspense>
  ) as JSX.Element;
}

// Re-export PriceDisplay from PriceChart (it doesn't use lightweight-charts at runtime,
// but shares code - acceptable trade-off for lazy loading the whole module)
export { PriceDisplay } from './PriceChart';
