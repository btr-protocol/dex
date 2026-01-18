import { useEffect, useRef } from 'preact/hooks';
import { BarChart as ChartistBar } from 'chartist';
import type { BarChartProps } from './types';

/**
 * Bar chart component using Chartist.js
 *
 * @example
 * ```tsx
 * // Simple vertical bar chart
 * <BarChart data={[10, 20, 30, 40]} />
 *
 * // Horizontal bar chart with labels
 * <BarChart
 *   data={[100, 200, 150]}
 *   labels={['BTC', 'ETH', 'SOL']}
 *   horizontal={true}
 *   color="#E99339"
 * />
 *
 * // Stacked bars with multiple series
 * <BarChart
 *   data={[
 *     [10, 20, 30],
 *     [20, 10, 15]
 *   ]}
 *   stacked={true}
 *   color={['#E99339', '#3d7eff']}
 * />
 * ```
 */
export function BarChart({
  data,
  labels,
  width = 300,
  height = 200,
  color,
  className = '',
  horizontal = false,
  stacked = false,
}: BarChartProps) {
  const chartRef = useRef<HTMLDivElement>(null);
  const styleRef = useRef<HTMLStyleElement | null>(null);

  useEffect(() => {
    if (!chartRef.current || !Array.isArray(data) || data.length === 0) return;

    // Prepare data format - normalize to multi-series format for BarChart
    const isMultiSeries = Array.isArray(data[0]);
    const series = isMultiSeries ? (data as number[][]) : [data as number[]];

    const chartData = {
      labels: labels || series[0].map((_: number, i: number) => i.toString()),
      series,
    };

    const options = {
      width,
      height,
      axisX: {
        showGrid: true,
        showLabel: true,
      },
      axisY: {
        showGrid: true,
        showLabel: true,
        offset: horizontal ? 40 : 0,
      },
      chartPadding: {
        top: 10,
        right: 20,
        bottom: 10,
        left: horizontal ? 40 : 0,
      },
      stackBars: stacked,
      horizontalBars: horizontal,
    };

    // Clear previous chart
    chartRef.current.innerHTML = '';

    // Create new chart (type assertion for Chartist.js types)
    const chart = new ChartistBar(chartRef.current, chartData as any, options as any);

    // Apply custom styling
    const styleId = Math.random().toString(36).substr(2, 9);
    const colors = Array.isArray(color) ? color : color ? [color] : undefined;

    const cssRules: string[] = [];

    if (colors) {
      colors.forEach((c, i) => {
        cssRules.push(`
          .bar-chart-${styleId} .ct-series:nth-child(${i + 1}) .ct-bar {
            stroke: ${c} !important;
          }
        `);
      });
    }

    // Grid and label styling
    cssRules.push(`
      .bar-chart-${styleId} .ct-grid {
        stroke: var(--chart-grid);
        stroke-dasharray: 2;
      }
      .bar-chart-${styleId} .ct-label {
        fill: var(--chart-text);
        color: var(--chart-text);
        font-family: var(--font-body);
        font-size: 10px;
      }
      .bar-chart-${styleId} .ct-axis-title {
        fill: var(--chart-text);
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
    chartRef.current.classList.add(`bar-chart-${styleId}`);

    return () => {
      if (styleRef.current) {
        styleRef.current.remove();
      }
      chart.detach();
    };
  }, [data, labels, width, height, color, horizontal, stacked]);

  return (
    <div
      ref={chartRef}
      className={`ct-chart ${className}`}
      style={{ width, height }}
    />
  );
}
