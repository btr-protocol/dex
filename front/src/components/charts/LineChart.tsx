import { useEffect, useRef } from 'preact/hooks';
import { LineChart as ChartistLine } from 'chartist';
import type { LineChartProps } from './types';

/**
 * Line chart component with multiple variants using Chartist.js
 *
 * @example
 * ```tsx
 * // Simple line chart
 * <LineChart data={[10, 20, 15, 30, 25]} />
 *
 * // Area chart
 * <LineChart
 *   data={[10, 20, 15, 30, 25]}
 *   showArea={true}
 *   color="#E99339"
 * />
 *
 * // Scatter chart (only points)
 * <LineChart
 *   data={[10, 20, 15, 30, 25]}
 *   showLine={false}
 *   showPoint={true}
 * />
 *
 * // Smooth line with area
 * <LineChart
 *   data={[10, 20, 15, 30, 25]}
 *   showArea={true}
 *   smooth={true}
 *   color="#3d7eff"
 * />
 *
 * // Multiple series
 * <LineChart
 *   data={[
 *     [10, 20, 15, 30, 25],
 *     [5, 15, 25, 20, 35]
 *   ]}
 *   color={['#E99339', '#3d7eff']}
 * />
 * ```
 */
export function LineChart({
  data,
  labels,
  width = 300,
  height = 200,
  color,
  className = '',
  showLine = true,
  showArea = false,
  showPoint = true,
  smooth = false,
  stacked = false,
}: LineChartProps) {
  const chartRef = useRef<HTMLDivElement>(null);
  const styleRef = useRef<HTMLStyleElement | null>(null);

  useEffect(() => {
    if (!chartRef.current || !Array.isArray(data) || data.length === 0) return;

    // Prepare data format - normalize to multi-series format for LineChart
    const isMultiSeries = Array.isArray(data[0]);
    const series = isMultiSeries ? (data as number[][]) : [data as number[]];

    const chartData = {
      labels: labels || series[0].map((_: number, i: number) => i.toString()),
      series,
    };

    const options = {
      width,
      height,
      showLine,
      showArea,
      showPoint,
      fullWidth: true,
      chartPadding: {
        top: 10,
        right: 20,
        bottom: 10,
        left: 0,
      },
      axisX: {
        showGrid: true,
        showLabel: true,
      },
      axisY: {
        showGrid: true,
        showLabel: true,
        offset: 40,
      },
      lineSmooth: smooth,
      stackBars: stacked,
    };

    // Clear previous chart
    chartRef.current.innerHTML = '';

    // Create new chart (type assertion for Chartist.js types)
    const chart = new ChartistLine(chartRef.current, chartData as any, options as any);

    // Apply custom styling
    const styleId = Math.random().toString(36).substr(2, 9);
    const colors = Array.isArray(color) ? color : color ? [color] : undefined;

    const cssRules: string[] = [];

    if (colors) {
      colors.forEach((c, i) => {
        cssRules.push(`
          .line-chart-${styleId} .ct-series:nth-child(${i + 1}) .ct-line {
            stroke: ${c} !important;
            stroke-width: 2px;
          }
          .line-chart-${styleId} .ct-series:nth-child(${i + 1}) .ct-point {
            stroke: ${c} !important;
            stroke-width: 2px;
          }
          .line-chart-${styleId} .ct-series:nth-child(${i + 1}) .ct-area {
            fill: ${c}20 !important;
          }
        `);
      });
    }

    // Grid and label styling
    cssRules.push(`
      .line-chart-${styleId} .ct-grid {
        stroke: var(--chart-grid);
        stroke-dasharray: 2;
      }
      .line-chart-${styleId} .ct-label {
        fill: var(--chart-text);
        color: var(--chart-text);
        font-family: var(--font-body);
        font-size: 10px;
      }
      .line-chart-${styleId} .ct-axis {
        stroke: var(--chart-border);
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
    chartRef.current.classList.add(`line-chart-${styleId}`);

    return () => {
      if (styleRef.current) {
        styleRef.current.remove();
      }
      chart.detach();
    };
  }, [data, labels, width, height, color, showLine, showArea, showPoint, smooth, stacked]);

  return (
    <div
      ref={chartRef}
      className={`ct-chart ${className}`}
      style={{ width, height }}
    />
  );
}
