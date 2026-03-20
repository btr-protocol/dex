/**
 * Formatting utilities for numbers, currencies, durations, and text
 * Used across frontend and backend for consistent display
 */

import { round, precision, getDigits } from './maths.js';

// ─────────────────────────────────────────────────────────────
// Currency
// ─────────────────────────────────────────────────────────────

export const CURRENCY_SYMBOLS: Record<string, string> = {
  USD: '$', EUR: '€', GBP: '£', JPY: '¥', CNY: '¥',
  CHF: 'CHF', CAD: 'C$', AUD: 'A$', KRW: '₩', INR: '₹',
};

/** Format currency with auto-precision based on magnitude */
export function formatCurrency(n: number | null | undefined, currency = 'USD', signed = false): string {
  if (n == null || !isFinite(n)) return `${CURRENCY_SYMBOLS[currency] ?? '$'}0.00`;

  const absN = Math.abs(n);
  const sign = n < 0 ? '-' : signed ? '+' : '';
  const symbol = CURRENCY_SYMBOLS[currency] ?? '$';

  // Large values: compact notation
  if (absN >= 1_000_000_000) return `${sign}${symbol}${round(absN / 1_000_000_000, 2)}B`;
  if (absN >= 1_000_000) return `${sign}${symbol}${round(absN / 1_000_000, 2)}M`;
  if (absN >= 10_000) return `${sign}${symbol}${round(absN / 1_000, 1)}K`;

  // Standard values: 2 decimals with commas
  if (absN >= 1) {
    return sign + symbol + absN.toLocaleString('en-US', {
      minimumFractionDigits: 2,
      maximumFractionDigits: 2,
    });
  }

  // Small values: show significant figures
  const decimals = absN >= 0.01 ? 4 : getDigits(absN) + 2;
  return sign + symbol + absN.toFixed(Math.min(decimals, 8));
}

/** Format currency with compact notation ($1.5M, $2.3B) */
export function formatCurrencyCompact(n: number | null | undefined, currency = 'USD', signed = false): string {
  if (n == null || !isFinite(n)) return `${CURRENCY_SYMBOLS[currency] ?? '$'}0`;

  const absN = Math.abs(n);
  const sign = n < 0 ? '-' : signed ? '+' : '';
  const symbol = CURRENCY_SYMBOLS[currency] ?? '$';

  if (absN >= 1_000_000_000_000) return `${sign}${symbol}${round(absN / 1_000_000_000_000, 2)}T`;
  if (absN >= 1_000_000_000) return `${sign}${symbol}${round(absN / 1_000_000_000, 2)}B`;
  if (absN >= 1_000_000) return `${sign}${symbol}${round(absN / 1_000_000, 2)}M`;
  if (absN >= 1_000) return `${sign}${symbol}${round(absN / 1_000, 2)}K`;

  return `${sign}${symbol}${round(absN, 2)}`;
}

// ─────────────────────────────────────────────────────────────
// Token Units (Ethereum Wei/Decimals)
// ─────────────────────────────────────────────────────────────

/** Format token amount from wei to decimal string */
export function formatUnits(value: bigint, decimals: number): string {
  const str = value.toString().padStart(decimals + 1, '0');
  const intPart = str.slice(0, -decimals) || '0';
  const decPart = str.slice(-decimals);
  const trimmed = decPart.replace(/0+$/, '');
  return trimmed ? `${intPart}.${trimmed}` : intPart;
}

/** Parse decimal string to token amount (wei) */
export function parseUnits(value: string, decimals: number): bigint {
  const [intPart, decPart = ''] = value.split('.');
  const padded = decPart.padEnd(decimals, '0').slice(0, decimals);
  return BigInt(intPart + padded);
}

/** Format from wei to ether (18 decimals) */
export function formatEther(value: bigint): string {
  return formatUnits(value, 18);
}

/** Parse ether decimal to wei */
export function parseEther(value: string): bigint {
  return parseUnits(value, 18);
}

// ─────────────────────────────────────────────────────────────
// Numbers
// ─────────────────────────────────────────────────────────────

/** Format number with auto-precision */
export function formatNumber(n: number | null | undefined, maxDecimals?: number): string {
  if (n == null || !isFinite(n)) return '0';

  const decimals = maxDecimals ?? precision(n);
  const rounded = round(n, decimals);

  if (Math.abs(rounded) >= 1000) {
    return rounded.toLocaleString('en-US', {
      minimumFractionDigits: 0,
      maximumFractionDigits: decimals,
    });
  }

  return rounded.toFixed(decimals).replace(/\.?0+$/, '') || '0';
}

/** Format with compact notation (1K, 1M, 1B) */
export function formatCompact(n: number | null | undefined, signed = false): string {
  if (n == null || !isFinite(n)) return '0';

  const absN = Math.abs(n);
  const sign = n < 0 ? '-' : signed ? '+' : '';

  if (absN >= 1_000_000_000_000) return `${sign}${round(absN / 1_000_000_000_000, 2)}T`;
  if (absN >= 1_000_000_000) return `${sign}${round(absN / 1_000_000_000, 2)}B`;
  if (absN >= 1_000_000) return `${sign}${round(absN / 1_000_000, 2)}M`;
  if (absN >= 1_000) return `${sign}${round(absN / 1_000, 2)}K`;

  return sign + formatNumber(absN);
}

/** Format price with appropriate decimals */
export function formatPrice(n: number | null | undefined): string {
  if (n == null || !isFinite(n)) return '0.00';

  const absN = Math.abs(n);

  if (absN >= 1000) {
    return n.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  if (absN >= 1) {
    const decimals = absN >= 100 ? 2 : absN >= 10 ? 3 : 4;
    return n.toFixed(decimals);
  }
  if (absN >= 0.001) {
    const leadingZeros = Math.floor(-Math.log10(absN));
    return n.toFixed(leadingZeros + 4);
  }

  // Use scientific notation for prices under 0.001 with 4 significant digits
  return n.toExponential(4);
}

/** Format for chart axis labels */
export function formatAxisLabel(n: number | null | undefined): string {
  if (n == null || !isFinite(n)) return '0';

  const absN = Math.abs(n);

  if (absN >= 1_000_000) return formatCompact(n);
  if (absN >= 10_000) return Math.round(n).toLocaleString('en-US');
  if (absN >= 100) return round(n, 1).toLocaleString('en-US');
  if (absN >= 10) return round(n, 2).toString();
  if (absN >= 1) return round(n, 3).toString();
  if (absN >= 0.001) {
    const leadingZeros = Math.floor(-Math.log10(absN));
    return n.toFixed(leadingZeros + 2);
  }
  // Use scientific notation for values under 0.001 with 4 significant digits
  if (absN > 0) return n.toExponential(4);

  return '0';
}

// ─────────────────────────────────────────────────────────────
// Percentages
// ─────────────────────────────────────────────────────────────

/** Format percentage value */
export function formatPercent(n: number | null | undefined, decimals = 2, signed = false): string {
  if (n == null || !isFinite(n)) return '0%';
  const sign = n > 0 && signed ? '+' : '';
  // Handle multipliers (>200% shown as Nx)
  if (Math.abs(n) >= 200) return `${sign}${round(n / 100, 1)}x`;
  return `${sign}${round(n, decimals)}%`;
}

// ─────────────────────────────────────────────────────────────
// Duration / Time
// ─────────────────────────────────────────────────────────────

/** Format milliseconds to human-readable duration */
export function formatDuration(ms: number | null | undefined): string {
  if (!ms || ms < 0) return '0ms';

  const s = ms / 1000;
  if (s < 1) return `${Math.round(ms)}ms`;
  if (s < 60) return `${round(s, 2)}s`;
  if (s < 3600) return `${round(s / 60, 2)}m`;
  if (s < 86400) return `${round(s / 3600, 2)}h`;
  if (s < 31536000) return `${round(s / 86400, 2)}d`;
  return `${round(s / 31536000, 2)}y`;
}

/** Format bytes to human-readable size */
export function formatBytes(bytes: number | null | undefined): string {
  if (!bytes || bytes === 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  const i = Math.floor(Math.log(bytes) / Math.log(1024));
  return `${round(bytes / Math.pow(1024, i), 2)} ${units[i]}`;
}

// ─────────────────────────────────────────────────────────────
// Text
// ─────────────────────────────────────────────────────────────

/** Shorten address/hash with ellipsis */
export function shortenAddress(address: string, start = 4, end = 4, sep = '...'): string {
  if (address.length <= start + end + 2) return address;
  return `${address.slice(0, 2 + start)}${sep}${address.slice(-end)}`;
}

/** Convert string to URL-friendly slug */
export function slugify(s: string, sep = '-'): string {
  return s
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9.\s-]/g, '')  // Keep dots for section numbers (1.1.1)
    .replace(/\.\s+/g, sep)          // "1.1.1. Something" -> "1.1.1-something"
    .replace(/[\s_]+/g, sep)
    .replace(new RegExp(`${sep}+`, 'g'), sep);
}

/** Slugify a doc file, handling category prefix for generic names like Overview */
export function slugifyDoc(filename: string, categoryPrefix?: string): string {
  const slug = slugify(filename);
  // Prefix generic names with category number to avoid collisions
  if (slug === 'overview' && categoryPrefix) {
    const match = categoryPrefix.match(/^(\d+)\./);
    if (match) return `${match[1]}-overview`;
  }
  return slug;
}

/** Convert slug back to readable string */
export function unslug(s: string, sep = '-'): string {
  return s
    .split(sep)
    .map(w => w.charAt(0).toUpperCase() + w.slice(1))
    .join(' ');
}

/** Capitalize first letter of each word */
export function capitalize(s: string): string {
  return s.replace(/\b\w/g, c => c.toUpperCase());
}

/**
 * Generate anchor ID from heading text.
 * Only strips the trailing ". " from section numbers (e.g., "7.1. Title" -> "7.1-title").
 *
 * @example
 * generateAnchorId("2.2. Spending Authorities") // "2.2-spending-authorities"
 * generateAnchorId("7.1. Cross-Chain Voting") // "7.1-cross-chain-voting"
 */
export function generateAnchorId(text: string): string {
  return text
    .toLowerCase()
    .replace(/^([\d.]+)\.\s+/, '$1-')  // Leading "X.Y. " -> "X.Y-" (only trailing dot of section number)
    .replace(/[^a-z0-9\s.-]/g, '')    // Remove special chars (keep dots, numbers, letters, spaces, dashes)
    .replace(/\s+/g, '-')              // Spaces to dashes
    .replace(/-+/g, '-')               // Collapse multiple dashes
    .replace(/^-|-$/g, '');            // Trim leading/trailing dashes
}

// ─────────────────────────────────────────────────────────────
// Parsing
// ─────────────────────────────────────────────────────────────

/** Parse formatted number string back to number */
export function parseFormattedNumber(value: string): number {
  if (!value) return 0;
  const cleaned = value.replace(/[^0-9.-]+/g, '');
  const num = parseFloat(cleaned);
  return isNaN(num) ? 0 : num;
}

// ─────────────────────────────────────────────────────────────
// Date/Time Formatting
// ─────────────────────────────────────────────────────────────

export const TIME_FORMATS = {
  TIME_24H: { hour12: false, hour: '2-digit', minute: '2-digit', second: '2-digit' },
  TIME_12H: { hour12: true, hour: '2-digit', minute: '2-digit', second: '2-digit' },
  DATE_LONG: { weekday: 'long', month: 'long', day: 'numeric' },
} as const;

/** Format timestamp as localized time */
export function formatTime(timestamp: number, format = TIME_FORMATS.TIME_24H): string {
  return new Date(timestamp).toLocaleTimeString('en-US', format);
}

/** Format timestamp as day header (TODAY/YESTERDAY/full date) */
export function formatDayHeader(timestamp: number): string {
  const date = new Date(timestamp);
  const today = new Date();
  const yesterday = new Date(today);
  yesterday.setDate(yesterday.getDate() - 1);

  today.setHours(0, 0, 0, 0);
  yesterday.setHours(0, 0, 0, 0);
  date.setHours(0, 0, 0, 0);

  if (date.getTime() === today.getTime()) return 'TODAY';
  if (date.getTime() === yesterday.getTime()) return 'YESTERDAY';

  return date.toLocaleDateString('en-US', TIME_FORMATS.DATE_LONG).toUpperCase();
}

/** Format timestamp as UTC date/time for chart vertical lines */
export function formatVerticalLineTime(timestamp: number): string {
  const date = new Date(timestamp * 1000);
  const day = date.getUTCDate().toString().padStart(2, '0');
  const month = (date.getUTCMonth() + 1).toString().padStart(2, '0');
  const hours = date.getUTCHours().toString().padStart(2, '0');
  const minutes = date.getUTCMinutes().toString().padStart(2, '0');
  return `${day}/${month} ${hours}:${minutes}`;
}

/** Format timestamp as relative time ("5m ago", "2h ago") */
export function formatTimeAgo(timestamp: number): string {
  const seconds = Math.floor((Date.now() - timestamp) / 1000);
  if (seconds < 60) return 'just now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h ago`;
  if (seconds < 604800) return `${Math.floor(seconds / 86400)}d ago`;
  return new Date(timestamp).toLocaleDateString();
}
