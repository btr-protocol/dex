import { createContext, JSX } from 'preact';
import { useContext, useEffect, useState } from 'preact/hooks';
import { ComponentChildren } from 'preact';

// ─────────────────────────────────────────────────────────────
// Color parsing + cache
// ─────────────────────────────────────────────────────────────

export interface ThemeColors {
  // Palette (used by charts)
  blue: string;
  green: string;
  orange: string;
  red: string;
  pink: string;
  cyan: string;
  // UI - Foreground/Background levels
  fg0: string;
  fg1: string;
  fg2: string;
  bg0: string;
  bg1: string;
  bg2: string;
  // Chart
  chartGrid: string;
  chartBorder: string;
  chartText: string;
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
  const result: Record<string, string> = {};

  for (const key of COLOR_PROPERTIES) {
    const cssVar = CSS_VAR_MAP[key];
    const value = styles.getPropertyValue(cssVar).trim();

    // Preserve alpha for chartText, parse to hex for others
    result[key] = key === 'chartText' ? value : parseColor(value);
  }

  // Verify all required properties exist
  const required: (keyof ThemeColors)[] = [
    'blue', 'green', 'orange', 'red', 'pink', 'cyan',
    'fg0', 'fg1', 'fg2', 'bg0', 'bg1', 'bg2',
    'chartGrid', 'chartBorder', 'chartText'
  ];

  for (const key of required) {
    if (!result[key]) {
      result[key] = '#000000'; // Fallback for missing colors
    }
  }

  return (result as unknown) as ThemeColors;
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
// Color Definitions - CSS Properties to Extract
// ─────────────────────────────────────────────────────────────

const COLOR_PROPERTIES = [
  'blue', 'green', 'orange', 'red', 'pink', 'cyan',
  'fg0', 'fg1', 'fg2', 'bg0', 'bg1', 'bg2',
  'chartGrid', 'chartBorder', 'chartText'
] as const;

const CSS_VAR_MAP: Record<string, string> = {
  // Palette
  blue: '--blue',
  green: '--green',
  orange: '--orange',
  red: '--red',
  pink: '--pink',
  cyan: '--cyan',
  // UI
  fg0: '--fg-0',
  fg1: '--fg-1',
  fg2: '--fg-2',
  bg0: '--bg-0',
  bg1: '--bg-1',
  bg2: '--bg-2',
  // Chart
  chartGrid: '--border-color',
  chartBorder: '--border-color',
  chartText: '--fg-3',
};

// ─────────────────────────────────────────────────────────────
// Chart Config Generators
// ─────────────────────────────────────────────────────────────

export const getChartTheme = () => {
  const c = getColors();
  return {
    layout: { background: { type: 'solid', color: c.bg2 }, textColor: c.fg2 },
    grid: { vertLines: { color: c.bg2 }, horzLines: { color: c.bg2 } },
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

export function ThemeProvider({ children }: { children: ComponentChildren }) {
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
  ) as JSX.Element;
}

export const useTheme = (): ThemeContextType => {
  const c = useContext(ThemeCtx);
  if (!c) throw new Error('No ThemeProvider');
  return c;
};
