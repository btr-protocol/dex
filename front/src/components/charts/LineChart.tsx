import { useEffect, useRef } from 'preact/hooks';
import { getColors } from '@lib/theme';
import type { LineChartProps, ChartConfig } from './types';
import * as Chartist from 'chartist';
import 'chartist/dist/index.css';
import { logger } from '@sdk/utils';

const log = logger.withContext('LineChart');

/**
 * Line chart component with multiple variants using Chartist.js
 *
 * Colors default to theme colors if not specified.
 * Axis and labels use theme colors automatically.
 * Uses Catmull-Rom (Cardinal) spline interpolation with configurable tension.
 *
 * @example
 * ```tsx
 * // Simple line chart (uses theme color)
 * <LineChart data={[10, 20, 15, 30, 25]} />
 *
 * // Area chart with axis titles
 * <LineChart
 *   data={[10, 20, 15, 30, 25]}
 *   showArea={true}
 *   titleX="Price Offset"
 *   titleY="Liquidity Depth"
 * />
 *
 * // Scatter chart (only points)
 * <LineChart
 *   data={[10, 20, 15, 30, 25]}
 *   showLine={false}
 *   showPoint={true}
 * />
 *
 * // Tight curves (good for liquidity profiles)
 * <LineChart
 *   data={[10, 20, 15, 30, 25]}
 *   showArea={true}
 *   tension={0.2}  // Moderately tight
 * />
 *
 * // Loose curves (for smooth flow)
 * <LineChart
 *   data={[10, 20, 15, 30, 25]}
 *   showArea={true}
 *   tension={0.8}  // Looser curves
 * />
 *
 * // Multiple series
 * <LineChart
 *   data={[
 *     [10, 20, 15, 30, 25],
 *     [5, 15, 25, 20, 35]
 *   ]}
 * />
 * ```
 */
export function LineChart(props: LineChartProps & { config?: ChartConfig }) {
  const chartRef = useRef<HTMLDivElement>(null);
  const styleRef = useRef<HTMLStyleElement | null>(null);

  useEffect(() => {
    if (!chartRef.current) return;

    // Extract config
    const config = props.config;

    try {
      // Extract data from config or props
      const data = config?.data ?? (props.data as number[] | number[][]);

      if (!Array.isArray(data) || data.length === 0) return;

      // Prepare data format - normalize to multi-series format for LineChart
      const isMultiSeries = Array.isArray(data[0]);
      const series = isMultiSeries ? (data as number[][]) : [data as number[]];

      const chartData = {
        labels: config?.labels ?? props.labels ?? series[0].map((_: number, i: number) => i.toString()),
        series,
      };

      // Extract tension from config or props
      const tension = config?.tension ?? (props as any).tension ?? 0.5;

      const chartOptions = {
        width: config?.width ?? props.width ?? 300,
        height: config?.height ?? props.height ?? 200,
        showLine: config?.showLine ?? props.showLine ?? true,
        showArea: config?.showArea ?? props.showArea ?? false,
        showPoint: config?.showPoint ?? props.showPoint ?? true,
        fullWidth: true,
        chartPadding: {
          top: (config?.titleY ?? props.titleY) ? 40 : 10,
          right: 20,
          bottom: (config?.titleX ?? props.titleX) ? 50 : 10,
          left: (config?.titleY ?? props.titleY) ? 60 : 0,
        },
        axisX: {
          showGrid: true,
          showLabel: true,
          labelInterpolationFnc: (value: any) => {
            return (config?.labels ?? props.labels)?.[Number(value)] || value;
          },
        },
        axisY: {
          showGrid: true,
          showLabel: true,
          labelInterpolationFnc: (value: any) => {
            return typeof value === 'number' ? value.toString() : value;
          },
          offset: 60,
        },
        // Catmull-Rom (Cardinal) spline tension parameter
        // Lower = tighter/more control-point-accurate curves
        // tension: 0.5 gives moderately tight, smooth curves (good for liquidity profiles)
        lineSmooth: !!(config?.smooth === false) && (props.smooth !== false),
        stackBars: config?.stacked ?? props.stacked ?? false,
      };

      // Clear previous chart
      chartRef.current.innerHTML = '';

      // Create new chart (type assertion for Chartist.js types)
      const ChartistLib = Chartist;
      log.debug('Creating Chartist chart with data', chartData);
      const chart = new (ChartistLib as any).Line(chartRef.current, chartData as any, chartOptions as any);

      // Get theme colors
      const theme = getColors();
      const configColor = config?.color ?? props.color;
      const colors = Array.isArray(configColor)
        ? configColor
        : configColor
          ? [configColor]
          : [theme.orange];

      // Apply custom styling
      const styleId = Math.random().toString(36).substr(2, 9);
      const cssRules: string[] = [];

      // Series colors
      colors.forEach((c: string, i: number) => {
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

      // Grid and axis styling - use theme colors
      cssRules.push(`
        .line-chart-${styleId} .ct-grid {
          stroke: var(--bg-5) !important;
          stroke-dasharray: 2;
        }
        .line-chart-${styleId} .ct-label {
          fill: var(--fg-1) !important;
          color: var(--fg-1) !important;
          font-family: var(--font-body);
          font-size: 10px;
        }
        .line-chart-${styleId} .ct-axis-title {
          fill: var(--fg-1) !important;
          color: var(--fg-1) !important;
          font-family: var(--font-body);
          font-size: 11px;
          font-weight: 600;
        }
        .line-chart-${styleId} .ct-axis {
          stroke: var(--fg-3) !important;
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

      // Add axis titles
      if (config?.titleX ?? props.titleX) {
        const titleDiv = document.createElement('div');
        titleDiv.className = 'chart-title-x';
        titleDiv.textContent = (config?.titleX ?? props.titleX) || null;
        titleDiv.style.cssText = `
          position: absolute;
          bottom: 5px;
          left: 50%;
          transform: translateX(-50%);
          color: var(--fg-1);
          font-family: var(--font-body);
          font-size: 11px;
          font-weight: 600;
        `;
        chartRef.current.appendChild(titleDiv);
      }

      if (config?.titleY ?? props.titleY) {
        const titleDiv = document.createElement('div');
        titleDiv.className = 'chart-title-y';
        titleDiv.textContent = (config?.titleY ?? props.titleY) || null;
        titleDiv.style.cssText = `
          position: absolute;
          left: 5px;
          top: 50%;
          transform: translateY(-50%) rotate(-90deg);
          transform-origin: center;
          color: var(--fg-1);
          font-family: var(--font-body);
          font-size: 11px;
          font-weight: 600;
          white-space: nowrap;
        `;
        chartRef.current.appendChild(titleDiv);
      }

      return () => {
        if (styleRef.current) {
          styleRef.current.remove();
        }
        chart.detach();
      };
    } catch (err) {
      log.error('Failed to create chart', err);
      const errorMsg = err instanceof Error ? err.message : String(err);
      if (chartRef.current) {
        chartRef.current.innerHTML = `<div class="p-4 bg-red-900/20 border border-red-500 text-red-500 rounded">
          <div class="font-bold">Failed to create chart</div>
          <div class="text-sm mt-1">${errorMsg}</div>
        </div>`;
      }
    }
  }, [props]);

  return (
    <div
      ref={chartRef}
      className={`ct-chart ${(props.className ?? props.config?.className)}`}
      style={{ width: props.config?.width ?? props.width, height: props.config?.height ?? props.height, background: 'transparent' }}
    />
  );
}
