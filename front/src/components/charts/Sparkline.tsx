import type { SparklineProps } from './types';
import { LineChart } from './LineChart';

/**
 * Sparkline component - a minimalist line chart with no axes
 * Perfect for showing trends in small spaces
 *
 * @example
 * ```tsx
 * // Basic sparkline
 * <Sparkline data={[10, 20, 15, 30, 25]} />
 *
 * // With custom dimensions and color
 * <Sparkline
 *   data={[10, 20, 15, 30, 25]}
 *   width={120}
 *   height={40}
 *   color="#10B981"
 * />
 *
 * // As area sparkline
 * <Sparkline
 *   data={[10, 20, 15, 30, 25]}
 *   showArea={true}
 *   showPoint={false}
 *   color="#E99339"
 * />
 *
 * // Smooth curve
 * <Sparkline
 *   data={[10, 20, 15, 30, 25]}
 *   smooth={true}
 *   showArea={true}
 * />
 * ```
 */
export function Sparkline(props: SparklineProps) {
  return (
    <LineChart
      {...props}
      // Sparkline-specific overrides
      showPoint={props.showPoint ?? false}
      showArea={props.showArea ?? true}
      // We'll hide axes via CSS styling in LineChart
      className={`${props.className || ''} sparkline`}
    />
  );
}

/**
 * Alias for backward compatibility with SimpleSparkline
 */
export { Sparkline as SimpleSparkline };
