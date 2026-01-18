import { useState, useEffect } from 'preact/hooks';
import type { ChartType } from './indicatorsConfig';
import type { InitialIndicator } from './useIndicatorParams';

interface PriceChartProps {
  base: string;
  quote: string;
  height?: number;
  className?: string;
  initialTimeframe?: number;
  initialChartType?: ChartType;
  initialIndicators?: InitialIndicator[];
  standalone?: boolean;
  onChangePair?: (base: string, quote: string) => void;
  onInvertPair?: () => void;
  onTimeframeChange?: (timeframe: number) => void;
  onChartTypeChange?: (chartType: ChartType) => void;
  onIndicatorsChange?: (indicators: InitialIndicator[]) => void;
}

export function PriceChart(props: PriceChartProps) {
  const [Component, setComponent] = useState<any>(null);

  useEffect(() => {
    import('./index').then(m => setComponent(() => m.PriceChart));
  }, []);

  return (
    <div
      className={`relative`}
      style={{ height: props.height || '100%', width: '100%' }}
    >
      {!Component ? (
        <div className="absolute inset-0 flex items-center justify-center">
          <div className="text-muted-foreground text-sm animate-pulse">
            Loading chart...
          </div>
        </div>
      ) : (
        <Component {...props} />
      )}
    </div>
  );
}

// Re-export PriceDisplay from index (it doesn't use lightweight-charts at runtime,
// but shares code - acceptable trade-off for lazy loading the whole module)
export { PriceDisplay } from './index';
