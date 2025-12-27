/**
 * Math utilities for rounding, precision, and numerical operations
 * Used across frontend, backend, and SDK for consistent number handling
 */

// ─────────────────────────────────────────────────────────────
// Array Statistics
// ─────────────────────────────────────────────────────────────

export function minmax(data: number[]): [min: number, max: number] {
  if (data.length === 0) return [0, 0];
  let min = data[0];
  let max = data[0];
  for (let i = 1; i < data.length; i++) {
    if (data[i] < min) min = data[i];
    if (data[i] > max) max = data[i];
  }
  return [min, max];
}

export function min(data: number[]): number {
  if (data.length === 0) return 0;
  let result = data[0];
  for (let i = 1; i < data.length; i++) {
    if (data[i] < result) result = data[i];
  }
  return result;
}

export function max(data: number[]): number {
  if (data.length === 0) return 0;
  let result = data[0];
  for (let i = 1; i < data.length; i++) {
    if (data[i] > result) result = data[i];
  }
  return result;
}

export function average(arr: number[]): number {
  if (arr.length === 0) return 0;
  return arr.reduce((a, v) => a + v, 0) / arr.length;
}

export function sum(arr: number[]): number {
  return arr.reduce((a, v) => a + v, 0);
}

// ─────────────────────────────────────────────────────────────
// Percentage Calculations
// ─────────────────────────────────────────────────────────────

export function calcPercent(partialValue: number, totalValue: number): number {
  if (totalValue === 0) return 0;
  return (100 * partialValue) / totalValue;
}

export function calcPercentChange(oldValue: number, newValue: number): number {
  if (oldValue === 0) return newValue === 0 ? 0 : 100;
  return ((newValue - oldValue) / Math.abs(oldValue)) * 100;
}

// ─────────────────────────────────────────────────────────────
// Rounding Functions
// ─────────────────────────────────────────────────────────────

export function round(n: number | undefined | null, scale = 5): number {
  if (n == null || !isFinite(n)) return 0;
  const multiplier = Math.pow(10, scale);
  return Math.round((n + Number.EPSILON) * multiplier) / multiplier;
}

export function ceil(n: number, scale: number): number {
  const multiplier = Math.pow(10, scale);
  return Math.ceil((n + Number.EPSILON) * multiplier) / multiplier;
}

export function floor(n: number, scale: number): number {
  const multiplier = Math.pow(10, scale);
  return Math.floor((n + Number.EPSILON) * multiplier) / multiplier;
}

export function roundAutoPrecision(n: number | undefined | null): number {
  if (n == null || !isFinite(n)) return 0;
  return round(n, precision(n));
}

// ─────────────────────────────────────────────────────────────
// Number Analysis
// ─────────────────────────────────────────────────────────────

export function getDigits(x: number): number {
  if (x === 0) return 1;
  return Math.floor(Math.log10(Math.abs(x))) + 1;
}

export function getTrailingZeros(s: string): number {
  let n = 0;
  while (s.charAt(s.length - n - 1) === '0') n++;
  return n;
}

export function getScale(n: number, maxPrecision = 16): number {
  if (!isFinite(n)) return 0;
  const digits = Math.round(Math.abs(n)).toString().length;
  const roundingScale = Math.max(maxPrecision - digits, 1);
  const s = round(n, roundingScale).toFixed(roundingScale);
  const floatIndex = s.indexOf('.') + 1;
  return floatIndex > 0 ? s.length - floatIndex - getTrailingZeros(s) : 0;
}

/**
 * Get the order of magnitude of a number
 * Examples:
 *   0.001 -> 0.001
 *   0.05 -> 0.01
 *   0.5 -> 0.1
 *   5 -> 1
 *   50 -> 10
 *   500 -> 100
 *   5000 -> 1000
 */
export function getMagnitude(n: number): number {
  if (n === 0) return 1;
  n = Math.abs(n);
  if (n >= 1) {
    const digits = Math.floor(Math.log10(n));
    return Math.pow(10, digits);
  } else {
    // Count leading zeros after decimal
    const leadingZeros = Math.floor(-Math.log10(n));
    return Math.pow(10, -(leadingZeros + 1));
  }
}

/**
 * Determine appropriate decimal precision based on number magnitude
 * Larger numbers need fewer decimals, smaller numbers need more
 */
export function precision(n: number): number {
  if (n === 0) return 2;
  const absN = Math.abs(n);

  // For very large numbers, use fewer decimals
  if (absN >= 1_000_000) return 0;
  if (absN >= 100_000) return 1;
  if (absN >= 10_000) return 1;
  if (absN >= 1_000) return 2;
  if (absN >= 100) return 2;
  if (absN >= 10) return 3;
  if (absN >= 1) return 4;

  // For small numbers, count leading zeros and add precision
  const leadingZeros = Math.floor(-Math.log10(absN));
  return Math.min(leadingZeros + 4, 12); // Cap at 12 decimal places
}

// ─────────────────────────────────────────────────────────────
// Clamp and Range Functions
// ─────────────────────────────────────────────────────────────

export function clamp(value: number, min: number, max: number): number {
  return Math.max(min, Math.min(max, value));
}

export function lerp(a: number, b: number, t: number): number {
  return a + (b - a) * t;
}

export function inverseLerp(a: number, b: number, value: number): number {
  if (a === b) return 0;
  return (value - a) / (b - a);
}

export function remap(
  value: number,
  inMin: number,
  inMax: number,
  outMin: number,
  outMax: number,
): number {
  return lerp(outMin, outMax, inverseLerp(inMin, inMax, value));
}

// ─────────────────────────────────────────────────────────────
// Nice Numbers for Chart Axes
// ─────────────────────────────────────────────────────────────

/**
 * Find a "nice" number for axis ticks
 * Based on Graphics Gems algorithm
 */
export function niceNum(range: number, round: boolean): number {
  const exponent = Math.floor(Math.log10(range));
  const fraction = range / Math.pow(10, exponent);

  let niceFraction: number;
  if (round) {
    if (fraction < 1.5) niceFraction = 1;
    else if (fraction < 3) niceFraction = 2;
    else if (fraction < 7) niceFraction = 5;
    else niceFraction = 10;
  } else {
    if (fraction <= 1) niceFraction = 1;
    else if (fraction <= 2) niceFraction = 2;
    else if (fraction <= 5) niceFraction = 5;
    else niceFraction = 10;
  }

  return niceFraction * Math.pow(10, exponent);
}

/**
 * Calculate nice axis bounds and tick interval
 */
export function niceScale(
  min: number,
  max: number,
  maxTicks = 10,
): { min: number; max: number; tickSpacing: number } {
  const range = niceNum(max - min, false);
  const tickSpacing = niceNum(range / (maxTicks - 1), true);
  const niceMin = Math.floor(min / tickSpacing) * tickSpacing;
  const niceMax = Math.ceil(max / tickSpacing) * tickSpacing;

  return { min: niceMin, max: niceMax, tickSpacing };
}
