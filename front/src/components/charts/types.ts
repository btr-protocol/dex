/**
 * Chart configuration from markdown (```chart blocks)
 * This interface is used to decode chart configs embedded in HTML
 *
 * NB: Colors default to theme colors if not specified.
 * Axis labels/titles default to theme colors (var(--fg-1)).
 * 
 * Smoothing: Catmull-Rom (Cardinal) spline uses tension parameter:
 * - tension: 0.5 (tight/loose) - moderately tight curves (good for liquidity profiles)
 * - tension: 0.3 (very loose) - more flowing curves
 * - tension: 0.2 (default-ish) - standard smoothness
 * - tension: 1.0 (very tight) - almost no curves
 *
 * NB: Chartist's `lineSmooth: true` is a boolean flag that uses Cardinal interpolation.
 * Use `tension` directly for more control over curve tightness.
 */
export interface ChartConfig {
  /** Chart type */
  type: 'pie' | 'bar' | 'line' | 'sparkline';
  /** Data array (single series) or 2D array (multiple series) */
  data: number[] | number[][];
  /** Optional labels for data points */
  labels?: string[];
  /** Chart width in pixels */
  width?: number;
  /** Chart height in pixels */
  height?: number;
  /** Single color or array of colors for series (defaults to theme) */
  color?: string | string[];
  /** X-axis title */
  titleX?: string;
  /** Y-axis title */
  titleY?: string;
  /** Additional CSS classes */
  className?: string;
  /** Line chart options */
  showLine?: boolean;
  showArea?: boolean;
  showPoint?: boolean;
  /** Use smooth bezier curves (deprecated: use tension parameter for Catmull-Rom) */
  smooth?: boolean;
  /** Catmull-Rom spline tension (0=tight, 0.5=default-ish, higher=looser) */
  tension?: number;
  stacked?: boolean;
  /** Bar chart options */
  horizontal?: boolean;
  /** Pie chart options */
  donut?: boolean;
  donutWidth?: number;
}

/**
 * Common base props for all chart components
 */
export interface ChartBaseProps {
  /** Data array (single series) or 2D array (multiple series) */
  data: number[] | number[][];
  /** Optional labels for data points */
  labels?: string[];
  /** Chart width in pixels */
  width?: number;
  /** Chart height in pixels */
  height?: number;
  /** Single color or array of colors for series (defaults to theme) */
  color?: string | string[];
  /** X-axis title */
  titleX?: string;
  /** Y-axis title */
  titleY?: string;
  /** Additional CSS classes */
  className?: string;
}

/**
 * Props for LineChart component
 */
export interface LineChartProps extends ChartBaseProps {
  /** Show line path */
  showLine?: boolean;
  /** Show area under line */
  showArea?: boolean;
  /** Show data points */
  showPoint?: boolean;
  /** Use smooth bezier curves (deprecated: use tension) */
  smooth?: boolean;
  /** Catmull-Rom spline tension (0=tight, 0.5=default, higher=looser) */
  tension?: number;
  /** Stack multiple series */
  stacked?: boolean;
}

/**
 * Props for BarChart component
 */
export interface BarChartProps extends ChartBaseProps {
  /** Display bars horizontally instead of vertically */
  horizontal?: boolean;
  /** Stack multiple series */
  stacked?: boolean;
}

/**
 * Props for PieChart component
 */
export interface PieChartProps extends ChartBaseProps {
  /** Display as donut chart (hollow center) */
  donut?: boolean;
  /** Thickness of donut (only applies when donut=true) */
  donutWidth?: number;
}

/**
 * Props for Sparkline component
 */
export interface SparklineProps extends LineChartProps {
  // Inherits all LineChartProps, but axes are always hidden
}

/**
 * Normalized data format for Chartist.js
 */
export function normalizeSeries(
  data: number[] | number[][]
): { series: number[][]; labels: string[]; isMultiSeries: boolean } {
  // Handle single number (edge case)
  if (typeof data === 'number') {
    return { series: [[data]], labels: ['0'], isMultiSeries: true };
  }

  // Handle empty array
  if (Array.isArray(data) && data.length === 0) {
    return { series: [[]], labels: [], isMultiSeries: false };
  }

  // Check if it's a single series (array of numbers)
  const firstElement = data[0];
  if (typeof firstElement === 'number') {
    return {
      series: [data as number[]],
      labels: data.map((_, i) => i.toString()),
      isMultiSeries: false,
    };
  }

  // Multi-series (2D array)
  const multiSeries = data as number[][];
  const maxLen = Math.max(...multiSeries.map(s => s.length));
  return {
    series: multiSeries,
    labels: Array.from({ length: maxLen }, (_, i) => i.toString()),
    isMultiSeries: true,
  };
}
