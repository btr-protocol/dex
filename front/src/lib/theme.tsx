import { createContext } from 'preact';
import { useContext, useEffect, useState } from 'preact/hooks';
import type { ReactNode } from 'preact/compat';

// ─────────────────────────────────────────────────────────────
// Color parsing + cache
// ─────────────────────────────────────────────────────────────

export interface ThemeColors {
  // Palette
  blue: string; green: string; orange: string; red: string;
  yellow: string; cyan: string; pink: string; violet: string;
  // UI
  fg0: string; fg1: string; fg2: string; fg3: string;
  bg0: string; bg1: string; bg2: string; bg3: string;
  // Backgrounds - Sentiment
  bgGreen: string; bgRed: string; bgYellow: string; bgOrange: string; bgBlue: string;
  bgPositive: string; bgNegative: string;
  bgSuccess: string; bgError: string; bgWarning: string; bgInfo: string;
  bgPrimary: string; bgSecondary: string;
  border: string;
  // Sentiment
  success: string; error: string; warn: string; info: string;
  // Chart
  chartGrid: string; chartBorder: string; chartText: string;
}

let cache: ThemeColors | null = null;
let ctx: CanvasRenderingContext2D | null = null;
let dbPromise: Promise<IDBDatabase> | null = null;

// Open IndexedDB for color cache persistence
function openDB(): Promise<IDBDatabase> {
  if (dbPromise) return dbPromise;

  dbPromise = new Promise((resolve, reject) => {
    const req = indexedDB.open('btr-theme', 1);
    req.onerror = () => reject(req.error);
    req.onsuccess = () => resolve(req.result);
    req.onupgradeneeded = (e) => {
      const db = (e.target as IDBOpenDBRequest).result;
      if (!db.objectStoreNames.contains('colors')) {
        db.createObjectStore('colors');
      }
    };
  });

  return dbPromise;
}

// Load cached colors from IndexedDB
async function loadCachedColors(theme: string): Promise<ThemeColors | null> {
  try {
    const db = await openDB();
    return new Promise((resolve) => {
      const tx = db.transaction('colors', 'readonly');
      const req = tx.objectStore('colors').get(theme);
      req.onsuccess = () => resolve(req.result || null);
      req.onerror = () => resolve(null);
    });
  } catch {
    return null;
  }
}

// Save colors to IndexedDB
async function saveCachedColors(theme: string, colors: ThemeColors): Promise<void> {
  try {
    const db = await openDB();
    const tx = db.transaction('colors', 'readwrite');
    tx.objectStore('colors').put(colors, theme);
  } catch {
    // Silently fail - non-critical
  }
}

function ensureCtx(): CanvasRenderingContext2D | null {
  if (ctx) return ctx;
  const canvas = document.createElement('canvas');
  ctx = canvas.getContext('2d');
  return ctx;
}

function rgbToHex(r: number, g: number, b: number): string {
  const to = (x: number) => Math.max(0, Math.min(255, x))
    .toString(16)
    .padStart(2, '0');
  return `#${to(r)}${to(g)}${to(b)}`;
}

/**
 * Normalize any valid CSS color string to a 6‑digit hex string.
 * Fallback is #000000.
 */
function parseColor(value: string): string {
  const v = value.trim();
  if (!v) return '#000000';

  // Fast‑path for hex values
  if (v[0] === '#') {
    if (v.length === 4) {
      // #rgb → #rrggbb
      return `#${v[1]}${v[1]}${v[2]}${v[2]}${v[3]}${v[3]}`;
    }
    return v.toLowerCase();
  }

  // Handle color-mix() manually (browser canvas doesn't support it)
  const mixMatch = v.match(/color-mix\(in\s+srgb,\s*([^,]+?)\s+(\d+(?:\.\d+)?)%,\s*([^)]+)\)/i);
  if (mixMatch) {
    const color1 = mixMatch[1].trim();
    const pct1 = parseFloat(mixMatch[2]) / 100;
    const color2 = mixMatch[3].trim();

    // Parse both colors to hex first
    const hex1 = parseColor(color1);
    const hex2 = parseColor(color2);

    const r1 = parseInt(hex1.slice(1, 3), 16);
    const g1 = parseInt(hex1.slice(3, 5), 16);
    const b1 = parseInt(hex1.slice(5, 7), 16);

    const r2 = parseInt(hex2.slice(1, 3), 16);
    const g2 = parseInt(hex2.slice(3, 5), 16);
    const b2 = parseInt(hex2.slice(5, 7), 16);

    const r = Math.round(r1 * pct1 + r2 * (1 - pct1));
    const g = Math.round(g1 * pct1 + g2 * (1 - pct1));
    const b = Math.round(b1 * pct1 + b2 * (1 - pct1));

    return rgbToHex(r, g, b);
  }

  const context = ensureCtx();
  if (!context) return '#000000';

  // Let the browser normalize any CSS color syntax
  context.fillStyle = v;
  const normalized = String(context.fillStyle);

  // Already hex
  if (normalized[0] === '#') {
    if (normalized.length === 4) {
      return `#${normalized[1]}${normalized[1]}${normalized[2]}${normalized[2]}${normalized[3]}${normalized[3]}`;
    }
    return normalized.toLowerCase();
  }

  // Normalize rgb(a) to hex
  const rgbMatch = normalized.match(
    /^rgba?\(\s*([\d.]+)\s*,\s*([\d.]+)\s*,\s*([\d.]+)(?:\s*,\s*([\d.]+))?\s*\)$/i,
  );
  if (rgbMatch) {
    const r = Number(rgbMatch[1]);
    const g = Number(rgbMatch[2]);
    const b = Number(rgbMatch[3]);
    return rgbToHex(r, g, b);
  }

  // Handle color(srgb ...) format from browser
  const colorMatch = normalized.match(/^color\(srgb\s+([\d.]+)\s+([\d.]+)\s+([\d.]+)(?:\s+\/\s+([\d.]+))?\)$/i);
  if (colorMatch) {
    const r = Math.round(parseFloat(colorMatch[1]) * 255);
    const g = Math.round(parseFloat(colorMatch[2]) * 255);
    const b = Math.round(parseFloat(colorMatch[3]) * 255);
    return rgbToHex(r, g, b);
  }

  // Anything else
  console.warn('Failed to normalize color:', value, '->', normalized);
  return '#000000';
}

function computeColors(): ThemeColors {
  const root = document.documentElement;
  const styles = getComputedStyle(root);
  const get = (name: string) => parseColor(styles.getPropertyValue(name));
  const getRaw = (name: string) => styles.getPropertyValue(name).trim();

  return {
    blue: get('--blue'),
    green: get('--green'),
    orange: get('--orange'),
    red: get('--red'),
    yellow: get('--yellow'),
    cyan: get('--cyan'),
    pink: get('--pink'),
    violet: get('--violet'),

    fg0: get('--fg-0'),
    fg1: get('--fg-1'),
    fg2: get('--fg-2'),
    fg3: get('--fg-3'),

    bg0: get('--bg-0'),
    bg1: get('--bg-1'),
    bg2: get('--bg-2'),
    bg3: get('--bg-3'),

    bgGreen: get('--bg-green'),
    bgRed: get('--bg-red'),
    bgYellow: get('--bg-yellow'),
    bgOrange: get('--bg-orange'),
    bgBlue: get('--bg-blue'),
    bgPositive: get('--bg-positive'),
    bgNegative: get('--bg-negative'),
    bgSuccess: get('--bg-success'),
    bgError: get('--bg-error'),
    bgWarning: get('--bg-warning'),
    bgInfo: get('--bg-info'),
    bgPrimary: get('--bg-primary'),
    bgSecondary: get('--bg-secondary'),

    border: get('--border-color'),

    success: get('--fg-success'),
    error: get('--fg-error'),
    warn: get('--fg-warning'),
    info: get('--fg-info'),

    chartGrid: get('--border-color'),
    chartBorder: get('--border-color'),
    chartText: getRaw('--fg-3'), // Preserve alpha for chart axis labels
  };
}

export function getColors(): ThemeColors {
  if (cache) return cache;
  cache = computeColors();

  // Async: save to IndexedDB for next load
  const theme = document.documentElement.classList.contains('dark') ? 'dark' : 'light';
  saveCachedColors(theme, cache);

  return cache;
}

// Try to warm cache from IndexedDB on load
export async function warmColorCache(): Promise<void> {
  const theme = document.documentElement.classList.contains('dark') ? 'dark' : 'light';
  const cached = await loadCachedColors(theme);
  if (cached && !cache) {
    cache = cached;
  }
}

// ─────────────────────────────────────────────────────────────
// Chart Config Generators
// ─────────────────────────────────────────────────────────────

export const getChartTheme = () => {
  const c = getColors();
  return {
    layout: { background: { type: 'solid', color: c.bg0 }, textColor: c.fg2 },
    grid: { vertLines: { color: c.bg1 }, horzLines: { color: c.bg1 } },
    crosshair: {
      vertLine: { color: c.bg2, labelBackgroundColor: c.bg2, style: 2 },
      horzLine: { color: c.bg2, labelBackgroundColor: c.bg2, style: 2 }
    },
    rightPriceScale: { borderColor: c.bg2 },
    timeScale: { borderColor: c.bg2, timeVisible: true, secondsVisible: false }
  } as const;
};

export const getCandleColors = () => {
  const c = getColors();
  return {
    upColor: c.green, downColor: c.red,
    borderUpColor: c.green, borderDownColor: c.red,
    wickUpColor: c.green, wickDownColor: c.red
  };
};

// ─────────────────────────────────────────────────────────────
// Context
// ─────────────────────────────────────────────────────────────

const KEY = 'btr-theme';

interface ThemeContextType {
  theme: string;
  setTheme: (theme: string) => void;
  toggleTheme: () => void;
}

const ThemeCtx = createContext<ThemeContextType | null>(null);

export function ThemeProvider({ children }: { children: ReactNode }) {
  const [theme, setTheme] = useState(() => localStorage.getItem(KEY) || 'dark');

  useEffect(() => {
    const cl = document.documentElement.classList;
    cl.remove('light', 'dark');
    cl.add(theme);
    localStorage.setItem(KEY, theme);
    cache = null; // Invalidate cache
  }, [theme]);

  return (
    <ThemeCtx.Provider value={{
      theme,
      setTheme,
      toggleTheme: () => setTheme(t => t === 'dark' ? 'light' : 'dark')
    }}>
      {children}
    </ThemeCtx.Provider>
  );
}

export const useTheme = (): ThemeContextType => {
  const c = useContext(ThemeCtx);
  if (!c) throw new Error('No ThemeProvider');
  return c;
};
