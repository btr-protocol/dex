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
  /** Single color or array of colors for series */
  color?: string | string[];
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
  /** Use smooth bezier curves */
  smooth?: boolean;
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
