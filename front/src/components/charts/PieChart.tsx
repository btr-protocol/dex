import { useEffect, useRef } from 'preact/hooks';
import type { PieChartProps } from './types';
import type { ChartConfig } from './types';
import * as Chartist from 'chartist';
import 'chartist/dist/index.css';

/**
 * Pie and donut chart component using Chartist.js
 *
 * @example
 * ```tsx
 * // Simple pie chart
 * <PieChart data={[10, 20, 30]} />
 *
 * // Donut chart with custom colors
 * <PieChart
 *   data={[25, 50, 25]}
 *   color={['#E99339', '#3d7eff', '#10B981']}
 *   donut={true}
 *   donutWidth={20}
 * />
 *
 * // With labels
 * <PieChart
 *   data={[30, 70]}
 *   labels={['BTC', 'ETH']}
 *   color={['#E99339', '#3d7eff']}
 * />
 * ```
 */
export function PieChart(props: PieChartProps & { config?: ChartConfig }) {
  const chartRef = useRef<HTMLDivElement>(null);
  const styleRef = useRef<HTMLStyleElement | null>(null);

  // Extract config if provided
  const config = props.config;

  useEffect(() => {
    if (!chartRef.current) return;

    const data = config?.data ?? props.data;

    if (!Array.isArray(data) || data.length === 0) return;

    // Flatten data if needed (pie charts always use flat series)
    const series = Array.isArray(data[0]) ? (data as number[][]).flat() : (data as number[]);

    const chartData = {
      labels: (config?.labels ?? props.labels) || series.map((_: number, i: number) => i.toString()),
      series,
    };

    const options = {
      width: config?.width ?? props.width ?? 300,
      height: config?.height ?? props.height ?? 300,
      donut: config?.donut ?? props.donut ?? false,
      donutWidth: config?.donutWidth ?? props.donutWidth ?? 20,
      chartPadding: 0,
      showLabel: true,
      labelPosition: 'outside' as const,
    };

    // Clear previous chart
    chartRef.current.innerHTML = '';

    // Create new chart (type assertion for Chartist.js types)
    const ChartistLib = Chartist;
    const chart = new (ChartistLib as any).Pie(chartRef.current, chartData as any, options as any);

    // Apply custom styling
    const styleId = Math.random().toString(36).substr(2, 9);
    const configColor = config?.color ?? props.color;
    const colors = Array.isArray(configColor) ? configColor : configColor ? [configColor] : undefined;

    const cssRules: string[] = [];

    if (colors) {
      colors.forEach((c, i) => {
        cssRules.push(`
          .pie-chart-${styleId} .ct-series:nth-child(${i + 1}) .ct-slice-pie,
          .pie-chart-${styleId} .ct-series:nth-child(${i + 1}) .ct-slice-donut {
            stroke: ${c} !important;
            fill: ${c} !important;
          }
        `);
      });
    }

    // Label styling
    cssRules.push(`
      .pie-chart-${styleId} .ct-label {
        fill: var(--fg-1);
        color: var(--fg-1);
        font-family: var(--font-body);
        font-size: 12px;
      }
    `);

    // Remove previous style
    if (styleRef.current) {
      styleRef.current.remove();
    }

    const style = document.createElement('style');
    style.textContent = cssRules.join('\n');
    document.head.appendChild(style);
    styleRef.current = style;
    chartRef.current.classList.add(`pie-chart-${styleId}`);

    return () => {
      if (styleRef.current) {
        styleRef.current.remove();
      }
      chart.detach();
    };
  }, [props]);

  return (
    <div
      ref={chartRef}
      className={`ct-chart ${(props.className ?? props.config?.className)}`}
      style={{ width: props.config?.width ?? props.width ?? 300, height: props.config?.height ?? props.height ?? 300 }}
    />
  );
}
