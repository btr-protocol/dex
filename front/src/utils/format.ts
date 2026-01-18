// Re-export all formatting utilities from SDK
export {
  // Currency
  CURRENCY_SYMBOLS,
  formatCurrency,
  formatCurrencyCompact,
  // Numbers
  formatNumber,
  formatCompact,
  formatPrice,
  formatAxisLabel,
  // Percentages
  formatPercent,
  // Duration/Size
  formatDuration,
  formatBytes,
  // Text
  shortenAddress,
  slugify,
  unslug,
  capitalize,
  // Parsing
  parseFormattedNumber,
} from '@sdk/utils/format';

// Re-export math utilities for convenience
export {
  calcPercentChange,
  round,
  roundAutoPrecision,
  precision,
  getMagnitude,
  clamp,
  min,
  max,
  minmax,
  average,
  niceScale,
} from '@sdk/utils/maths';

// Re-export date formatting utilities
export {
  formatTime,
  formatDayHeader,
  formatTimeAgo,
  formatVerticalLineTime,
} from './date';
